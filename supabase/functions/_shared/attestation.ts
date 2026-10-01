// Android Key Attestation verification (store-independent device integrity).
//
// The app generates a non-exportable EC P-256 key in the Android Keystore
// with the server's registration nonce as the attestation challenge. The
// secure hardware signs a certificate chain whose leaf carries the
// KeyDescription extension (OID 1.3.6.1.4.1.11129.2.1.17). We verify:
//   * every certificate signature up the chain,
//   * the root public key is one of Google's attestation roots,
//   * no certificate is on Google's revocation/suspension list,
//   * the attested challenge equals our single-use nonce,
//   * the key lives in a TEE/StrongBox, verified boot is "Verified" and the
//     bootloader is locked (enforce mode),
//   * the attesting app is our package, signed by our certificate.
// Attestation proves the key's home and the app/device state at
// registration; it does not certify physical GPS truth.
import "npm:reflect-metadata@0.2.2"; // required by @peculiar/x509 (tsyringe)
import * as x509 from "npm:@peculiar/x509@2.1.0";
import { AsnConvert } from "npm:@peculiar/asn1-schema@2.10.0";
import { SubjectPublicKeyInfo } from "npm:@peculiar/asn1-x509@2.10.0";
import { p256 } from "npm:@noble/curves@1.9.7/p256";
import { p384 } from "npm:@noble/curves@1.9.7/p384";
import {
  AttestationApplicationId,
  KeyDescription,
  NonStandardKeyDescription,
  SecurityLevel,
  VerifiedBootState,
} from "npm:@peculiar/asn1-android@2.10.0";
import { ApiError, bytesToB64, toHex } from "./http.ts";

x509.cryptoProvider.set(crypto);

const KEY_DESCRIPTION_OID = "1.3.6.1.4.1.11129.2.1.17";

// Google hardware attestation roots, from
// https://developer.android.com/privacy-and-security/security-key-attestation
// (reviewed 2026-09-29). Matching is by public key so re-issued certificates
// of the same RSA root are accepted too.
const GOOGLE_ROOTS_PEM = [
  // RSA root (serialNumber=f92009e853b6b045), current issuance.
  `-----BEGIN CERTIFICATE-----
MIIFHDCCAwSgAwIBAgIJAPHBcqaZ6vUdMA0GCSqGSIb3DQEBCwUAMBsxGTAXBgNV
BAUTEGY5MjAwOWU4NTNiNmIwNDUwHhcNMjIwMzIwMTgwNzQ4WhcNNDIwMzE1MTgw
NzQ4WjAbMRkwFwYDVQQFExBmOTIwMDllODUzYjZiMDQ1MIICIjANBgkqhkiG9w0B
AQEFAAOCAg8AMIICCgKCAgEAr7bHgiuxpwHsK7Qui8xUFmOr75gvMsd/dTEDDJdS
Sxtf6An7xyqpRR90PL2abxM1dEqlXnf2tqw1Ne4Xwl5jlRfdnJLmN0pTy/4lj4/7
tv0Sk3iiKkypnEUtR6WfMgH0QZfKHM1+di+y9TFRtv6y//0rb+T+W8a9nsNL/ggj
nar86461qO0rOs2cXjp3kOG1FEJ5MVmFmBGtnrKpa73XpXyTqRxB/M0n1n/W9nGq
C4FSYa04T6N5RIZGBN2z2MT5IKGbFlbC8UrW0DxW7AYImQQcHtGl/m00QLVWutHQ
oVJYnFPlXTcHYvASLu+RhhsbDmxMgJJ0mcDpvsC4PjvB+TxywElgS70vE0XmLD+O
JtvsBslHZvPBKCOdT0MS+tgSOIfga+z1Z1g7+DVagf7quvmag8jfPioyKvxnK/Eg
sTUVi2ghzq8wm27ud/mIM7AY2qEORR8Go3TVB4HzWQgpZrt3i5MIlCaY504LzSRi
igHCzAPlHws+W0rB5N+er5/2pJKnfBSDiCiFAVtCLOZ7gLiMm0jhO2B6tUXHI/+M
RPjy02i59lINMRRev56GKtcd9qO/0kUJWdZTdA2XoS82ixPvZtXQpUpuL12ab+9E
aDK8Z4RHJYYfCT3Q5vNAXaiWQ+8PTWm2QgBR/bkwSWc+NpUFgNPN9PvQi8WEg5Um
AGMCAwEAAaNjMGEwHQYDVR0OBBYEFDZh4QB8iAUJUYtEbEf/GkzJ6k8SMB8GA1Ud
IwQYMBaAFDZh4QB8iAUJUYtEbEf/GkzJ6k8SMA8GA1UdEwEB/wQFMAMBAf8wDgYD
VR0PAQH/BAQDAgIEMA0GCSqGSIb3DQEBCwUAA4ICAQB8cMqTllHc8U+qCrOlg3H7
174lmaCsbo/bJ0C17JEgMLb4kvrqsXZs01U3mB/qABg/1t5Pd5AORHARs1hhqGIC
W/nKMav574f9rZN4PC2ZlufGXb7sIdJpGiO9ctRhiLuYuly10JccUZGEHpHSYM2G
tkgYbZba6lsCPYAAP83cyDV+1aOkTf1RCp/lM0PKvmxYN10RYsK631jrleGdcdkx
oSK//mSQbgcWnmAEZrzHoF1/0gso1HZgIn0YLzVhLSA/iXCX4QT2h3J5z3znluKG
1nv8NQdxei2DIIhASWfu804CA96cQKTTlaae2fweqXjdN1/v2nqOhngNyz1361mF
mr4XmaKH/ItTwOe72NI9ZcwS1lVaCvsIkTDCEXdm9rCNPAY10iTunIHFXRh+7KPz
lHGewCq/8TOohBRn0/NNfh7uRslOSZ/xKbN9tMBtw37Z8d2vvnXq/YWdsm1+JLVw
n6yYD/yacNJBlwpddla8eaVMjsF6nBnIgQOf9zKSe06nSTqvgwUHosgOECZJZ1Eu
zbH4yswbt02tKtKEFhx+v+OTge/06V+jGsqTWLsfrOCNLuA8H++z+pUENmpqnnHo
vaI47gC+TNpkgYGkkBT6B/m/U01BuOBBTzhIlMEZq9qkDWuM2cA5kW5V3FJUcfHn
w1IdYIg2Wxg7yHcQZemFQg==
-----END CERTIFICATE-----`,
  // ECDSA P-384 root "Key Attestation CA1" (issued from February 2026).
  `-----BEGIN CERTIFICATE-----
MIICIjCCAaigAwIBAgIRAISp0Cl7DrWK5/8OgN52BgUwCgYIKoZIzj0EAwMwUjEc
MBoGA1UEAwwTS2V5IEF0dGVzdGF0aW9uIENBMTEQMA4GA1UECwwHQW5kcm9pZDET
MBEGA1UECgwKR29vZ2xlIExMQzELMAkGA1UEBhMCVVMwHhcNMjUwNzE3MjIzMjE4
WhcNMzUwNzE1MjIzMjE4WjBSMRwwGgYDVQQDDBNLZXkgQXR0ZXN0YXRpb24gQ0Ex
MRAwDgYDVQQLDAdBbmRyb2lkMRMwEQYDVQQKDApHb29nbGUgTExDMQswCQYDVQQG
EwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABCPaI3FO3z5bBQo8cuiEas4HjqCt
G/mLFfRT0MsIssPBEEU5Cfbt6sH5yOAxqEi5QagpU1yX4HwnGb7OtBYpDTB57uH5
Eczm34A5FNijV3s0/f0UPl7zbJcTx6xwqMIRq6NCMEAwDwYDVR0TAQH/BAUwAwEB
/zAOBgNVHQ8BAf8EBAMCAQYwHQYDVR0OBBYEFFIyuyz7RkOb3NaBqQ5lZuA0QepA
MAoGCCqGSM49BAMDA2gAMGUCMETfjPO/HwqReR2CS7p0ZWoD/LHs6hDi422opifH
EUaYLxwGlT9SLdjkVpz0UUOR5wIxAIoGyxGKRHVTpqpGRFiJtQEOOTp/+s1GcxeY
uR2zh/80lQyu9vAFCj6E4AXc+osmRg==
-----END CERTIFICATE-----`,
];

const GOOGLE_ROOT_SPKIS = new Set(
  GOOGLE_ROOTS_PEM.map((pem) => bytesToB64(new Uint8Array(new x509.X509Certificate(pem).publicKey.rawData))),
);

export interface AttestationSummary {
  root: "google" | "unknown";
  security_level: string;
  attestation_version: number;
  verified_boot_state: string | null;
  device_locked: boolean | null;
  package_names: string[];
  signature_digests: string[];
  os_patch_level: number | null;
  revoked: boolean;
  biometric_bound: boolean;
}

export interface AttestationResult {
  publicKeySpkiB64: string;
  level: "hardware" | "software";
  biometricBound: boolean;
  summary: AttestationSummary;
}

export interface AttestationOptions {
  mode: "enforce" | "development";
  packageName: string;
  certDigests: string[];
  requireCertDigests: boolean;
  revocationList?: () => Promise<Set<string> | null>;
}

let statusCache: { at: number; serials: Set<string> } | null = null;

/** Google attestation revocation/suspension list, cached per isolate. */
export async function googleRevocationList(): Promise<Set<string> | null> {
  if (statusCache && Date.now() - statusCache.at < 3600_000) return statusCache.serials;
  try {
    const res = await fetch("https://android.googleapis.com/attestation/status", { cache: "no-store" });
    if (!res.ok) return statusCache?.serials ?? null;
    const body = await res.json() as { entries?: Record<string, { status?: string }> };
    const serials = new Set(
      Object.entries(body.entries ?? {})
        .filter(([, v]) => v.status === "REVOKED" || v.status === "SUSPENDED")
        .map(([k]) => k.toLowerCase()),
    );
    statusCache = { at: Date.now(), serials };
    return serials;
  } catch {
    return statusCache?.serials ?? null;
  }
}

function fail(message: string): never {
  throw new ApiError("VERIFICATION_FAILED", message, 403);
}

function octets(v: unknown): Uint8Array {
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  const buffer = (v as { buffer?: ArrayBuffer })?.buffer;
  return buffer ? new Uint8Array(buffer) : new Uint8Array();
}

function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return diff === 0;
}

interface ParsedDescription {
  attestationVersion: number;
  securityLevel: number;
  challenge: Uint8Array;
  rootOfTrust: { verifiedBootState: number; deviceLocked: boolean } | null;
  appIdBytes: Uint8Array | null;
  osPatchLevel: number | null;
  /** Key usable only after a fresh strong biometric, per operation. */
  biometricBound: boolean;
}

// HardwareAuthenticatorType bit for biometrics (FINGERPRINT = 2 covers all
// strong biometrics in KeyMint).
const AUTH_BIOMETRIC = 2;

function biometricBound(noAuthRequired: unknown, userAuthType: unknown, authTimeout: unknown): boolean {
  const type = typeof userAuthType === "number" ? userAuthType : Number(userAuthType ?? 0);
  const timeout = authTimeout === undefined || authTimeout === null ? 0 : Number(authTimeout);
  return noAuthRequired === undefined && (type & AUTH_BIOMETRIC) !== 0 && timeout === 0;
}

function parseKeyDescription(ext: ArrayBuffer): ParsedDescription {
  try {
    const kd = AsnConvert.parse(ext, KeyDescription);
    const rot = kd.teeEnforced.rootOfTrust ?? kd.softwareEnforced.rootOfTrust;
    const appId = kd.softwareEnforced.attestationApplicationId ?? kd.teeEnforced.attestationApplicationId;
    // Auth rules are read from the list enforced where the key lives.
    const enforced = Number(kd.attestationSecurityLevel) === SecurityLevel.software ? kd.softwareEnforced : kd.teeEnforced;
    return {
      attestationVersion: Number(kd.attestationVersion),
      securityLevel: Number(kd.attestationSecurityLevel),
      challenge: octets(kd.attestationChallenge),
      rootOfTrust: rot ? { verifiedBootState: Number(rot.verifiedBootState), deviceLocked: !!rot.deviceLocked } : null,
      appIdBytes: appId ? octets(appId) : null,
      osPatchLevel: kd.teeEnforced.osPatchLevel ?? null,
      biometricBound: biometricBound(enforced.noAuthRequired, enforced.userAuthType, enforced.authTimeout),
    };
  } catch {
    // Some devices emit authorization tags out of canonical order.
    const kd = AsnConvert.parse(ext, NonStandardKeyDescription);
    const rot = kd.teeEnforced.findProperty("rootOfTrust") ?? kd.softwareEnforced.findProperty("rootOfTrust");
    const appId = kd.softwareEnforced.findProperty("attestationApplicationId") ??
      kd.teeEnforced.findProperty("attestationApplicationId");
    const enforced = Number(kd.attestationSecurityLevel) === SecurityLevel.software ? kd.softwareEnforced : kd.teeEnforced;
    return {
      attestationVersion: Number(kd.attestationVersion),
      securityLevel: Number(kd.attestationSecurityLevel),
      challenge: octets(kd.attestationChallenge),
      rootOfTrust: rot ? { verifiedBootState: Number(rot.verifiedBootState), deviceLocked: !!rot.deviceLocked } : null,
      appIdBytes: appId ? octets(appId) : null,
      osPatchLevel: (kd.teeEnforced.findProperty("osPatchLevel") as number | undefined) ?? null,
      biometricBound: biometricBound(enforced.findProperty("noAuthRequired"), enforced.findProperty("userAuthType"),
        enforced.findProperty("authTimeout")),
    };
  }
}

const EC_CURVES: Record<string, typeof p256> = { "P-256": p256, "P-384": p384 };

// Signed bytes of a certificate: the tbsCertificate element, sliced from the
// original DER (never re-encoded).
function tbsOf(cert: x509.X509Certificate): Uint8Array<ArrayBuffer> {
  const der = new Uint8Array(cert.rawData);
  const header = (at: number) => (der[at + 1] & 0x80 ? 2 + (der[at + 1] & 0x7f) : 2);
  const length = (at: number) => {
    const b = der[at + 1];
    if (!(b & 0x80)) return b;
    let n = 0;
    for (let k = 0; k < (b & 0x7f); k++) n = n * 256 + der[at + 2 + k];
    return n;
  };
  const start = header(0);
  return der.slice(start, start + header(start) + length(start));
}

// One link of the chain. EC signatures are checked in pure JS: the Edge
// runtime's WebCrypto only verifies matching curve/hash pairs, but TEE chains
// commonly sign SHA-256 with a P-384 intermediate (seen on real phones).
async function signedBy(cert: x509.X509Certificate, issuer: x509.X509Certificate): Promise<boolean> {
  const keyAlg = issuer.publicKey.algorithm as EcKeyAlgorithm;
  const sigAlg = cert.signatureAlgorithm as { name: string; hash?: { name: string } };
  if (keyAlg.name !== "ECDSA" || sigAlg.name !== "ECDSA") {
    return await cert.verify({ publicKey: issuer.publicKey, signatureOnly: true }).catch(() => false);
  }
  const curve = EC_CURVES[keyAlg.namedCurve];
  const hash = sigAlg.hash?.name;
  if (!curve || !hash || !["SHA-256", "SHA-384", "SHA-512"].includes(hash)) return false;
  try {
    const point = new Uint8Array(AsnConvert.parse(issuer.publicKey.rawData, SubjectPublicKeyInfo).subjectPublicKey);
    const digest = new Uint8Array(await crypto.subtle.digest(hash, tbsOf(cert)));
    return curve.verify(new Uint8Array(cert.signature), digest, point, { lowS: false, format: "der" });
  } catch {
    return false;
  }
}

export async function verifyAndroidAttestation(
  chainB64: string[],
  expectedChallenge: Uint8Array,
  opts: AttestationOptions,
): Promise<AttestationResult> {
  if (!Array.isArray(chainB64) || chainB64.length < 2 || chainB64.length > 10) {
    fail("Device verification data is missing.");
  }
  let chain: x509.X509Certificate[];
  try {
    chain = chainB64.map((c) => new x509.X509Certificate(c));
  } catch {
    fail("Device verification data is malformed.");
  }

  // 1. Signatures up the chain; the top certificate must be self-signed.
  for (let i = 0; i < chain.length; i++) {
    const issuer = chain[Math.min(i + 1, chain.length - 1)];
    if (!await signedBy(chain[i], issuer)) fail("Device verification chain is invalid.");
  }
  const rootSpki = bytesToB64(new Uint8Array(chain[chain.length - 1].publicKey.rawData));
  const root: "google" | "unknown" = GOOGLE_ROOT_SPKIS.has(rootSpki) ? "google" : "unknown";

  // 2. Revocation (Google list; serials lowercase hex without leading zeros).
  let revoked = false;
  if (root === "google") {
    const list = await (opts.revocationList ?? googleRevocationList)();
    if (list === null && opts.mode === "enforce") {
      throw new ApiError("VERIFICATION_FAILED", "Device verification service is unavailable. Try again later.", 503,
        {}, true);
    }
    revoked = !!list && chain.some((c) => list.has(c.serialNumber.toLowerCase().replace(/^0+/, "")));
  }

  // 3. Key description extension on the leaf.
  const leaf = chain[0];
  const ext = leaf.getExtension(KEY_DESCRIPTION_OID);
  if (!ext) fail("This phone did not provide hardware key attestation.");
  let kd: ParsedDescription;
  try {
    kd = parseKeyDescription(ext.value);
  } catch {
    fail("Device verification data could not be read.");
  }

  if (!constantTimeEqual(kd.challenge, expectedChallenge)) {
    fail("Device verification expired. Please try again.");
  }

  let packageNames: string[] = [];
  let digests: string[] = [];
  if (kd.appIdBytes) {
    try {
      const appId = AsnConvert.parse(kd.appIdBytes, AttestationApplicationId);
      packageNames = appId.packageInfos.map((p) => new TextDecoder().decode(octets(p.packageName)));
      digests = appId.signatureDigests.map((d) => toHex(octets(d)));
    } catch { /* treated as missing below */ }
  }
  if (!packageNames.includes(opts.packageName)) {
    fail("This app build is not recognised.");
  }

  const hardwareKey = kd.securityLevel === SecurityLevel.trustedEnvironment || kd.securityLevel === SecurityLevel.strongBox;
  const bootVerified = kd.rootOfTrust?.verifiedBootState === VerifiedBootState.verified;
  const locked = kd.rootOfTrust?.deviceLocked === true;
  const signerOk = opts.certDigests.length === 0
    ? !opts.requireCertDigests
    : digests.some((d) => opts.certDigests.includes(d));

  const strong = root === "google" && !revoked && hardwareKey && bootVerified && locked && signerOk;
  if (opts.mode === "enforce" && !strong) {
    if (!signerOk) fail("This app build is not recognised.");
    fail("This phone did not pass device verification (modified or unlocked phones are not supported).");
  }
  if (revoked) fail("This phone's security key has been revoked by the manufacturer.");

  const publicKey = leaf.publicKey;
  const alg = publicKey.algorithm as EcKeyAlgorithm;
  if (alg.name !== "ECDSA" || alg.namedCurve !== "P-256") fail("Unsupported device key type.");

  return {
    publicKeySpkiB64: bytesToB64(new Uint8Array(publicKey.rawData)),
    level: strong ? "hardware" : "software",
    biometricBound: kd.biometricBound,
    summary: {
      root,
      security_level: SecurityLevel[kd.securityLevel] ?? String(kd.securityLevel),
      attestation_version: kd.attestationVersion,
      verified_boot_state: kd.rootOfTrust ? (VerifiedBootState[kd.rootOfTrust.verifiedBootState] ?? null) : null,
      device_locked: kd.rootOfTrust?.deviceLocked ?? null,
      package_names: packageNames,
      signature_digests: digests,
      os_patch_level: kd.osPatchLevel,
      revoked,
      biometric_bound: kd.biometricBound,
    },
  };
}
