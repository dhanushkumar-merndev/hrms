// Public holiday calendar feed (iCalendar) -> holiday SUGGESTIONS. Nothing
// here publishes a holiday: an Admin reviews every suggestion in the app.
import { envOr } from "./env.ts";

export interface HolidayItem {
  day: string; // YYYY-MM-DD
  name: string;
  category: string | null;
  uid: string | null;
}

// Google's public "Holidays in India" calendar (no API key). Override with
// HRMS_HOLIDAY_ICS_URL for another region or provider.
export const HOLIDAY_ICS_URL = envOr(
  "HRMS_HOLIDAY_ICS_URL",
  "https://calendar.google.com/calendar/ical/en.indian%23holiday%40group.v.calendar.google.com/public/basic.ics",
);

const MAX_FEED_CHARS = 2_000_000;

function unescapeText(v: string): string {
  return v.replace(/\\n/gi, " ").replace(/\\([,;\\])/g, "$1").replace(/\s+/g, " ").trim();
}

function validDay(y: number, m: number, d: number): boolean {
  const date = new Date(Date.UTC(y, m - 1, d));
  return date.getUTCFullYear() === y && date.getUTCMonth() === m - 1 && date.getUTCDate() === d;
}

function toItem(ev: Record<string, string>): HolidayItem | null {
  const m = /^(\d{4})(\d{2})(\d{2})/.exec(ev.DTSTART ?? "");
  if (!m || !validDay(Number(m[1]), Number(m[2]), Number(m[3]))) return null;
  const name = unescapeText(ev.SUMMARY ?? "").slice(0, 120);
  if (!name) return null;
  // Feeds describe the kind on the first line ("Public holiday", "Observance").
  const firstLine = unescapeText((ev.DESCRIPTION ?? "").split(/\\n/i)[0]);
  const category = firstLine.split(/[.:]/)[0].trim().slice(0, 60);
  return { day: `${m[1]}-${m[2]}-${m[3]}`, name, category: category || null, uid: (ev.UID ?? "").slice(0, 200) || null };
}

/** Parses VEVENTs (RFC 5545 line unfolding; first value of each property). */
export function parseIcs(text: string, maxItems = 500): HolidayItem[] {
  const unfolded = text.slice(0, MAX_FEED_CHARS).replace(/\r?\n[ \t]/g, "");
  const out: HolidayItem[] = [];
  const seen = new Set<string>();
  let event: Record<string, string> | null = null;
  for (const raw of unfolded.split(/\r?\n/)) {
    const line = raw.trimEnd();
    if (line === "BEGIN:VEVENT") {
      event = {};
      continue;
    }
    if (line === "END:VEVENT") {
      const item = event ? toItem(event) : null;
      event = null;
      if (item && !seen.has(`${item.day}|${item.name}`)) {
        seen.add(`${item.day}|${item.name}`);
        out.push(item);
        if (out.length >= maxItems) break;
      }
      continue;
    }
    if (!event) continue;
    const idx = line.indexOf(":");
    if (idx <= 0) continue;
    const key = line.slice(0, idx).split(";")[0].toUpperCase();
    if (!(key in event)) event[key] = line.slice(idx + 1);
  }
  return out.sort((a, b) => a.day.localeCompare(b.day) || a.name.localeCompare(b.name));
}

export async function fetchHolidayFeed(url = HOLIDAY_ICS_URL): Promise<HolidayItem[]> {
  const res = await fetch(url, { headers: { accept: "text/calendar" }, signal: AbortSignal.timeout(15_000) });
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`feed status ${res.status}`);
  }
  const text = await res.text();
  if (text.length > MAX_FEED_CHARS) throw new Error("feed too large");
  return parseIcs(text);
}
