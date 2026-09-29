// POST /auth-reauth {password, action, target_id?}
// Verifies the current password through Auth and issues a 5-minute grant
// bound to actor + session + action (+ target). Sensitive RPCs (role
// elevation, payroll delegation, Admin reset, archive cleanup) consume it.
import { ApiError, isUuid, ok, readJson, serve } from "../_shared/http.ts";
import { actorParams, passwordGrant, requireCaller, rpc, signOut } from "../_shared/supabase.ts";

const ACTIONS = new Set(["role.elevate", "archive.cleanup", "export.bulk_salary", "export.annual", "credentials.reset_admin"]);

serve(async (req, requestId) => {
  const caller = await requireCaller(req);
  const body = await readJson<{ password?: string; action?: string; target_id?: string }>(req, 4096);
  if (!body.action || !ACTIONS.has(body.action)) throw new ApiError("VALIDATION_FAILED", "Unknown action.", 422);
  if (typeof body.password !== "string" || !body.password) {
    throw new ApiError("VALIDATION_FAILED", "Enter your password.", 422, { password: "Required" });
  }
  const actor = await rpc<{ employee_id: string; auth_alias: string }>(
    "internal_resolve_actor",
    { ...actorParams(caller), p_mode: "business" },
  );
  const allowed = await rpc<boolean>("internal_rate_limit", {
    p_bucket: `reauth:${actor.employee_id}`,
    p_window_seconds: 900,
    p_max: 5,
  });
  if (!allowed) throw new ApiError("RATE_LIMITED", "Too many attempts. Try again later.", 429, {}, true);

  const check = await passwordGrant(actor.auth_alias, body.password);
  if (!check) throw new ApiError("REAUTH_REQUIRED", "Password is incorrect.", 403, { password: "Incorrect" });
  await signOut(check.access_token);

  const grant = await rpc<{ grant_id: string; expires_at: string }>("internal_issue_reauth_grant", {
    ...actorParams(caller),
    p_action: body.action,
    p_target: isUuid(body.target_id) ? body.target_id : null,
  });
  return ok(grant, requestId);
});
