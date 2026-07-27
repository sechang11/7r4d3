// Session game plan — schema + evaluation.
//
// The plan is pre-commitment: you set it BEFORE the session, and it decides
// what you're allowed to do DURING it. The point is to move the risk decision
// out of the moment of temptation.
//
// This file holds no market-structure logic. It only combines:
//   (a) the EA's per-pattern availability  →  is this setup even present?
//   (b) your plan                          →  are you allowed to take it?
//
// Verdicts:
//   'go'      pattern is available AND permitted by the plan
//   'gate'    the EA says the setup isn't there (structure hasn't formed)
//   'plan'    the setup exists, but your plan forbids it — with a reason
//   'locked'  a session-wide cap is hit; nothing is permitted

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

const BUCKET_OF = {};
for (const b of BUCKETS) for (const id of b.ids) BUCKET_OF[id] = b.key;

const PLAN_DEFAULTS = {
  version: 1,
  active: false,
  note: '',
  bias: 'both',                 // both | long | short | standaside
  buckets: ['A', 'B', 'C', 'D', 'E'],
  maxTrades: 3,
  maxSessionLossUsd: 1000,
  requireH4Agree: false,
  minDrangePct: 0,
  windowStart: '',              // 'HH:MM' broker time, blank = no restriction
  windowEnd: '',
  countAllSymbols: true,        // trade cap spans the account, not just this chart
  activatedAt: null,
  baselineEquity: null,
  tradesAtActivation: null,     // EA's entry count when the plan was activated
};

/**
 * Trades taken since the plan was activated.
 *
 * Derived from the EA's own entry count rather than a counter we increment,
 * so trades placed by clicking the chart — the ones most likely to be
 * impulsive — count against the cap exactly like remote arms do.
 */
function tradesTaken(plan, state) {
  const s = state?.session;
  if (!s || plan?.tradesAtActivation == null) return 0;
  const now = plan.countAllSymbols ? s.tradesTodayAll : s.tradesTodaySymbol;
  if (now == null) return 0;
  return Math.max(0, now - plan.tradesAtActivation);
}

// Broker wall-clock minutes-since-midnight from the EA's timestamp.
// state.ts is broker server time, so read it in UTC to get broker hours.
function brokerMinutes(ts) {
  if (!ts) return null;
  const d = new Date(Number(ts) * 1000);
  return d.getUTCHours() * 60 + d.getUTCMinutes();
}

const hhmmToMin = (s) => {
  if (!s || !/^\d{1,2}:\d{2}$/.test(s)) return null;
  const [h, m] = s.split(':').map(Number);
  return h * 60 + m;
};

/**
 * Session-wide checks that block *everything* regardless of pattern.
 * @returns {{locked:boolean, reasons:string[], lossSoFar:number|null}}
 */
function evaluateSession(plan, state) {
  const reasons = [];
  const taken = tradesTaken(plan, state);
  if (!plan?.active) return { locked: false, reasons, lossSoFar: null, taken };

  // Realised+floating drawdown against the equity recorded at activation.
  let lossSoFar = null;
  if (plan.baselineEquity != null && state?.account?.equity != null) {
    lossSoFar = plan.baselineEquity - state.account.equity;
    if (plan.maxSessionLossUsd > 0 && lossSoFar >= plan.maxSessionLossUsd) {
      reasons.push(`session loss cap hit — down $${Math.round(lossSoFar)} of $${plan.maxSessionLossUsd}`);
    }
  }

  if (plan.maxTrades > 0 && taken >= plan.maxTrades) {
    reasons.push(`trade cap hit — ${taken}/${plan.maxTrades} taken`);
  }

  if (plan.bias === 'standaside') reasons.push('plan says stand aside today');

  const now = brokerMinutes(state?.ts);
  const a = hhmmToMin(plan.windowStart), b = hhmmToMin(plan.windowEnd);
  if (now != null && a != null && b != null) {
    const inWindow = a <= b ? (now >= a && now <= b) : (now >= a || now <= b);
    if (!inWindow) reasons.push(`outside session window ${plan.windowStart}–${plan.windowEnd} broker time`);
  }

  return { locked: reasons.length > 0, reasons, lossSoFar, taken };
}

/**
 * Per-pattern verdict.
 * @returns {{verdict:string, reason:string}}
 */
function evaluatePattern(pattern, plan, state, session) {
  if (session.locked) return { verdict: 'locked', reason: session.reasons[0] };

  // The EA is authoritative on whether the setup exists at all.
  if (!pattern.available) {
    return { verdict: 'gate', reason: 'setup not present — gate not satisfied' };
  }

  if (!plan?.active) return { verdict: 'go', reason: 'no active plan' };

  if (plan.bias === 'long'  && pattern.dir < 0) return { verdict: 'plan', reason: 'plan is long-only' };
  if (plan.bias === 'short' && pattern.dir > 0) return { verdict: 'plan', reason: 'plan is short-only' };

  const bucket = BUCKET_OF[pattern.id];
  if (bucket && !plan.buckets.includes(bucket)) {
    const name = BUCKETS.find((b) => b.key === bucket)?.name ?? bucket;
    return { verdict: 'plan', reason: `bucket ${bucket} (${name}) not in plan` };
  }

  if (plan.requireH4Agree) {
    const h4 = state?.h4?.trend;                 // 1 bullish, 2 bearish
    const want = pattern.dir > 0 ? 1 : 2;
    if (h4 && h4 !== want) {
      return { verdict: 'plan', reason: `H4 is ${h4 === 1 ? 'bullish' : 'bearish'}, conflicts with this direction` };
    }
  }

  if (plan.minDrangePct > 0) {
    const dr = state?.m15?.drangePct ?? 0;
    if (dr < plan.minDrangePct) {
      return { verdict: 'plan', reason: `dealing range ${dr.toFixed(1)}% below required ${plan.minDrangePct}%` };
    }
  }

  return { verdict: 'go', reason: 'permitted by plan' };
}

window.RMPlan = { BUCKETS, BUCKET_OF, PLAN_DEFAULTS, evaluateSession, evaluatePattern, tradesTaken };
