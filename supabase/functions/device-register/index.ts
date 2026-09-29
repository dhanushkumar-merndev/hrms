// POST /device-register {challenge_id, nonce, installation_id, platform,
//                        certificate_chain: [base64 DER, leaf first], device_label}
// Registers this phone's hardware-backed punch-signing key after verifying
// its Android Key Attestation chain against the single-use server nonce.
import {
  ANDROID_CERT_DIGESTS,
  ANDROID_PACKAGE,
  INTEGRITY_MODE,
  IS_PRODUCTION,
} from "../_shared/env.ts";
import { verifyAndroidAttestation } from "../_shared/attestation.ts";
import { ApiError, ok, readJson, serve, uuid } from "../_shared/http.ts";
import { actorParams, requireCaller, rpc } from "../_shared/supabase.ts";

serve(async (req, requestId) => {
  const caller = await requireCaller(req);
  const body = await readJson<{
    challenge_id?: string;
    nonce?: string;
    installation_id?: string;
    platform?: string;
    certificate_chain?: string[];
    device_label?: string;
  }>(req, 65536);
  const challengeId = uuid(body.challenge_id, "challenge_id");
  const installationId = uuid(body.installation_id, "installation_id");
  if (typeof body.nonce !== "string" || !/^[A-Za-z0-9_-]{16,128}$/.test(body.nonce)) {
    throw new ApiError("VALIDATION_FAILED", "Invalid registration data.", 422);
  }
  if (body.platform !== "android") {
    throw new ApiError("VERIFICATION_FAILED", "Punching from this phone type is not set up yet.", 403);
  }
  if (IS_PRODUCTION && ANDROID_CERT_DIGESTS.length === 0) {
    // Fail closed: production must pin the app signing certificate.
    throw new ApiError("VERIFICATION_FAILED", "Device registration is not configured. Contact your Admin.", 503);
  }

  const attestation = await verifyAndroidAttestation(
    body.certificate_chain ?? [],
    new TextEncoder().encode(body.nonce),
    {
      mode: INTEGRITY_MODE,
      packageName: ANDROID_PACKAGE,
      certDigests: ANDROID_CERT_DIGESTS,
      requireCertDigests: IS_PRODUCTION,
    },
  );

  const result = await rpc<{ data: { device_id: string; attestation_level: string; biometric_bound: boolean } }>(
    "internal_register_device",
    {
      ...actorParams(caller),
      p_challenge_id: challengeId,
      p_nonce: body.nonce,
      p_installation_id: installationId,
      p_platform: "android",
      p_public_key_spki: attestation.publicKeySpkiB64,
      p_attestation_level: attestation.level,
      p_attestation_summary: attestation.summary,
      p_device_label: typeof body.device_label === "string" ? body.device_label.slice(0, 120) : null,
      p_biometric_bound: attestation.biometricBound,
    },
  );
  return ok(result.data, requestId);
});
