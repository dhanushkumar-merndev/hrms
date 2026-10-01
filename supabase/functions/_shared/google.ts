// Google service-account access tokens (OAuth 2.0 JWT bearer grant), shared
// by push (FCM) and the Google Sheets mirror. Tokens are cached per scope in
// memory only; the private key never leaves the function.
import { b64ToBytes } from "./http.ts";

export interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

/** Parses a base64-encoded service-account JSON; null when absent/invalid. */
export function parseServiceAccount(b64: string): ServiceAccount | null {
  if (!b64) return null;
  try {
    const sa = JSON.parse(new TextDecoder().decode(b64ToBytes(b64))) as ServiceAccount;
    return sa.client_email && sa.private_key ? sa : null;
  } catch {
    return null;
  }
}

function b64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let bin = "";
  for (const x of b) bin += String.fromCharCode(x);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const cache = new Map<string, { value: string; expiresAt: number }>();

export async function googleAccessToken(
  sa: ServiceAccount,
  scope: string,
  fetchFn: typeof fetch = fetch,
): Promise<string> {
  const key = `${sa.client_email} ${scope}`;
  const hit = cache.get(key);
  if (hit && hit.expiresAt > Date.now() + 60_000) return hit.value;
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const signingKey = await crypto.subtle.importKey(
    "pkcs8",
    b64ToBytes(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = b64url(JSON.stringify({
    iss: sa.client_email,
    scope,
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const signature = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", signingKey, new TextEncoder().encode(`${header}.${claims}`)),
  );
  const res = await fetchFn("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${b64url(signature)}`,
    }),
  });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`Google sign-in failed (${res.status}). Check the service account key.`);
  }
  const body = await res.json() as { access_token: string; expires_in: number };
  cache.set(key, { value: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 });
  return body.access_token;
}
