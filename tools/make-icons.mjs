// Generates the PWA app icons with zero dependencies.
//
// PNG has no built-in encoder in Node, but node:zlib gives us DEFLATE, which is
// all a PNG's IDAT actually is. We compute an RGBA pixel buffer by hand — a
// rounded-square in the EA's palette with three ascending bars (a trading motif
// that reads at 48px on a home screen) — then wrap it in the four PNG chunks.
//
//   node tools/make-icons.mjs
import fs from 'node:fs';
import zlib from 'node:zlib';
import path from 'node:path';

const OUT = path.join(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')),
                      '..', 'webapp', 'public');

// ── CRC32 (PNG chunk checksum) ──────────────────────────────────────
const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return (buf) => {
    let c = 0xFFFFFFFF;
    for (let i = 0; i < buf.length; i++) c = t[(c ^ buf[i]) & 0xFF] ^ (c >>> 8);
    return (c ^ 0xFFFFFFFF) >>> 0;
  };
})();

const chunk = (type, data) => {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(CRC(body), 0);
  return Buffer.concat([len, body, crc]);
};

const png = (w, h, rgba) => {
  const sig = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6;   // 8-bit, RGBA
  // Each scanline is prefixed with a filter byte (0 = none).
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, y * stride + stride);
  }
  const idat = zlib.deflateSync(raw, { level: 9 });
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
};

// ── the mark ────────────────────────────────────────────────────────
const hex = (s) => [parseInt(s.slice(0, 2), 16), parseInt(s.slice(2, 4), 16), parseInt(s.slice(4, 6), 16)];
const BG   = hex('0e0e16');   // panel bg
const PANEL= hex('181a26');
const GOLD = hex('b99b37');
const GREEN= hex('009650');
const BLUE = hex('1976d2');

function draw(size, maskable) {
  const rgba = Buffer.alloc(size * size * 4);
  // Maskable icons must keep their content inside a safe circle, so the design
  // fills the whole canvas and lets the launcher crop; non-maskable gets a
  // rounded square with transparent corners.
  const pad = maskable ? 0 : Math.round(size * 0.06);
  const radius = maskable ? 0 : Math.round(size * 0.22);
  const inner = size - pad * 2;

  const put = (x, y, [r, g, b], a = 255) => {
    if (x < 0 || y < 0 || x >= size || y >= size) return;
    const i = (y * size + x) * 4;
    rgba[i] = r; rgba[i + 1] = g; rgba[i + 2] = b; rgba[i + 3] = a;
  };

  const inRounded = (x, y) => {
    const lx = x - pad, ly = y - pad;
    if (lx < 0 || ly < 0 || lx >= inner || ly >= inner) return false;
    if (radius === 0) return true;
    const cx = Math.min(lx, inner - 1 - lx), cy = Math.min(ly, inner - 1 - ly);
    if (cx >= radius || cy >= radius) return true;
    const dx = radius - cx, dy = radius - cy;
    return dx * dx + dy * dy <= radius * radius;
  };

  // background
  for (let y = 0; y < size; y++)
    for (let x = 0; x < size; x++)
      if (inRounded(x, y)) put(x, y, maskable ? PANEL : BG);

  // gold frame
  const fw = Math.max(2, Math.round(size * 0.02));
  for (let y = 0; y < size; y++)
    for (let x = 0; x < size; x++) {
      if (!inRounded(x, y)) continue;
      const lx = x - pad, ly = y - pad;
      if (lx < fw || ly < fw || lx >= inner - fw || ly >= inner - fw) put(x, y, GOLD);
    }

  // three ascending bars
  const bars = [{ h: 0.30, c: BLUE }, { h: 0.50, c: GOLD }, { h: 0.72, c: GREEN }];
  const zoneX = pad + inner * 0.20, zoneW = inner * 0.60;
  const baseY = pad + inner * 0.76;
  const bw = zoneW / 3 * 0.6, gap = zoneW / 3 * 0.4;
  bars.forEach((bar, k) => {
    const x0 = Math.round(zoneX + k * (bw + gap));
    const top = Math.round(baseY - inner * bar.h);
    for (let y = top; y < baseY; y++)
      for (let x = x0; x < x0 + bw; x++)
        put(Math.round(x), Math.round(y), bar.c);
  });

  return png(size, size, rgba);
}

for (const [name, size, mask] of [
  ['icon-192.png', 192, false],
  ['icon-512.png', 512, false],
  ['icon-maskable-512.png', 512, true],
  ['apple-touch-icon.png', 180, false],
]) {
  const file = path.join(OUT, name);
  fs.writeFileSync(file, draw(size, mask));
  console.log('wrote', name, fs.statSync(file).size, 'bytes');
}
