// RiskManager dashboard.
//
// This file deliberately contains NO market-structure logic. Every value it
// shows was computed by the EA and shipped in the state snapshot. If you ever
// find yourself wanting to calculate a swing/trend/FVG here — don't. Add it to
// the EA's BuildStateJson() instead, so there is only one source of truth.

// Wrapped in an IIFE so nothing here lands in global scope. Without this,
// `const { BUCKETS, ... } = window.RMPlan` redeclares names plan.js already
// defined globally, and the whole file fails to execute.
(() => {
const $ = (id) => document.getElementById(id);

// Thesis buckets and plan evaluation live in plan.js so the same rules can be
// reused elsewhere (and eventually mirrored into the EA for hard enforcement).
const { BUCKETS, PLAN_DEFAULTS, evaluateSession, evaluatePattern } = window.RMPlan;

let plan = { ...PLAN_DEFAULTS };
let lastState = null;

// Which EA the detail view is showing. One EA per (account, symbol); the server
// keys them the same way. Remembered so a reload returns to the same chart.
const INST_KEY = 'rm_instance';
let selectedKey = localStorage.getItem(INST_KEY) ?? null;
let liveKey = null;               // what the server actually served us
let lastRows = [];                // instance summaries from the last poll

// ── auth ────────────────────────────────────────────────────────────
// The server guards /api/* with a shared secret (RM_TOKEN). We keep it in
// localStorage so it's entered once per browser, and re-prompt on any 401.
const TOKEN_KEY = 'rm_token';
let token = localStorage.getItem(TOKEN_KEY) ?? '';
let authBlocked = false;   // true while the server is rejecting us

// An in-page gate, deliberately NOT window.prompt: the poll loop runs once a
// second, so a prompt-on-401 produced a modal every second and made the whole
// page feel dead.
function showAuthBar(msg) {
  authBlocked = true;
  $('authBar').hidden = false;
  $('authMsg').textContent = msg ?? '';
}

function hideAuthBar() {
  if (!authBlocked) return;
  authBlocked = false;
  $('authBar').hidden = true;
  $('authMsg').textContent = '';
}

/** fetch wrapper that attaches the token and surfaces 401 via the auth bar */
async function api(path, opts = {}) {
  const headers = { ...(opts.headers ?? {}) };
  if (token) headers['Authorization'] = `Bearer ${token}`;
  const res = await fetch(path, { ...opts, headers });
  if (res.status === 401) {
    showAuthBar(token ? 'That token was rejected by the server.' : 'Enter the server\'s RM_TOKEN.');
    throw new Error('unauthorised');
  }
  hideAuthBar();
  // Throw on any other failure too. Otherwise a 404/500 body flows onward as
  // if it were real data — e.g. a JSON error blob saved as RiskManager.mq5.
  if (!res.ok) throw new Error(`http ${res.status}`);
  return res;
}

window.RMApi = api;   // journal.js reuses the same auth + error handling

$('authSave').onclick = async () => {
  token = $('authInput').value.trim();
  localStorage.setItem(TOKEN_KEY, token);
  $('authInput').value = '';
  $('authMsg').textContent = 'checking…';
  try {
    const { plan: saved } = await api('/api/plan').then((r) => r.json());
    if (saved) plan = { ...PLAN_DEFAULTS, ...saved };
    planToForm();
    await loadSourceMeta();
    await poll();
  } catch { /* api() already re-showed the bar with the reason */ }
};

$('authInput').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') $('authSave').click();
});

const TREND = { 1: ['BULLISH', 'up'], 2: ['BEARISH', 'down'] };
const FLOW  = { 1: ['UP ▲', 'up'],    2: ['DOWN ▼', 'down'] };
const CANDLESTATE = {
  0: 'none', 1: 'pattern formed', 2: 'with trend',
  3: 'against trend', 4: 'TREND BREAKING',
};

let remoteArmed = false;
let digits = 2;

const fmt   = (v, d = digits) => (v === null || v === undefined) ? '—' : Number(v).toFixed(d);
const money = (v) => (v === null || v === undefined) ? '—'
  : (v < 0 ? '-' : '') + '$' + Math.abs(Number(v)).toLocaleString(undefined, { maximumFractionDigits: 0 });

const setTxt = (id, text, cls) => {
  const el = $(id);
  if (!el) return;
  el.textContent = text;
  el.className = 'v' + (cls ? ' ' + cls : '');
};

// ── pattern tiles ───────────────────────────────────────────────────
// A tile is only clickable on verdict 'go'. Everything else carries the
// reason in its tooltip, so a blocked setup always explains itself.
function renderBuckets(patterns, state, session) {
  const byId = Object.fromEntries((patterns ?? []).map((p) => [p.id, p]));
  const host = $('buckets');
  host.innerHTML = '';

  for (const b of BUCKETS) {
    const present = b.ids.map((id) => byId[id]).filter(Boolean);
    if (!present.length) continue;

    const verdicts = present.map((p) => ({ p, ...evaluatePattern(p, plan, state, session) }));
    const goCount = verdicts.filter((v) => v.verdict === 'go').length;
    const inPlan = !plan.active || plan.buckets.includes(b.key);

    const wrap = document.createElement('div');
    wrap.className = 'bucket';
    wrap.style.opacity = inPlan ? '1' : '.5';
    wrap.innerHTML =
      `<div class="bucket-head">
         <strong>${b.key} · ${b.name}</strong>
         <span class="desc">${b.desc}</span>
         <div class="spacer"></div>
         <span class="desc">${inPlan ? `${goCount} permitted now` : 'excluded by plan'}</span>
       </div>`;

    const tiles = document.createElement('div');
    tiles.className = 'tiles';
    for (const { p, verdict, reason } of verdicts) {
      const side = p.dir > 0 ? 'buy' : 'sell';
      const cls = verdict === 'go'   ? 'ok ' + side
                : verdict === 'plan' ? 'plan'
                : 'blocked';
      const el = document.createElement('div');
      el.className = `tile ${cls}`;
      const sub = verdict === 'go' ? p.type
                : verdict === 'plan' ? 'blocked by plan'
                : verdict === 'locked' ? 'session locked'
                : p.type;
      el.innerHTML = `${p.label}<span class="sub">${sub}</span>`;
      el.title = `${p.id}\n${reason}`;
      if (verdict === 'go') el.onclick = () => queueArm(p);
      tiles.appendChild(el);
    }
    wrap.appendChild(tiles);
    host.appendChild(wrap);
  }
}

// ── plan UI ─────────────────────────────────────────────────────────
function renderBucketChooser() {
  const host = $('pBuckets');
  host.innerHTML = '';
  for (const b of BUCKETS) {
    const el = document.createElement('div');
    const sel = plan.buckets.includes(b.key);
    el.className = 'chip' + (sel ? ' sel' : '');
    el.innerHTML = `${b.key} · ${b.name}<small>${b.desc}</small>`;
    el.onclick = () => {
      plan.buckets = sel ? plan.buckets.filter((k) => k !== b.key) : [...plan.buckets, b.key];
      renderBucketChooser();
    };
    host.appendChild(el);
  }
}

function planToForm() {
  $('pBias').value      = plan.bias;
  $('pMaxTrades').value = plan.maxTrades;
  $('pMaxLoss').value   = plan.maxSessionLossUsd;
  $('pMinDrange').value = plan.minDrangePct;
  $('pWinStart').value  = plan.windowStart;
  $('pWinEnd').value    = plan.windowEnd;
  $('pH4').checked      = plan.requireH4Agree;
  $('pNote').value      = plan.note;
  renderBucketChooser();
}

function formToPlan() {
  plan.bias              = $('pBias').value;
  plan.maxTrades         = Number($('pMaxTrades').value) || 0;
  plan.maxSessionLossUsd = Number($('pMaxLoss').value) || 0;
  plan.minDrangePct      = Number($('pMinDrange').value) || 0;
  plan.windowStart       = $('pWinStart').value.trim();
  plan.windowEnd         = $('pWinEnd').value.trim();
  plan.requireH4Agree    = $('pH4').checked;
  plan.note              = $('pNote').value.trim();
}

async function savePlan(msg) {
  await api('/api/plan', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(plan),
  });
  $('planMsg').textContent = msg;
  setTimeout(() => ($('planMsg').textContent = ''), 3000);
}

$('planToggle').onclick = () => {
  const ed = $('planEditor');
  ed.hidden = !ed.hidden;
  $('planToggle').textContent = ed.hidden ? 'edit' : 'close';
};

$('planSave').onclick = async () => { formToPlan(); await savePlan('draft saved'); };

$('planActivate').onclick = async () => {
  formToPlan();
  // Without a live snapshot there's no equity to measure the loss cap against
  // and no entry count to measure the trade cap against. Say so rather than
  // activating a plan whose two hardest limits silently do nothing.
  if (!lastState) {
    const go = confirm(
      'The EA is not connected yet.\n\n' +
      'The session loss cap and trade cap need a live snapshot to baseline against, ' +
      'so they will not be enforced until you re-activate with the EA running.\n\n' +
      'Activate anyway (bias, buckets and window will still apply)?'
    );
    if (!go) return;
  }
  plan.active = true;
  plan.activatedAt = Date.now();
  // Snapshot equity NOW — the session loss cap is measured against this.
  plan.baselineEquity = lastState?.account?.equity ?? null;
  // Snapshot the EA's entry count so mid-session activation counts from here.
  plan.tradesAtActivation = plan.countAllSymbols
    ? (lastState?.session?.tradesTodayAll ?? 0)
    : (lastState?.session?.tradesTodaySymbol ?? 0);
  await savePlan('plan activated — enforcement live');
  $('planEditor').hidden = true;
  $('planToggle').textContent = 'edit';
};

$('planDeactivate').onclick = async () => {
  plan.active = false;
  await savePlan('plan deactivated');
};

function renderPlanStatus(session) {
  const pill = $('planPill');
  if (!plan.active) {
    pill.className = 'pill down';
    $('planPillTxt').textContent = 'no active plan';
  } else if (session.locked) {
    pill.className = 'pill down';
    $('planPillTxt').textContent = 'LOCKED';
  } else {
    pill.className = 'pill plan-on';
    const bits = [plan.bias === 'both' ? 'both ways' : plan.bias,
                  plan.buckets.join('')];
    if (plan.maxTrades) bits.push(`${session.taken}/${plan.maxTrades} trades`);
    $('planPillTxt').textContent = bits.join(' · ');
  }

  const locks = $('planLocks');
  locks.innerHTML = '';
  for (const r of session.reasons) {
    const d = document.createElement('div');
    d.className = 'lock hard';
    d.textContent = `STOP — ${r}`;
    locks.appendChild(d);
  }
  // Advance warning at 70% of the loss cap, before it becomes a hard stop.
  if (plan.active && !session.locked && session.lossSoFar > 0 && plan.maxSessionLossUsd > 0) {
    const pct = session.lossSoFar / plan.maxSessionLossUsd;
    if (pct >= 0.7) {
      const d = document.createElement('div');
      d.className = 'lock';
      d.textContent = `WARNING — down $${Math.round(session.lossSoFar)} of your $${plan.maxSessionLossUsd} cap (${Math.round(pct * 100)}%)`;
      locks.appendChild(d);
    }
  }
  if (plan.active && plan.note) {
    const d = document.createElement('div');
    d.className = 'lock';
    d.style.background = 'var(--plc)';
    d.style.color = 'var(--text)';
    d.textContent = `NOTE — ${plan.note}`;
    locks.appendChild(d);
  }
}

async function queueArm(p) {
  if (!remoteArmed) {
    $('armNote').textContent = 'remote disarmed — press ARM REMOTE first';
    return;
  }
  // Address the command at one instance. The queue refuses untargeted commands
  // precisely so a click can't land on whichever of ten EAs polls first.
  if (!liveKey) { $('armNote').textContent = 'no instance selected'; return; }
  const sym = lastState?.symbol ?? liveKey;
  if (!confirm(`Queue ARM for ${p.label} (${p.type}) on ${sym}?\n\nThis tells the EA to draw the entry/SL/TP lines.\nIt does NOT send an order.`)) return;
  const r = await api('/api/commands', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'arm', target: liveKey, params: { button: p.id } }),
  }).then((x) => x.json());
  $('armNote').textContent = `queued #${r.id} · arm ${p.label} on ${sym}`;
}

$('cRiskSet').onclick = () => {
  const v = Number($('cRiskCustom').value);
  if (!v || v <= 0) { $('ctrlMsg').textContent = 'enter an amount'; return; }
  cmd('setRisk', { amount: v }, `custom risk $${v}`);
};
$('cRiskCustom').addEventListener('keydown', (e) => { if (e.key === 'Enter') $('cRiskSet').click(); });

$('armBtn').onclick = () => {
  remoteArmed = !remoteArmed;
  $('armBox').className = 'arm' + (remoteArmed ? ' on' : '');
  $('armBtn').textContent = remoteArmed ? 'DISARM' : 'ARM REMOTE';
  // Name the target. With several clients and ten symbols each, "clicking a
  // pattern queues a command" is not enough to know where the order lands.
  const where = lastState?.symbol ? ` on ${lastState.symbol}` : '';
  $('armNote').textContent = remoteArmed
    ? `remote armed${where} — clicking a pattern queues a command`
    : 'remote commands disarmed';
};

// ── open positions ──────────────────────────────────────────────────
// Assembled across every instance on the selected account, so this reads like
// MT5's Trade tab rather than one symbol at a time. Each EA reports only its
// OWN symbol's tickets — that keeps each payload proportional, but it also
// means a position on a symbol with no EA attached cannot appear here. The
// note under the table says so when the account P&L disagrees with the sum.
function renderPositions(rows, state) {
  const card = $('posCard');
  const login = state?.account?.login ?? null;
  if (login === null) { card.hidden = true; return; }

  const mine = (rows ?? []).filter((r) => r.login === login);
  const all = [];
  for (const r of mine)
    for (const p of (r.positions ?? []))
      all.push({ ...p, symbol: r.symbol, stale: r.stale, key: r.key });

  card.hidden = false;
  $('posScope').textContent = `account ${login} · ${mine.length} chart${mine.length === 1 ? '' : 's'} reporting`;

  const tbl = $('posTbl');
  tbl.replaceChildren();
  if (all.length === 0) {
    const tr = tbl.insertRow();
    tr.insertCell().outerHTML = '<td colspan="9" class="mute" style="padding:10px 0">no open positions</td>';
    $('posTotal').textContent = '';
  } else {
    const head = tbl.createTHead().insertRow();
    for (const h of ['Symbol', 'Type', 'Lots', 'Open', 'S/L', 'T/P', 'P&L', 'Since', ''])
      head.insertCell().outerHTML = `<th>${h}</th>`;

    all.sort((a, b) => a.symbol.localeCompare(b.symbol) || a.ticket - b.ticket);
    for (const p of all) {
      const tr = tbl.insertRow();
      const d = p.symbol.includes('JPY') ? 3 : undefined;
      const cells = [
        `<strong>${p.symbol}</strong>`,
        `<span class="${p.type === 'buy' ? 'up' : 'down'}">${p.type.toUpperCase()}</span>`,
        p.lots.toFixed(2),
        fmt(p.open, d ?? digits),
        p.sl ? fmt(p.sl, d ?? digits) : '<span class="mute">—</span>',
        p.tp ? fmt(p.tp, d ?? digits) : '<span class="mute">—</span>',
        `<span class="${p.profit > 0 ? 'up' : p.profit < 0 ? 'down' : 'mute'}">` +
          `${p.profit >= 0 ? '+' : ''}${p.profit.toFixed(2)}</span>`,
        `<span class="mute">${p.openTime ? fmtAge(Date.now() - p.openTime * 1000) : '—'}</span>`,
      ];
      cells.forEach((c) => { tr.insertCell().innerHTML = c; });

      const td = tr.insertCell();
      const b = btn('Close', 'danger', () => {
        if (!confirm(`Close #${p.ticket} — ${p.type.toUpperCase()} ${p.lots} ${p.symbol}?\n\n` +
                     `Open ${fmt(p.open, d ?? digits)}, P&L ${p.profit >= 0 ? '+' : ''}${p.profit.toFixed(2)}`)) return;
        cmdTo(p.key, 'closeTicket', { ticket: p.ticket }, `close #${p.ticket}`);
      });
      // The command must go to the EA that owns that symbol, not the selected one.
      b.disabled = p.stale;
      if (p.stale) b.title = 'that chart is not reporting right now';
      td.appendChild(b);
    }
    const sum = all.reduce((a, p) => a + p.profit, 0);
    $('posTotal').innerHTML = `${all.length} position${all.length === 1 ? '' : 's'} · ` +
      `<span class="${sum > 0 ? 'up' : sum < 0 ? 'down' : 'mute'}">${sum >= 0 ? '+' : ''}${sum.toFixed(2)}</span>`;
  }

  // pnlAll is account-wide; the table is only what the attached EAs can see.
  const pnlAll = state?.account?.pnlAll;
  const sum = all.reduce((a, p) => a + p.profit, 0);
  $('posNote').textContent =
    (pnlAll != null && Math.abs(pnlAll - sum) > 0.01)
      ? `Account P&L is ${pnlAll.toFixed(2)} but these tickets total ${sum.toFixed(2)} — ` +
        `the difference is on symbols with no EA attached, which cannot be listed or closed from here.`
      : '';
}

// ── trade controls ──────────────────────────────────────────────────
// Every button here queues a command addressed at the selected instance. None
// of them send an order: the only action that does is `execute`, and the EA
// refuses it unless InpAllowRemoteExec is on.
async function cmdTo(key, action, params, msg) {
  if (!key) { $('ctrlMsg').textContent = 'no instance selected'; return null; }
  try {
    const r = await api('/api/commands', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, target: key, params: params ?? {} }),
    }).then((x) => x.json());
    $('ctrlMsg').textContent = `${msg ?? action} — queued #${r.id}`;
    return r;
  } catch (e) {
    $('ctrlMsg').textContent = `failed: ${e.message}`;
    return null;
  }
}

async function cmd(action, params, msg) {
  if (!liveKey) { $('ctrlMsg').textContent = 'no instance selected'; return null; }
  try {
    const r = await api('/api/commands', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ action, target: liveKey, params: params ?? {} }),
    }).then((x) => x.json());
    $('ctrlMsg').textContent = `${msg ?? action} — queued #${r.id}`;
    return r;
  } catch (e) {
    $('ctrlMsg').textContent = `failed: ${e.message}`;
    return null;
  }
}

const btn = (label, cls, onclick, title) => {
  const b = document.createElement('button');
  b.className = 'pbtn' + (cls ? ' ' + cls : '');
  b.textContent = label;
  if (title) b.title = title;
  b.onclick = onclick;
  return b;
};

function renderControls(state) {
  const card = $('ctrlCard');
  if (!state) { card.hidden = true; return; }
  card.hidden = false;

  const r = state.risk ?? {};
  const d = state.digits ?? 2;

  // Risk presets. Index 3 is the CUSTOM slot the on-chart panel edits by
  // keyboard; here it takes a number field instead.
  const risk = $('cRisk');
  risk.replaceChildren();
  (r.riskOpts ?? []).forEach((v, i) => {
    const lbl = i === 3 ? (v > 0 ? '$' + v : 'CUSTOM') : '$' + v;
    risk.appendChild(btn(lbl, i === r.riskIndex ? 'sel' : '',
      () => i === 3 ? $('cRiskCustom').focus() : cmd('setRisk', { index: i }, `risk $${v}`)));
  });

  const sl = $('cSlPct');
  sl.replaceChildren();
  (r.slPctOpts ?? []).forEach((v, i) =>
    sl.appendChild(btn(v + '%', i === r.slPctIndex ? 'sel' : '',
      () => cmd('setSlPct', { index: i }, `SL ${v}%`))));

  const rr = $('cRR');
  rr.replaceChildren();
  (r.rrOpts ?? []).forEach((v, i) =>
    rr.appendChild(btn(v.toFixed(1) + ':1', i === r.rrIndex ? 'sel' : '',
      () => cmd('setRR', { index: i }, `R:R ${v}`))));

  const sp = $('cSplit');
  sp.replaceChildren();
  for (let n = 1; n <= 5; n++)
    sp.appendChild(btn(n === 1 ? 'none' : 'x' + n, n === r.split ? 'sel' : '',
      () => cmd('setSplit', { count: n }, `split x${n}`)));

  const hid = $('cHidden');
  hid.replaceChildren();
  hid.appendChild(btn('Limit', r.hiddenLmt ? 'on' : '',
    () => cmd('hiddenLmt', { on: !r.hiddenLmt }, 'hidden limit'),
    'Armed locally; only sent to the broker when price reaches entry'));
  hid.appendChild(btn('Stop', r.hiddenStp ? 'on' : '',
    () => cmd('hiddenStp', { on: !r.hiddenStp }, 'hidden stop')));

  // Armed setup: cancel is always offered, execute only when the EA allows it.
  const armed = state.armed ?? {};
  const box = $('cArmed');
  box.replaceChildren();
  if (!armed.active) {
    const s = document.createElement('span');
    s.className = 'mute';
    s.textContent = 'nothing armed — click a pattern below to draw lines on the chart';
    box.appendChild(s);
  } else {
    const info = document.createElement('span');
    info.innerHTML = `<strong>${armed.button ?? '—'}</strong>` +
      `<span class="mute"> entry ${fmt(armed.entry, d)} · SL ${fmt(armed.sl, d)} · TP ${fmt(armed.tp, d)}` +
      `${armed.hidden ? ' · hidden' : ''} · ${r.lots ?? '—'} lots</span>`;
    box.appendChild(info);
    box.appendChild(btn('Cancel', 'danger', () => cmd('cancel', {}, 'cancelled')));

    const canExec = state.session?.remoteExecAllowed;
    box.appendChild(btn(canExec ? 'EXECUTE' : 'EXECUTE (disabled)', canExec ? 'go' : 'off',
      () => {
        if (!canExec) return;
        if (!confirm(`Send this order for real?\n\n${armed.button} on ${state.symbol}\n` +
                     `entry ${fmt(armed.entry, d)}  SL ${fmt(armed.sl, d)}  TP ${fmt(armed.tp, d)}\n` +
                     `${r.lots} lots, $${r.riskUsd} risk\n\nThis is not a preview.`)) return;
        cmd('execute', {}, 'ORDER SENT');
      },
      canExec ? 'Sends the order' : 'Set InpAllowRemoteExec = true in the EA to enable'));
  }

  const openCount = state.exposure?.openCount ?? 0;
  const cl = $('cClose');
  cl.replaceChildren();
  [25, 50, 75].forEach((p) => {
    const b = btn(p + '%', '', () => {
      if (confirm(`Close ${p}% of every open position on ${state.symbol}?`)) cmd('closePct', { pct: p }, `closed ${p}%`);
    });
    b.disabled = openCount === 0;
    cl.appendChild(b);
  });
  const all = btn('Close all', 'danger', () => {
    if (confirm(`Close ALL positions on ${state.symbol}?`)) cmd('closeAll', {}, 'closed all');
  });
  all.disabled = openCount === 0;
  cl.appendChild(all);

  for (const [id, act, field] of [['cMoveBE', 'moveBE', null],
                                 ['cSetSL', 'setSL', 'cSlPrice'],
                                 ['cSetTP', 'setTP', 'cTpPrice']]) {
    const el = $(id);
    el.disabled = openCount === 0;
    el.onclick = () => {
      if (!field) {
        if (confirm(`Move SL to entry on every position on ${state.symbol}?`)) cmd('moveBE', {}, 'SL to BE');
        return;
      }
      const px = Number($(field).value);
      if (!px) { $('ctrlMsg').textContent = 'enter a price first'; return; }
      cmd(act, { price: px }, `${act} ${px}`);
    };
  }
}

// ── instance strip ──────────────────────────────────────────────────
// One card per live EA, grouped by client. With ten charts per terminal and
// several terminals, this is the only way to know which symbol the detail
// view below is actually describing — and which one an ARM would land on.
const fmtAge = (ms) => {
  if (ms == null) return '—';
  const sec = Math.round(ms / 1000);
  if (sec < 90) return sec + 's ago';
  const min = Math.round(sec / 60);
  return min < 90 ? min + 'm ago' : Math.round(min / 60) + 'h ago';
};

const COLLAPSE_KEY = 'rm_collapsed';
const readCollapsed = () => {
  try { return new Set(JSON.parse(localStorage.getItem(COLLAPSE_KEY) ?? '[]')); }
  catch { return new Set(); }
};
const isCollapsed = (login) => readCollapsed().has(String(login));
const toggleCollapsed = (login) => {
  const s = readCollapsed(), k = String(login);
  if (s.has(k)) s.delete(k); else s.add(k);
  localStorage.setItem(COLLAPSE_KEY, JSON.stringify([...s]));
};

function renderInstances(rows, servedKey) {
  const bar = $('instBar'), list = $('instList');
  if (!rows || rows.length === 0) { bar.hidden = true; return; }
  bar.hidden = false;

  // Group by account: a terminal maps to exactly one login, so this is also
  // "one group per terminal", which is how the caps will be scoped in step 2.
  const byLogin = new Map();
  for (const r of rows) {
    if (!byLogin.has(r.login)) byLogin.set(r.login, []);
    byLogin.get(r.login).push(r);
  }

  list.replaceChildren();
  for (const [login, group] of byLogin) {
    const online  = group.filter((g) => !g.stale).length;
    const armed   = group.filter((g) => g.armed).length;
    const openSum = group.reduce((a, g) => a + (g.openCount ?? 0), 0);
    const pnlSum  = group.reduce((a, g) => a + (g.pnlSymbol ?? 0), 0);
    // Collapse state is per client and remembered, so a ten-symbol terminal you
    // aren't trading doesn't push the one you are off the screen.
    const collapsed = isCollapsed(login);

    const h = document.createElement('div');
    h.className = 'instAcct' + (collapsed ? ' collapsed' : '');
    const srv = group.find((g) => g.server)?.server;
    h.innerHTML =
      `<span class="caret">${collapsed ? '▶' : '▼'}</span>` +
      `<span class="acctName">${login ?? 'unknown client'}</span>` +
      (srv ? `<span class="mute"> · ${srv}</span>` : '') +
      `<span class="acctTags">` +
        `<span class="${online === group.length ? 'up' : online ? 'warn' : 'down'}">` +
          `${online}/${group.length} online</span>` +
        `<span class="mute"> · ${openSum} open</span>` +
        (armed ? `<span class="warn"> · ${armed} armed</span>` : '') +
        `<span class="${pnlSum > 0 ? 'up' : pnlSum < 0 ? 'down' : 'mute'}"> · ` +
          `${pnlSum >= 0 ? '+' : ''}${pnlSum.toFixed(2)}</span>` +
      `</span>`;
    h.onclick = () => { toggleCollapsed(login); renderInstances(rows, servedKey); };
    list.appendChild(h);

    if (collapsed) continue;

    const strip = document.createElement('div');
    strip.className = 'instStrip';
    for (const r of group) {
      const [tTxt, tCls] = TREND[r.trend] ?? ['—', 'mute'];
      const el = document.createElement('div');
      el.className = 'inst' + (r.key === servedKey ? ' sel' : '') +
                     (r.stale ? ' stale' : '') + (r.collision ? ' clash' : '');
      el.innerHTML =
        `<div class="instSym"><span class="idot ${r.stale ? 'off' : 'on'}"></span>` +
        `${r.symbol ?? '—'}${r.armed ? '<span class="armFlag">ARMED</span>' : ''}</div>` +
        `<div class="instMeta"><span class="${tCls}">${tTxt}</span>` +
        `<span class="mute"> · ${r.drangePct != null ? r.drangePct.toFixed(0) + '% DR' : '—'}</span></div>` +
        `<div class="instMeta"><span class="${r.pnlSymbol > 0 ? 'up' : r.pnlSymbol < 0 ? 'down' : 'mute'}">` +
        `${r.pnlSymbol != null ? (r.pnlSymbol >= 0 ? '+' : '') + r.pnlSymbol.toFixed(2) : '—'}</span>` +
        `<span class="mute"> · ${r.openCount} open · ${r.available} avail</span></div>` +
        // Say which cadence it is on. An idle chart posting on M5 closes can be
        // four minutes old and perfectly healthy, so "3m ago" alone reads as a
        // problem when it isn't.
        `<div class="instMeta"><span class="mode ${r.mode ?? ''}">${(r.mode ?? '—').toUpperCase()}</span>` +
        `<span class="mute"> · ${fmtAge(r.ageMs)}</span></div>` +
        (r.stale ? `<div class="instMeta down">no post for ${fmtAge(r.ageMs)}</div>` : '') +
        (r.versionMatch === false ? `<div class="instMeta down">v${r.eaVersion}</div>` : '');
      el.onclick = () => {
        selectedKey = r.key;
        localStorage.setItem(INST_KEY, r.key);
        poll();
      };
      strip.appendChild(el);
    }
    list.appendChild(strip);
  }

  const clash = rows.find((r) => r.collision);
  const cb = $('collisionBanner');
  if (clash) {
    cb.hidden = false;
    cb.textContent =
      `TWO CHARTS ON ${clash.symbol} — charts ${clash.collision.chartIds.join(' and ')} are both ` +
      `posting as ${clash.key}. They overwrite each other; remove the EA from one of them.`;
  } else cb.hidden = true;
}

// ── main render ─────────────────────────────────────────────────────
function render(payload) {
  const { connected, stale, ageMs, state, versionMatch, eaVersion, contractVersion } = payload;
  $('ctrVer').textContent = contractVersion;

  liveKey = payload.key ?? null;
  if (window.RMJournal) window.RMJournal.setLogin(payload.state?.account?.login ?? 'default');
  lastRows = payload.instances ?? [];
  renderInstances(payload.instances, liveKey);
  // The chart we were pinned to disappeared (EA removed, terminal closed) —
  // follow the server's fallback rather than showing an empty page forever.
  if (payload.keyMissing && liveKey) {
    selectedKey = liveKey;
    localStorage.setItem(INST_KEY, liveKey);
  }

  // The plan is a browser+server concern and must render whether or not the EA
  // is connected — otherwise the whole planning UI is dead until MT is running,
  // which is exactly backwards: you write the plan BEFORE the session.
  const session = evaluateSession(plan, state);
  renderPlanStatus(session);

  const conn = $('conn');
  if (!state) {
    conn.className = 'pill down';
    $('connTxt').textContent = 'waiting for EA…';
    renderBuckets([], null, session);
    $('ctrlCard').hidden = true;
    $('posCard').hidden = true;
    return;
  }
  if (stale)         { conn.className = 'pill stale'; $('connTxt').textContent = `stale ${Math.round(ageMs / 1000)}s`; }
  else if (connected){ conn.className = 'pill live';  $('connTxt').textContent = `live · ${Math.round(ageMs / 1000)}s ago`; }

  // A version mismatch means the page may be misreading the payload — say so loudly.
  const banner = $('versionBanner');
  if (versionMatch === false) {
    banner.hidden = false;
    banner.textContent =
      `VERSION MISMATCH — EA reports ${eaVersion}, this app expects ${contractVersion}. ` +
      `Recompile/re-attach the EA, or update the web app. Values below may be misaligned.`;
  } else banner.hidden = true;

  digits = state.digits ?? 2;

  renderControls(state);
  renderPositions(lastRows, state);

  $('sym').textContent   = state.symbol ?? '—';
  $('price').textContent = fmt(state.price?.bid);

  // ── M15 ──
  const m = state.m15 ?? {};
  const [tTxt, tCls] = TREND[m.trend] ?? ['—', 'mute'];
  const [fTxt, fCls] = FLOW[m.flow]   ?? ['—', 'mute'];
  setTxt('m15Trend', tTxt, tCls);
  setTxt('m15Flow',  fTxt, fCls);
  setTxt('m15SwH',   fmt(m.swingHigh));
  setTxt('m15SwL',   fmt(m.swingLow));
  setTxt('m15Drange', m.drangePct != null ? m.drangePct.toFixed(1) + '%' : '—',
         m.drangePct >= 50 ? 'up' : m.drangePct > 0 ? 'mute' : '');
  const armedBos = [m.check4UpBos ? 'UP' : null, m.check4DnBos ? 'DOWN' : null].filter(Boolean);
  setTxt('m15Bos', armedBos.length ? armedBos.join(' + ') : 'none', armedBos.length ? '' : 'mute');

  // Which of CH_R / BS_R is live is decided purely by which event is newer.
  const choch = Number(m.lastChochTime ?? 0), cont = Number(m.lastContBosTime ?? 0);
  let lastTxt = '—';
  if (choch || cont) {
    lastTxt = choch > cont
      ? `CHOCH ${m.lastChochIsHigh ? '▲' : '▼'} → CH_R`
      : `BOS ${m.lastContBosIsHigh ? '▲' : '▼'} → BS_R`;
  }
  setTxt('m15Last', lastTxt);

  // ── H4 ──
  const h = state.h4 ?? {};
  const [h4t, h4c] = TREND[h.trend] ?? ['—', 'mute'];
  const [h4f, h4fc] = FLOW[h.flow]  ?? ['—', 'mute'];
  setTxt('h4Trend', h4t, h4c);
  setTxt('h4Flow',  h4f, h4fc);
  setTxt('h4SwH',   fmt(h.swingHigh));
  setTxt('h4SwL',   fmt(h.swingLow));
  const agree = h.trend && m.trend ? h.trend === m.trend : null;
  setTxt('h4Agree', agree === null ? '—' : agree ? 'YES — aligned' : 'NO — conflicting',
         agree === null ? 'mute' : agree ? 'up' : 'down');

  // ── M5 close-trend ──
  const c = state.m5ctrend ?? {};
  const [ctTxt, ctCls] = TREND[c.cstrend] ?? ['—', 'mute'];
  setTxt('ctrTrend', ctTxt, ctCls);
  setTxt('ctrFlow',  c.flow === 1 ? 'BUY pattern' : c.flow === 2 ? 'SELL pattern' : '—',
         c.flow === 1 ? 'up' : c.flow === 2 ? 'down' : 'mute');
  setTxt('ctrState', CANDLESTATE[c.candlestate] ?? '—', c.candlestate === 4 ? 'down' : '');
  setTxt('ctrFlip',  fmt(c.cstrend === 1 ? c.dnPatternC : c.upPatternC));

  // ── risk ──
  const r = state.risk ?? {};
  setTxt('rkUsd',    money(r.riskUsd));
  setTxt('rkSlPct',  r.slPct != null ? (r.slPct * 100).toFixed(0) + '% of prev daily range' : '—');
  setTxt('rkRR',     r.rr != null ? r.rr.toFixed(1) + ' : 1' : '—');
  setTxt('rkSlDist', fmt(r.slDistance));
  setTxt('rkLots',   r.lots != null ? Number(r.lots).toFixed(2) : '—');
  setTxt('rkSplit',  r.split > 1 ? `${r.split} orders` : 'single');

  // ── account ──
  const a = state.account ?? {};
  setTxt('acBal',    money(a.balance));
  setTxt('acEq',     money(a.equity));
  setTxt('acPnlSym', money(a.pnlSymbol), a.pnlSymbol > 0 ? 'up' : a.pnlSymbol < 0 ? 'down' : 'mute');
  setTxt('acPnlAll', money(a.pnlAll),    a.pnlAll    > 0 ? 'up' : a.pnlAll    < 0 ? 'down' : 'mute');
  const guards = [
    a.eqTPOn ? `TP ${a.eqTPPct}%` : null,
    a.eqSLOn ? `SL ${a.eqSLPct}%` : null,
  ].filter(Boolean);
  setTxt('acGuards', guards.length ? guards.join(' · ') + ' armed' : 'disarmed',
         guards.length ? 'up' : 'mute');

  // ── exposure ──
  const e = state.exposure ?? {};
  setTxt('exCount', e.openCount ?? '—', e.openCount ? '' : 'mute');
  setTxt('exLots',  e.openLots != null ? Number(e.openLots).toFixed(2) : '—');
  setTxt('exRisk',  money(e.openRisk), e.openRisk > 0 ? 'down' : 'mute');
  setTxt('exRew',   money(e.openReward), e.openReward > 0 ? 'up' : 'mute');
  const ar = state.armed ?? {};
  setTxt('exArmed', ar.active ? `${ar.button}${ar.hidden ? ' (hidden)' : ''} @ ${fmt(ar.entry)}` : 'none',
         ar.active ? '' : 'mute');

  renderBuckets(state.patterns, state, session);
  renderSrcVerdict();
}

// ── EA source ───────────────────────────────────────────────────────
let srcMeta = null;

const kb = (n) => (n / 1024).toFixed(0) + ' KB';

async function loadSourceMeta() {
  try {
    const { sources } = await api('/api/source').then((r) => r.json());
    srcMeta = sources;
  } catch (e) {
    // Never leave the card stuck on "checking…" with the buttons disabled —
    // that reads as a hang when it's actually a failed request.
    srcMeta = null;
    const why = e.message === 'unauthorised' ? 'enter the bridge token first' : `bridge error (${e.message})`;
    $('srcMeta5').textContent = why;
    $('srcMeta4').textContent = why;
    $('srcGet5').disabled = true;
    $('srcGet4').disabled = true;
    $('srcVerdict').className = 'pill down';
    $('srcVerdictTxt').textContent = e.message === 'unauthorised' ? 'token required' : 'source check failed';
    return;
  }

  for (const [key, id, btn] of [['mq5', 'srcMeta5', 'srcGet5'],
                                ['mq4', 'srcMeta4', 'srcGet4'],
                                ['tpl', 'srcMetaTpl', 'srcGetTpl']]) {
    const m = srcMeta[key];
    if (m?.available) {
      const stamp = `${kb(m.bytes)} · ${m.sha256} · ${new Date(m.modified).toLocaleDateString()}`;
      $(id).textContent = m.version ? `v${m.version} · ${stamp}` : stamp;
      $(btn).disabled = false;
    } else {
      $(id).textContent = 'not present in this deployment';
      $(btn).disabled = true;
    }
  }
  renderSrcVerdict();
}

// Compare what the connected EA reports against what this bridge is serving,
// so "your EA is out of date" is a fact rather than a guess.
function renderSrcVerdict() {
  const latest = srcMeta?.mq5?.version;
  const running = lastState?.v;
  const pill = $('srcVerdict');
  const txt = $('srcVerdictTxt');
  if (!latest)          { pill.className = 'pill down';  txt.textContent = 'source unavailable'; return; }
  if (!running)         { pill.className = 'pill stale'; txt.textContent = `latest v${latest} · EA not connected`; return; }
  if (running === latest) { pill.className = 'pill ok';  txt.textContent = `EA up to date · v${running}`; return; }
  pill.className = 'pill down';
  txt.textContent = `EA is v${running}, latest is v${latest} — update`;
}

// The download must carry the auth header, so a plain <a href> won't do;
// fetch it and hand the browser a blob instead.
async function downloadSource(key) {
  $('srcMsg').textContent = 'downloading…';
  try {
    const res = await api(`/api/source/${key}`);
    const blob = await res.blob();
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = srcMeta?.[key]?.name ?? `RiskManager.${key}`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
    // "compile it in MetaEditor" is nonsense advice for a .bat or a template.
    const after = {
      mq5:    'Now compile it in MetaEditor (F7) and re-attach the EA.',
      mq4:    'Now compile it in MetaEditor (F7) and re-attach the EA.',
      tpl:    'Put it in MQL5/Profiles/Templates, then right-click chart → Template.',
      guibat: 'Keep it beside Update-EA.ps1 and updater.config.json, then double-click it.',
      guips1: 'Keep it beside Update-EA-GUI.bat — the .bat is the one you double-click.',
      bat:    'Keep it beside Update-EA.ps1 and updater.config.json, then double-click it.',
      ps1:    'Keep it in the same folder as the .bat; the .bat runs it.',
    }[key] ?? '';
    $('srcMsg').textContent = `Saved ${a.download}. ${after}`;
  } catch (e) {
    $('srcMsg').textContent = e.message === 'unauthorised'
      ? 'Enter the bridge token first.'
      : 'Download failed — is the file present in this deployment?';
  }
}

$('getBat').onclick    = () => downloadSource('bat');
$('getPs1').onclick    = () => downloadSource('ps1');
$('getGuiBat').onclick = () => downloadSource('guibat');
$('getGuiPs1').onclick = () => downloadSource('guips1');

// Built in the browser, not fetched: the token is already here in
// localStorage, and this way it never round-trips through the server just to
// come back again. Paths are left blank on purpose — the script detects them
// on first run and writes them back.
$('getCfg').onclick = () => {
  if (!token) { $('srcMsg').textContent = 'Enter the bridge token first.'; return; }
  const cfg = {
    bridgeUrl: location.origin,
    token,
    metaEditorPath: '',
    terminalDataDir: '',
  };
  // Per-client EA filename. MetaTrader's server-side journal can record the
  // expert's name, so a distinct one per machine stops that being a handle
  // that links accounts together. Strip anything a filename cannot carry.
  const eaName = $('cfgEaName').value.trim().replace(/[^A-Za-z0-9_\- ]/g, '');
  if (eaName) cfg.eaName = eaName;
  const blob = new Blob([JSON.stringify(cfg, null, 4)], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = 'updater.config.json';
  document.body.appendChild(a); a.click(); a.remove();
  URL.revokeObjectURL(url);
  $('srcMsg').textContent = 'Saved updater.config.json (bridge URL and token filled in'
    + (eaName ? `, EA name ${eaName}` : '') + '). Keep it private.';
};

$('srcGet5').onclick = () => downloadSource('mq5');
$('srcGet4').onclick = () => downloadSource('mq4');
$('srcGetTpl').onclick = () => downloadSource('tpl');

let srcRetryAt = 0;

async function poll() {
  if (authBlocked) return;          // don't hammer a server that's rejecting us
  // A single failed metadata load must not disable the card forever.
  if (!srcMeta && Date.now() > srcRetryAt) { srcRetryAt = Date.now() + 15000; loadSourceMeta(); }
  try {
    const q = selectedKey ? '?key=' + encodeURIComponent(selectedKey) : '';
    const payload = await api('/api/state' + q).then((r) => r.json());
    lastState = payload.state;
    render(payload);
  } catch (e) {
    $('conn').className = 'pill down';
    $('connTxt').textContent = e.message === 'unauthorised' ? 'token required' : 'bridge unreachable';
    // Keep the plan usable even when the bridge is unreachable.
    renderPlanStatus(evaluateSession(plan, null));
  }
}

async function boot() {
  // Ask up front whether a token is needed, so the gate appears immediately
  // instead of after a failed call.
  const health = await fetch('/api/health').then((r) => r.json()).catch(() => null);
  if (health?.authRequired && !token) showAuthBar('Enter the server\'s RM_TOKEN.');

  try {
    const { plan: saved } = await api('/api/plan').then((r) => r.json());
    if (saved) plan = { ...PLAN_DEFAULTS, ...saved };
  } catch { /* unauthenticated or no saved plan — the UI still works */ }

  planToForm();
  renderPlanStatus(evaluateSession(plan, null));   // plan UI live from first paint
  await loadSourceMeta();
  await poll();
  setInterval(poll, 1000);
}

boot();
})();
