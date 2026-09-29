// Canonical punch payload v1 and device signature verification.
//
// The exact UTF-8 bytes signed by the device key (ECDSA P-256, SHA-256):
//   lines joined by "\n", no trailing newline, UUIDs lowercase:
//   hrms-punch-v1
//   <challenge_id> <nonce> <operation_key> <employee_id> <device_id>
//   <action IN|OUT> <target_id> <office_id>
//   <latitude, 7 decimals> <longitude, 7 decimals> <accuracy m, 2 decimals>
//   <sample time, epoch milliseconds>
// Numbers travel as these exact decimal strings (never JSON floats) so client
// and server serialise identically. Mirrors hrms.punch_payload_v1 and the
// Dart PunchPayload.
import { ApiError, b64ToBytes } from "./http.ts";

export interface PunchFields {
  challengeId: string;
  nonce: string;
  operationKey: string;
  employeeId: string;
  deviceId: string;
  action: "IN" | "OUT";
  targetId: string;
  officeId: string;
  latitude: string;
  longitude: string;
  accuracy: string;
  sampleAtMs: string;
}

const LAT_RE = /^-?\d{1,2}\.\d{7}$/;
const LNG_RE = /^-?\d{1,3}\.\d{7}$/;
const ACC_RE = /^\d{1,4}\.\d{2}$/;
const MS_RE = /^\d{13}$/;
const NONCE_RE = /^[A-Za-z0-9_-]{16,128}$/;

export function validatePunchFields(f: PunchFields): void {
  const errors: Record<string, string> = {};
  if (f.action !== "IN" && f.action !== "OUT") errors.action = "IN or OUT";
  if (!LAT_RE.test(f.latitude) || Math.abs(Number(f.latitude)) > 90) errors.latitude = "Invalid";
  if (!LNG_RE.test(f.longitude) || Math.abs(Number(f.longitude)) > 180) errors.longitude = "Invalid";
  if (!ACC_RE.test(f.accuracy)) errors.accuracy = "Invalid";
  if (!MS_RE.test(f.sampleAtMs)) errors.sample_at_ms = "Invalid";
  if (!NONCE_RE.test(f.nonce)) errors.nonce = "Invalid";
  if (Object.keys(errors).length) {
    throw new ApiError("LOCATION_REQUIRED", "A valid location reading is required.", 400, errors);
  }
}

export function canonicalPayloadV1(f: PunchFields): string {
  return [
    "hrms-punch-v1",
    f.challengeId.toLowerCase(),
    f.nonce,
    f.operationKey.toLowerCase(),
    f.employeeId.toLowerCase(),
    f.deviceId.toLowerCase(),
    f.action,
    f.targetId.toLowerCase(),
    f.officeId.toLowerCase(),
    f.latitude,
    f.longitude,
    f.accuracy,
    f.sampleAtMs,
  ].join("\n");
}

/** Converts a DER ECDSA signature (Android/Java format) to IEEE P1363
 * (r || s) as WebCrypto expects. */
export function derToP1363(der: Uint8Array, size = 32): Uint8Array<ArrayBuffer> {
  let i = 0;
  if (der[i++] !== 0x30) throw new Error("not a DER sequence");
  let len = der[i++];
  if (len & 0x80) {
    const n = len & 0x7f;
    len = 0;
    for (let k = 0; k < n; k++) len = (len << 8) | der[i++];
  }
  const readInt = (): Uint8Array => {
    if (der[i++] !== 0x02) throw new Error("expected INTEGER");
    const l = der[i++];
    let v = der.slice(i, i + l);
    i += l;
    while (v.length > size && v[0] === 0) v = v.slice(1);
    if (v.length > size) throw new Error("integer too long");
    const out = new Uint8Array(size);
    out.set(v, size - v.length);
    return out;
  };
  const r = readInt();
  const s = readInt();
  const out = new Uint8Array(size * 2);
  out.set(r, 0);
  out.set(s, size);
  return out;
}

/** Verifies the device signature over the canonical payload bytes. */
export async function verifyDeviceSignature(spkiB64: string, signatureB64: string, payload: string): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      "spki",
      b64ToBytes(spkiB64),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    const sigBytes = b64ToBytes(signatureB64);
    const raw: Uint8Array<ArrayBuffer> = sigBytes.length === 64 ? sigBytes : derToP1363(sigBytes);
    return await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      raw,
      new TextEncoder().encode(payload),
    );
  } catch {
    return false;
  }
}
