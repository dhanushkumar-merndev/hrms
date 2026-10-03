// POST /punch — submit a signed IN/OUT punch.
// Body: {operation_key, challenge_id, nonce, action, target_id, device_id,
//        office_id, employee_id, latitude, longitude, accuracy, sample_at_ms,
//        is_mocked, signature, wifi_ssid?, wifi_nearby?}
// Order (architecture §5.1): record trusted receipt time -> authenticate ->
// committed-replay lookup (returns the original result before any freshness
// or signature check) -> verify device signature over the server-rebuilt
// canonical payload -> transactional commit in the database.
import { INTEGRITY_MODE, MAINTENANCE_SECRET } from "../_shared/env.ts";
import { ApiError, ipHash, json, readJson, serve, sha256Hex, uuid } from "../_shared/http.ts";
import { canonicalPayloadV1, type PunchFields, validatePunchFields, verifyDeviceSignature } from "../_shared/punch.ts";
import { actorParams, requireCaller, rpc } from "../_shared/supabase.ts";

const DEADLINE_MS = 30_000;

serve(async (req, requestId) => {
  const receiptAt = new Date();
  const caller = await requireCaller(req);
  const b = await readJson<Record<string, unknown>>(req, 8192);

  const fields: PunchFields = {
    challengeId: uuid(b.challenge_id, "challenge_id"),
    nonce: String(b.nonce ?? ""),
    operationKey: uuid(b.operation_key, "operation_key"),
    employeeId: uuid(b.employee_id, "employee_id"),
    deviceId: uuid(b.device_id, "device_id"),
    action: b.action === "OUT" ? "OUT" : b.action === "IN" ? "IN" : ("X" as "IN"),
    targetId: uuid(b.target_id, "target_id"),
    officeId: uuid(b.office_id, "office_id"),
    latitude: String(b.latitude ?? ""),
    longitude: String(b.longitude ?? ""),
    accuracy: String(b.accuracy ?? ""),
    sampleAtMs: String(b.sample_at_ms ?? ""),
  };
  const logReject = async (code: string, detail: Record<string, unknown>) => {
    await rpc("internal_log_punch_rejection", {
      p_auth_user_id: caller.authUserId,
      p_code: code,
      p_detail: detail,
      p_ip_hash: await ipHash(req, MAINTENANCE_SECRET),
    }).catch(() => undefined);
  };
  try {
    validatePunchFields(fields);
  } catch (e) {
    await logReject("MALFORMED", { reason: "payload" });
    throw e;
  }

  const payload = canonicalPayloadV1(fields);
  const payloadHash = await sha256Hex(payload);

  // 1. Committed replay: original result even if nonce/proof expired since.
  const lookup = await rpc<{ found: boolean; conflict?: boolean; result?: unknown }>("internal_punch_lookup", {
    ...actorParams(caller),
    p_operation_key: fields.operationKey,
    p_payload_hash: payloadHash,
  });
  if (lookup.found && lookup.conflict) {
    throw new ApiError("IDEMPOTENCY_CONFLICT", "This punch was already recorded with different details.", 409);
  }
  if (lookup.found) return json(lookup.result);

  // 2. Device key belongs to the caller and signed exactly this payload.
  const device = await rpc<{ found: boolean; employee_id?: string; public_key_spki?: string; attestation_level?: string }>(
    "internal_device_key",
    { ...actorParams(caller), p_device_id: fields.deviceId },
  );
  if (!device.found || device.employee_id !== fields.employeeId.toLowerCase()) {
    await logReject("DEVICE", { reason: "unregistered" });
    throw new ApiError("VERIFICATION_FAILED", "This phone is not registered for punching.", 403);
  }
  if (INTEGRITY_MODE === "enforce" && device.attestation_level !== "hardware") {
    await logReject("DEVICE", { reason: "software_key" });
    throw new ApiError("VERIFICATION_FAILED", "This phone did not pass device verification.", 403);
  }
  const signature = typeof b.signature === "string" ? b.signature : "";
  if (!(await verifyDeviceSignature(device.public_key_spki!, signature, payload))) {
    await logReject("SIGNATURE", { reason: "invalid" });
    throw new ApiError("VERIFICATION_FAILED", "Verification failed. Please try again.", 403, {}, true);
  }

  // 3. Bounded request deadline measured from trusted receipt time.
  if (Date.now() - receiptAt.getTime() > DEADLINE_MS) {
    throw new ApiError("VERIFICATION_FAILED", "Verification took too long. Please try again.", 408, {}, true);
  }

  const result = await rpc<Record<string, unknown>>("internal_commit_punch", {
    ...actorParams(caller),
    p_operation_key: fields.operationKey,
    p_payload_hash: payloadHash,
    p_challenge_id: fields.challengeId,
    p_action: fields.action,
    p_target_id: fields.targetId,
    p_device_id: fields.deviceId,
    p_office_id: fields.officeId,
    p_latitude: Number(fields.latitude),
    p_longitude: Number(fields.longitude),
    p_accuracy: Number(fields.accuracy),
    p_sample_at: new Date(Number(fields.sampleAtMs)).toISOString(),
    p_receipt_at: receiptAt.toISOString(),
    p_integrity: {
      level: device.attestation_level,
      mock_location: b.is_mocked === true,
      // Connected Wi-Fi name reported by the phone; checked against the office list.
      wifi_ssid: typeof b.wifi_ssid === "string" ? b.wifi_ssid.slice(0, 64) : null,
      // Office Wi-Fi names seen nearby in a scan (phone may be on mobile data).
      wifi_nearby: Array.isArray(b.wifi_nearby)
        ? b.wifi_nearby.filter((n): n is string => typeof n === "string").slice(0, 30).map((n) => n.slice(0, 64))
        : [],
      signature_verified: true,
      request_id: requestId,
    },
  });
  return json(result, result.ok === false ? 422 : 200);
});
