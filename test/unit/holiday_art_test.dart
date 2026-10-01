import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/leave/leave_screen.dart';

void main() {
  test('first 21 holidays use distinct illustration assets', () {
    final art = [for (var i = 0; i < 21; i++) holidayIllustrationNumber(i, 2026)];

    expect(art.toSet(), hasLength(21));
    expect(art.every((number) => number >= 1 && number <= 21), isTrue);
  });
}
