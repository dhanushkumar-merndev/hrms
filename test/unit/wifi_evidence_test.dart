import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/attendance/wifi_evidence.dart';

void main() {
  test('connected office Wi-Fi wins case-insensitively', () {
    final evidence = classifyOfficeWifi(
      const ['Airtel_Office'],
      '  airtel_office  ',
      const ['Airtel_Office'],
    );

    expect(evidence.mode, WifiEvidenceMode.connected);
    expect(evidence.matchedSsid, 'airtel_office');
  });

  test('nearby office Wi-Fi is distinct from the connected network', () {
    final evidence = classifyOfficeWifi(
      const ['Office 5G'],
      'Personal hotspot',
      const ['Coffee Shop', 'Office 5G'],
    );

    expect(evidence.mode, WifiEvidenceMode.nearby);
    expect(evidence.matchedSsid, 'Office 5G');
  });

  test('configured office Wi-Fi can be missing', () {
    final evidence = classifyOfficeWifi(
      const ['Office'],
      null,
      const ['Neighbour'],
    );

    expect(evidence.mode, WifiEvidenceMode.missing);
    expect(evidence.matchedSsid, isNull);
  });

  test('empty policy does not require Wi-Fi', () {
    final evidence = classifyOfficeWifi(
      const ['', '   '],
      'Anything',
      const ['Anything'],
    );

    expect(evidence.mode, WifiEvidenceMode.notRequired);
  });

  test('blank and duplicate scan names are ignored', () {
    final evidence = classifyOfficeWifi(
      const ['Office'],
      ' ',
      const ['', 'office', ' OFFICE '],
    );

    expect(evidence.mode, WifiEvidenceMode.nearby);
    expect(evidence.matchedSsid, 'office');
  });
}
