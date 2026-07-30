// Sanitise an MT5 chart template (.tpl) for distribution.
//
//   node tools/sanitize-template.mjs <input.tpl> [output.tpl]
//
// Three things have to happen before a template is safe to commit or serve:
//
//  1. .tpl files are UTF-16LE. Byte-oriented tools (grep, most editors) see
//     nothing in them, which makes secrets easy to miss. Decode, edit, and
//     re-encode as UTF-16LE or MetaTrader won't load the result.
//
//  2. MT5 bakes the attached EA's INPUT VALUES into the template. That is how
//     a Discord webhook / bridge token ends up in a file you were about to
//     publish. We drop the <inputs> block entirely so the EA falls back to its
//     compiled defaults, which are deliberately blank.
//
//  3. Every chart object gets saved too — including trade markers naming
//     tickets, volumes and symbols. Those are session state, not template
//     content, and they bloat the file enormously.

import fs from 'node:fs';
import path from 'node:path';

const [, , inPath, outPathArg] = process.argv;
if (!inPath) {
  console.error('usage: node tools/sanitize-template.mjs <input.tpl> [output.tpl]');
  process.exit(1);
}
const outPath = outPathArg ?? inPath.replace(/\.tpl$/i, '') + '.sanitised.tpl';

const raw = fs.readFileSync(inPath);
const isUtf16 = raw[0] === 0xff && raw[1] === 0xfe;
let text = raw.toString(isUtf16 ? 'utf16le' : 'utf8');
if (isUtf16 && text.charCodeAt(0) === 0xfeff) text = text.slice(1);   // strip BOM char

const before = {
  bytes: raw.length,
  objects: (text.match(/^<object>/gm) ?? []).length,
  inputs: (text.match(/^<inputs>/gm) ?? []).length,
};

// 1. Remove every <object> … </object> block.
text = text.replace(/^<object>\r?\n[\s\S]*?^<\/object>\r?\n?/gm, '');
// 2. Zero the declared object count so the header agrees with the body.
text = text.replace(/^objects=\d+/gm, 'objects=0');
// 3. Empty the EA input block — keep the tags, drop every value.
text = text.replace(/^<inputs>\r?\n[\s\S]*?^<\/inputs>/gm, '<inputs>\n</inputs>');
// 4. Collapse the blank lines the removals leave behind.
text = text.replace(/(\r?\n){3,}/g, '\n\n');

// ── refuse to emit anything that still looks like a credential ──
const SECRET_PATTERNS = [
  /https?:\/\/discord\.com\/api\/webhooks\/\S+/i,
  /\b[0-9a-f]{32,}\b/i,                 // long hex — bridge tokens look like this
  /(token|secret|password|apikey|api_key)\s*=\s*\S+/i,
  /https?:\/\/hooks\.slack\.com\/\S+/i,
];
const hits = SECRET_PATTERNS.flatMap((re) => text.match(re) ?? []);
if (hits.length) {
  console.error('REFUSING TO WRITE — the sanitised template still matches credential patterns:');
  for (const h of hits) console.error('   ' + h.slice(0, 60) + '…');
  process.exit(2);
}

// Re-encode as UTF-16LE with BOM, which is what MetaTrader expects.
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(text, 'utf16le')]));

const after = fs.statSync(outPath).size;
console.log(`in  : ${inPath}`);
console.log(`      ${before.bytes.toLocaleString()} bytes · ${before.objects} objects · ${before.inputs} input block(s)`);
console.log(`out : ${outPath}`);
console.log(`      ${after.toLocaleString()} bytes · 0 objects · inputs emptied`);
console.log(`      ${(100 - (after / before.bytes) * 100).toFixed(1)}% smaller · no credential patterns found`);
