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
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT = Number(process.env.PORT ?? 8787);
const HOST = process.env.HOST ?? '127.0.0.1';

// Contract version this server was built against. Compared to the EA's
// RM_VERSION on every snapshot so a stale EA can't masquerade as live.
const CONTRACT_VERSION = '6.01';

const DATA_DIR  = path.join(__dirname, 'data');
const PLAN_FILE = path.join(DATA_DIR, 'plan.json');
const JOURNAL   = path.join(DATA_DIR, 'journal.jsonl');
fs.mkdirSync(DATA_DIR, { recursive: true });

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

const appendJournal = (entry) => {
  try {
    fs.appendFileSync(JOURNAL, JSON.stringify({ at: Date.now(), ...entry }) + '\n');
  } catch (e) {
    console.error('journal write failed:', e.message);
  }
};

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

    // ---- health --------------------------------------------------
    if (p === '/api/health') {
      return send(res, 200, { ok: true, contractVersion: CONTRACT_VERSION, uptimeSec: Math.round(process.uptime()) });
    }

    if (req.method === 'GET') return serveStatic(res, p);
    return send(res, 405, { error: 'method not allowed' });
  } catch (err) {
    console.error('request error:', err);
    return send(res, 500, { error: String(err && err.message) });
  }
});

server.listen(PORT, HOST, () => {
  console.log(`RiskManager bridge  →  http://${HOST}:${PORT}`);
  console.log(`contract version    →  ${CONTRACT_VERSION}`);
  console.log('');
  console.log('In MetaTrader set:');
  console.log(`  InpBridgeURL = http://${HOST}:${PORT}`);
  console.log(`  Tools > Options > Expert Advisors > Allow WebRequest for: http://${HOST}:${PORT}`);
});
