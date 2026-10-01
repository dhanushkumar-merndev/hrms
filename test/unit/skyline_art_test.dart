import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/home/home_screen.dart';

void main() {
  test('home uses four distinct skyline SVGs for its four day phases', () {
    final assets = [
      homeSkylineAsset(DateTime(2026, 10, 2, 8)),
      homeSkylineAsset(DateTime(2026, 10, 2, 14)),
      homeSkylineAsset(DateTime(2026, 10, 2, 18)),
      homeSkylineAsset(DateTime(2026, 10, 2, 22)),
    ];

    expect(assets, [
      'assets/illustrations/skyline_morning.svg',
      'assets/illustrations/skyline_afternoon.svg',
      'assets/illustrations/skyline.svg',
      'assets/illustrations/skyline_night.svg',
    ]);
    expect(assets.toSet(), hasLength(4));
    for (final asset in assets) {
      expect(
        File(asset).existsSync(),
        isTrue,
        reason: '$asset must be bundled',
      );
      expect(File(asset).readAsStringSync(), contains('<svg'));
    }
  });
}
