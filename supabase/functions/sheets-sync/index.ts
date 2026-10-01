// POST /sheets-sync {action: "status"}  -> is Google access set up, and which
//                                          address to share the sheet with
// POST /sheets-sync {action: "sync"}    -> rewrite the company sheet now
// Admin only. Scheduled refreshes run through /maintenance {kind: "sheets"}.
import { ApiError, ok, readJson, serve } from "../_shared/http.ts";
import { sheetsAccount, syncOrg } from "../_shared/sheets.ts";
import { actorParams, requireCaller, rpc } from "../_shared/supabase.ts";

serve(async (req, requestId) => {
  const caller = await requireCaller(req);
  const body = await readJson<{ action?: string }>(req, 1024);
  const actor = await rpc<{ org_id: string }>("internal_sheet_sync_authorize", actorParams(caller));

  if (body.action === "status") {
    const sa = sheetsAccount();
    return ok({ configured: sa !== null, service_account_email: sa?.client_email ?? null }, requestId);
  }

  if (body.action === "sync") {
    const allowed = await rpc<boolean>("internal_rate_limit", {
      p_bucket: `sheets:${actor.org_id}`,
      p_window_seconds: 3600,
      p_max: 30,
    });
    if (!allowed) throw new ApiError("RATE_LIMITED", "Too many syncs. Try again later.", 429, {}, true);
    const result = await syncOrg(actor.org_id);
    if (!result.ok) throw new ApiError("SHEET_SYNC_FAILED", result.error ?? "Sync failed.", 502, {}, true);
    return ok({ rows: result.rows }, requestId);
  }

  throw new ApiError("VALIDATION_FAILED", "Unknown action.", 400);
});
