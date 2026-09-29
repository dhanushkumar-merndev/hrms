// POST /admin-users {action: "provision", operation_id, fields}
// POST /admin-users {action: "reset", operation_id, employee_id}
// Provisioning and credential resets by Admin / authorised HR. The
// temporary password is generated here, returned ONCE to the issuer and never
// stored or logged. Retries with the same operation id reconcile instead of
// creating duplicate identities.
import { ALIAS_DOMAIN } from "../_shared/env.ts";
import { ApiError, ok, readJson, serve, uuid } from "../_shared/http.ts";
import {
  actorParams,
  adminCreateUser,
  adminFindUserByEmail,
  adminUpdatePassword,
  requireCaller,
  rpc,
  temporaryPassword,
} from "../_shared/supabase.ts";

serve(async (req, requestId) => {
  const caller = await requireCaller(req);
  const body = await readJson<{ action?: string; operation_id?: string; fields?: Record<string, unknown>; employee_id?: string }>(req, 16384);
  const operationId = uuid(body.operation_id, "operation_id");
  const actor = await rpc<{ employee_id: string }>("internal_resolve_actor", { ...actorParams(caller), p_mode: "business" });

  if (body.action === "provision") {
    if (!body.fields || typeof body.fields !== "object") throw new ApiError("VALIDATION_FAILED", "Missing fields.", 422);
    const begin = await rpc<{ employee_id: string; auth_alias: string; provisioning_state: string }>(
      "internal_provision_begin",
      { ...actorParams(caller), p_operation_id: operationId, p_fields: body.fields, p_alias_domain: ALIAS_DOMAIN },
    );
    if (begin.provisioning_state === "complete") {
      return ok({ employee_id: begin.employee_id, already: true, temporary_password: null }, requestId);
    }
    const password = temporaryPassword();
    let userId: string | undefined;
    const created = await adminCreateUser(begin.auth_alias, password);
    if (created.status < 300 && created.user) {
      userId = created.user.id;
    } else if (created.status === 422 || created.status === 409 || created.status === 400) {
      // Identity may exist from an interrupted earlier attempt: reconcile.
      const existing = await adminFindUserByEmail(begin.auth_alias);
      if (!existing) {
        throw new ApiError("PROVISIONING_FAILED", created.message || "Could not create the login.", 502, {}, true);
      }
      const reset = await adminUpdatePassword(existing.id, password);
      if (reset.status >= 300) throw new ApiError("PROVISIONING_FAILED", "Could not set the password.", 502, {}, true);
      userId = existing.id;
    } else {
      throw new ApiError("PROVISIONING_FAILED", "Could not create the login. Try again.", 502, {}, true);
    }
    const link = await rpc<{ employee_id: string; employee_code: string }>("internal_provision_link", {
      ...actorParams(caller),
      p_operation_id: operationId,
      p_new_auth_user_id: userId,
    });
    return ok({
      employee_id: link.employee_id,
      employee_code: link.employee_code,
      temporary_password: password,
      already: false,
    }, requestId);
  }

  if (body.action === "reset") {
    const employeeId = uuid(body.employee_id, "employee_id");
    const begin = await rpc<{ stage: string; target_auth_user_id: string; employee_code: string }>(
      "internal_credential_begin",
      { ...actorParams(caller), p_operation_id: operationId, p_kind: "admin_reset", p_target_employee_id: employeeId },
    );
    if (begin.stage === "finalized") {
      throw new ApiError("VALIDATION_FAILED", "This reset already finished. Start a new reset to get a new password.", 409);
    }
    const password = temporaryPassword();
    const update = await adminUpdatePassword(begin.target_auth_user_id, password);
    if (update.status >= 300 || !update.user) {
      await rpc("internal_credential_fail", {
        p_operation_id: operationId,
        p_actor_employee_id: actor.employee_id,
        p_auth_unchanged: update.status >= 400 && update.status < 500,
        p_error: `auth status ${update.status}`,
      });
      throw new ApiError("CREDENTIAL_OPERATION_PENDING", "Could not reset the password. Try again.", 503, {}, true);
    }
    await rpc("internal_credential_finalize", { p_operation_id: operationId, p_actor_employee_id: actor.employee_id });
    return ok({ employee_id: employeeId, employee_code: begin.employee_code, temporary_password: password }, requestId);
  }

  throw new ApiError("VALIDATION_FAILED", "Unknown action.", 400);
});
