// Response envelope, error mapping and request plumbing shared by functions.
// Success: {data, version, request_id}; error: {error:{code,message,
// field_errors,retryable}, request_id} (architecture.md §9).

export class ApiError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status = 400,
    readonly fieldErrors: Record<string, string> = {},
    readonly retryable = false,
  ) {
    super(message);
  }
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

export function requestIdOf(req: Request): string {
  const header = req.headers.get("x-request-id");
  return header && isUuid(header) ? header : crypto.randomUUID();
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

export function ok(data: unknown, requestId: string, version: number | null = null): Response {
  return json({ data, version, request_id: requestId });
}

const STATUS_BY_CODE: Record<string, number> = {
  AUTH_REQUIRED: 401,
  AUTH_FAILED: 401,
  ACCESS_DENIED: 403,
  ACCOUNT_INACTIVE: 403,
  PASSWORD_CHANGE_REQUIRED: 403,
  CREDENTIAL_OPERATION_PENDING: 409,
  REAUTH_REQUIRED: 403,
  VERIFICATION_FAILED: 403,
  RATE_LIMITED: 429,
  STALE_VERSION: 409,
  REQUEST_LOCKED: 409,
  IDEMPOTENCY_CONFLICT: 409,
  FILE_TOO_LARGE: 413,
  STORAGE_BUDGET_EXCEEDED: 507,
};

export function errorResponse(err: unknown, requestId: string): Response {
  if (err instanceof ApiError) {
    return json({
      error: { code: err.code, message: err.message, field_errors: err.fieldErrors, retryable: err.retryable },
      request_id: requestId,
    }, err.status);
  }
  // Unexpected: log a redacted diagnostic, return a generic message.
  console.error(JSON.stringify({ request_id: requestId, error: String((err as Error)?.message ?? err).slice(0, 300) }));
  return json({
    error: { code: "INTERNAL", message: "Something went wrong. Please try again.", field_errors: {}, retryable: true },
    request_id: requestId,
  }, 500);
}

/** Maps a PostgREST error from an HRMS RPC (P0001, message = code, details =
 * JSON) into an ApiError. */
export function fromPostgrest(e: { code?: string; message?: string; details?: string; hint?: string }): ApiError {
  if (e.code === "P0001" && e.message && /^[A-Z_]+$/.test(e.message)) {
    let detail: { message?: string; field_errors?: Record<string, string>; retryable?: boolean } = {};
    try {
      detail = JSON.parse(e.details ?? "{}");
    } catch { /* keep defaults */ }
    return new ApiError(
      e.message,
      detail.message ?? e.message,
      STATUS_BY_CODE[e.message] ?? 400,
      detail.field_errors ?? {},
      detail.retryable ?? e.hint === "retryable",
    );
  }
  if (e.code === "42501") return new ApiError("ACCESS_DENIED", "Not allowed.", 403);
  return new ApiError("INTERNAL", "Something went wrong. Please try again.", 500, {}, true);
}

export async function readJson<T = Record<string, unknown>>(req: Request, maxBytes = 65536): Promise<T> {
  if (req.method !== "POST") throw new ApiError("METHOD_NOT_ALLOWED", "Use POST.", 405);
  const length = Number(req.headers.get("content-length") ?? "0");
  if (length > maxBytes) throw new ApiError("VALIDATION_FAILED", "Request too large.", 413);
  const text = await req.text();
  if (text.length > maxBytes) throw new ApiError("VALIDATION_FAILED", "Request too large.", 413);
  try {
    const parsed = JSON.parse(text);
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("not an object");
    return parsed as T;
  } catch {
    throw new ApiError("VALIDATION_FAILED", "Invalid JSON body.", 400);
  }
}

/** Wraps a handler with request ids and uniform error handling. */
export function serve(handler: (req: Request, requestId: string) => Promise<Response>): void {
  Deno.serve(async (req) => {
    const requestId = requestIdOf(req);
    if (req.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: { "access-control-allow-methods": "POST" } });
    }
    try {
      return await handler(req, requestId);
    } catch (err) {
      return errorResponse(err, requestId);
    }
  });
}

export function str(v: unknown, field: string, max = 500): string {
  if (typeof v !== "string" || v.length === 0 || v.length > max) {
    throw new ApiError("VALIDATION_FAILED", `Invalid ${field}.`, 400, { [field]: "Invalid value" });
  }
  return v;
}

export function uuid(v: unknown, field: string): string {
  if (!isUuid(v)) throw new ApiError("VALIDATION_FAILED", `Invalid ${field}.`, 400, { [field]: "Invalid id" });
  return v;
}

/** Keyed hash of the caller IP (never store raw IPs). */
export async function ipHash(req: Request, pepper: string): Promise<string> {
  const ip = (req.headers.get("x-forwarded-for") ?? "").split(",")[0].trim() || "unknown";
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(pepper || "hrms-ip"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(ip));
  return toHex(new Uint8Array(mac)).slice(0, 32);
}

export function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

export async function sha256Hex(data: Uint8Array | string): Promise<string> {
  const bytes: Uint8Array<ArrayBuffer> = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  return toHex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)));
}

export function timingSafeEqual(a: string, b: string): boolean {
  const ea = new TextEncoder().encode(a);
  const eb = new TextEncoder().encode(b);
  let diff = ea.length ^ eb.length;
  for (let i = 0; i < Math.max(ea.length, eb.length); i++) diff |= (ea[i] ?? 0) ^ (eb[i] ?? 0);
  return diff === 0;
}

export function b64ToBytes(b64: string): Uint8Array<ArrayBuffer> {
  const normalized = b64.replace(/-/g, "+").replace(/_/g, "/");
  const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  const bin = atob(padded);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin);
}
