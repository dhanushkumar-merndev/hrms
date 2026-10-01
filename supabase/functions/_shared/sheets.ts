// Google Sheets mirror: rewrites one company spreadsheet, one tab per area,
// from internal_sheet_export. Values are written RAW so nothing is ever
// evaluated as a formula. New tabs get a coloured, frozen header row and
// banded rows; a tab we no longer send (Salary turned off) is deleted so its
// data does not linger.
import { SHEETS_SERVICE_ACCOUNT_B64 } from "./env.ts";
import { googleAccessToken, parseServiceAccount, type ServiceAccount } from "./google.ts";
import { rpc } from "./supabase.ts";

export const SHEETS_SCOPE = "https://www.googleapis.com/auth/spreadsheets";
/** Tabs this app owns; only these are ever deleted. */
export const OWNED_TABS = ["Overview", "Employees", "Attendance", "Leave & Requests", "Approvals",
  "Leave Balances", "Roles & Access", "Teams", "Salary"];

export interface Tab {
  name: string;
  header: unknown[];
  rows: unknown[][];
}

export class SheetError extends Error {}

let account: ServiceAccount | null | undefined;
export function sheetsAccount(): ServiceAccount | null {
  if (account === undefined) account = parseServiceAccount(SHEETS_SERVICE_ACCOUNT_B64);
  return account;
}

const API = "https://sheets.googleapis.com/v4/spreadsheets";
const HEADER_BG = { red: 0.294, green: 0.349, blue: 0.78 }; // #4B59C7 (app primary)
const BAND_ODD = { red: 0.937, green: 0.945, blue: 1 };
const WHITE = { red: 1, green: 1, blue: 1 };

const quote = (name: string) => `'${name.replaceAll("'", "''")}'`;

function cell(v: unknown): string | number | boolean {
  if (v === null || v === undefined) return "";
  if (typeof v === "number" || typeof v === "boolean") return v;
  if (typeof v === "string") return v;
  return JSON.stringify(v);
}

async function call(fetchFn: typeof fetch, token: string, url: string, body?: unknown, email = ""): Promise<unknown> {
  const res = await fetchFn(url, {
    method: body === undefined ? "GET" : "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (res.ok) return await res.json();
  const text = await res.text();
  if (text.includes("SERVICE_DISABLED") || text.includes("has not been used")) {
    throw new SheetError("Turn on the Google Sheets API for the service account's Google Cloud project.");
  }
  if (res.status === 403 || res.status === 404) {
    throw new SheetError(
      `The app cannot open this sheet. Share it with ${email || "the HRMS service account"} as Editor, then sync again.`,
    );
  }
  throw new SheetError(`Google Sheets error ${res.status}. Try again later.`);
}

/** Rewrites the spreadsheet with [tabs]; returns the number of data rows. */
export async function writeWorkbook(
  spreadsheetId: string,
  tabs: Tab[],
  sa: ServiceAccount,
  fetchFn: typeof fetch = fetch,
): Promise<number> {
  const token = await googleAccessToken(sa, SHEETS_SCOPE, fetchFn);
  const base = `${API}/${encodeURIComponent(spreadsheetId)}`;
  const meta = await call(fetchFn, token, `${base}?fields=sheets.properties(sheetId,title)`, undefined,
    sa.client_email) as { sheets?: { properties: { sheetId: number; title: string } }[] };
  const existing = new Map((meta.sheets ?? []).map((s) => [s.properties.title, s.properties.sheetId]));
  const wanted = new Set(tabs.map((t) => t.name));

  // Add missing tabs (styled), delete owned tabs we no longer send.
  const structure: unknown[] = [];
  const added: string[] = [];
  tabs.forEach((t, index) => {
    if (existing.has(t.name)) return;
    added.push(t.name);
    structure.push({
      addSheet: {
        properties: {
          title: t.name,
          index,
          gridProperties: { frozenRowCount: t.name === "Overview" ? 0 : 1 },
          tabColorStyle: { rgbColor: t.name === "Overview" ? HEADER_BG : BAND_ODD },
        },
      },
    });
  });
  for (const [title, sheetId] of existing) {
    if (!wanted.has(title) && OWNED_TABS.includes(title)) structure.push({ deleteSheet: { sheetId } });
  }
  // A spreadsheet must keep one sheet: delete the default "Sheet1" only
  // once ours exist.
  if (existing.has("Sheet1") && !wanted.has("Sheet1") && existing.size === 1 && added.length > 0) {
    structure.push({ deleteSheet: { sheetId: existing.get("Sheet1") } });
  }
  if (structure.length > 0) {
    const res = await call(fetchFn, token, `${base}:batchUpdate`, { requests: structure }, sa.client_email) as {
      replies?: { addSheet?: { properties: { sheetId: number; title: string } } }[];
    };
    for (const r of res.replies ?? []) {
      if (r.addSheet) existing.set(r.addSheet.properties.title, r.addSheet.properties.sheetId);
    }
  }

  // Values: clear, then write header + rows RAW.
  await call(fetchFn, token, `${base}/values:batchClear`, { ranges: tabs.map((t) => quote(t.name)) }, sa.client_email);
  let rows = 0;
  await call(fetchFn, token, `${base}/values:batchUpdate`, {
    valueInputOption: "RAW",
    data: tabs.map((t) => {
      rows += t.rows.length;
      return { range: `${quote(t.name)}!A1`, values: [t.header.map(cell), ...t.rows.map((r) => r.map(cell))] };
    }),
  }, sa.client_email);

  // Look: header style + banding on new tabs; column widths every time.
  const format: unknown[] = [];
  for (const t of tabs) {
    const sheetId = existing.get(t.name)!;
    if (added.includes(t.name)) {
      format.push({
        repeatCell: {
          range: { sheetId, startRowIndex: 0, endRowIndex: 1 },
          cell: {
            userEnteredFormat: {
              backgroundColorStyle: { rgbColor: HEADER_BG },
              textFormat: { bold: true, foregroundColorStyle: { rgbColor: WHITE }, fontSize: t.name === "Overview" ? 13 : 10 },
              verticalAlignment: "MIDDLE",
            },
          },
          fields: "userEnteredFormat(backgroundColorStyle,textFormat,verticalAlignment)",
        },
      });
      if (t.name !== "Overview") {
        format.push({
          addBanding: {
            bandedRange: {
              range: { sheetId, startRowIndex: 1, startColumnIndex: 0, endColumnIndex: Math.max(t.header.length, 1) },
              rowProperties: { firstBandColorStyle: { rgbColor: WHITE }, secondBandColorStyle: { rgbColor: BAND_ODD } },
            },
          },
        });
      }
    }
    format.push({
      autoResizeDimensions: {
        dimensions: { sheetId, dimension: "COLUMNS", startIndex: 0, endIndex: Math.max(t.header.length, 2) },
      },
    });
  }
  await call(fetchFn, token, `${base}:batchUpdate`, { requests: format }, sa.client_email);
  return rows;
}

/** Exports one organisation and writes its sheet; records the outcome. */
export async function syncOrg(orgId: string, fetchFn: typeof fetch = fetch): Promise<{ ok: boolean; rows?: number; error?: string }> {
  const sa = sheetsAccount();
  const exported = await rpc<{ spreadsheet_id: string; tabs: Tab[] }>("internal_sheet_export", { p_org_id: orgId });
  let outcome: { ok: boolean; rows?: number; error?: string };
  if (!sa) {
    outcome = { ok: false, error: "Google access is not set up on the server yet (service account key missing)." };
  } else {
    try {
      outcome = { ok: true, rows: await writeWorkbook(exported.spreadsheet_id, exported.tabs, sa, fetchFn) };
    } catch (e) {
      outcome = { ok: false, error: e instanceof SheetError ? e.message : "Could not reach Google Sheets. Retrying soon." };
    }
  }
  await rpc("internal_sheet_sync_result", {
    p_org_id: orgId,
    p_ok: outcome.ok,
    p_error: outcome.error ?? null,
    p_rows: outcome.rows ?? null,
  });
  return outcome;
}
