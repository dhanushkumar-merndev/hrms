// POST /holiday-suggestions {}
// Admin (or HR with policy drafting) refreshes suggestions from the public
// holiday feed now. Suggestions only: nothing is published or drafted until
// the reviewer chooses "Add as draft" in the app.
import { fetchHolidayFeed } from "../_shared/holidays.ts";
import { ApiError, ok, readJson, serve } from "../_shared/http.ts";
import { actorParams, requireCaller, rpc } from "../_shared/supabase.ts";

serve(async (req, requestId) => {
  const caller = await requireCaller(req);
  await readJson(req, 1024);
  const actor = await rpc<{ org_id: string; permissions: string[] }>(
    "internal_resolve_actor",
    { ...actorParams(caller), p_mode: "business" },
  );
  const perms = actor.permissions ?? [];
  if (!perms.includes("*") && !perms.includes("policy.draft")) throw new ApiError("ACCESS_DENIED", "Not allowed.", 403);
  const allowed = await rpc<boolean>("internal_rate_limit", {
    p_bucket: `holidays:${actor.org_id}`,
    p_window_seconds: 3600,
    p_max: 5,
  });
  if (!allowed) throw new ApiError("RATE_LIMITED", "Too many refreshes. Try again later.", 429, {}, true);

  let items;
  try {
    items = await fetchHolidayFeed();
  } catch {
    throw new ApiError("FEED_UNAVAILABLE",
      "The public holiday calendar could not be reached. You can still add holidays manually.", 503, {}, true);
  }
  const stored = await rpc<{ added: number }>("internal_store_holiday_suggestions", {
    p_org_id: actor.org_id,
    p_source: "public_calendar",
    p_items: items,
  });
  return ok({ fetched: items.length, added: stored.added }, requestId);
});
