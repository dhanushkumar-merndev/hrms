import { ApiError, ok, readJson } from "../_shared/http.ts";

export interface LoginSupportLookup {
  allowed: boolean;
  display_phone: string | null;
  tel_uri: string | null;
}

export interface PublicConfigDependencies {
  hashIp(req: Request): Promise<string>;
  lookup(orgCode: string, ipHash: string): Promise<LoginSupportLookup>;
}

export function createPublicConfigHandler(deps: PublicConfigDependencies) {
  return async (req: Request, requestId: string): Promise<Response> => {
    const body = await readJson<{ action?: unknown; org_code?: unknown }>(req, 2048);
    if (body.action !== "login-support") {
      throw new ApiError("VALIDATION_FAILED", "Unknown public configuration request.", 400);
    }
    const orgCode = typeof body.org_code === "string" ? body.org_code.trim().toUpperCase() : "";
    if (!/^[A-Z0-9_-]{2,32}$/.test(orgCode)) {
      throw new ApiError("VALIDATION_FAILED", "Invalid organization.", 400, { org_code: "Invalid" });
    }
    const result = await deps.lookup(orgCode, await deps.hashIp(req));
    if (!result.allowed) {
      throw new ApiError("RATE_LIMITED", "Too many requests. Please wait a few minutes and try again.", 429, {}, true);
    }
    return ok({ display_phone: result.display_phone, tel_uri: result.tel_uri }, requestId);
  };
}
