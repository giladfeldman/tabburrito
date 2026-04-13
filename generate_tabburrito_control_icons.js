const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

function roundedRect(x, y, w, h, r, px, py) {
  const dx = Math.max(Math.abs(px - (x + w / 2)) - (w / 2 - r), 0);
  const dy = Math.max(Math.abs(py - (y + h / 2)) - (h / 2 - r), 0);
  return Math.sqrt(dx * dx + dy * dy) <= r;
}

function circle(cx, cy, r, px, py) {
  const dx = px - cx;
  const dy = py - cy;
  return dx * dx + dy * dy <= r * r;
}

function createPng(size) {
  const w = size;
  const h = size;
  const raw = Buffer.alloc((w * 4 + 1) * h);

  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const off = y * (w * 4 + 1) + 1 + x * 4;
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;

      const bg = roundedRect(w * 0.08, h * 0.08, w * 0.84, h * 0.84, w * 0.18, x, y);
      if (bg) {
        const t = y / h;
        r = Math.round(10 + t * 8);
        g = Math.round(110 + t * 40);
        b = Math.round(108 + t * 28);
        a = 255;
      }

      const accent = roundedRect(w * 0.18, h * 0.22, w * 0.64, h * 0.54, w * 0.14, x, y);
      if (accent) {
        r = 245;
        g = 132;
        b = 31;
        a = 255;
      }

      const stripe1 = roundedRect(w * 0.25, h * 0.34, w * 0.5, h * 0.08, w * 0.03, x, y);
      const stripe2 = roundedRect(w * 0.25, h * 0.46, w * 0.5, h * 0.08, w * 0.03, x, y);
      if (stripe1 || stripe2) {
        r = 255;
        g = 245;
        b = 236;
        a = 255;
      }

      const badge = circle(w * 0.76, h * 0.26, w * 0.12, x, y);
      if (badge) {
        r = 16;
        g = 34;
        b = 34;
        a = 255;
      }

      const badgeDot = circle(w * 0.76, h * 0.26, w * 0.055, x, y);
      if (badgeDot) {
        r = 255;
        g = 255;
        b = 255;
        a = 255;
      }

      raw[off] = r;
      raw[off + 1] = g;
      raw[off + 2] = b;
      raw[off + 3] = a;
    }
  }

  const deflated = zlib.deflateSync(raw);
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  function chunk(type, data) {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const t = Buffer.from(type);
    const cd = Buffer.concat([t, data]);
    let crc = 0xffffffff;
    for (const value of cd) {
      crc ^= value;
      for (let i = 0; i < 8; i++) {
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
      }
    }
    crc = (crc ^ 0xffffffff) >>> 0;
    const c = Buffer.alloc(4);
    c.writeUInt32BE(crc);
    return Buffer.concat([len, t, data, c]);
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;

  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', deflated), chunk('IEND', Buffer.alloc(0))]);
}

function createIco(png32) {
  const hdr = Buffer.alloc(6);
  hdr.writeUInt16LE(0, 0);
  hdr.writeUInt16LE(1, 2);
  hdr.writeUInt16LE(1, 4);
  const entry = Buffer.alloc(16);
  entry[0] = 32;
  entry[1] = 32;
  entry.writeUInt16LE(1, 4);
  entry.writeUInt16LE(32, 6);
  entry.writeUInt32LE(png32.length, 8);
  entry.writeUInt32LE(22, 12);
  return Buffer.concat([hdr, entry, png32]);
}

const outDir = path.join(__dirname, 'tabburrito-lite', 'src-tauri', 'icons');
fs.mkdirSync(outDir, { recursive: true });

const icon32 = createPng(32);
const icon128 = createPng(128);

fs.writeFileSync(path.join(outDir, 'icon.png'), icon32);
fs.writeFileSync(path.join(outDir, 'icon-notification.png'), icon32);
fs.writeFileSync(path.join(outDir, 'icon.ico'), createIco(icon32));

console.log(`Wrote Tabburrito Control icons to ${outDir}`);
