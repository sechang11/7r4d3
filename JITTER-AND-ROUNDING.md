# Jitter & rounding in RiskManager — what's there, and why

A reference so we can revisit these and decide what to keep. There are **three**
mechanisms that add variation or snap values to a grid. None of them are load-
bearing for correctness — the EA trades fine with all three off — so any of them
can be removed without breaking anything.

Framing (from the boundary we agreed): variation that lets **independent users
represent their own choices** is fine; anything whose purpose is to make one
operator's automation **pass as manual to a monitor** is the part to drop. Notes
below flag which is which.

---

## 1. Risk jitter — `InpRiskJitterPct` (default 5)

**What:** shaves a random slice off the dollar risk of each armed setup, so the
lot size isn't always exactly $500 / $1000 / etc.

**How:** `EffectiveRisk()` (RiskManager.mq5). Once per armed setup it draws
`g_riskJitter = 1 - rand(0 .. N%)`, i.e. a multiplier between `(1 - N/100)` and
`1.0`, and multiplies the base risk by it. **Downward only** — never above the
figure you set. Drawn once and frozen for the setup, so the size shown on the
panel equals the size that fills (and stays identical across split legs).

- `InpRiskJitterPct = 0` turns it off completely (exact sizes).
- Redrawn when a setup is armed; cleared when abandoned or sent.

**Honest read:** this one is the closest to the line. Its only effect is making
automated sizes look less round. If you keep it, keep it small; if the goal is
just "independent users differ," per-user **size tiers** (below) already do that
more legitimately. Candidate for removal.

---

## 2. Split-leg timing — `InpStaggerMinMs` (200) / `InpStaggerMaxMs` (2000)

**What:** when a trade is split into N legs, the legs are sent with a random gap
between them instead of all at once.

**How:** `StaggerGapMs()` returns `lo + rand(0 .. hi-lo)` ms; `ProcessPendingLegs`
(called from `OnTick`) sends the next leg once that gap elapses. Non-blocking —
it does **not** `Sleep()`, because OnTick still has to run the exit/BE/partials
matrices and equity guards; blocking those to space legs out would delay a stop.

- Set `InpStaggerMaxMs = 0` (or both to 0) to send all legs at once.
- Split count itself is `InpOrderSplit` / the SPLIT button (separate feature).

**Honest read:** legitimate as "independent users don't fire identical
millisecond-aligned bursts." Keep it at "avoid collisions," not "beat a timing
detector." Fine to keep; fine to zero out.

---

## 3. Lot-step rounding — not configurable (broker-driven)

**What:** the computed lot size is floored to the broker's volume step.

**How:** `CalcLotSize()` does `lots = floor(lots / lotStep) * lotStep`, then
clamps to `[lotMin, lotMax]` and `NormalizeDouble(lots, 8)`. This is **not**
disguise — it's required: brokers reject volumes that aren't a multiple of the
step (e.g. 0.01). **Floor**, not round, so risk is never rounded *up* past your
figure. Leave this alone.

Related: entry/SL/TP are `NormalizeDouble(price, _Digits)` — snapping to the
symbol's tick precision. Also required, also not disguise.

---

## Summary

| Mechanism | Input | Default | Purpose | Safe to remove? |
|---|---|---|---|---|
| Risk jitter | `InpRiskJitterPct` | 5 | vary lot size | Yes — set 0 |
| Split-leg timing | `InpStaggerMin/MaxMs` | 200 / 2000 | space split legs | Yes — set 0 |
| Lot-step rounding | (none) | broker step | valid volumes | **No** — required |

The **legitimate** way to make independent users differ is per-user
configuration — size tiers (`InpRisk1/2/3`), SL presets (`InpSLPct1..4`), R:R
(`InpRR1..3`), split count (`InpOrderSplit`) — which represent each trader's own
choices rather than randomizing one operator's footprint. Prefer those over the
jitters if the goal is "two users shouldn't look identical."
