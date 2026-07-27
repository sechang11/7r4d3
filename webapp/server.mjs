// RiskManager Web Bridge — zero-dependency Node server.
//
//   EA  ──POST /api/state──────────►  server  ──►  web app (view + plan)
//       ◄─GET  /api/commands/next──┘
//
// Design rules:
//  * The EA is the single source of truth for live computation. This server
//    stores snapshots and relays commands; it never recomputes engine state.
//  * Every command carries a unique id. The EA acks by id, and a command is
//    only ever dispatched once — a duplicate poll cannot double-fire an order.
//  * Binds to 127.0.0.1 by default. Nothing is exposed to the network unless
//    you explicitly set HOST.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = Number(process.env.PORT ?? 8787);

// A container on a PaaS must bind 0.0.0.0 or the platform's router can't reach
// it — binding loopback there produces a "service unavailable" health check
// failure even though the process is running fine. Locally we still default to
// loopback, which is the safe choice. Explicit HOST always wins.
const ON_PAAS = Boolean(
  process.env.RAILWAY_ENVIRONMENT || process.env.RAILWAY_SERVICE_ID ||
  process.env.RAILWAY_PROJECT_ID  || process.env.RENDER ||
  process.env.FLY_APP_NAME        || process.env.DYNO ||
  process.env.K_SERVICE
);
const HOST = process.env.HOST ?? (ON_PAAS ? '0.0.0.0' : '127.0.0.1');

// Contract version this server was built against. Compared to the EA's
// RM_VERSION on every snapshot so a stale EA can't masquerade as live.
const CONTRACT_VERSION = '6.01';

// Shared secret guarding every /api/* route. Set RM_TOKEN in the environment
// (never in source). Both the EA and the browser must present it.
const RM_TOKEN = process.env.RM_TOKEN ?? '';

// Railway and similar platforms have an EPHEMERAL filesystem — anything under
// the app directory is wiped on redeploy. Point RM_DATA_DIR at a mounted
// volume there so the plan and the journal survive.
const DATA_DIR  = process.env.RM_DATA_DIR ?? path.join(__dirname, 'data');
const PLAN_FILE = path.join(DATA_DIR, 'plan.json');
const JOURNAL   = path.join(DATA_DIR, 'journal.jsonl');
fs.mkdirSync(DATA_DIR, { recursive: true });

// ── fail-safe: never expose an unauthenticated API beyond loopback ──
const isLoopback = HOST === '127.0.0.1' || HOST === 'localhost' || HOST === '::1';
if (!RM_TOKEN && !isLoopback) {
  console.error('');
  console.error('=========================================================');
  console.error('  REFUSING TO START — RM_TOKEN is not set');
  console.error('=========================================================');
  console.error(`  Binding to ${HOST}, which is reachable from outside this`);
  console.error('  process. Without a token, /api/commands is open to anyone,');
  console.error('  and that endpoint queues commands your EA executes.');
  console.error('');
  console.error('  Fix: add a service variable');
  console.error('      RM_TOKEN = <long random string>');
  console.error('  then redeploy. Generate one with:');
  console.error('      node -e "console.log(require(\'crypto\').randomBytes(32).toString(\'hex\'))"');
  console.error('=========================================================');
  console.error('');
  process.exit(1);
}

// ── in-memory state ────────────────────────────────────────────────
let latestState = null;
let lastStateAt = 0;

/** @type {{id:number,ts:number,action:string,params:object,status:string,result:string|null}[]} */
const commands = [];
let cmdSeq = 0;

const STALE_MS = 15_000;

// ── helpers ────────────────────────────────────────────────────────
const send = (res, code, obj) => {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    'Content-Type': 'application/json',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
};

const readBody = (req, limit = 1_000_000) =>
  new Promise((resolve, reject) => {
    let n = 0;
    const chunks = [];
    req.on('data', (c) => {
      n += c.length;
      if (n > limit) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });

// ── auth ───────────────────────────────────────────────────────────
// Constant-time compare so the token can't be recovered by timing the
// responses. Accepts either `Authorization: Bearer <t>` or `X-RM-Token: <t>`
// (the second is friendlier for MQL's WebRequest header string).
const safeEqual = (a, b) => {
  const A = Buffer.from(String(a ?? ''));
  const B = Buffer.from(String(b ?? ''));
  if (A.length !== B.length) return false;
  return crypto.timingSafeEqual(A, B);
};

const presentedToken = (req) => {
  const auth = req.headers['authorization'];
  if (auth && /^Bearer\s+/i.test(auth)) return auth.replace(/^Bearer\s+/i, '').trim();
  const x = req.headers['x-rm-token'];
  return typeof x === 'string' ? x.trim() : '';
};

/** @returns {boolean} true when the request may proceed */
const authorised = (req) => {
  if (!RM_TOKEN) return true;             // loopback-only dev mode (enforced at startup)
  return safeEqual(presentedToken(req), RM_TOKEN);
};

const appendJournal = (entry) => {
  try {
    fs.appendFileSync(JOURNAL, JSON.stringify({ at: Date.now(), ...entry }) + '\n');
  } catch (e) {
    console.error('journal write failed:', e.message);
  }
};

// ── EA source distribution ─────────────────────────────────────────
// Lets a client pull the current .mq5 / .mq4 from the running bridge,
// save it into MQL5/Experts and recompile. The files ship in the image
// (Nixpacks copies the repo), so what's served is exactly what this
// deployment was built from.
const SRC_ROOT = path.join(__dirname, '..');
const SOURCES = {
  mq5: 'RiskManager.mq5',
  mq4: 'RiskManager.mq4',
};

// Read RM_VERSION out of the file itself rather than trusting a constant,
// so the version shown can never drift from the file being handed out.
const parseEaVersion = (text) =>
  text.match(/#define\s+RM_VERSION\s+"([^"]+)"/)?.[1] ?? null;

function sourceMeta() {
  const out = {};
  for (const [key, name] of Object.entries(SOURCES)) {
    const file = path.join(SRC_ROOT, name);
    try {
      const st = fs.statSync(file);
      const text = fs.readFileSync(file, 'utf8');
      out[key] = {
        name,
        available: true,
        bytes: st.size,
        modified: st.mtime.toISOString(),
        version: parseEaVersion(text),
        sha256: crypto.createHash('sha256').update(text).digest('hex').slice(0, 12),
      };
    } catch {
      out[key] = { name, available: false };
    }
  }
  return out;
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js':   'text/javascript; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg':  'image/svg+xml',
};

const serveStatic = (res, urlPath) => {
  const rel = urlPath === '/' ? '/index.html' : urlPath;
  // Contain path traversal: resolve, then verify the result stays under public/.
  const root = path.join(__dirname, 'public');
  const file = path.resolve(root, '.' + rel);
  if (!file.startsWith(root)) { send(res, 403, { error: 'forbidden' }); return; }
  fs.readFile(file, (err, buf) => {
    if (err) { send(res, 404, { error: 'not found' }); return; }
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(file)] ?? 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(buf);
  });
};

// ── request router ─────────────────────────────────────────────────
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);
  const p = url.pathname;

  try {
    // ---- health: intentionally public so platform health checks work.
    // Leaks nothing beyond "a server is up" and the contract version.
    if (p === '/api/health') {
      return send(res, 200, {
        ok: true,
        contractVersion: CONTRACT_VERSION,
        authRequired: Boolean(RM_TOKEN),
        uptimeSec: Math.round(process.uptime()),
      });
    }

    // ---- everything else under /api requires the shared secret ----
    if (p.startsWith('/api/') && !authorised(req)) {
      return send(res, 401, { error: 'unauthorised' });
    }

    // ---- EA → server: state snapshot -----------------------------
    if (p === '/api/state' && req.method === 'POST') {
      const raw = await readBody(req);
      let parsed;
      try {
        parsed = JSON.parse(raw);
      } catch {
        console.error('bad state JSON:', raw.slice(0, 300));
        return send(res, 400, { error: 'invalid json' });
      }
      latestState = parsed;
      lastStateAt = Date.now();
      return send(res, 200, { ok: true });
    }

    // ---- web app → server: read state ----------------------------
    if (p === '/api/state' && req.method === 'GET') {
      const age = latestState ? Date.now() - lastStateAt : null;
      return send(res, 200, {
        connected: latestState !== null && age < STALE_MS,
        stale: latestState !== null && age >= STALE_MS,
        ageMs: age,
        contractVersion: CONTRACT_VERSION,
        eaVersion: latestState?.v ?? null,
        versionMatch: latestState ? latestState.v === CONTRACT_VERSION : null,
        state: latestState,
      });
    }

    // ---- EA polls for the next command ---------------------------
    // Dispatches at most one pending command, and marks it dispatched so a
    // repeated poll (or a retry) can never fire the same order twice.
    if (p === '/api/commands/next' && req.method === 'GET') {
      const next = commands.find((c) => c.status === 'pending');
      if (!next) return send(res, 200, { command: null });
      next.status = 'dispatched';
      next.dispatchedAt = Date.now();
      appendJournal({ type: 'command_dispatched', id: next.id, action: next.action, params: next.params });
      return send(res, 200, { command: { id: next.id, action: next.action, params: next.params } });
    }

    // ---- EA reports the outcome ----------------------------------
    if (p === '/api/commands/ack' && req.method === 'POST') {
      const { id, ok, result } = JSON.parse(await readBody(req));
      const cmd = commands.find((c) => c.id === Number(id));
      if (!cmd) return send(res, 404, { error: 'unknown command id' });
      cmd.status = ok ? 'done' : 'failed';
      cmd.result = result ?? null;
      cmd.ackedAt = Date.now();
      appendJournal({ type: 'command_ack', id: cmd.id, action: cmd.action, ok, result, state: latestState });
      return send(res, 200, { ok: true });
    }

    // ---- web app enqueues a command ------------------------------
    if (p === '/api/commands' && req.method === 'POST') {
      const { action, params } = JSON.parse(await readBody(req));
      if (typeof action !== 'string' || !action) return send(res, 400, { error: 'action required' });
      const cmd = { id: ++cmdSeq, ts: Date.now(), action, params: params ?? {}, status: 'pending', result: null };
      commands.push(cmd);
      appendJournal({ type: 'command_queued', id: cmd.id, action, params });
      return send(res, 200, { ok: true, id: cmd.id });
    }

    if (p === '/api/commands' && req.method === 'GET') {
      return send(res, 200, { commands: commands.slice(-50) });
    }

    // ---- EA source: metadata + download --------------------------
    if (p === '/api/source' && req.method === 'GET') {
      return send(res, 200, { sources: sourceMeta() });
    }

    if (p.startsWith('/api/source/') && req.method === 'GET') {
      // Whitelist by key — never resolve a caller-supplied path, or this
      // becomes an arbitrary file reader for anyone holding the token.
      const key = p.slice('/api/source/'.length);
      const name = SOURCES[key];
      if (!name) return send(res, 404, { error: 'unknown source' });

      let buf;
      try {
        buf = fs.readFileSync(path.join(SRC_ROOT, name));
      } catch {
        return send(res, 404, { error: `${name} is not present in this deployment` });
      }
      res.writeHead(200, {
        'Content-Type': 'text/plain; charset=utf-8',
        'Content-Disposition': `attachment; filename="${name}"`,
        'Content-Length': buf.length,
        'Cache-Control': 'no-store',
      });
      appendJournal({ type: 'source_download', file: name });
      return res.end(buf);
    }

    // ---- game plan (persisted) -----------------------------------
    if (p === '/api/plan' && req.method === 'GET') {
      let plan = null;
      try { plan = JSON.parse(fs.readFileSync(PLAN_FILE, 'utf8')); } catch { /* none yet */ }
      return send(res, 200, { plan });
    }

    if (p === '/api/plan' && req.method === 'POST') {
      const plan = JSON.parse(await readBody(req));
      fs.writeFileSync(PLAN_FILE, JSON.stringify(plan, null, 2));
      appendJournal({ type: 'plan_saved', plan });
      return send(res, 200, { ok: true });
    }

    if (req.method === 'GET') return serveStatic(res, p);
    return send(res, 405, { error: 'method not allowed' });
  } catch (err) {
    console.error('request error:', err);
    return send(res, 500, { error: String(err && err.message) });
  }
});

server.on('error', (err) => {
  console.error(`FAILED TO BIND ${HOST}:${PORT} — ${err.code ?? err.message}`);
  if (err.code === 'EADDRINUSE') console.error('Another process is already on that port.');
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  console.log(`RiskManager bridge  →  http://${HOST}:${PORT}`);
  console.log(`contract version    →  ${CONTRACT_VERSION}`);
  console.log(`data dir            →  ${DATA_DIR}`);
  console.log(`environment         →  ${ON_PAAS ? 'PaaS detected — bound to all interfaces' : 'local'}`);
  console.log(`auth                →  ${RM_TOKEN ? 'ON (RM_TOKEN set)' : 'OFF — loopback only'}`);
  if (!RM_TOKEN) {
    console.log('');
    console.log('  Running without auth. Safe here because the socket is bound to');
    console.log('  loopback, but set RM_TOKEN before exposing this anywhere.');
  }
  console.log('');
  console.log('In MetaTrader set:');
  console.log(`  InpBridgeURL   = http://${HOST}:${PORT}`);
  if (RM_TOKEN) console.log('  InpBridgeToken = <your RM_TOKEN>');
  console.log(`  Tools > Options > Expert Advisors > Allow WebRequest for: http://${HOST}:${PORT}`);
});
