import 'package:flutter_test/flutter_test.dart';
import 'package:hrms/features/attendance/punch_payload.dart';

void main() {
  // PUNCH-013: the Dart client must produce exactly the bytes the server
  // rebuilds. Expected hash computed from supabase/functions/_shared/punch.ts
  // with the same inputs.
  const vector = PunchPayload(
    challengeId: '11111111-1111-4111-8111-111111111111',
    nonce: 'AbCdEfGhIjKlMnOpQrStUv',
    operationKey: '22222222-2222-4222-8222-222222222222',
    employeeId: '33333333-3333-4333-8333-333333333333',
    deviceId: '44444444-4444-4444-8444-444444444444',
    action: 'IN',
    targetId: '55555555-5555-4555-8555-555555555555',
    officeId: '66666666-6666-4666-8666-666666666666',
    latitude: '12.9716000',
    longitude: '77.5946000',
    accuracy: '5.00',
    sampleAtMs: '1790700000000',
  );

  test('canonical payload hash matches the server implementation', () {
    expect(vector.sha256Hex, '4118b770573d1643d191ff20b2d04039ea35b4618de140e01fb3d456b5179d03');
  });

  test('uppercase UUIDs serialise identically', () {
    const upper = PunchPayload(
      challengeId: '11111111-1111-4111-8111-111111111111',
      nonce: 'AbCdEfGhIjKlMnOpQrStUv',
      operationKey: '22222222-2222-4222-8222-222222222222',
      employeeId: '33333333-3333-4333-8333-333333333333',
      deviceId: '44444444-4444-4444-8444-444444444444',
      action: 'IN',
      targetId: '55555555-5555-4555-8555-555555555555',
      officeId: '66666666-6666-4666-8666-666666666666',
      latitude: '12.9716000',
      longitude: '77.5946000',
      accuracy: '5.00',
      sampleAtMs: '1790700000000',
    );
    expect(upper.canonical, vector.canonical);
  });

  test('numeric formatting is fixed-point with exact decimals', () {
    expect(PunchPayload.lat(12.97160004), '12.9716000');
    expect(PunchPayload.lng(-77.5), '-77.5000000');
    expect(PunchPayload.acc(4.999), '5.00');
    expect(PunchPayload.acc(15), '15.00');
  });

  test('canonical form has 13 lines and no trailing newline', () {
    final lines = vector.canonical.split('\n');
    expect(lines, hasLength(13));
    expect(lines.first, 'hrms-punch-v1');
    expect(vector.canonical.endsWith('\n'), isFalse);
  });
}
