// FILE-003/004/018: structural validation of final uploaded bytes.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { detectMime, imageSize, MAX_BYTES, validateFile } from "../_shared/files.ts";

const enc = (s: string) => new TextEncoder().encode(s);
const PDF = ["application/pdf"];

function pdf(body = "", size?: number): Uint8Array {
  const head = `%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n3 0 obj << /Type /Page /Parent 2 0 R >> endobj\n${body}`;
  const tail = "\ntrailer << /Root 1 0 R >>\n%%EOF\n";
  if (!size) return enc(head + tail);
  const pad = size - enc(head).length - enc(tail).length;
  return enc(head + "%" + "x".repeat(Math.max(0, pad - 1)) + tail);
}

Deno.test("valid PDF accepted; exactly 5,000,000 bytes accepted; one byte more rejected", () => {
  assert(validateFile(pdf(), "application/pdf", PDF).valid);
  const max = pdf("", MAX_BYTES);
  assertEquals(max.length, MAX_BYTES);
  assert(validateFile(max, "application/pdf", PDF).valid, "exact 5,000,000 bytes");
  const over = pdf("", MAX_BYTES + 1);
  assertEquals(over.length, MAX_BYTES + 1);
  assert(!validateFile(over, "application/pdf", PDF).valid, "5,000,001 bytes rejected");
});

Deno.test("empty, truncated, mismatched and wrong-class files rejected", () => {
  assert(!validateFile(new Uint8Array(), "application/pdf", PDF).valid);
  assert(!validateFile(enc("%PDF-1.4\n1 0 obj"), "application/pdf", PDF).valid, "no %%EOF");
  assert(!validateFile(pdf(), "image/png", ["image/png"]).valid, "declared PNG but is PDF");
  assert(!validateFile(enc("MZ\x90\x00 executable"), "application/pdf", PDF).valid, "bad magic");
});

Deno.test("encrypted PDFs and active content rejected", () => {
  assert(!validateFile(pdf("4 0 obj << /Filter /Standard >> endobj\ntrailer << /Encrypt 4 0 R >>"), "application/pdf", PDF).valid);
  assert(!validateFile(pdf("5 0 obj << /S /JavaScript /JS (app.alert(1)) >> endobj"), "application/pdf", PDF).valid);
  assert(!validateFile(pdf("6 0 obj << /S /Launch /F (cmd.exe) >> endobj"), "application/pdf", PDF).valid);
});

Deno.test("image dimensions parsed and bounded", () => {
  const png = new Uint8Array(33);
  png.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]);
  const dv = new DataView(png.buffer);
  dv.setUint32(16, 800);
  dv.setUint32(20, 600);
  assertEquals(detectMime(png), "image/png");
  assertEquals(imageSize(png, "image/png"), { w: 800, h: 600 });
  assert(validateFile(png, "image/png", ["image/png"]).valid);
  dv.setUint32(16, 50000);
  dv.setUint32(20, 50000);
  assert(!validateFile(png, "image/png", ["image/png"]).valid, "decompression-bomb dimensions rejected");

  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x00, 0x00, 0xff, 0xc0, 0x00, 0x11, 0x08,
    0x01, 0xe0, 0x02, 0x80, 0x03, 0x01, 0x22, 0x00]);
  assertEquals(imageSize(jpeg, "image/jpeg"), { w: 640, h: 480 });
});
