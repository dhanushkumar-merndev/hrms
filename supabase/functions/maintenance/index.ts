// POST /maintenance {kind: "outbox" | "tick" | "daily"}
// Invoked by pg_cron through pg_net with a shared secret from Vault (never a
// user token). Work is claimed in bounded, leased batches and stops before
// the runtime deadline; uncertain pushes retry with the same event id.
import { MAINTENANCE_SECRET } from "../_shared/env.ts";
import { pushConfigured, sendPush } from "../_shared/fcm.ts";
import { ApiError, ok, readJson, serve, timingSafeEqual } from "../_shared/http.ts";
import { rpc, serviceClient } from "../_shared/supabase.ts";

const SOFT_DEADLINE_MS = 40_000;

interface Job {
  outbox_id: number;
  event_id: string;
  kind: string;
  title: string;
  body: string | null;
  deep_link: string | null;
  tokens: { token: string; platform: string }[];
}

serve(async (req, requestId) => {
  const secret = req.headers.get("x-hrms-maintenance-secret") ?? "";
  if (!MAINTENANCE_SECRET || !timingSafeEqual(secret, MAINTENANCE_SECRET)) {
    throw new ApiError("ACCESS_DENIED", "Not allowed.", 403);
  }
  const started = Date.now();
  const body = await readJson<{ kind?: string }>(req, 1024);

  if (body.kind === "outbox") {
    const jobs = await rpc<Job[]>("internal_claim_outbox", { p_limit: 50, p_lease_seconds: 60 });
    const results: { outbox_id: number; outcome: string; error?: string; invalid_tokens?: string[] }[] = [];
    for (const job of jobs) {
      if (Date.now() - started > SOFT_DEADLINE_MS) {
        results.push({ outbox_id: job.outbox_id, outcome: "retry", error: "deadline" });
        continue;
      }
      if (!pushConfigured() || job.tokens.length === 0) {
        results.push({ outbox_id: job.outbox_id, outcome: "skipped" });
        continue;
      }
      const invalid: string[] = [];
      let sent = 0;
      let retry = false;
      for (const t of job.tokens) {
        try {
          const outcome = await sendPush(t.token, {
            eventId: job.event_id, kind: job.kind, title: job.title, body: job.body, deepLink: job.deep_link,
          });
          if (outcome === "sent") sent++;
          else if (outcome === "invalid") invalid.push(t.token);
          else retry = true;
        } catch {
          retry = true;
        }
      }
      results.push({
        outbox_id: job.outbox_id,
        outcome: sent > 0 ? "sent" : retry ? "retry" : "skipped",
        invalid_tokens: invalid,
      });
    }
    const done = await rpc("internal_complete_outbox", { p_results: results });
    return ok({ claimed: jobs.length, ...done as object }, requestId);
  }

  if (body.kind === "tick") {
    const tick = await rpc<{ staging_keys: string[]; final_keys: string[]; rolled_over_sessions: number }>(
      "internal_maintenance_tick",
      {},
    );
    const storage = serviceClient().storage;
    for (let i = 0; i < tick.staging_keys.length; i += 100) {
      await storage.from("hrms-staging").remove(tick.staging_keys.slice(i, i + 100));
    }
    for (let i = 0; i < tick.final_keys.length; i += 100) {
      await storage.from("hrms-files").remove(tick.final_keys.slice(i, i + 100));
    }
    return ok({ rolled_over_sessions: tick.rolled_over_sessions, removed_uploads: tick.staging_keys.length }, requestId);
  }

  if (body.kind === "daily") {
    return ok(await rpc("internal_maintenance_daily", {}), requestId);
  }

  throw new ApiError("VALIDATION_FAILED", "Unknown kind.", 400);
});
