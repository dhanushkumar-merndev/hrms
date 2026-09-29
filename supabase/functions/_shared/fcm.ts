// Firebase Cloud Messaging (HTTP v1) sender. Push is best effort / at least
// once: each message carries the stable event_id so the app can discard
// duplicates. Payloads never include salary, medical, location or private
// details — only the lock-screen-safe title/body stored with the inbox row.
import { b64ToBytes } from "./http.ts";
import { FCM_SERVICE_ACCOUNT_B64 } from "./env.ts";

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

let account: ServiceAccount | null | undefined;
let token: { value: string; expiresAt: number } | null = null;

function serviceAccount(): ServiceAccount | null {
  if (account !== undefined) return account;
  try {
    account = FCM_SERVICE_ACCOUNT_B64
      ? JSON.parse(new TextDecoder().decode(b64ToBytes(FCM_SERVICE_ACCOUNT_B64))) as ServiceAccount
      : null;
  } catch {
    account = null;
  }
  return account;
}

export function pushConfigured(): boolean {
  return serviceAccount() !== null;
}

function b64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let bin = "";
  for (const x of b) bin += String.fromCharCode(x);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function accessToken(): Promise<string> {
  if (token && token.expiresAt > Date.now() + 60_000) return token.value;
  const sa = serviceAccount();
  if (!sa) throw new Error("push not configured");
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const key = await crypto.subtle.importKey(
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
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const signature = new Uint8Array(
    await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claims}`)),
  );
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: `${header}.${claims}.${b64url(signature)}`,
    }),
  });
  if (!res.ok) throw new Error(`oauth ${res.status}`);
  const body = await res.json() as { access_token: string; expires_in: number };
  token = { value: body.access_token, expiresAt: Date.now() + body.expires_in * 1000 };
  return token.value;
}

export type PushOutcome = "sent" | "invalid" | "retry";

export async function sendPush(
  deviceToken: string,
  msg: { eventId: string; kind: string; title: string; body: string | null; deepLink: string | null },
): Promise<PushOutcome> {
  const sa = serviceAccount();
  if (!sa) return "retry";
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${await accessToken()}`, "content-type": "application/json" },
    body: JSON.stringify({
      message: {
        token: deviceToken,
        notification: { title: msg.title, body: msg.body ?? "" },
        data: { event_id: msg.eventId, kind: msg.kind, deep_link: msg.deepLink ?? "/notifications" },
        android: { priority: "HIGH", notification: { channel_id: "hrms_default" } },
        apns: { payload: { aps: { sound: "default" } } },
      },
    }),
  });
  if (res.ok) {
    await res.body?.cancel();
    return "sent";
  }
  const text = await res.text();
  if (res.status === 404 || text.includes("UNREGISTERED") || (res.status === 400 && text.includes("INVALID_ARGUMENT"))) {
    return "invalid";
  }
  return "retry";
}
