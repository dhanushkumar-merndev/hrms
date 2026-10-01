// POST /files {action: "begin" | "finish" | "access", ...}
//   begin  -> reserve quota, create a staging slot, return a signed upload URL
//   finish -> copy staging bytes to a NEW server-only final object, validate
//             and hash the FINAL bytes, settle the reservation, delete staging
//   access -> authorise, audit and return a <=60 s signed download URL
// Clients have no direct Storage permissions on either bucket.
import { ApiError, ok, readJson, serve, sha256Hex, uuid } from "../_shared/http.ts";
import { validateFile } from "../_shared/files.ts";
import { actorParams, requireCaller, rpc, serviceClient } from "../_shared/supabase.ts";

const ALLOWED: Record<string, string[]> = {
  payslip: ["application/pdf"],
  employee_document: ["application/pdf"],
  avatar: ["image/jpeg", "image/png", "image/webp"],
};
const DEFAULT_ALLOWED = ["application/pdf", "image/jpeg", "image/png"];

serve(async (req, requestId) => {
  const caller = await requireCaller(req);
  const body = await readJson<Record<string, unknown>>(req, 8192);
  const storage = serviceClient().storage;

  if (body.action === "begin") {
    const begin = await rpc<{ file_version_id: string; staging_bucket: string; staging_key: string; expires_at: string }>(
      "internal_begin_upload",
      {
        ...actorParams(caller),
        p_class: body.class,
        p_owner_employee_id: body.owner_employee_id ?? null,
        p_salary_month: body.salary_month ?? null,
        p_document_date: body.document_date ?? null,
        p_title: body.title ?? null,
        p_filename: typeof body.filename === "string" ? body.filename.slice(0, 200) : "file",
        p_declared_size: Number(body.size ?? 0),
        p_declared_mime: body.mime ?? null,
      },
    );
    const { data, error } = await storage.from(begin.staging_bucket).createSignedUploadUrl(begin.staging_key);
    if (error || !data) throw new ApiError("UPLOAD_UNAVAILABLE", "Upload is temporarily unavailable.", 503, {}, true);
    return ok({
      file_version_id: begin.file_version_id,
      upload_url: data.signedUrl,
      upload_token: data.token,
      bucket: begin.staging_bucket,
      path: begin.staging_key,
      expires_at: begin.expires_at,
    }, requestId);
  }

  if (body.action === "finish") {
    const versionId = uuid(body.file_version_id, "file_version_id");
    const prep = await rpc<{
      already_complete: boolean;
      state?: string;
      staging_bucket: string;
      staging_key: string;
      final_bucket: string;
      final_key: string;
      class: string;
      declared_mime: string;
    }>("internal_finish_upload_prepare", { ...actorParams(caller), p_file_version_id: versionId });
    if (prep.already_complete) return ok(prep, requestId);

    // Copy staging -> final (server-only). If a previous attempt already
    // wrote the final object, keep it: replayed staging uploads cannot
    // change bytes that were promoted.
    const existing = await storage.from(prep.final_bucket).download(prep.final_key);
    if (existing.error) {
      const staged = await storage.from(prep.staging_bucket).download(prep.staging_key);
      if (staged.error || !staged.data) {
        throw new ApiError("VALIDATION_FAILED", "The upload was not received. Please upload again.", 422, {}, true);
      }
      const bytes = new Uint8Array(await staged.data.arrayBuffer());
      if (bytes.length > 5_000_000) {
        await rpc("internal_finish_upload_complete", {
          ...actorParams(caller), p_file_version_id: versionId, p_valid: false, p_detected_mime: null,
          p_size_bytes: null, p_sha256: null, p_error: "File larger than 5,000,000 bytes",
        });
        await storage.from(prep.staging_bucket).remove([prep.staging_key]);
        throw new ApiError("FILE_TOO_LARGE", "Files must be at most 5 MB (5,000,000 bytes).", 413);
      }
      const put = await storage.from(prep.final_bucket).upload(prep.final_key, bytes, {
        contentType: prep.declared_mime,
        upsert: false,
      });
      if (put.error && !String(put.error.message).includes("exists")) {
        throw new ApiError("UPLOAD_UNAVAILABLE", "Could not store the file. Try again.", 503, {}, true);
      }
    } else {
      await existing.data?.arrayBuffer();
    }

    // Validate and hash the FINAL bytes only.
    const final = await storage.from(prep.final_bucket).download(prep.final_key);
    if (final.error || !final.data) throw new ApiError("UPLOAD_UNAVAILABLE", "Could not verify the file.", 503, {}, true);
    const finalBytes = new Uint8Array(await final.data.arrayBuffer());
    const check = validateFile(finalBytes, prep.declared_mime, ALLOWED[prep.class] ?? DEFAULT_ALLOWED);
    const sha = check.valid ? await sha256Hex(finalBytes) : null;
    const done = await rpc<Record<string, unknown>>("internal_finish_upload_complete", {
      ...actorParams(caller),
      p_file_version_id: versionId,
      p_valid: check.valid,
      p_detected_mime: check.mime ?? null,
      p_size_bytes: check.valid ? finalBytes.length : null,
      p_sha256: sha,
      p_error: check.error ?? null,
    });
    await storage.from(prep.staging_bucket).remove([prep.staging_key]);
    if (!check.valid) {
      await storage.from(prep.final_bucket).remove([prep.final_key]);
      throw new ApiError("INVALID_FILE_TYPE", check.error ?? "The file was rejected.", 422, { file: check.error ?? "Rejected" });
    }
    return ok({ file_version_id: versionId, ...done }, requestId);
  }

  if (body.action === "access") {
    const versionId = uuid(body.file_version_id, "file_version_id");
    const purpose = body.purpose === "download" ? "download" : body.purpose === "review" ? "review" : "view";
    const grant = await rpc<{
      available: boolean;
      grant_id?: string;
      bucket?: string;
      object_key?: string;
      ttl_seconds?: number;
      mime?: string;
      filename?: string;
      size_bytes?: number;
      message?: string;
    }>("internal_authorize_file_access", { ...actorParams(caller), p_file_version_id: versionId, p_purpose: purpose });
    if (!grant.available) return ok({ available: false, message: grant.message }, requestId);
    const { data, error } = await storage.from(grant.bucket!).createSignedUrl(grant.object_key!, 60,
      purpose === "download" ? { download: grant.filename ?? true } : undefined);
    if (error || !data) throw new ApiError("UPLOAD_UNAVAILABLE", "Could not open the file. Try again.", 503, {}, true);
    return ok({
      available: true,
      url: data.signedUrl,
      expires_in: 60,
      grant_id: grant.grant_id,
      mime: grant.mime,
      filename: grant.filename,
      size_bytes: grant.size_bytes,
    }, requestId);
  }

  throw new ApiError("VALIDATION_FAILED", "Unknown action.", 400);
});
