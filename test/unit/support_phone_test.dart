import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/auth/support_phone.dart';

void main() {
  test(
    'SUPPORT-UI-001 normalizes an international number for a telephone link',
    () {
      final phone = SupportPhone.parse('+91 98765 43210');

      expect(phone?.display, '+91 98765 43210');
      expect(phone?.uri, Uri.parse('tel:+919876543210'));
    },
  );

  test(
    'SUPPORT-UI-002 rejects non-phone text, URI injection and unsafe lengths',
    () {
      for (final value in [
        null,
        '',
        '9876543210',
        'javascript:alert(1)',
        '+12',
        '+1234567890123456',
      ]) {
        expect(
          SupportPhone.parse(value),
          isNull,
          reason: '$value must not become a telephone link',
        );
      }
    },
  );
}
