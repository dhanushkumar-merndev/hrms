import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wifi_scan/wifi_scan.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/auth/secure_session_storage.dart';
import '../../core/auth/session_controller.dart';
import '../../core/device/device_key.dart';
import '../../core/location/location_service.dart';
import '../home/home_providers.dart';
import 'punch_payload.dart';

enum PunchPhase {
  checking,
  unavailable,
  needsDevice,
  registering,
  locationPermission,
  locationDenied,
  locationDeniedForever,
  locationServiceOff,
  approximateOnly,
  acquiring,
  ready,
  verifying,
  success,
  failure,
}

class PunchState {
  const PunchState(
    this.phase, {
    this.message,
    this.shift,
    this.action,
    this.sample,
    this.distance,
    this.result,
    this.retryable = true,
    this.biometricRequired = true,
  });

  final PunchPhase phase;
  final String? message;
  final Map<String, dynamic>? shift;
  final String? action;
  final Position? sample;
  final double? distance;
  final Map<String, dynamic>? result;
  final bool retryable;
  final bool biometricRequired;

  Map<String, dynamic>? get office => (shift?['office'] as Map?)?.cast<String, dynamic>();

  PunchState copy({
    PunchPhase? phase,
    String? message,
    Position? sample,
    double? distance,
    Map<String, dynamic>? result,
    bool? retryable,
  }) =>
      PunchState(
        phase ?? this.phase,
        message: message,
        shift: shift,
        action: action,
        sample: sample ?? this.sample,
        distance: distance ?? this.distance,
        result: result ?? this.result,
        retryable: retryable ?? this.retryable,
        biometricRequired: biometricRequired,
      );
}

/// S04 punch flow. The UI only ever shows success after the server commit.
class PunchController extends Notifier<PunchState> {
  static const _pendingKey = 'hrms.pending_punch';
  final _location = const LocationService();
  final _deviceKey = const DeviceKey();

  ApiClient get _api => ref.read(apiProvider);
  SessionContext get _session => ref.read(sessionContextProvider)!;
  String get _alias => DeviceKey.aliasFor(_session.employeeId);

  @override
  PunchState build() {
    Future.microtask(load);
    return const PunchState(PunchPhase.checking);
  }

  Future<void> load() async {
    state = const PunchState(PunchPhase.checking);
    try {
      await reconcilePending();
      final summary = await ref.refresh(homeSummaryProvider.future);
      final shift = (summary['shift'] as Map?)?.cast<String, dynamic>();
      final action = shift?['next_action'] as String?;
      final org = (summary['org'] as Map).cast<String, dynamic>();
      final biometric = org['require_biometric_punch'] != false;
      if (shift == null || action == null) {
        state = PunchState(PunchPhase.unavailable,
            shift: shift, message: _unavailableMessage(shift), biometricRequired: biometric);
        return;
      }
      if (shift['office'] == null) {
        state = PunchState(PunchPhase.unavailable,
            shift: shift, message: 'No office is assigned to you yet. Contact HR.', biometricRequired: biometric);
        return;
      }
      state = PunchState(PunchPhase.checking, shift: shift, action: action, biometricRequired: biometric);

      // This installation must hold the registered, still-valid device key.
      final device = (summary['device'] as Map?)?.cast<String, dynamic>();
      final status = await _deviceKey.status(_alias);
      final installation = await Installation.id();
      final registeredHere = device != null && device['installation_id'] == installation;
      if (!registeredHere || !status.keyUsable || (biometric && device['biometric_bound'] != true && status.keyBiometricBound == false)) {
        state = PunchState(PunchPhase.needsDevice, shift: shift, action: action, biometricRequired: biometric,
            message: !status.biometricReady && biometric ? _biometricMessage(status.biometric) : null);
        return;
      }
      await _checkLocation();
    } on DeviceKeyException catch (e) {
      state = PunchState(PunchPhase.unavailable, message: e.message);
    } on ApiException catch (e) {
      state = PunchState(PunchPhase.failure, message: e.message, retryable: true);
    }
  }

  Future<void> _checkLocation({bool request = false}) async {
    final access = request ? await _location.request() : await _location.check();
    switch (access) {
      case LocationAccess.granted:
        await acquire();
      case LocationAccess.approximateOnly:
        state = state.copy(phase: PunchPhase.approximateOnly);
      case LocationAccess.denied:
        state = state.copy(phase: request ? PunchPhase.locationDenied : PunchPhase.locationPermission);
      case LocationAccess.deniedForever:
        state = state.copy(phase: PunchPhase.locationDeniedForever);
      case LocationAccess.serviceOff:
        state = state.copy(phase: PunchPhase.locationServiceOff);
    }
  }

  Future<void> requestLocation() => _checkLocation(request: true);
  Future<void> openAppSettings() => _location.openAppSettings();
  Future<void> openLocationSettings() => _location.openLocationSettings();

  /// Provisional reading for display only; the server decides.
  Future<void> acquire() async {
    state = state.copy(phase: PunchPhase.acquiring);
    try {
      final p = await _location.freshSample();
      final office = state.office!;
      final d = _location.distanceMeters(
          p.latitude, p.longitude, (office['latitude'] as num).toDouble(), (office['longitude'] as num).toDouble());
      state = state.copy(phase: PunchPhase.ready, sample: p, distance: d);
    } catch (_) {
      state = state.copy(
        phase: PunchPhase.failure,
        message: 'Could not get a precise location. Move near a window or outdoors, then try again.',
        retryable: true,
      );
    }
  }

  /// Registers this phone: server nonce -> attested key -> verification.
  Future<void> registerDevice() async {
    final prev = state;
    state = prev.copy(phase: PunchPhase.registering);
    try {
      final status = await _deviceKey.status(_alias);
      if (prev.biometricRequired && !status.biometricReady) {
        state = PunchState(PunchPhase.needsDevice, shift: prev.shift, action: prev.action,
            biometricRequired: prev.biometricRequired, message: _biometricMessage(status.biometric));
        return;
      }
      final challenge = (await _api.rpc('create_device_challenge')).map;
      final nonce = challenge['nonce'] as String;
      final chain = await _deviceKey.generate(_alias, Uint8List.fromList(utf8.encode(nonce)),
          requireBiometric: prev.biometricRequired);
      await _api.function('device-register', {
        'challenge_id': challenge['challenge_id'],
        'nonce': nonce,
        'installation_id': await Installation.id(),
        'platform': 'android',
        'certificate_chain': chain,
        'device_label': status.model,
      });
      await load();
    } on DeviceKeyException catch (e) {
      state = PunchState(PunchPhase.needsDevice, shift: prev.shift, action: prev.action,
          biometricRequired: prev.biometricRequired, message: e.message);
    } on ApiException catch (e) {
      state = PunchState(PunchPhase.needsDevice, shift: prev.shift, action: prev.action,
          biometricRequired: prev.biometricRequired, message: e.message);
    }
  }

  /// Nonce first, then a FRESH sample, then the biometric-bound signature
  /// over the canonical payload, then the server commit.
  Future<void> submit() async {
    final s = state;
    final shift = s.shift!;
    final action = s.action!;
    final targetId = (action == 'IN' ? shift['instance_id'] : shift['session_id']) as String;
    final summary = ref.read(homeSummaryProvider).value;
    final device = (summary?['device'] as Map?)?.cast<String, dynamic>();
    if (device == null) {
      state = s.copy(phase: PunchPhase.needsDevice);
      return;
    }
    final operationKey = ApiClient.newOperationKey();
    state = s.copy(phase: PunchPhase.verifying);
    // Scan for office Wi-Fi in parallel with the challenge and fingerprint.
    final wifi = _wifiInfo();
    try {
      await SecureSessionStorage.storage.write(
          key: _pendingKey, value: jsonEncode({'key': operationKey, 'action': action, 'employee': _session.employeeId}));

      final challenge = (await _api.rpc('create_punch_challenge', {
        'p_action': action,
        'p_target_id': targetId,
        'p_device_id': device['device_id'],
      }))
          .map;
      final serverNow = DateTime.parse(challenge['server_time'] as String).toUtc();
      final skewMs = serverNow.millisecondsSinceEpoch - DateTime.now().toUtc().millisecondsSinceEpoch;

      // Fingerprint first, then a fresh reading: time at the prompt never
      // makes the location stale (server allows only a few seconds).
      await _deviceKey.authorize(_alias,
          title: action == 'IN' ? 'Confirm check-in' : 'Confirm check-out',
          subtitle: 'Use your fingerprint or face to verify it is you');
      final sample = await _location.freshSample();
      final sampleMs = sample.timestamp.toUtc().millisecondsSinceEpoch + skewMs;
      final payload = PunchPayload(
        challengeId: challenge['challenge_id'] as String,
        nonce: challenge['nonce'] as String,
        operationKey: operationKey,
        employeeId: _session.employeeId,
        deviceId: device['device_id'] as String,
        action: action,
        targetId: targetId,
        officeId: (shift['office'] as Map)['id'] as String,
        latitude: PunchPayload.lat(sample.latitude),
        longitude: PunchPayload.lng(sample.longitude),
        accuracy: PunchPayload.acc(sample.accuracy.clamp(0, 9999.99).toDouble()),
        sampleAtMs: sampleMs.toString(),
      );
      final signature = await _deviceKey.signAuthorized(Uint8List.fromList(payload.bytes));

      final res = await _api.function(
          'punch', payload.toRequest(signature, isMocked: sample.isMocked, wifiSsid: (await wifi).$1, wifiNearby: (await wifi).$2));
      await _finish(res.map);
    } on DeviceKeyException catch (e) {
      await _clearPending();
      state = s.copy(
        phase: e.invalidated ? PunchPhase.needsDevice : PunchPhase.ready,
        message: e.cancelled ? 'Verification cancelled.' : e.message,
      );
    } on ApiException catch (e) {
      if (e.isNetwork) {
        // The commit may have happened: recover by operation key first.
        final recovered = await reconcilePending();
        if (!recovered) {
          state = s.copy(phase: PunchPhase.failure, message: e.message, retryable: true);
        }
      } else {
        await _clearPending();
        state = s.copy(phase: PunchPhase.failure, message: e.message, retryable: e.retryable || _retryableCode(e.code));
      }
    } catch (_) {
      await _clearPending();
      await _deviceKey.clearAuthorized();
      state = s.copy(
          phase: PunchPhase.failure,
          message: 'Could not get a fresh precise location. Move to a spot with better signal and retry.',
          retryable: true);
    }
  }

  Future<void> _finish(Map<String, dynamic> res) async {
    await _clearPending();
    if (res['ok'] == true) {
      ref.invalidate(homeSummaryProvider);
      state = state.copy(phase: PunchPhase.success, result: (res['data'] as Map).cast<String, dynamic>());
    } else {
      final err = (res['error'] as Map?)?.cast<String, dynamic>() ?? const {};
      state = state.copy(
        phase: PunchPhase.failure,
        message: err['message'] as String? ?? 'The punch was not accepted.',
        retryable: err['retryable'] == true,
      );
    }
  }

  /// Recovers a punch whose response was lost (app killed / network drop).
  /// Returns true if a committed result was found and shown.
  Future<bool> reconcilePending() async {
    final raw = await SecureSessionStorage.storage.read(key: _pendingKey);
    if (raw == null) return false;
    final pending = (jsonDecode(raw) as Map).cast<String, dynamic>();
    if (pending['employee'] != ref.read(sessionContextProvider)?.employeeId) {
      await _clearPending();
      return false;
    }
    try {
      final res = (await _api.rpc('get_punch_operation', {'p_operation_key': pending['key']})).map;
      await _clearPending();
      if (res['found'] == true) {
        final result = (res['result'] as Map).cast<String, dynamic>();
        ref.invalidate(homeSummaryProvider);
        state = state.copy(phase: PunchPhase.success, result: (result['data'] as Map).cast<String, dynamic>());
        return true;
      }
    } on ApiException catch (e) {
      if (!e.isNetwork) await _clearPending();
    }
    return false;
  }

  /// Connected Wi-Fi name (Android wraps it in quotes) and the Wi-Fi names
  /// seen nearby. The server accepts the punch when either matches the
  /// office list, so being at the office is enough even on mobile data.
  /// Android throttles scans; the last system scan is used when a new one is refused.
  static Future<(String?, List<String>)> _wifiInfo() async {
    String? connected;
    try {
      final name = (await NetworkInfo().getWifiName())?.replaceAll('"', '').trim();
      connected = name == null || name.isEmpty || name == '<unknown ssid>' ? null : name;
    } catch (_) {}
    final nearby = <String>{};
    try {
      final scan = WiFiScan.instance;
      if (await scan.canStartScan() == CanStartScan.yes) {
        await scan.startScan();
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (await scan.canGetScannedResults() == CanGetScannedResults.yes) {
        for (final ap in await scan.getScannedResults()) {
          final n = ap.ssid.trim();
          if (n.isNotEmpty) nearby.add(n.length > 64 ? n.substring(0, 64) : n);
          if (nearby.length >= 30) break;
        }
      }
    } catch (_) {}
    return (connected, nearby.toList());
  }

  Future<void> _clearPending() => SecureSessionStorage.storage.delete(key: _pendingKey);

  static bool _retryableCode(String code) =>
      const {'OUTSIDE_ZONE', 'WIFI_REQUIRED', 'LOCATION_INACCURATE', 'LOCATION_STALE', 'VERIFICATION_FAILED', 'RATE_LIMITED'}.contains(code);

  static String _unavailableMessage(Map<String, dynamic>? shift) {
    if (shift == null) return 'No shift is scheduled for you today.';
    return switch (shift['blocked_reason']) {
      'outside_work' =>
        'Outside work today${shift['outside_reason'] == null ? '' : ' (${shift['outside_reason']})'}. No check-in or check-out is needed.',
      'on_leave' => 'You are on approved leave today.',
      'holiday' => 'Happy holiday! No check-in or check-out is needed today.',
      'weekly_off' => 'Today is your weekly off.',
      'day_off' => 'Today is a day off for you.',
      'not_open_yet' => 'Check-in opens a little before your shift starts.',
      'window_closed' => 'The check-in window for this shift has closed. Request a correction if you worked.',
      'completed' => 'You have already completed today\'s shift.',
      'needs_correction' => 'This shift needs a correction. Use "Fix a punch".',
      _ => 'Punching is not available right now.',
    };
  }

  static String _biometricMessage(String biometric) => switch (biometric) {
        'none_enrolled' => 'Set up fingerprint or face unlock in your phone settings, then come back.',
        'no_hardware' => 'This phone has no fingerprint or face sensor. Ask your Admin about punching options.',
        'update_required' => 'Install the latest security update on this phone, then try again.',
        _ => 'Fingerprint/face verification is not available on this phone right now.',
      };
}

final punchProvider = NotifierProvider.autoDispose<PunchController, PunchState>(PunchController.new);
