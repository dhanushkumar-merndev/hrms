// Firebase Cloud Messaging (HTTP v1) sender. Push is best effort / at least
// once: each message carries the stable event_id so the app can discard
// duplicates. Payloads never include salary, medical, location or private
// details — only the lock-screen-safe title/body stored with the inbox row.
import { FCM_SERVICE_ACCOUNT_B64 } from "./env.ts";
import { googleAccessToken, parseServiceAccount, type ServiceAccount } from "./google.ts";

let account: ServiceAccount | null | undefined;

function serviceAccount(): ServiceAccount | null {
  if (account === undefined) account = parseServiceAccount(FCM_SERVICE_ACCOUNT_B64);
  return account;
}

export function pushConfigured(): boolean {
  return serviceAccount() !== null;
}

function accessToken(): Promise<string> {
  const sa = serviceAccount();
  if (!sa) throw new Error("push not configured");
  return googleAccessToken(sa, "https://www.googleapis.com/auth/firebase.messaging");
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
