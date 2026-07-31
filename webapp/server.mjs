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
const CONTRACT_VERSION = '6.09';

// Shared secret guarding every /api/* route. Set RM_TOKEN in the environment
// (never in source). Both the EA and the browser must present it.
const RM_TOKEN = process.env.RM_TOKEN ?? '';

// Railway and similar platforms have an EPHEMERAL filesystem — anything under
// the app directory is wiped on redeploy. Point RM_DATA_DIR at a mounted
// volume there so the plan and the journal survive.
const DATA_DIR  = process.env.RM_DATA_DIR ?? path.join(__dirname, 'data');
const PLAN_FILE = path.join(DATA_DIR, 'plan.json');
const JOURNAL   = path.join(DATA_DIR, 'journal.jsonl');
// Daily journal: one file per account, keyed by date. Separate from the
// append-only command journal above - this one is edited.
const JRNL_DIR    = path.join(DATA_DIR, 'journal');
const SCHEMA_FILE = path.join(DATA_DIR, 'journal-schema.json');
fs.mkdirSync(JRNL_DIR, { recursive: true });
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
// One entry per live EA, keyed `<login>:<symbol>`. A terminal maps to exactly
// one trading account and a chart to one symbol, so that pair identifies an
// instance — see MULTI-INSTANCE.md. A single slot here would let ten EAs
// overwrite each other, which is what made the plan's caps meaningless.
/** @type {Map<string,{state:object,at:number,chartId:number|null,collision:object|null}>} */
const instances = new Map();

const instanceKey = (s) => `${s?.account?.login ?? '?'}:${s?.symbol ?? '?'}`;

/** Freshest instance, used when the caller doesn't name one. */
const freshestKey = () => {
  let best = null, bestAt = -1;
  for (const [k, e] of instances) if (e.at > bestAt) { best = k; bestAt = e.at; }
  return best;
};

// The EA paces itself: every few seconds when a position or armed order is
// live, on each M1 close while stalking, on each M5 close when flat and
// unattended. A fixed 15s window would therefore report every idle chart as
// offline, so derive the window from the interval the EA reports.
const MODE_NAME = ['idle', 'stalking', 'active'];
const staleAfter = (s) => Math.max(STALE_MS, (Number(s?.postSec) || 3) * 1000 * 2.5);

/** Compact per-instance row for the dashboard's selector. */
const summarise = (key, e) => {
  const s = e.state, age = Date.now() - e.at;
  const pats = Array.isArray(s?.patterns) ? s.patterns : [];
  return {
    key,
    login:      s?.account?.login   ?? null,
    server:     s?.account?.server  ?? null,
    symbol:     s?.symbol           ?? null,
    spoken:     s?.spoken           ?? s?.symbol ?? null,
    eaVersion:  s?.v                ?? null,
    versionMatch: s?.v === CONTRACT_VERSION,
    ageMs:      age,
    stale:      age >= staleAfter(s),
    postSec:    Number(s?.postSec) || null,
    mode:       MODE_NAME[Number(s?.mode)] ?? null,
    price:      s?.price            ?? null,
    digits:     s?.digits           ?? 5,
    trend:      s?.m15?.trend       ?? null,
    h4Trend:    s?.h4?.trend        ?? null,
    drangePct:  s?.m15?.drangePct   ?? null,
    pnlSymbol:  s?.account?.pnlSymbol ?? null,
    openCount:  s?.exposure?.openCount ?? 0,
    // Ticket detail, so the dashboard can assemble an account-wide Trade tab
    // by merging every instance rather than asking each one separately.
    positions:  Array.isArray(s?.exposure?.positions) ? s.exposure.positions : [],
    armed:      s?.armed?.active ? (s.armed.button ?? true) : null,
    available:  pats.filter((v) => v?.available).length,
    collision:  e.collision,
  };
};

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

// ── daily journal ──────────────────────────────────────────────────
const DEFAULT_SCHEMA = path.join(__dirname, 'journal-schema.json');

const readSchema = () => {
  // A schema saved through the API wins; otherwise fall back to the one that
  // ships with the app, so a fresh deploy is never without columns.
  for (const f of [SCHEMA_FILE, DEFAULT_SCHEMA]) {
    try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { /* next */ }
  }
  return { symbols: [], groups: [], perSymbol: [] };
};

const journalPath = (login) => path.join(JRNL_DIR, String(login).replace(/[^\w.-]/g, '_') + '.json');

const loadJournalFile = (login) => {
  try { return JSON.parse(fs.readFileSync(journalPath(login), 'utf8')); } catch { return {}; }
};
const saveJournalFile = (login, obj) =>
  fs.writeFileSync(journalPath(login), JSON.stringify(obj, null, 2));

/** Merge one level deeper than Object.assign, so a symbol patch keeps its siblings. */
const deepMerge = (base, patch) => {
  const out = { ...base };
  for (const [k, v] of Object.entries(patch ?? {})) {
    out[k] = (v && typeof v === 'object' && !Array.isArray(v))
      ? { ...(out[k] ?? {}), ...v }
      : v;
  }
  return out;
};

const isoDay = (d) => new Date(d).toISOString().slice(0, 10);

/** The last `days` calendar days, newest first, each with whatever was saved. */
const readJournal = (login, days) => {
  const saved = loadJournalFile(login);
  const out = [];
  const today = new Date(); today.setHours(12, 0, 0, 0);
  for (let i = 0; i < days; i++) {
    const d = new Date(today); d.setDate(d.getDate() - i);
    const key = isoDay(d);
    out.push({ date: key, dow: d.getDay(), ...(saved[key] ?? {}) });
  }
  return out;
};

const dotGet = (obj, dotted) =>
  String(dotted).split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj);

/**
 * Fill the schema's `auto` fields for today from whatever the EAs are currently
 * reporting. Called when a client loads the journal, so the row fills itself as
 * the session runs rather than needing a separate scheduler.
 */
const captureAuto = () => {
  const schema = readSchema();
  const defs = schema?.auto?.perSymbol ?? [];
  if (defs.length === 0) return;

  const today = isoDay(new Date());
  const byLogin = new Map();
  for (const [, e] of instances) {
    const login = e.state?.account?.login;
    const sym   = e.state?.symbol;
    if (login == null || !sym) continue;
    if (!byLogin.has(login)) byLogin.set(login, {});
    for (const def of defs) {
      let v = dotGet(e.state, def.from);
      if (v == null) continue;
      if (def.map)  v = def.map[String(v)] ?? v;
      if (def.round != null && typeof v === 'number') v = Number(v.toFixed(def.round));
      // Match a reported symbol to a schema column: US500.sim -> ES needs the
      // alias table below; a plain prefix match covers XAUUSD -> XAU etc.
      const col = (schema.symbols ?? []).find((c) =>
        sym === c || sym.toUpperCase().startsWith(c.toUpperCase()) ||
        (schema.aliases?.[c] ?? []).includes(sym));
      if (!col) continue;
      byLogin.get(login)[col] = { ...(byLogin.get(login)[col] ?? {}), [def.key]: v };
    }
  }

  for (const [login, patch] of byLogin) {
    if (Object.keys(patch).length === 0) continue;
    const all = loadJournalFile(login);
    all[today] = deepMerge(all[today] ?? {}, patch);
    all[today].autoAt = Date.now();
    saveJournalFile(login, all);
  }
};

// ── EA source distribution ─────────────────────────────────────────
// Lets a client pull the current .mq5 / .mq4 from the running bridge,
// save it into MQL5/Experts and recompile. The files ship in the image
// (Nixpacks copies the repo), so what's served is exactly what this
// deployment was built from.
const SRC_ROOT = path.join(__dirname, '..');
// key -> { rel: path within the repo, name: filename to save as }
const SOURCES = {
  mq5: { rel: 'RiskManager.mq5',       name: 'RiskManager.mq5' },
  mq4: { rel: 'RiskManager.mq4',       name: 'RiskManager.mq4' },
  tpl: { rel: 'templates/default.tpl', name: 'default.tpl'     },
  // The updater serves itself, which is what lets the .bat stay the only
  // file a user ever has to fetch by hand: the .ps1 replaces itself when
  // a newer one is published.
  bat: { rel: 'tools/Update-EA.bat',   name: 'Update-EA.bat'   },
  ps1: { rel: 'tools/Update-EA.ps1',   name: 'Update-EA.ps1'   },
  guibat: { rel: 'tools/Update-EA-GUI.bat', name: 'Update-EA-GUI.bat' },
  guips1: { rel: 'tools/Update-EA-GUI.ps1', name: 'Update-EA-GUI.ps1' },
};

// Read RM_VERSION out of the file itself rather than trusting a constant,
// so the version shown can never drift from the file being handed out.
const parseEaVersion = (text) =>
  text.match(/#define\s+RM_VERSION\s+"([^"]+)"/)?.[1] ?? null;

function sourceMeta() {
  const out = {};
  for (const [key, spec] of Object.entries(SOURCES)) {
    const file = path.join(SRC_ROOT, spec.rel);
    try {
      const st = fs.statSync(file);
      const buf = fs.readFileSync(file);
      // Templates are UTF-16LE; hash the bytes so the value is meaningful
      // regardless of the file's encoding.
      out[key] = {
        name: spec.name,
        available: true,
        bytes: st.size,
        modified: st.mtime.toISOString(),
        version: parseEaVersion(buf.toString('utf8')),
        sha256: crypto.createHash('sha256').update(buf).digest('hex').slice(0, 12),
      };
    } catch {
      out[key] = { name: spec.name, available: false };
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
      // Include source availability + version only (never content or paths):
      // enough to diagnose a deployment that shipped without the .mq5/.mq4,
      // without turning a public endpoint into an information leak.
      const meta = sourceMeta();
      return send(res, 200, {
        ok: true,
        // The journal lives on disk. On a PaaS the app directory is wiped on
        // every redeploy, so surface where it is going and whether that is a
        // mounted volume - losing a month of journal to a deploy is silent.
        dataDir: DATA_DIR,
        dataPersistent: !ON_PAAS || Boolean(process.env.RM_DATA_DIR),
        contractVersion: CONTRACT_VERSION,
        authRequired: Boolean(RM_TOKEN),
        uptimeSec: Math.round(process.uptime()),
        sourceRoot: SRC_ROOT,
        sources: Object.fromEntries(
          Object.entries(meta).map(([k, v]) => [k, { available: v.available, version: v.version ?? null }])
        ),
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
      const key  = instanceKey(parsed);
      const now  = Date.now();
      const prev = instances.get(key);
      const cid  = parsed?.chartId ?? null;

      // Two charts of the same symbol on the same account are fighting for one
      // slot. Surface it rather than let them silently overwrite each other.
      let collision = prev?.collision ?? null;
      if (prev && cid !== null && prev.chartId !== null && prev.chartId !== cid) {
        if (now - prev.at < staleAfter(prev.state)) {
          collision = { chartIds: [prev.chartId, cid], since: collision?.since ?? now };
          console.warn(`state collision on ${key}: charts ${prev.chartId} and ${cid}`);
        }
      } else if (collision && now - (prev?.at ?? 0) >= staleAfter(prev?.state)) {
        collision = null;   // the other chart went away
      }

      instances.set(key, { state: parsed, at: now, chartId: cid, collision });
      return send(res, 200, { ok: true, key });
    }

    // ---- web app → server: read state ----------------------------
    // Returns every live instance for the selector, plus the full state of the
    // one being viewed (`?key=`, defaulting to whichever posted most recently).
    if (p === '/api/state' && req.method === 'GET') {
      const rows = [...instances].map(([k, e]) => summarise(k, e))
        .sort((a, b) => String(a.symbol).localeCompare(String(b.symbol)));

      const want = url.searchParams.get('key');
      const key  = (want && instances.has(want)) ? want : freshestKey();
      const e    = key ? instances.get(key) : null;
      const age  = e ? Date.now() - e.at : null;

      return send(res, 200, {
        contractVersion: CONTRACT_VERSION,
        instances: rows,
        key,
        keyMissing: Boolean(want) && !instances.has(want),
        connected: e !== null && age < staleAfter(e?.state),
        stale:     e !== null && age >= staleAfter(e?.state),
        ageMs:     age,
        eaVersion: e?.state?.v ?? null,
        versionMatch: e ? e.state.v === CONTRACT_VERSION : null,
        collision: e?.collision ?? null,
        state: e?.state ?? null,
      });
    }

    // ---- EA polls for the next command ---------------------------
    // Dispatches at most one pending command, and marks it dispatched so a
    // repeated poll (or a retry) can never fire the same order twice.
    // Commands are addressed to one instance. An untargeted command is never
    // dispatched — with ten EAs polling, "whoever asks first" would fire an
    // order on an arbitrary symbol.
    if (p === '/api/commands/next' && req.method === 'GET') {
      const me = `${url.searchParams.get('login') ?? '?'}:${url.searchParams.get('symbol') ?? '?'}`;
      const next = commands.find((c) => c.status === 'pending' && c.target === me);
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
      appendJournal({
        type: 'command_ack', id: cmd.id, action: cmd.action, ok, result,
        target: cmd.target, state: instances.get(cmd.target)?.state ?? null,
      });
      return send(res, 200, { ok: true });
    }

    // ---- web app enqueues a command ------------------------------
    if (p === '/api/commands' && req.method === 'POST') {
      const { action, params, target } = JSON.parse(await readBody(req));
      if (typeof action !== 'string' || !action) return send(res, 400, { error: 'action required' });
      if (typeof target !== 'string' || !instances.has(target)) {
        return send(res, 400, { error: 'target must name a live instance' });
      }
      const cmd = { id: ++cmdSeq, ts: Date.now(), target, action, params: params ?? {}, status: 'pending', result: null };
      commands.push(cmd);
      appendJournal({ type: 'command_queued', id: cmd.id, target, action, params });
      return send(res, 200, { ok: true, id: cmd.id });
    }

    // ---- daily journal --------------------------------------------
    // Schema-driven on purpose: the columns are defined in journal-schema.json,
    // so adding a field the EA fills is a data change, not a code change.
    if (p === '/api/journal/schema' && req.method === 'GET') {
      return send(res, 200, { schema: readSchema() });
    }
    if (p === '/api/journal/schema' && req.method === 'PUT') {
      try {
        const next = JSON.parse(await readBody(req));
        if (!next || typeof next !== 'object') return send(res, 400, { error: 'object required' });
        fs.writeFileSync(SCHEMA_FILE, JSON.stringify(next, null, 2));
        return send(res, 200, { ok: true, schema: next });
      } catch (e) { return send(res, 400, { error: e.message }); }
    }

    if (p === '/api/journal' && req.method === 'GET') {
      const login = url.searchParams.get('login') ?? 'default';
      const days  = Math.min(Number(url.searchParams.get('days')) || 70, 400);
      captureAuto();
      return send(res, 200, { login, schema: readSchema(), rows: readJournal(login, days) });
    }

    // One day at a time. The client sends only the cells it changed, so two
    // tabs editing different columns cannot clobber each other's work.
    if (p === '/api/journal' && req.method === 'PUT') {
      try {
        const { login = 'default', date, patch } = JSON.parse(await readBody(req));
        if (!/^\d{4}-\d{2}-\d{2}$/.test(String(date ?? ''))) {
          return send(res, 400, { error: 'date must be YYYY-MM-DD' });
        }
        const all = loadJournalFile(login);
        all[date] = deepMerge(all[date] ?? {}, patch ?? {});
        all[date].updatedAt = Date.now();
        saveJournalFile(login, all);
        return send(res, 200, { ok: true, date, row: all[date] });
      } catch (e) { return send(res, 400, { error: e.message }); }
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
      const spec = SOURCES[key];
      if (!spec) return send(res, 404, { error: 'unknown source' });

      let buf;
      try {
        buf = fs.readFileSync(path.join(SRC_ROOT, spec.rel));
      } catch {
        return send(res, 404, { error: `${spec.name} is not present in this deployment` });
      }
      res.writeHead(200, {
        // octet-stream, not text: templates are UTF-16 and must not be
        // re-encoded in transit or MetaTrader will refuse to load them.
        'Content-Type': 'application/octet-stream',
        'Content-Disposition': `attachment; filename="${spec.name}"`,
        'Content-Length': buf.length,
        'Cache-Control': 'no-store',
      });
      appendJournal({ type: 'source_download', file: spec.name });
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
