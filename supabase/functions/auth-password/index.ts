// POST /auth-password {operation_id, current_password, new_password}
// Self-service password change (also completes the mandatory first change).
// Fail-closed saga: DB hold -> verify current password -> Auth update ->
// DB barrier + gate -> hold cleared last. A retry with the same operation id
// reconciles by checking which password Auth accepts — never by blindly
// clearing the hold. On success every existing session is invalid and the
// app signs in again with the new password.
import { ApiError, ok, readJson, serve, uuid } from "../_shared/http.ts";
import {
  actorParams,
  adminUpdatePassword,
  passwordGrant,
  requireCaller,
  rpc,
  signOut,
  validateNewPassword,
} from "../_shared/supabase.ts";

interface Begin {
  operation_id: string;
  stage: string;
  resumed: boolean;
  target_auth_user_id: string;
  target_alias: string;
  employee_code: string;
}

serve(async (req, requestId) => {
  const caller = await requireCaller(req);
  const body = await readJson<{ operation_id?: string; current_password?: string; new_password?: string }>(req, 4096);
  const operationId = uuid(body.operation_id, "operation_id");
  const current = typeof body.current_password === "string" ? body.current_password : "";
  if (!current) throw new ApiError("VALIDATION_FAILED", "Enter your current password.", 422, { current_password: "Required" });

  const actor = await rpc<{ employee_id: string; employee_code: string }>(
    "internal_resolve_actor",
    { ...actorParams(caller), p_mode: "restricted" },
  );
  const next = validateNewPassword(body.new_password, actor.employee_code);
  if (next === current) {
    throw new ApiError("VALIDATION_FAILED", "Choose a password different from the current one.", 422,
      { new_password: "Must differ from current password" });
  }

  const begin = await rpc<Begin>("internal_credential_begin", {
    ...actorParams(caller),
    p_operation_id: operationId,
    p_kind: "self_change",
    p_target_employee_id: null,
  });
  if (begin.stage === "finalized") return ok({ status: "completed" }, requestId);

  const finalize = async () => {
    await rpc("internal_credential_finalize", { p_operation_id: operationId, p_actor_employee_id: actor.employee_id });
    await signOut(caller.jwt, "global");
    return ok({ status: "completed" }, requestId);
  };

  // Reconcile a resumed operation: if Auth already has the new password,
  // only the database finalisation is missing.
  if (begin.resumed) {
    const probe = await passwordGrant(begin.target_alias, next);
    if (probe) {
      await signOut(probe.access_token);
      return await finalize();
    }
  }

  const check = await passwordGrant(begin.target_alias, current);
  if (!check) {
    await rpc("internal_credential_fail", {
      p_operation_id: operationId,
      p_actor_employee_id: actor.employee_id,
      p_auth_unchanged: true,
      p_error: "current password rejected",
    });
    throw new ApiError("VALIDATION_FAILED", "Your current password is incorrect.", 422,
      { current_password: "Incorrect" });
  }
  await signOut(check.access_token);

  const update = await adminUpdatePassword(begin.target_auth_user_id, next);
  if (update.status >= 400 && update.status < 500) {
    await rpc("internal_credential_fail", {
      p_operation_id: operationId,
      p_actor_employee_id: actor.employee_id,
      p_auth_unchanged: true,
      p_error: `auth rejected: ${update.message ?? update.status}`,
    });
    throw new ApiError("VALIDATION_FAILED", update.message || "This password is not accepted. Try a stronger one.", 422,
      { new_password: "Not accepted" });
  }
  if (update.status >= 500 || !update.user) {
    // Outcome uncertain: keep the hold; the app retries with the same id.
    await rpc("internal_credential_fail", {
      p_operation_id: operationId,
      p_actor_employee_id: actor.employee_id,
      p_auth_unchanged: false,
      p_error: `auth status ${update.status}`,
    });
    throw new ApiError("CREDENTIAL_OPERATION_PENDING", "Could not confirm the change. Please try again.", 503, {}, true);
  }
  return await finalize();
});
