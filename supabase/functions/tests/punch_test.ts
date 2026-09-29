// PUNCH-013 / LOC-009: canonical payload and device signature verification.
import { assert, assertEquals, assertThrows } from "jsr:@std/assert@1";
import { bytesToB64 } from "../_shared/http.ts";
import { canonicalPayloadV1, derToP1363, type PunchFields, validatePunchFields, verifyDeviceSignature } from "../_shared/punch.ts";

const base: PunchFields = {
  challengeId: "11111111-1111-4111-8111-111111111111",
  nonce: "AbCdEfGhIjKlMnOpQrStUv",
  operationKey: "22222222-2222-4222-8222-222222222222",
  employeeId: "33333333-3333-4333-8333-333333333333",
  deviceId: "44444444-4444-4444-8444-444444444444",
  action: "IN",
  targetId: "55555555-5555-4555-8555-555555555555",
  officeId: "66666666-6666-4666-8666-666666666666",
  latitude: "12.9716000",
  longitude: "77.5946000",
  accuracy: "5.00",
  sampleAtMs: "1790700000000",
};

Deno.test("canonical payload v1 has exact field order and no trailing newline", () => {
  const p = canonicalPayloadV1(base);
  const lines = p.split("\n");
  assertEquals(lines.length, 13);
  assertEquals(lines[0], "hrms-punch-v1");
  assertEquals(lines[6], "IN");
  assertEquals(lines[9], "12.9716000");
  assertEquals(lines[12], "1790700000000");
  assert(!p.endsWith("\n"));
});

Deno.test("canonical payload lowercases uuids so client and server agree", () => {
  const upper = { ...base, deviceId: base.deviceId.toUpperCase() };
  assertEquals(canonicalPayloadV1(upper), canonicalPayloadV1(base));
});

Deno.test("numeric encodings are strict (no floats, exponents or missing decimals)", () => {
  for (const latitude of ["12.9716", "1.2e1", "12.97160000", "91.0000000", "abc"]) {
    assertThrows(() => validatePunchFields({ ...base, latitude }));
  }
  for (const accuracy of ["5", "5.0", "-1.00", "NaN"]) {
    assertThrows(() => validatePunchFields({ ...base, accuracy }));
  }
  assertThrows(() => validatePunchFields({ ...base, sampleAtMs: "1790700000" }));
  validatePunchFields(base);
});

function p1363ToDer(raw: Uint8Array): Uint8Array {
  const int = (b: Uint8Array) => {
    let v = Array.from(b);
    while (v.length > 1 && v[0] === 0) v = v.slice(1);
    if (v[0] & 0x80) v = [0, ...v];
    return [0x02, v.length, ...v];
  };
  const body = [...int(raw.slice(0, 32)), ...int(raw.slice(32))];
  return new Uint8Array([0x30, body.length, ...body]);
}

Deno.test("DER <-> P1363 conversion round-trips", () => {
  const raw = crypto.getRandomValues(new Uint8Array(64));
  raw[0] = 0x80; // force a leading-zero pad in DER
  raw[32] = 0x00; // and a stripped leading zero
  assertEquals(derToP1363(p1363ToDer(raw)), raw);
});

Deno.test("device signature verifies only the exact payload (DER as Android sends)", async () => {
  const keys = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const spki = bytesToB64(new Uint8Array(await crypto.subtle.exportKey("spki", keys.publicKey)));
  const payload = canonicalPayloadV1(base);
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, keys.privateKey,
    new TextEncoder().encode(payload)));
  const der = bytesToB64(p1363ToDer(raw));
  assert(await verifyDeviceSignature(spki, der, payload), "valid DER signature");
  assert(await verifyDeviceSignature(spki, bytesToB64(raw), payload), "valid raw signature");
  // Tampering with any bound field fails.
  for (const tampered of [
    { ...base, latitude: "12.9716001" },
    { ...base, action: "OUT" as const },
    { ...base, nonce: "AbCdEfGhIjKlMnOpQrStUw" },
    { ...base, deviceId: "44444444-4444-4444-8444-444444444445" },
    { ...base, accuracy: "5.01" },
  ]) {
    assert(!(await verifyDeviceSignature(spki, der, canonicalPayloadV1(tampered))), "tampered payload rejected");
  }
  assert(!(await verifyDeviceSignature(spki, "not-base64!!", payload)), "garbage signature rejected");
});
