#!/usr/bin/env node
// Splits everything in client/ into ≤ 24,000-byte chunks that script/DeployUI.s.sol uploads.
//
//   node scripts/chunk.js            -> writes out/ui/files.txt + out/ui/<i>_<k>.bin
//
// files.txt format, one file per line:   <path>|<content-type>|<chunk-count>
const fs = require('fs');
const path = require('path');

const SRC = path.join(__dirname, '..', 'client');
const OUT = path.join(__dirname, '..', 'out', 'ui');
const CHUNK = 24_000; // SSTORE2 max is 24,575; leave headroom

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.txt': 'text/plain; charset=utf-8',
};

function walk(dir, base = '') {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const rel = base ? `${base}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...walk(path.join(dir, e.name), rel));
    else out.push(rel);
  }
  return out;
}

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });

const files = walk(SRC).filter((f) => !f.endsWith('.md'));
const lines = [];
let total = 0;
files.forEach((rel, i) => {
  const data = fs.readFileSync(path.join(SRC, rel));
  const type = TYPES[path.extname(rel)] || 'application/octet-stream';
  const n = Math.max(1, Math.ceil(data.length / CHUNK));
  for (let k = 0; k < n; k++) {
    fs.writeFileSync(path.join(OUT, `${i}_${k}.bin`), data.subarray(k * CHUNK, (k + 1) * CHUNK));
  }
  lines.push(`${rel}|${type}|${n}`);
  total += data.length;
  console.log(`${rel.padEnd(32)} ${String(data.length).padStart(7)} bytes  ${n} chunk(s)`);
});
fs.writeFileSync(path.join(OUT, 'files.txt'), lines.join('\n') + '\n');
console.log(`\n${files.length} files, ${total} bytes -> ${OUT}`);
console.log(`estimated upload gas: ~${Math.round(total * 200 / 1000)}k + ${files.length * 60}k overhead`);
