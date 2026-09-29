// Device registration: Android Key Attestation parsing and policy, using a
// synthetic chain (test CA, real KeyDescription extension). Real Google-root
// chains are exercised on physical devices.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import "npm:reflect-metadata@0.2.2"; // required by @peculiar/x509 (tsyringe)
import * as x509 from "npm:@peculiar/x509@2.1.0";
import { AsnConvert, OctetString } from "npm:@peculiar/asn1-schema@2.10.0";
import {
  AttestationApplicationId,
  AttestationPackageInfo,
  AuthorizationList,
  KeyDescription,
  RootOfTrust,
  SecurityLevel,
  VerifiedBootState,
} from "npm:@peculiar/asn1-android@2.10.0";
import { bytesToB64 } from "../_shared/http.ts";
import { verifyAndroidAttestation } from "../_shared/attestation.ts";

x509.cryptoProvider.set(crypto);
const PKG = "com.internalhrms.hrms";
const challenge = new TextEncoder().encode("server-nonce-1234567890");

async function chain(opts: { biometric?: boolean; pkg?: string; challenge?: Uint8Array; boot?: number } = {}) {
  const alg = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;
  const rootKeys = await crypto.subtle.generateKey(alg, true, ["sign", "verify"]);
  const leafKeys = await crypto.subtle.generateKey(alg, true, ["sign", "verify"]);
  const root = await x509.X509CertificateGenerator.createSelfSigned({
    serialNumber: "01", name: "CN=Test Attestation Root", notBefore: new Date(Date.now() - 86400e3),
    notAfter: new Date(Date.now() + 86400e3), signingAlgorithm: alg, keys: rootKeys,
    extensions: [new x509.BasicConstraintsExtension(true, undefined, true)],
  });

  const appId = new AttestationApplicationId({
    packageInfos: [new AttestationPackageInfo({ packageName: new OctetString(new TextEncoder().encode(opts.pkg ?? PKG)), version: 1 })],
    signatureDigests: [new OctetString(new Uint8Array(32).fill(7))],
  });
  const tee = new AuthorizationList({
    rootOfTrust: new RootOfTrust({
      verifiedBootKey: new OctetString(new Uint8Array(32)),
      deviceLocked: true,
      verifiedBootState: opts.boot ?? VerifiedBootState.verified,
    }),
  });
  if (opts.biometric) tee.userAuthType = 2;
  else tee.noAuthRequired = null;
  const kd = new KeyDescription({
    attestationVersion: 200,
    attestationSecurityLevel: SecurityLevel.trustedEnvironment,
    keymasterVersion: 200,
    keymasterSecurityLevel: SecurityLevel.trustedEnvironment,
    attestationChallenge: new OctetString(opts.challenge ?? challenge),
    uniqueId: new OctetString(new Uint8Array()),
    softwareEnforced: new AuthorizationList({ attestationApplicationId: new OctetString(AsnConvert.serialize(appId)) }),
    teeEnforced: tee,
  });
  const leaf = await x509.X509CertificateGenerator.create({
    serialNumber: "02", subject: "CN=Android Keystore Key", issuer: root.subject,
    notBefore: new Date(Date.now() - 3600e3), notAfter: new Date(Date.now() + 86400e3),
    signingAlgorithm: alg, publicKey: leafKeys.publicKey, signingKey: rootKeys.privateKey,
    extensions: [new x509.Extension("1.3.6.1.4.1.11129.2.1.17", false, AsnConvert.serialize(kd))],
  });
  return {
    certs: [bytesToB64(new Uint8Array(leaf.rawData)), bytesToB64(new Uint8Array(root.rawData))],
    leafSpki: bytesToB64(new Uint8Array(await crypto.subtle.exportKey("spki", leafKeys.publicKey))),
  };
}

const dev = { mode: "development" as const, packageName: PKG, certDigests: [], requireCertDigests: false,
  revocationList: () => Promise.resolve(new Set<string>()) };

Deno.test("development mode accepts a non-Google chain as SOFTWARE and extracts the key", async () => {
  const c = await chain({ biometric: true });
  const r = await verifyAndroidAttestation(c.certs, challenge, dev);
  assertEquals(r.level, "software");
  assertEquals(r.summary.root, "unknown");
  assertEquals(r.publicKeySpkiB64, c.leafSpki);
  assertEquals(r.summary.package_names, [PKG]);
  assertEquals(r.summary.verified_boot_state, "verified");
  assert(r.biometricBound, "biometric-bound key detected");
});

Deno.test("keys usable without authentication are not biometric-bound", async () => {
  const r = await verifyAndroidAttestation((await chain({ biometric: false })).certs, challenge, dev);
  assertEquals(r.biometricBound, false);
});

Deno.test("enforce mode rejects chains not rooted in Google's attestation roots", async () => {
  const c = await chain({ biometric: true });
  await assertRejects(() => verifyAndroidAttestation(c.certs, challenge, { ...dev, mode: "enforce" }));
});

Deno.test("wrong challenge, wrong package and broken signatures are rejected", async () => {
  const wrongChallenge = await chain({ challenge: new TextEncoder().encode("other-nonce-00000000000") });
  await assertRejects(() => verifyAndroidAttestation(wrongChallenge.certs, challenge, dev));
  const wrongPkg = await chain({ pkg: "com.evil.clone" });
  await assertRejects(() => verifyAndroidAttestation(wrongPkg.certs, challenge, dev));
  const a = await chain();
  const b = await chain();
  // Leaf not signed by the presented root.
  await assertRejects(() => verifyAndroidAttestation([a.certs[0], b.certs[1]], challenge, dev));
  await assertRejects(() => verifyAndroidAttestation([a.certs[0]], challenge, dev));
});
