// RiskManager dashboard.
//
// This file deliberately contains NO market-structure logic. Every value it
// shows was computed by the EA and shipped in the state snapshot. If you ever
// find yourself wanting to calculate a swing/trend/FVG here — don't. Add it to
// the EA's BuildStateJson() instead, so there is only one source of truth.

const $ = (id) => document.getElementById(id);

// Thesis buckets — see TRADING_SYSTEM.md §5.2. This is presentation only:
// which patterns are *legal* comes from the EA, this just groups them by intent.
const BUCKETS = [
  { key: 'A', name: 'With-trend continuation',
    desc: 'trend established — join pullbacks or breakouts',
    ids: ['RM_BuyMktSw','RM_SellMktSw','RM_BuyLmtBOS','RM_SellLmtBOS',
          'RM_BuyLmtBoR','RM_SellLmtBoR','RM_BuyStpBK','RM_SellStpBK',
          'RM_BuyStpChC','RM_SellStpChC'] },
  { key: 'B', name: 'Post-reversal',
    desc: 'structure just flipped — first retrace of the new trend',
    ids: ['RM_BuyLmtChR','RM_SellLmtChR'] },
  { key: 'C', name: 'Reversal anticipation',
    desc: 'pre-positioned for the break that confirms a flip',
    ids: ['RM_BuyStpCH','RM_SellStpCH','RM_BuyStpCB','RM_SellStpCB'] },
  { key: 'D', name: 'Mean reversion',
    desc: 'price overextended outside the dealing range — fade it',
    ids: ['RM_BuyMktUFV','RM_SellMktUFV'] },
  { key: 'E', name: 'Level-based',
    desc: "yesterday's range rather than intraday structure",
    ids: ['RM_BuyLmtDK','RM_SellLmtDK','RM_BuyMkt','RM_SellMkt',
          'RM_BuyLmt','RM_SellLmt','RM_BuyStp','RM_SellStp'] },
];

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
function renderBuckets(patterns) {
  const byId = Object.fromEntries((patterns ?? []).map((p) => [p.id, p]));
  const host = $('buckets');
  host.innerHTML = '';

  for (const b of BUCKETS) {
    const present = b.ids.map((id) => byId[id]).filter(Boolean);
    if (!present.length) continue;
    const live = present.filter((p) => p.available).length;

    const wrap = document.createElement('div');
    wrap.className = 'bucket';
    wrap.innerHTML =
      `<div class="bucket-head">
         <strong>${b.key} · ${b.name}</strong>
         <span class="desc">${b.desc}</span>
         <div class="spacer"></div>
         <span class="desc">${live}/${present.length} available</span>
       </div>`;

    const tiles = document.createElement('div');
    tiles.className = 'tiles';
    for (const p of present) {
      const side = p.dir > 0 ? 'buy' : 'sell';
      const el = document.createElement('div');
      el.className = `tile ${p.available ? 'ok ' + side : 'blocked'}`;
      el.innerHTML = `${p.label}<span class="sub">${p.type}</span>`;
      el.title = p.available
        ? `${p.id} — available. Click to queue an arm command.`
        : `${p.id} — gate not satisfied right now (see TRADING_SYSTEM.md §5.3)`;
      if (p.available) el.onclick = () => queueArm(p);
      tiles.appendChild(el);
    }
    wrap.appendChild(tiles);
    host.appendChild(wrap);
  }
}

async function queueArm(p) {
  if (!remoteArmed) {
    $('armNote').textContent = 'remote disarmed — press ARM REMOTE first';
    return;
  }
  if (!confirm(`Queue ARM for ${p.label} (${p.type})?\n\nThis tells the EA to draw the entry/SL/TP lines.\nIt does NOT send an order.`)) return;
  const r = await fetch('/api/commands', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'arm', params: { button: p.id } }),
  }).then((x) => x.json());
  $('armNote').textContent = `queued #${r.id} · arm ${p.label}`;
}

$('armBtn').onclick = () => {
  remoteArmed = !remoteArmed;
  $('armBox').className = 'arm' + (remoteArmed ? ' on' : '');
  $('armBtn').textContent = remoteArmed ? 'DISARM' : 'ARM REMOTE';
  $('armNote').textContent = remoteArmed
    ? 'remote armed — clicking a pattern queues a command'
    : 'remote commands disarmed';
};

// ── main render ─────────────────────────────────────────────────────
function render(payload) {
  const { connected, stale, ageMs, state, versionMatch, eaVersion, contractVersion } = payload;
  $('ctrVer').textContent = contractVersion;

  const conn = $('conn');
  if (!state)        { conn.className = 'pill down';  $('connTxt').textContent = 'waiting for EA…'; return; }
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

  renderBuckets(state.patterns);
}

async function poll() {
  try {
    render(await fetch('/api/state').then((r) => r.json()));
  } catch {
    $('conn').className = 'pill down';
    $('connTxt').textContent = 'bridge unreachable';
  }
}

poll();
setInterval(poll, 1000);
