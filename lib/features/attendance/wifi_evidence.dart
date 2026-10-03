enum WifiEvidenceMode { connected, nearby, missing, notRequired }

class WifiEvidence {
  const WifiEvidence(this.mode, {this.matchedSsid});

  final WifiEvidenceMode mode;
  final String? matchedSsid;
}

WifiEvidence classifyOfficeWifi(
  List<String> accepted,
  String? connected,
  List<String> nearby,
) {
  final configured = <String>{};
  for (final value in accepted) {
    final cleaned = _clean(value);
    if (cleaned != null) configured.add(cleaned.toLowerCase());
  }
  if (configured.isEmpty) {
    return const WifiEvidence(WifiEvidenceMode.notRequired);
  }

  final connectedName = _clean(connected);
  if (connectedName != null &&
      configured.contains(connectedName.toLowerCase())) {
    return WifiEvidence(WifiEvidenceMode.connected, matchedSsid: connectedName);
  }

  final seen = <String>{};
  for (final value in nearby) {
    final cleaned = _clean(value);
    if (cleaned == null) continue;
    final normalized = cleaned.toLowerCase();
    if (!seen.add(normalized)) continue;
    if (configured.contains(normalized)) {
      return WifiEvidence(WifiEvidenceMode.nearby, matchedSsid: cleaned);
    }
  }
  return const WifiEvidence(WifiEvidenceMode.missing);
}

String? _clean(String? value) {
  final cleaned = value?.trim();
  if (cleaned == null || cleaned.isEmpty) return null;
  return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
}
