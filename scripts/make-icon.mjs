#!/usr/bin/env node
// Generates App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png (1024×1024, opaque RGB)
// with no dependencies: diagonal gradient + white check mark inside a ring + three "team" dots.
import { deflateSync } from 'node:zlib';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const SIZE = 1024;
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'App', 'Resources', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon.png');

const top = [65, 108, 217]; // accent blue
const bottom = [88, 56, 179]; // indigo
const white = [255, 255, 255];

function distToSegment(px, py, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay;
  const t = Math.max(0, Math.min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)));
  return Math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

// Coverage in [0,1] of a shape given a signed distance (negative inside), 1px anti-aliasing.
const cover = (signedDistance) => Math.max(0, Math.min(1, 0.5 - signedDistance));

const cx = 512, cy = 470, ringR = 300, ringW = 44;
const check = [[362, 478], [470, 588], [668, 380]];
const checkW = 58;
const dots = [[392, 868], [512, 868], [632, 868]];
const dotR = 38;

const rowBytes = SIZE * 3 + 1;
const raw = Buffer.alloc(rowBytes * SIZE);
for (let y = 0; y < SIZE; y++) {
  raw[y * rowBytes] = 0; // filter: none
  for (let x = 0; x < SIZE; x++) {
    const t = (x + y) / (2 * SIZE);
    let color = top.map((c, i) => c + (bottom[i] - c) * t);

    const ring = Math.abs(Math.hypot(x - cx, y - cy) - ringR) - ringW / 2;
    const tick = Math.min(
      distToSegment(x, y, ...check[0], ...check[1]),
      distToSegment(x, y, ...check[1], ...check[2]),
    ) - checkW / 2;
    const dot = Math.min(...dots.map(([dx, dy]) => Math.hypot(x - dx, y - dy))) - dotR;

    const alpha = Math.max(cover(ring), cover(tick), cover(dot));
    color = color.map((c, i) => Math.round(c + (white[i] - c) * alpha));
    const o = y * rowBytes + 1 + x * 3;
    raw[o] = color[0];
    raw[o + 1] = color[1];
    raw[o + 2] = color[2];
  }
}

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});
function crc32(buf) {
  let c = 0xffffffff;
  for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0);
ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 2; // color type: RGB (no alpha — required for App Store icons)
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);
writeFileSync(out, png);
console.log(`Wrote ${path.relative(root, out)} (${png.length} bytes)`);
