import 'package:geolocator/geolocator.dart';

enum LocationAccess { granted, approximateOnly, denied, deniedForever, serviceOff }

/// Foreground, on-demand location for the punch screen only. No background
/// permission, no continuous tracking; the stream is never left running.
class LocationService {
  const LocationService();

  Future<LocationAccess> check() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceOff;
    final p = await Geolocator.checkPermission();
    return _map(p, await _precise(p));
  }

  Future<LocationAccess> request() async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationAccess.serviceOff;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
    return _map(p, await _precise(p));
  }

  Future<bool> _precise(LocationPermission p) async {
    if (p != LocationPermission.whileInUse && p != LocationPermission.always) return false;
    try {
      return await Geolocator.getLocationAccuracy() == LocationAccuracyStatus.precise;
    } catch (_) {
      return true;
    }
  }

  LocationAccess _map(LocationPermission p, bool precise) => switch (p) {
        LocationPermission.whileInUse || LocationPermission.always =>
          precise ? LocationAccess.granted : LocationAccess.approximateOnly,
        LocationPermission.deniedForever => LocationAccess.deniedForever,
        _ => LocationAccess.denied,
      };

  /// A fresh high-accuracy fix, bounded by [timeout] (initial target 15 s).
  Future<Position> freshSample({Duration timeout = const Duration(seconds: 15)}) {
    return Geolocator.getCurrentPosition(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        timeLimit: timeout,
        forceLocationManager: false,
      ),
    );
  }

  double distanceMeters(double lat1, double lng1, double lat2, double lng2) =>
      Geolocator.distanceBetween(lat1, lng1, lat2, lng2);

  Future<void> openLocationSettings() => Geolocator.openLocationSettings();
  Future<void> openAppSettings() => Geolocator.openAppSettings();
}
