// Generate Tabburrito icons — a cute burrito emoji-style icon
const fs = require('fs');
const zlib = require('zlib');

function createPNG(size, hasNotification = false) {
  const w = size, h = size;
  const raw = Buffer.alloc((w * 4 + 1) * h);
  const cx = w / 2, cy = h / 2;
  const r = w * 0.42; // main radius

  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0; // filter: none
    for (let x = 0; x < w; x++) {
      const off = y * (w * 4 + 1) + 1 + x * 4;
      const dx = x - cx, dy = y - cy;
      const dist = Math.sqrt(dx * dx + dy * dy);

      let R = 0, G = 0, B = 0, A = 0;

      // Burrito body — warm tortilla oval
      const ovalX = dx / (r * 1.1);
      const ovalY = dy / (r * 0.85);
      const ovalDist = Math.sqrt(ovalX * ovalX + ovalY * ovalY);

      if (ovalDist < 1.0) {
        // Tortilla gradient — warm golden brown
        const t = ovalDist;
        R = Math.round(240 - t * 50);
        G = Math.round(190 - t * 60);
        B = Math.round(120 - t * 50);
        A = 255;

        // Filling stripe in the middle (colorful)
        const stripeY = (y - cy) / r;
        if (Math.abs(stripeY) < 0.25 && ovalDist < 0.85) {
          // Rice/beans/salsa layers
          const stripePos = (stripeY + 0.25) / 0.5; // 0-1
          if (stripePos < 0.33) {
            // Green (guac/lettuce)
            R = 100; G = 180; B = 80;
          } else if (stripePos < 0.66) {
            // Red (salsa)
            R = 220; G = 80; B = 60;
          } else {
            // Yellow (cheese)
            R = 250; G = 210; B = 80;
          }
        }

        // Wrap fold lines (subtle darker curves)
        const foldAngle = Math.atan2(dy, dx);
        if (ovalDist > 0.7 && ovalDist < 0.95) {
          const fold = Math.sin(foldAngle * 3 + 1.5) * 0.5 + 0.5;
          if (fold > 0.7) {
            R = Math.round(R * 0.85);
            G = Math.round(G * 0.85);
            B = Math.round(B * 0.85);
          }
        }

        // Cute face — eyes and smile
        const eyeL = Math.sqrt((x - cx + r*0.22) ** 2 + (y - cy + r*0.05) ** 2);
        const eyeR = Math.sqrt((x - cx - r*0.22) ** 2 + (y - cy + r*0.05) ** 2);
        const eyeSize = r * 0.09;

        if (eyeL < eyeSize || eyeR < eyeSize) {
          R = 40; G = 30; B = 30; A = 255;
        }

        // Eye shine
        const shineL = Math.sqrt((x - cx + r*0.24) ** 2 + (y - cy + r*0.08) ** 2);
        const shineR = Math.sqrt((x - cx - r*0.20) ** 2 + (y - cy + r*0.08) ** 2);
        if (shineL < eyeSize * 0.4 || shineR < eyeSize * 0.4) {
          R = 255; G = 255; B = 255; A = 255;
        }

        // Smile (arc below eyes)
        const smileDist = Math.sqrt(dx * dx + (y - cy - r*0.12) ** 2);
        if (smileDist > r * 0.18 && smileDist < r * 0.24 && y > cy + r*0.08) {
          R = 40; G = 30; B = 30; A = 255;
        }

        // Anti-alias edge
        if (ovalDist > 0.92) {
          const edge = (1.0 - ovalDist) / 0.08;
          A = Math.round(255 * Math.max(0, Math.min(1, edge)));
        }
      }

      // Notification dot (top-right, red circle)
      if (hasNotification) {
        const dotCx = w * 0.78, dotCy = h * 0.18;
        const dotR = w * 0.15;
        const dotDist = Math.sqrt((x - dotCx) ** 2 + (y - dotCy) ** 2);
        if (dotDist < dotR) {
          R = 239; G = 68; B = 68; A = 255;
          // White border
          if (dotDist > dotR * 0.7 && dotDist < dotR) {
            const edge = (dotR - dotDist) / (dotR * 0.3);
            if (edge < 0.3) {
              R = 255; G = 255; B = 255;
            }
          }
          // Anti-alias
          if (dotDist > dotR - 1) {
            A = Math.round(255 * (dotR - dotDist));
          }
        }
      }

      raw[off] = R;
      raw[off + 1] = G;
      raw[off + 2] = B;
      raw[off + 3] = A;
    }
  }

  const deflated = zlib.deflateSync(raw);
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

  function chunk(type, data) {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const t = Buffer.from(type);
    const cd = Buffer.concat([t, data]);
    let crc = 0xFFFFFFFF;
    for (const b of cd) { crc ^= b; for (let i = 0; i < 8; i++) crc = (crc >>> 1) ^ (crc & 1 ? 0xEDB88320 : 0); }
    crc = (crc ^ 0xFFFFFFFF) >>> 0;
    const c = Buffer.alloc(4); c.writeUInt32BE(crc);
    return Buffer.concat([len, t, data, c]);
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 6;

  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', deflated), chunk('IEND', Buffer.alloc(0))]);
}

function createICO(png32) {
  const hdr = Buffer.alloc(6);
  hdr.writeUInt16LE(0, 0); hdr.writeUInt16LE(1, 2); hdr.writeUInt16LE(1, 4);
  const entry = Buffer.alloc(16);
  entry[0] = 32; entry[1] = 32; entry[2] = 0; entry[3] = 0;
  entry.writeUInt16LE(1, 4); entry.writeUInt16LE(32, 6);
  entry.writeUInt32LE(png32.length, 8); entry.writeUInt32LE(22, 12);
  return Buffer.concat([hdr, entry, png32]);
}

// Normal icons
const sizes = { '32x32.png': 32, '128x128.png': 128, '128x128@2x.png': 256, 'icon.png': 32 };
for (const [name, size] of Object.entries(sizes)) {
  fs.writeFileSync(`src-tauri/icons/${name}`, createPNG(size, false));
  console.log(`Created ${name}`);
}
fs.writeFileSync('src-tauri/icons/icon.ico', createICO(createPNG(32, false)));
console.log('Created icon.ico');

// Notification variant icons (with red dot)
fs.writeFileSync('src-tauri/icons/icon-notification.png', createPNG(32, true));
fs.writeFileSync('src-tauri/icons/icon-notification.ico', createICO(createPNG(32, true)));
console.log('Created notification icons');
