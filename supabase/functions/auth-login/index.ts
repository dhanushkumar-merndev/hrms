// POST /auth-login {org_code?, employee_code, password}
// Employee-ID login. The internal Auth alias never leaves the server, so the
// only way to attempt a password is through this endpoint, which applies IP
// and per-account rate limits with bounded cooldowns. Every failure returns
// the same generic message and similar timing (unknown IDs still perform an
// Auth attempt against a random alias).
import { ALIAS_DOMAIN, MAINTENANCE_SECRET } from "../_shared/env.ts";
import { ApiError, ipHash, ok, readJson, serve } from "../_shared/http.ts";
import { passwordGrant, rpc, signOut } from "../_shared/supabase.ts";

const GENERIC = "Employee ID or password is incorrect.";

serve(async (req, requestId) => {
  const body = await readJson<{ org_code?: string; employee_code?: string; password?: string }>(req, 4096);
  const code = typeof body.employee_code === "string" ? body.employee_code.slice(0, 64) : "";
  const password = typeof body.password === "string" ? body.password : "";
  const orgCode = typeof body.org_code === "string" ? body.org_code.slice(0, 32) : "";
  if (!code || !password || password.length > 256) throw new ApiError("AUTH_FAILED", GENERIC, 401);

  const ip = await ipHash(req, MAINTENANCE_SECRET);
  const lookup = await rpc<{ allowed: boolean; alias: string | null; retry_after_seconds?: number }>(
    "internal_login_lookup",
    { p_org_code: orgCode, p_employee_code: code, p_ip_hash: ip },
  );
  if (!lookup.allowed) {
    throw new ApiError("RATE_LIMITED", "Too many attempts. Please wait a few minutes and try again.", 429, {}, true);
  }

  const email = lookup.alias ?? `x-${crypto.randomUUID()}@${ALIAS_DOMAIN}`;
  const session = await passwordGrant(email, password);
  const success = session !== null && lookup.alias !== null;

  const result = await rpc<{ ok: boolean; must_change_password?: boolean; credential_hold?: boolean }>(
    "internal_login_result",
    {
      p_org_code: orgCode,
      p_employee_code: code,
      p_ip_hash: ip,
      p_success: success,
      p_auth_user_id: session?.user?.id ?? null,
    },
  );
  if (!success || !result.ok) {
    if (session) await signOut(session.access_token);
    throw new ApiError("AUTH_FAILED", GENERIC, 401);
  }

  return ok({
    session: {
      access_token: session!.access_token,
      refresh_token: session!.refresh_token,
      expires_in: session!.expires_in,
      expires_at: session!.expires_at,
      token_type: session!.token_type,
      user: session!.user,
    },
    must_change_password: result.must_change_password ?? false,
    credential_hold: result.credential_hold ?? false,
  }, requestId);
});
