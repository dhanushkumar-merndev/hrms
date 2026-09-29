// Caller authentication, service RPCs and Supabase Auth HTTP helpers.
// Service credentials bypass RLS, so every internal RPC receives an actor
// identity that THIS module verified from the caller's JWT — never a
// client-supplied actor id.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.117.2";
import { createLocalJWKSet, jwtVerify, type JWTPayload } from "npm:jose@6.2.12";
import { keyHeaders, publicKey, serviceKey, SUPABASE_URL } from "./env.ts";
import { ApiError, fromPostgrest } from "./http.ts";

export interface Caller {
  authUserId: string;
  sessionId: string;
  email: string;
  jwt: string;
}

let admin: SupabaseClient | null = null;

export function serviceClient(): SupabaseClient {
  admin ??= createClient(SUPABASE_URL, serviceKey(), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  return admin;
}

/** Calls an HRMS RPC with the service role and maps errors. */
export async function rpc<T = Record<string, unknown>>(fn: string, params: Record<string, unknown>): Promise<T> {
  const { data, error } = await serviceClient().rpc(fn, params);
  if (error) throw fromPostgrest(error);
  return data as T;
}

/** Actor parameters every internal_* RPC expects. */
export function actorParams(c: Caller): Record<string, string> {
  return { p_auth_user_id: c.authUserId, p_session_id: c.sessionId, p_email: c.email };
}

function decodePayload(jwt: string): JWTPayload & Record<string, unknown> {
  const part = jwt.split(".")[1] ?? "";
  const normalized = part.replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(normalized + "=".repeat((4 - (normalized.length % 4)) % 4)));
}

let jwks: ReturnType<typeof createLocalJWKSet> | null | undefined;

function localJwks() {
  if (jwks !== undefined) return jwks;
  try {
    const raw = Deno.env.get("SUPABASE_JWKS");
    const set = raw ? JSON.parse(raw) : null;
    const usable = set?.keys?.filter((k: { kty?: string }) => k.kty === "EC" || k.kty === "RSA") ?? [];
    jwks = usable.length ? createLocalJWKSet({ keys: usable }) : null;
  } catch {
    jwks = null;
  }
  return jwks;
}

/** Verifies the caller's Supabase access token. Asymmetric project keys are
 * verified locally with the JWKS; otherwise Auth validates the token. The
 * database then re-checks the session row and credential barrier. */
export async function requireCaller(req: Request): Promise<Caller> {
  const header = req.headers.get("authorization") ?? "";
  const jwt = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (!jwt || jwt.split(".").length !== 3) throw new ApiError("AUTH_REQUIRED", "Please sign in.", 401);

  let payload: JWTPayload & Record<string, unknown>;
  const keys = localJwks();
  try {
    if (keys) {
      const verified = await jwtVerify(jwt, keys, { issuer: `${SUPABASE_URL}/auth/v1`, audience: "authenticated" });
      payload = verified.payload as JWTPayload & Record<string, unknown>;
    } else {
      const res = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
        headers: { ...keyHeaders(publicKey()), Authorization: `Bearer ${jwt}` },
      });
      if (!res.ok) throw new Error(`auth ${res.status}`);
      await res.body?.cancel();
      payload = decodePayload(jwt);
    }
  } catch {
    throw new ApiError("AUTH_REQUIRED", "Your session expired. Please sign in again.", 401);
  }
  if (payload.role !== "authenticated" || typeof payload.sub !== "string" ||
      typeof payload.session_id !== "string" || typeof payload.email !== "string") {
    throw new ApiError("AUTH_REQUIRED", "Please sign in.", 401);
  }
  if (typeof payload.exp === "number" && payload.exp * 1000 < Date.now()) {
    throw new ApiError("AUTH_REQUIRED", "Your session expired. Please sign in again.", 401);
  }
  return { authUserId: payload.sub, sessionId: payload.session_id, email: payload.email, jwt };
}

// ---------------------------------------------------------------- Auth HTTP

export interface AuthSession {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  expires_at?: number;
  token_type: string;
  user: { id: string; email?: string };
}

/** Password grant. Returns null on any credential failure (never throws on
 * 4xx so callers can respond generically). */
export async function passwordGrant(email: string, password: string): Promise<AuthSession | null> {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { ...keyHeaders(publicKey()), "content-type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  if (res.status >= 500) throw new ApiError("AUTH_UNAVAILABLE", "Sign-in is temporarily unavailable.", 503, {}, true);
  if (!res.ok) {
    await res.body?.cancel();
    return null;
  }
  return await res.json() as AuthSession;
}

/** Revokes a session (local) or all of the user's sessions (global). */
export async function signOut(accessToken: string, scope: "local" | "global" = "local"): Promise<void> {
  try {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/logout?scope=${scope}`, {
      method: "POST",
      headers: { ...keyHeaders(publicKey()), Authorization: `Bearer ${accessToken}` },
    });
    await res.body?.cancel();
  } catch { /* best effort: the database barrier still applies */ }
}

export interface AdminResult {
  status: number;
  user?: { id: string; email?: string };
  message?: string;
}

async function adminCall(method: string, path: string, body?: unknown): Promise<AdminResult> {
  const res = await fetch(`${SUPABASE_URL}/auth/v1/admin${path}`, {
    method,
    headers: { ...keyHeaders(serviceKey()), "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let parsed: Record<string, unknown> = {};
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch { /* non-JSON */ }
  const user = (parsed.id ? parsed : parsed.user) as { id: string; email?: string } | undefined;
  return {
    status: res.status,
    user: user?.id ? { id: user.id, email: user.email } : undefined,
    message: String(parsed.msg ?? parsed.message ?? parsed.error_description ?? "").slice(0, 200),
  };
}

export function adminCreateUser(email: string, password: string): Promise<AdminResult> {
  return adminCall("POST", "/users", {
    email,
    password,
    email_confirm: true,
    app_metadata: {},
    user_metadata: {},
  });
}

export function adminUpdatePassword(userId: string, password: string): Promise<AdminResult> {
  return adminCall("PUT", `/users/${userId}`, { password });
}

/** Finds an Auth user by alias email (bounded paging; small organisations). */
export async function adminFindUserByEmail(email: string): Promise<{ id: string } | null> {
  for (let page = 1; page <= 50; page++) {
    const res = await fetch(`${SUPABASE_URL}/auth/v1/admin/users?page=${page}&per_page=200`, {
      headers: keyHeaders(serviceKey()),
    });
    if (!res.ok) return null;
    const body = await res.json() as { users?: { id: string; email?: string }[] };
    const users = body.users ?? [];
    const hit = users.find((u) => (u.email ?? "").toLowerCase() === email.toLowerCase());
    if (hit) return { id: hit.id };
    if (users.length < 200) return null;
  }
  return null;
}

/** Random temporary password: 16 chars, unambiguous alphabet, never stored. */
export function temporaryPassword(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  let out = "";
  for (const b of bytes) out += alphabet[b % alphabet.length];
  // Guarantee a digit and both cases for common password policies.
  return out.slice(0, 13) + "K7m";
}

export function validateNewPassword(pw: unknown, employeeCode?: string): string {
  if (typeof pw !== "string" || pw.length < 12 || pw.length > 128) {
    throw new ApiError("VALIDATION_FAILED", "Use at least 12 characters.", 422,
      { new_password: "At least 12 characters" });
  }
  if (employeeCode && pw.toUpperCase().includes(employeeCode.toUpperCase())) {
    throw new ApiError("VALIDATION_FAILED", "Do not include your employee ID in the password.", 422,
      { new_password: "Must not contain your employee ID" });
  }
  if (/^(.)\1+$/.test(pw)) {
    throw new ApiError("VALIDATION_FAILED", "Choose a less predictable password.", 422,
      { new_password: "Too simple" });
  }
  return pw;
}
