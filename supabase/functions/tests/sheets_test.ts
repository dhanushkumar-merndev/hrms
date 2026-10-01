// SHEET-005..007: the Google Sheets writer, against a fake Google API.
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import type { ServiceAccount } from "../_shared/google.ts";
import { SheetError, type Tab, writeWorkbook } from "../_shared/sheets.ts";

async function testAccount(): Promise<ServiceAccount> {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let bin = "";
  for (const b of der) bin += String.fromCharCode(b);
  return {
    project_id: "test",
    client_email: `sheets-${crypto.randomUUID().slice(0, 8)}@test.iam.gserviceaccount.com`,
    private_key: `-----BEGIN PRIVATE KEY-----\n${btoa(bin)}\n-----END PRIVATE KEY-----\n`,
  };
}

interface Call {
  url: string;
  body: Record<string, unknown> | null;
}

function fakeGoogle(existing: { title: string; sheetId: number }[], opts: { metaStatus?: number } = {}) {
  const calls: Call[] = [];
  let nextId = 100;
  const fn = (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    const body = init?.body && typeof init.body === "string" ? JSON.parse(init.body) : null;
    calls.push({ url, body });
    const json = (v: unknown, status = 200) => Promise.resolve(new Response(JSON.stringify(v), { status }));
    if (url.startsWith("https://oauth2.googleapis.com/token")) return json({ access_token: "tok", expires_in: 3600 });
    if (url.includes("?fields=")) {
      if (opts.metaStatus) return json({ error: { status: "PERMISSION_DENIED" } }, opts.metaStatus);
      return json({ sheets: existing.map((p) => ({ properties: p })) });
    }
    if (url.endsWith(":batchUpdate")) {
      const requests = (body?.requests as Record<string, { properties: { title: string } }>[]) ?? [];
      return json({
        replies: requests.map((r) =>
          r.addSheet ? { addSheet: { properties: { sheetId: nextId++, title: r.addSheet.properties.title } } } : {}
        ),
      });
    }
    return json({});
  };
  return { fn: fn as typeof fetch, calls };
}

const tabs: Tab[] = [
  { name: "Overview", header: ["HRMS live data", ""], rows: [["Organisation", "Test"]] },
  { name: "Employees", header: ["Employee ID", "Name", "Salary"], rows: [["EMP01", "=HYPERLINK(\"x\")", 45000], ["EMP02", null, null]] },
];

Deno.test("SHEET-005 new sheet: tabs added and styled, default Sheet1 removed, values RAW", async () => {
  const g = fakeGoogle([{ title: "Sheet1", sheetId: 0 }]);
  const rows = await writeWorkbook("sheet123", tabs, await testAccount(), g.fn);
  assertEquals(rows, 3);
  const structure = g.calls.find((c) => c.url.endsWith(":batchUpdate"))!.body!.requests as Record<string, unknown>[];
  assertEquals(structure.filter((r) => r.addSheet).length, 2);
  assert(structure.some((r) => (r.deleteSheet as { sheetId: number } | undefined)?.sheetId === 0), "Sheet1 removed");
  const write = g.calls.find((c) => c.url.endsWith("/values:batchUpdate"))!.body!;
  assertEquals(write.valueInputOption, "RAW", "never evaluated as formulas");
  const data = write.data as { range: string; values: unknown[][] }[];
  assertEquals(data[1].range, "'Employees'!A1");
  assertEquals(data[1].values[1], ["EMP01", "=HYPERLINK(\"x\")", 45000], "text kept as text, numbers as numbers");
  assertEquals(data[1].values[2], ["EMP02", "", ""], "nulls become empty cells");
  const format = g.calls.filter((c) => c.url.endsWith(":batchUpdate")).at(-1)!.body!.requests as Record<string, unknown>[];
  assert(format.some((r) => r.repeatCell), "header styled");
  assert(format.some((r) => r.addBanding), "rows banded");
});

Deno.test("SHEET-006 Salary tab is deleted when salary export is turned off; other tabs untouched", async () => {
  const g = fakeGoogle([
    { title: "Overview", sheetId: 1 },
    { title: "Employees", sheetId: 2 },
    { title: "Salary", sheetId: 3 },
    { title: "My notes", sheetId: 4 },
  ]);
  await writeWorkbook("sheet123", tabs, await testAccount(), g.fn);
  const structure = g.calls.find((c) => c.url.endsWith(":batchUpdate"))!.body!.requests as Record<string, unknown>[];
  assertEquals(structure, [{ deleteSheet: { sheetId: 3 } }], "only the app-owned Salary tab is removed");
  const format = g.calls.filter((c) => c.url.endsWith(":batchUpdate")).at(-1)!.body!.requests as Record<string, unknown>[];
  assert(!format.some((r) => r.addBanding), "existing tabs are not re-styled");
});

Deno.test("SHEET-007 sheet not shared with the service account -> clear instruction with its email", async () => {
  const sa = await testAccount();
  const g = fakeGoogle([], { metaStatus: 403 });
  const err = await assertRejects(() => writeWorkbook("sheet123", tabs, sa, g.fn), SheetError);
  assert(err.message.includes(sa.client_email), err.message);
  assert(!g.calls.some((c) => c.url.includes("values")), "nothing written");
});
