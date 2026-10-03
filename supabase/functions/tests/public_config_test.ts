import { assertEquals } from "jsr:@std/assert@1";
import { createPublicConfigHandler, type LoginSupportLookup } from "../public-config/handler.ts";

const request = (body: unknown) => new Request("https://example.test/functions/v1/public-config", {
  method: "POST",
  headers: { "content-type": "application/json", "x-forwarded-for": "203.0.113.7" },
  body: JSON.stringify(body),
});

function handler(result: LoginSupportLookup) {
  return createPublicConfigHandler({
    hashIp: async () => "hashed-ip",
    lookup: async (orgCode, ipHash) => {
      assertEquals(orgCode, "MAIN");
      assertEquals(ipHash, "hashed-ip");
      return result;
    },
  });
}

Deno.test("SUPPORT-005 login support returns only the configured phone projection", async () => {
  const res = await handler({ allowed: true, display_phone: "+91 98765 43210", tel_uri: "tel:+919876543210" })(
    request({ action: "login-support", org_code: "MAIN" }),
    "00000000-0000-4000-8000-000000000001",
  );
  assertEquals(res.status, 200);
  assertEquals(await res.json(), {
    data: { display_phone: "+91 98765 43210", tel_uri: "tel:+919876543210" },
    version: null,
    request_id: "00000000-0000-4000-8000-000000000001",
  });
  assertEquals(res.headers.get("cache-control"), "no-store");
});

Deno.test("SUPPORT-005 missing configuration is a successful null projection", async () => {
  const res = await handler({ allowed: true, display_phone: null, tel_uri: null })(
    request({ action: "login-support", org_code: "MAIN" }),
    "00000000-0000-4000-8000-000000000002",
  );
  assertEquals(res.status, 200);
  assertEquals((await res.json()).data, { display_phone: null, tel_uri: null });
});

Deno.test("SUPPORT-006 lookup throttling maps to a retryable generic rate limit", async () => {
  const res = await handler({ allowed: false, display_phone: null, tel_uri: null })(
    request({ action: "login-support", org_code: "MAIN" }),
    "00000000-0000-4000-8000-000000000003",
  ).catch((error) => error);
  assertEquals(res.code, "RATE_LIMITED");
  assertEquals(res.status, 429);
  assertEquals(res.retryable, true);
});

Deno.test("SUPPORT-007 unsupported actions and malformed organisation codes are rejected before lookup", async () => {
  let calls = 0;
  const h = createPublicConfigHandler({
    hashIp: async () => "hashed-ip",
    lookup: async () => {
      calls++;
      return { allowed: true, display_phone: null, tel_uri: null };
    },
  });
  for (const body of [
    { action: "employees", org_code: "MAIN" },
    { action: "login-support", org_code: "MAIN<script>" },
  ]) {
    const error = await h(request(body), crypto.randomUUID()).catch((value) => value);
    assertEquals(error.code, "VALIDATION_FAILED");
  }
  assertEquals(calls, 0);
});
