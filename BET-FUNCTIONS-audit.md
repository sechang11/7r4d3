# MQL Bet Functions Audit — Existing vs. New Spec

> **Status:** Audit only. Do **not** apply changes blindly — each delta below changes live order-placement behavior. Review per handler, discuss, then refactor.
>
> Reference: `TrillionGame/docs/BET-FUNCTIONS-spec.md` (canonical), `TrillionGame/client/src/utils/betFunctions.js` (reference impl).

## Existing handlers in `RiskManager.mq5` / `.mq4`

| Handler | Spec mapping | Lines (mq5) |
|---|---|---|
| `HandleSwingOrderButton(dir, type)` | Generic swing-level order (market / limit / stop). Roughly maps to **CHOCH breakout** when `type==2`, otherwise has no direct spec equivalent. | ~6595 |
| `HandleChochOrderButton(dir)` | **CHOCH breakout.** | ~6646 |
| `HandleBkoOrderButton(dir)` | **BOS breakout.** Named "BKO" (BreaKOut). | ~6711 |
| `HandleDstkOrderButton(dir)` | DSTK matrix levels — no spec equivalent. Out of scope. | ~6856 |
| `HandleRfvOrderButton(dir)` | "R_FV" = reactive fair value — closest to **UFV reversion** but uses limit-at-swing, not market-when-tick-exceeds-swing. | ~6920 |
| `HandleBosOrderButton(dir)` | **BOS retrace**, but uses **67% retracement** rather than a wick FVG. | ~6959 |

### Missing from MQL

- **CHOCH retrace** (wick FVG limit order after CHOCH). No handler exists.
- **CHOCH continuation** (anticipatory stop at new swing-extreme after a counter-flow). No handler exists.
- **UFV reversion (market)** — `HandleRfvOrderButton` is a limit at the swing, not a market-on-overshoot.

## Deltas per existing handler

### `HandleChochOrderButton` ↔ §1 CHOCH Breakout

- **Spec:** Returns null if price already breached (`tick >= sh.price` long / `tick <= sl.price` short).  
  **MQL:** No precheck — places the stop unconditionally. Will instantly trigger as a market order if breached.
- **Spec:** Stop = opposite swing extreme (`lastSwingLow` / `lastSwingHigh`).  
  **MQL:** Two modes via `g_chochMode`: (0) SL Range from daily range (default), (1) swing SL. Spec maps to **mode 1 only**.
- **Spec:** Requires `tTrend == 2` for long, `tTrend == 1` for short, AND `check4UpBos` / `check4DnBos` armed.  
  **MQL:** No trend/arming check — uses whatever `g_tt_swingHigh / g_tt_swingLow` currently is.

### `HandleBkoOrderButton` ↔ §4 BOS Breakout

- **Spec:** Entry = current swing high/low (forward-looking anticipation).  
  **MQL:** Entry = `FindHighestHighSince(lastBosSwHTime)` / `FindLowestLowSince(lastBosSwLTime)` — looks back over completed bars for the extreme. This is a **trailing** breakout, not an anticipatory one.
- **Spec:** Requires `tTrend` matches breakout side AND no CHOCH after last BOS.  
  **MQL:** Only checks `g_tt_lastBosTime != 0` — no trend or CHOCH-after-BOS check.
- **Spec:** Stop = current `lastSwingLow` / `lastSwingHigh`.  
  **MQL:** Stop = `g_tt_lastBosSwL` / `g_tt_lastBosSwH` — the swing **at time of last BOS**, not current. Diverges when swings advance after the BOS.

### `HandleBosOrderButton` ↔ §5 BOS Retrace

- **Spec:** Entry = bottom of deepest unfilled bullish wick FVG (`c[2].high`) within window `[lastBOS.time, now]`.  
  **MQL:** Entry = 67% retracement from highest high since BOS toward swing low. Geometric retracement, not FVG-based.
- **Spec:** Stop = `lastSwingLow.price` (current).  
  **MQL:** No explicit SL beyond the retrace-anchor swing low. Function continues past line 7000 — review needed for full TP/SL flow.

### `HandleRfvOrderButton` ↔ §6 UFV Reversion

- **Spec:** Market order **when tick exceeds the swing**. Entry = `tickPrice`. Stop reflects the FV-range mirror.  
  **MQL:** Limit-at-swing for an anticipated retrace **back** to the swing. Completely different intent (continuation vs. reversion). May want to keep `RFV` as-is and add a **new** UFV reversion handler.

## Recommended refactor plan (incremental)

1. **No code changes yet.** Each delta is a behavior change to a working button. Confirm intent per handler with user.
2. Add the three **missing** handlers as **new buttons** without touching existing ones:
   - `HandleChochRetraceButton(dir)` — wick-FVG limit after CHOCH (red THRS gating).
   - `HandleChochContinuationButton(dir)` — anticipatory stop on counter-flow after CHOCH.
   - `HandleUfvReversionButton(dir)` — market order on swing overshoot.
3. Once new buttons are validated, optionally **gate-and-align** existing handlers behind a "Strict spec" toggle that adds the missing checks (trend, arming, breached-price, CHOCH-after-BOS) without changing default behavior.
4. Mirror all changes to `RiskManager.mq4`.

## Shared helpers needed for new handlers

```mql5
// Find most recent BOS mark (CHOCH=false) at-or-before `t`.
// Returns mark via out-params; false if none.
bool FindLastBOS(datetime t, double &swH, double &swL, datetime &bosTime, bool &isHigh);

// Find most recent CHOCH (CHOCH=true) at-or-before `t`.
bool FindLastCHOCH(datetime t, double &swH, double &swL, datetime &bosTime, bool &isHigh);

// 3-candle wick FVG scan over bars [fromBar..0]. Returns deepest valid + unfilled.
struct WickFVG { double top; double bottom; datetime time; bool filled; };
bool FindDeepestUnfilledWickFVG(int fromBar, int direction /* +1 bull, -1 bear */,
                                double swingFilterPrice, WickFVG &out);
```

Existing thrust state already tracks `g_tt_lastBosSwH/SwL/SwHTime/SwLTime` and `g_tt_swingHigh/Low/HighTime/LowTime`, but only the *latest* CHOCH or BOS. For CHOCH retrace + BOS retrace gating ("is the latest mark a CHOCH or a later BOS?") we need to track **both** with timestamps separately:

```mql5
datetime g_tt_lastChochTime = 0;
double   g_tt_lastChochSwH = 0, g_tt_lastChochSwL = 0;
bool     g_tt_lastChochIsHigh = false;
// existing g_tt_lastBosTime / SwH / SwL are now strictly continuation BOS,
// updated only when isCHCH == false.
```

This refactor is the prerequisite for all four new/aligned handlers.
