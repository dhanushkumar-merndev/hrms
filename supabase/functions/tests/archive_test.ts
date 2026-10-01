// HOL-002 (feed parsing is suggestion input only) and DEL-004/005 (exact-key
// batch deletion with truthful per-item outcomes).
import { assertEquals } from "jsr:@std/assert@1";
import { deleteBatch } from "../_shared/archive.ts";
import { parseIcs } from "../_shared/holidays.ts";

const FEED = [
  "BEGIN:VCALENDAR",
  "BEGIN:VEVENT",
  "DTSTART;VALUE=DATE:20270126",
  "DTEND;VALUE=DATE:20270127",
  "SUMMARY:Republic Day",
  "DESCRIPTION:Public holiday",
  "UID:20270126_republic@google.com",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTSTART;VALUE=DATE:20270815",
  "SUMMARY:Independence",
  "  Day",
  "DESCRIPTION:Public holiday. More text\\, escaped",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTSTART;VALUE=DATE:20270126",
  "SUMMARY:Republic Day",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTSTART;VALUE=DATE:20270230",
  "SUMMARY:Impossible date",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTSTART;VALUE=DATE:20271101",
  "SUMMARY:",
  "END:VEVENT",
  "BEGIN:VEVENT",
  "DTSTART;VALUE=DATE:20270314",
  "SUMMARY:Holi",
  "DESCRIPTION:Observance\\nTo hide observances\\, change settings",
  "END:VEVENT",
  "END:VCALENDAR",
].join("\r\n");

Deno.test("HOL-002 feed parsing: unfolding, de-duplication, invalid dates and empty names dropped", () => {
  const items = parseIcs(FEED);
  assertEquals(items.map((i) => `${i.day} ${i.name}`), [
    "2027-01-26 Republic Day",
    "2027-03-14 Holi",
    "2027-08-15 Independence Day",
  ]);
  assertEquals(items[0].category, "Public holiday");
  assertEquals(items[0].uid, "20270126_republic@google.com");
  assertEquals(items[1].category, "Observance");
  assertEquals(items[2].category, "Public holiday");
});

Deno.test("HOL-002 bounded output", () => {
  const many = ["BEGIN:VCALENDAR"];
  for (let d = 1; d <= 28; d++) {
    many.push("BEGIN:VEVENT", `DTSTART;VALUE=DATE:202702${String(d).padStart(2, "0")}`, `SUMMARY:Day ${d}`, "END:VEVENT");
  }
  assertEquals(parseIcs(many.join("\n"), 10).length, 10);
});

Deno.test("DEL-004 only the exact claimed keys are removed, per bucket, in chunks", async () => {
  const calls: { bucket: string; keys: string[] }[] = [];
  const items = Array.from({ length: 25 }, (_, i) => ({ item_id: i + 1, bucket: "hrms-files", object_key: `org/${i}` }));
  const results = await deleteBatch(items, (bucket, keys) => {
    calls.push({ bucket, keys });
    return Promise.resolve({ error: null });
  }, 20);
  assertEquals(calls.map((c) => c.keys.length), [20, 5]);
  assertEquals(calls.flatMap((c) => c.keys), items.map((i) => i.object_key));
  assertEquals(results.every((r) => r.ok), true);
});

Deno.test("DEL-005 a failing chunk reports failure for exactly its items", async () => {
  const items = [
    { item_id: 1, bucket: "hrms-files", object_key: "org/a" },
    { item_id: 2, bucket: "hrms-files", object_key: "org/b" },
    { item_id: 3, bucket: "hrms-files", object_key: "org/c" },
  ];
  let call = 0;
  const results = await deleteBatch(items, () => {
    call++;
    if (call === 2) return Promise.reject(new Error("storage 503"));
    return Promise.resolve({ error: null });
  }, 2);
  assertEquals(results, [
    { item_id: 1, ok: true },
    { item_id: 2, ok: true },
    { item_id: 3, ok: false, error: "storage 503" },
  ]);
});

Deno.test("DEL-004 traversal-looking keys are never sent to storage", async () => {
  const sent: string[] = [];
  const results = await deleteBatch([
    { item_id: 1, bucket: "hrms-files", object_key: "../other-org/x" },
    { item_id: 2, bucket: "hrms-files", object_key: "/abs" },
    { item_id: 3, bucket: "hrms-files", object_key: "org/ok" },
  ], (_b, keys) => {
    sent.push(...keys);
    return Promise.resolve({ error: null });
  });
  assertEquals(sent, ["org/ok"]);
  assertEquals(results, [{ item_id: 3, ok: true }]);
});
