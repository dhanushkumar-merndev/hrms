// POST /archive {action: "file_url", job_id, file_version_id}
//   -> audited <=60 s signed link for ONE inventoried cloud file of an annual
//      export (Admin only). The app streams it to disk and verifies SHA-256.
// POST /archive {action: "cleanup_batch", cleanup_job_id, reconcile_only?}
//   -> claims one leased batch for the current driver Admin, deletes exactly
//      those objects, and records each outcome (tombstones + audit).
import { deleteBatch } from "../_shared/archive.ts";
import { ApiError, ok, readJson, serve, uuid } from "../_shared/http.ts";
import { actorParams, requireCaller, rpc, serviceClient } from "../_shared/supabase.ts";

serve(async (req, requestId) => {
  const caller = await requireCaller(req);
  const body = await readJson<Record<string, unknown>>(req, 4096);
  const storage = serviceClient().storage;

  if (body.action === "file_url") {
    const grant = await rpc<{
      available: boolean;
      bucket?: string;
      object_key?: string;
      size_bytes?: number;
      sha256?: string;
      grant_id?: string;
      message?: string;
    }>("internal_authorize_export_file", {
      ...actorParams(caller),
      p_job_id: uuid(body.job_id, "job_id"),
      p_file_version_id: uuid(body.file_version_id, "file_version_id"),
    });
    if (!grant.available) return ok({ available: false, message: grant.message }, requestId);
    const { data, error } = await storage.from(grant.bucket!).createSignedUrl(grant.object_key!, 60);
    if (error || !data) throw new ApiError("UPLOAD_UNAVAILABLE", "Could not prepare the download. Try again.", 503, {}, true);
    return ok({
      available: true,
      url: data.signedUrl,
      expires_in: 60,
      size_bytes: grant.size_bytes,
      sha256: grant.sha256,
      grant_id: grant.grant_id,
    }, requestId);
  }

  if (body.action === "cleanup_batch") {
    const jobId = uuid(body.cleanup_job_id, "cleanup_job_id");
    const worker = crypto.randomUUID();
    const claim = await rpc<{
      done?: boolean;
      busy?: boolean;
      items?: { item_id: number; bucket: string; object_key: string }[];
    }>("internal_cleanup_claim", {
      ...actorParams(caller),
      p_cleanup_job_id: jobId,
      p_worker: worker,
      p_limit: 20,
      p_reconcile_only: body.reconcile_only === true,
    });
    const items = claim.items ?? [];
    if (claim.done || claim.busy || items.length === 0) return ok(claim, requestId);
    const results = await deleteBatch(items, async (bucket, keys) => {
      const { error } = await storage.from(bucket).remove(keys);
      return { error };
    });
    const done = await rpc("internal_cleanup_complete", {
      ...actorParams(caller),
      p_cleanup_job_id: jobId,
      p_worker: worker,
      p_results: results,
    });
    return ok(done, requestId);
  }

  throw new ApiError("VALIDATION_FAILED", "Unknown action.", 400);
});
