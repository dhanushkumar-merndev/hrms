import '../../core/widgets/app_icon.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/time/org_time.dart';
import '../../core/widgets/cards.dart';
import '../../core/widgets/states.dart';
import 'punch_controller.dart';

/// S04 — location-verified punch. The screen shows a provisional estimate;
/// only the server decides, and success appears only after its commit.
class PunchScreen extends ConsumerWidget {
  const PunchScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(punchProvider);
    final c = ref.read(punchProvider.notifier);
    final isOut = s.action == 'OUT';
    return Scaffold(
      appBar: AppBar(title: Text(s.action == null ? 'Punch' : (isOut ? 'Check out' : 'Check in'))),
      body: SafeArea(
        child: Column(children: [
          const OfflineBanner(),
          Expanded(
            child: ListView(padding: const EdgeInsets.all(AppSpacing.page), children: [
              if (s.shift != null) _ShiftSummary(shift: s.shift!),
              const SizedBox(height: AppSpacing.lg),
              Semantics(liveRegion: true, child: _Body(state: s, controller: c)),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Your location is used only while this screen is open, to confirm you are at your office. '
                'The server makes the final decision; distances here are estimates.',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ShiftSummary extends StatelessWidget {
  const _ShiftSummary({required this.shift});
  final Map<String, dynamic> shift;

  @override
  Widget build(BuildContext context) {
    final office = (shift['office'] as Map?)?.cast<String, dynamic>();
    return SectionCard(
      child: Row(children: [
        const AppIcon(Icons.schedule_rounded, color: AppColors.primary, size: 30),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(OrgTime.date(shift['shift_date'] as String?), style: Theme.of(context).textTheme.titleSmall),
            Text('${OrgTime.time(shift['start_at'])} – ${OrgTime.time(shift['end_at'])}'
                '${office != null ? ' · ${office['name']}' : ''}',
                style: Theme.of(context).textTheme.bodyMedium),
            if (shift['session_state'] == 'open')
              Text('Checked in at ${OrgTime.time(shift['effective_in_at'])}',
                  style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.w600)),
          ]),
        ),
      ]),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.controller});
  final PunchState state;
  final PunchController controller;

  @override
  Widget build(BuildContext context) {
    final s = state;
    final isOut = s.action == 'OUT';
    switch (s.phase) {
      case PunchPhase.checking:
        return const _Progress('Checking your shift and this phone…');
      case PunchPhase.registering:
        return const _Progress('Setting up secure punching on this phone…');
      case PunchPhase.acquiring:
        return const _Progress('Getting a precise location (up to 15 seconds)…');
      case PunchPhase.verifying:
        return const _Progress('Verifying with the server…');
      case PunchPhase.unavailable:
        return _Message(icon: Icons.event_busy_rounded, tone: AppColors.textSecondary, text: s.message ?? '',
            actions: [
              OutlinedButton(onPressed: () => context.pop(), child: const Text('Back')),
              if (s.shift?['blocked_reason'] == 'needs_correction' || s.shift?['blocked_reason'] == 'window_closed')
                FilledButton(
                  onPressed: () => context.push('/corrections/new?date=${s.shift?['shift_date']}'),
                  child: const Text('Request correction'),
                ),
            ]);
      case PunchPhase.needsDevice:
        return _DeviceSetup(state: s, onSetup: controller.registerDevice);
      case PunchPhase.locationPermission:
      case PunchPhase.locationDenied:
        return _Message(
          icon: Icons.location_on_outlined,
          tone: AppColors.primary,
          text: s.phase == PunchPhase.locationDenied
              ? 'Location permission was not allowed. It is needed to confirm you are at the office.'
              : 'Allow precise location while using the app so we can confirm you are at your office. '
                  'We never track you in the background.',
          actions: [FilledButton(onPressed: controller.requestLocation, child: const Text('Allow location'))],
        );
      case PunchPhase.locationDeniedForever:
        return _Message(
          icon: Icons.location_off_outlined,
          tone: AppColors.error,
          text: 'Location is blocked for this app. Open settings, choose Permissions › Location › '
              '"Allow only while using the app", and turn on Precise location.',
          actions: [
            FilledButton(onPressed: controller.openAppSettings, child: const Text('Open settings')),
            OutlinedButton(onPressed: controller.load, child: const Text('I\'ve allowed it')),
          ],
        );
      case PunchPhase.locationServiceOff:
        return _Message(
          icon: Icons.location_disabled_outlined,
          tone: AppColors.warning,
          text: 'Location is turned off on this phone. Turn it on to punch.',
          actions: [
            FilledButton(onPressed: controller.openLocationSettings, child: const Text('Turn on location')),
            OutlinedButton(onPressed: controller.load, child: const Text('Try again')),
          ],
        );
      case PunchPhase.approximateOnly:
        return _Message(
          icon: Icons.my_location_outlined,
          tone: AppColors.warning,
          text: 'Only approximate location is allowed. Turn on "Precise location" for this app to punch.',
          actions: [
            FilledButton(onPressed: controller.openAppSettings, child: const Text('Open settings')),
            OutlinedButton(onPressed: controller.load, child: const Text('Try again')),
          ],
        );
      case PunchPhase.ready:
        return _Ready(state: s, controller: controller, isOut: isOut);
      case PunchPhase.success:
        return _Success(result: s.result ?? const {});
      case PunchPhase.failure:
        return _Message(
          icon: Icons.error_outline_rounded,
          tone: AppColors.error,
          text: s.message ?? 'The punch was not recorded.',
          actions: [
            if (s.retryable) FilledButton(onPressed: controller.acquire, child: const Text('Try again')),
            OutlinedButton(
              onPressed: () => context.push('/corrections/new?date=${s.shift?['shift_date'] ?? ''}'),
              child: const Text('Request correction'),
            ),
          ],
        );
    }
  }
}

class _Progress extends StatelessWidget {
  const _Progress(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Row(children: [
        const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
        const SizedBox(width: AppSpacing.lg),
        Expanded(child: Text(text, style: Theme.of(context).textTheme.bodyLarge)),
      ]),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.tone, required this.text, this.actions = const []});
  final IconData icon;
  final Color tone;
  final String text;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AppIcon(icon, color: tone, size: 40),
        const SizedBox(height: AppSpacing.md),
        Text(text, style: Theme.of(context).textTheme.bodyLarge, textAlign: TextAlign.center),
        if (actions.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          for (final a in actions) Padding(padding: const EdgeInsets.only(top: AppSpacing.sm), child: a),
        ],
      ]),
    );
  }
}

class _DeviceSetup extends StatelessWidget {
  const _DeviceSetup({required this.state, required this.onSetup});
  final PunchState state;
  final VoidCallback onSetup;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const AppIcon(Icons.phonelink_lock_rounded, color: AppColors.primary, size: 40),
        const SizedBox(height: AppSpacing.md),
        Text('Set up this phone for punching', style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.md),
        Text(
          state.biometricRequired
              ? 'A security key is created inside this phone\'s secure chip. Every check-in and check-out will '
                  'ask for your fingerprint or face. Only one phone can be registered for you; registering this '
                  'one replaces any previous phone. If a new fingerprint is added to this phone later, you will '
                  'need to register again.'
              : 'A security key is created inside this phone\'s secure chip and used to sign each punch. '
                  'Only one phone can be registered for you.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (state.message != null) ...[
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(color: AppColors.warningSoft, borderRadius: BorderRadius.circular(12)),
            child: Text(state.message!, style: const TextStyle(color: AppColors.warning)),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        FilledButton.icon(onPressed: onSetup, icon: const AppIcon(Icons.fingerprint), label: const Text('Set up this phone')),
      ]),
    );
  }
}

class _Ready extends StatefulWidget {
  const _Ready({required this.state, required this.controller, required this.isOut});
  final PunchState state;
  final PunchController controller;
  final bool isOut;

  @override
  State<_Ready> createState() => _ReadyState();
}

class _ReadyState extends State<_Ready> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final office = s.office!;
    final p = s.sample!;
    final radius = (office['radius_m'] as num).toDouble();
    final maxAcc = (office['max_accuracy_m'] as num).toDouble();
    final age = DateTime.now().difference(p.timestamp).inSeconds;
    final inside = (s.distance ?? 1e9) <= radius;
    final accurate = p.accuracy <= maxAcc;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Location check (estimate)', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: AppSpacing.md),
          _Metric(
            icon: inside ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
            tone: inside ? AppColors.success : AppColors.warning,
            label: 'Distance to ${office['name']}',
            value: inside
                ? 'About ${s.distance!.toStringAsFixed(0)} m — inside the ${radius.toStringAsFixed(0)} m zone'
                : 'About ${s.distance!.toStringAsFixed(0)} m away — zone is ${radius.toStringAsFixed(0)} m',
          ),
          _Metric(
            icon: accurate ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
            tone: accurate ? AppColors.success : AppColors.warning,
            label: 'Accuracy',
            value: '±${p.accuracy.toStringAsFixed(0)} m${accurate ? '' : ' — needs ±${maxAcc.toStringAsFixed(0)} m or better'}',
          ),
          _Metric(
            icon: Icons.timer_outlined,
            tone: AppColors.textSecondary,
            label: 'Reading taken',
            value: age <= 1 ? 'just now' : '$age s ago (a fresh reading is taken when you confirm)',
          ),
          if (!accurate || !inside) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              !accurate
                  ? 'Indoor signal can be weak. Step near a window or outside, then refresh.'
                  : 'Move closer to the office entrance and refresh.',
              style: const TextStyle(color: AppColors.warning),
            ),
          ],
        ]),
      ),
      const SizedBox(height: AppSpacing.lg),
      FilledButton.icon(
        onPressed: widget.controller.submit,
        style: FilledButton.styleFrom(
          backgroundColor: widget.isOut ? AppColors.primary : AppColors.success,
          minimumSize: const Size.fromHeight(56),
          shape: const StadiumBorder(),
        ),
        icon: const AppIcon(Icons.fingerprint, size: 28),
        label: Text(widget.isOut ? 'Verify & check out' : 'Verify & check in', style: const TextStyle(fontSize: 18)),
      ),
      const SizedBox(height: AppSpacing.sm),
      OutlinedButton.icon(
        onPressed: widget.controller.acquire,
        icon: const AppIcon(Icons.refresh_rounded),
        label: const Text('Refresh location'),
      ),
    ]);
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.icon, required this.tone, required this.label, required this.value});
  final IconData icon;
  final Color tone;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        AppIcon(icon, color: tone, size: 22),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            Text(value, style: Theme.of(context).textTheme.bodyLarge),
          ]),
        ),
      ]),
    );
  }
}

class _Success extends StatelessWidget {
  const _Success({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final action = result['action'] == 'OUT' ? 'Checked out' : 'Checked in';
    final late = result['is_late'] == true;
    return SectionCard(
      color: AppColors.successSoft,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const AppIcon(Icons.verified_rounded, color: AppColors.success, size: 56),
        const SizedBox(height: AppSpacing.md),
        Text('$action at ${OrgTime.time(result['server_time'])}',
            style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.sm),
        Text('Recorded by the server · ${result['distance_m']} m from the office${late ? ' · marked late' : ''}',
            style: Theme.of(context).textTheme.bodyMedium, textAlign: TextAlign.center),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(onPressed: () => context.pop(), child: const Text('Done')),
      ]),
    );
  }
}
