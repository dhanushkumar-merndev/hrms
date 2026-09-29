// Bounded validation of uploaded bytes (runs on the FINAL immutable copy).
// This is structural validation, not malware scanning: no scanner is
// claimed. PDFs with encryption or active content are rejected; images must
// have sane decoded dimensions so small compressed files cannot expand into
// huge bitmaps downstream.

export const MAX_BYTES = 5_000_000;
const MAX_PIXELS = 40_000_000;
const MAX_SIDE = 12_000;
const MAX_PDF_PAGES = 2_000;

export interface FileCheck {
  valid: boolean;
  mime?: string;
  error?: string;
}

function startsWith(bytes: Uint8Array, sig: number[], offset = 0): boolean {
  return sig.every((b, i) => bytes[offset + i] === b);
}

export function detectMime(bytes: Uint8Array): string | null {
  if (startsWith(bytes, [0x25, 0x50, 0x44, 0x46, 0x2d])) return "application/pdf";
  if (startsWith(bytes, [0xff, 0xd8, 0xff])) return "image/jpeg";
  if (startsWith(bytes, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) return "image/png";
  if (startsWith(bytes, [0x52, 0x49, 0x46, 0x46]) && startsWith(bytes, [0x57, 0x45, 0x42, 0x50], 8)) return "image/webp";
  return null;
}

function latin1(bytes: Uint8Array): string {
  // Chunked to keep memory bounded for 5 MB inputs.
  let out = "";
  for (let i = 0; i < bytes.length; i += 65536) {
    out += String.fromCharCode(...bytes.subarray(i, Math.min(i + 65536, bytes.length)));
  }
  return out;
}

function checkPdf(bytes: Uint8Array): string | null {
  const text = latin1(bytes);
  const tail = text.slice(-4096);
  if (!tail.includes("%%EOF")) return "The PDF is incomplete or damaged.";
  if (/\/Encrypt\b/.test(text)) return "Password-protected PDFs cannot be checked. Upload an unprotected copy.";
  if (/\/(JavaScript|JS|Launch|EmbeddedFile|RichMedia|XFA)\b/.test(text)) {
    return "The PDF contains scripts or embedded content and was rejected.";
  }
  const pages = (text.match(/\/Type\s*\/Page(?![s\w])/g) ?? []).length;
  if (pages > MAX_PDF_PAGES) return "The PDF has too many pages.";
  return null;
}

function u32be(b: Uint8Array, o: number): number {
  return ((b[o] << 24) >>> 0) + (b[o + 1] << 16) + (b[o + 2] << 8) + b[o + 3];
}

export function imageSize(bytes: Uint8Array, mime: string): { w: number; h: number } | null {
  if (mime === "image/png") {
    if (bytes.length < 24) return null;
    return { w: u32be(bytes, 16), h: u32be(bytes, 20) };
  }
  if (mime === "image/jpeg") {
    let i = 2;
    while (i + 9 < bytes.length) {
      if (bytes[i] !== 0xff) return null;
      const marker = bytes[i + 1];
      const len = (bytes[i + 2] << 8) + bytes[i + 3];
      const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
      if (isSof) return { h: (bytes[i + 5] << 8) + bytes[i + 6], w: (bytes[i + 7] << 8) + bytes[i + 8] };
      if (len < 2) return null;
      i += 2 + len;
    }
    return null;
  }
  if (mime === "image/webp") {
    const chunk = String.fromCharCode(...bytes.subarray(12, 16));
    if (chunk === "VP8X" && bytes.length >= 30) {
      return {
        w: 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16)),
        h: 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16)),
      };
    }
    if (chunk === "VP8 " && bytes.length >= 30) {
      return { w: (bytes[26] | (bytes[27] << 8)) & 0x3fff, h: (bytes[28] | (bytes[29] << 8)) & 0x3fff };
    }
    if (chunk === "VP8L" && bytes.length >= 25) {
      const b = bytes.subarray(21, 25);
      return { w: 1 + (((b[1] & 0x3f) << 8) | b[0]), h: 1 + (((b[3] & 0x0f) << 10) | (b[2] << 2) | ((b[1] & 0xc0) >> 6)) };
    }
    return null;
  }
  return null;
}

export function validateFile(bytes: Uint8Array, declaredMime: string, allowed: string[]): FileCheck {
  if (bytes.length === 0) return { valid: false, error: "The file is empty." };
  if (bytes.length > MAX_BYTES) return { valid: false, error: "The file is larger than 5 MB (5,000,000 bytes)." };
  const mime = detectMime(bytes);
  if (!mime || !allowed.includes(mime)) return { valid: false, error: "This file type is not allowed here." };
  if (mime !== declaredMime) return { valid: false, error: "The file content does not match its type." };
  if (mime === "application/pdf") {
    const err = checkPdf(bytes);
    return err ? { valid: false, mime, error: err } : { valid: true, mime };
  }
  const size = imageSize(bytes, mime);
  if (!size || size.w < 1 || size.h < 1) return { valid: false, mime, error: "The image could not be read." };
  if (size.w > MAX_SIDE || size.h > MAX_SIDE || size.w * size.h > MAX_PIXELS) {
    return { valid: false, mime, error: "The image dimensions are too large." };
  }
  return { valid: true, mime };
}
