// Server-side configuration for Edge Functions. Values come from Supabase's
// injected variables plus the HRMS_* secrets pushed by tool/deploy.dart.
// Nothing here is ever returned to clients.

export function envOr(name: string, fallback = ""): string {
  return Deno.env.get(name) ?? fallback;
}

export const SUPABASE_URL = envOr("SUPABASE_URL");

function namedKey(jsonVar: string): string {
  const raw = Deno.env.get(jsonVar);
  if (!raw) return "";
  try {
    const parsed = JSON.parse(raw) as Record<string, string>;
    return parsed["default"] ?? Object.values(parsed)[0] ?? "";
  } catch {
    return "";
  }
}

/** Service key (bypasses RLS). Legacy JWT preferred while it exists. */
export function serviceKey(): string {
  return envOr("SUPABASE_SERVICE_ROLE_KEY") || namedKey("SUPABASE_SECRET_KEYS");
}

/** Public key used for end-user Auth calls (password grant, logout). */
export function publicKey(): string {
  return envOr("SUPABASE_ANON_KEY") || namedKey("SUPABASE_PUBLISHABLE_KEYS");
}

/** Headers for calling Supabase APIs with a key. New-style keys (sb_...)
 * go on `apikey` only; legacy JWT keys also on Authorization. */
export function keyHeaders(key: string): Record<string, string> {
  return key.startsWith("sb_") ? { apikey: key } : { apikey: key, Authorization: `Bearer ${key}` };
}

export const ENVIRONMENT = envOr("HRMS_ENVIRONMENT", "staging");
export const IS_PRODUCTION = ENVIRONMENT === "production";

/** Production always enforces hardware attestation; other environments
 * additionally accept software/emulator keys (recorded as such). */
export const INTEGRITY_MODE: "enforce" | "development" = IS_PRODUCTION
  ? "enforce"
  : (envOr("HRMS_INTEGRITY_MODE", "development") === "enforce" ? "enforce" : "development");

export const ALIAS_DOMAIN = envOr("HRMS_AUTH_ALIAS_DOMAIN", "staff.hrms.invalid");
export const ANDROID_PACKAGE = envOr("HRMS_ANDROID_PACKAGE_NAME", "com.internalhrms.hrms");
/** SHA-256 digests (hex, lowercase, no colons) of certificates allowed to
 * sign the app. Comma separated. Empty = not enforced outside production. */
export const ANDROID_CERT_DIGESTS = envOr("HRMS_ANDROID_CERT_SHA256")
  .split(",")
  .map((s) => s.trim().toLowerCase().replaceAll(":", ""))
  .filter((s) => s.length === 64);

export const MAINTENANCE_SECRET = envOr("HRMS_MAINTENANCE_SECRET");
export const FCM_SERVICE_ACCOUNT_B64 = envOr("HRMS_FCM_SERVICE_ACCOUNT_B64");
/** Service account for the Google Sheets mirror; falls back to the push
 * (Firebase) account when the same Google Cloud project is used for both. */
export const SHEETS_SERVICE_ACCOUNT_B64 = envOr("HRMS_SHEETS_SERVICE_ACCOUNT_B64") || FCM_SERVICE_ACCOUNT_B64;
