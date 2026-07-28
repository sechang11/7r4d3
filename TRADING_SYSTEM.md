# Trading System Reference — Definitions & Entry Patterns

**Source of truth:** `RiskManager.mq5` / `RiskManager.mq4` (identical logic, dual-platform).
**Companion docs:** [FEATURES.md](FEATURES.md) documents the *UI/buttons*. [EXECUTION-FOOTPRINT.md](EXECUTION-FOOTPRINT.md) audits how mechanical the order flow looks and how to reduce that. This doc documents the *trading system* — the vocabulary, the math, and the entry menu.

> **Purpose of this file.** Before a session you build a **game plan**: what you expect, which structures you'll trade, which entries you'll allow yourself. This doc is the fixed menu that plan draws from. Nothing here is discretionary — every definition below is exactly what the code computes.

---

## Table of Contents

1. [The three engines](#1--the-three-engines)
2. [Core definitions](#2--core-definitions)
3. [Daily & session structure](#3--daily--session-structure)
4. [Risk model](#4--risk-model)
5. [Entry pattern catalog](#5--entry-pattern-catalog)
6. [Trade management tools](#6--trade-management-tools)
7. [Alerts](#7--alerts)
8. [Machine-readable state](#8--machine-readable-state)
9. [Game-plan scaffold](#9--game-plan-scaffold-next-build)

---

## 1 · The three engines

Everything in the system is derived from three independent state machines. Know which engine an entry reads from — that's what determines its timeframe character.

| Engine | Runs on | Lookback | Drives | State prefix |
|---|---|---|---|---|
| **M15 Thrust** | M15 bars, 4-bar pivot window | `TT_LOOKBACK = 6240` bars (~3 months) | Swings, BOS, CHOCH, flow, trend, FV, FVG, DRange — **most entries** | `g_tt_*` |
| **H4 Thrust** | H1 bars, 4-bar window (≈H4 swings) | `H4_LOOKBACK = 1560` bars (~3 months) | Higher-TF bias, H4 trail, H4 flow alert | `g_h4_*` |
| **M5 Close-Trend** (`ctrend`) | M5 closed bars | 2000 bars (~7 days) | Close-trend flip alert, candlestate | `g_ctrM5.*` |

**Critical implementation note:** the M15 thrust engine is a *full recompute* — `ComputeThrust()` wipes all state and re-walks the entire lookback from oldest to newest. It includes **bar 0 (the forming candle)**, so swing values can shift intra-bar during fast moves. Any dedup logic must key on **pivot time**, not pivot price. (This was the cause of the CHCH alert spam.)

---

## 2 · Core definitions

### 2.1 Pivot

The anchor point for everything. Current bar vs. the **previous 4 bars**.

```
isPivotLow  =  low[i]  <= low[i+1]  && low[i]  <= low[i+2]
            && low[i]  <= low[i+3]  && low[i]  <= low[i+4]

isPivotHigh =  high[i] >= high[i+1] && high[i] >= high[i+2]
            && high[i] >= high[i+3] && high[i] >= high[i+4]
```

When found, it's stored as the *candidate*: `lowPH`/`lowTH` (price/time) or `highPH`/`highTH`. A pivot is not yet a swing — it's promoted to a swing by a **thrust**.

> **Button:** `PIVT` — plots pivot arrows (blue = pivot high, orange = pivot low).

### 2.2 Flow (`tFlow`)

Short-term directional state. `1 = up`, `2 = down`. Flips on a thrust.

**Flow level** = the trailing extreme of the last 4 bars:
- `tFlow == 1` (up) → flow level = **lowest low** of bars [1..4] (dynamic support)
- `tFlow == 2` (down) → flow level = **highest high** of bars [1..4] (dynamic resistance)

> **Button:** `FLW▲/▼` — aqua dashed extending line at the flow level.

### 2.3 Thrust

The event that **promotes a pivot to a swing**. A thrust = price breaking the 4-bar extreme against the current flow.

```
DOWN THRUST   if tFlow == 1 and low[i] < lowestLow(bars i+1..i+4):
                  swingHigh  = last pivot high (highPH)
                  swingHighTime = highTH
                  tFlow      = 2
                  check4UpBos = true          ← arms an up-BOS watch

UP THRUST     if tFlow == 2 and high[i] > highestHigh(bars i+1..i+4):
                  swingLow   = last pivot low (lowPH)
                  swingLowTime = lowTH
                  tFlow      = 1
                  check4DnBos = true          ← arms a down-BOS watch
```

The down-thrust check runs **twice** per bar (before and after the up-thrust check) to catch same-bar reversals.

> **Button:** `THRS` — horizontal line at each thrust's swing level. **Olive** = pending (no BOS yet).

### 2.4 Swing High / Swing Low

The two levels that define the current **dealing range**. Set only by thrusts (§2.3). These are the most-referenced values in the whole system — most entries anchor their SL to one of them.

- `g_tt_swingHigh` / `g_tt_swingHighTime`
- `g_tt_swingLow` / `g_tt_swingLowTime`

> **Buttons:** `SW.HL` (dots/lines per bar), `S.MTX` (position within range as %).

### 2.5 BOS — Break of Structure

A **close-independent** break of an armed swing level.

```
UP BOS     if check4UpBos and high[i] > swingHigh:
               check4UpBos = false
               tTrend = 1
UP BOS is a CHOCH if tTrend was 2 (bearish→bullish), else a continuation.

DOWN BOS   if check4DnBos and low[i] < swingLow:
               check4DnBos = false
               tTrend = 2
DOWN BOS is a CHOCH if tTrend was 1 (bullish→bearish), else a continuation.
```

**Line recoloring:** the thrust line that gets recolored is the one for the *responsible opposite swing* — the swing low that launched the rally that broke the high (not the broken high itself).

- **Green** = continuation BOS
- **Maroon** = CHOCH (reversal)

> **Buttons:** `BOS` (recolor), `CHCH` (show/hide maroon), `BOS#` (sequential count — resets to 1 on CHOCH, increments on continuation).

### 2.6 Trend (`tTrend`)

`1 = bullish`, `2 = bearish`. Changes **only** via BOS. This is the master gate for most entry buttons — a button greys out when trend doesn't match its requirement.

> **Button:** `TREND▲/▼` (display only).

### 2.7 CHOCH vs continuation — tracked separately

The engine keeps two independent "last event" records, which is what lets `CH_R` and `BS_R` know which context you're in:

| Record | Set when | Fields |
|---|---|---|
| **Last CHOCH** | BOS that *flipped* the trend | `lastChochTime`, `lastChochSwH/SwL`, `lastChochIsHigh` |
| **Last continuation BOS** | BOS in the *same* direction as trend | `lastContBosTime`, `lastContBosSwH/SwL`, `lastContBosIsHigh` |

**Which is "current" is decided by time comparison:**
- `lastContBosTime > lastChochTime` → you are in a **continuation** leg → use `BS_R`
- `lastChochTime > lastContBosTime` → you are in a **fresh reversal** leg → use `CH_R`

`*IsHigh = true` means the break was upward (bullish).

### 2.8 Fair Value (FV) zone

The rectangle between `swingHigh` and `swingLow` for each segment where both levels stay constant. This is the "fair" channel — price inside it is in balance.

> **Button:** `FV` — 3-state (off / subtle / solid). Forest green, drawn behind price.

### 2.9 Fair Value Gap (FVG) — wick FVG, 3-candle

Used by the `CH_R` and `BS_R` entries. Strict 3-candle definition:

Let `c2` = bar `j` (older), `c0` = bar `j-2` (newer):

```
BULLISH FVG   c2.high < c0.low     →  gap edge = c2.high
BEARISH FVG   c2.low  > c0.high    →  gap edge = c2.low
```

Three filters applied:

1. **Swing filter** — the gap edge must sit on the correct side of the protective swing:
   - bullish: `edge > swingLow`
   - bearish: `edge < swingHigh`
2. **Unfilled** — no bar from `j-3` down to `0` may have traded through the edge:
   - bullish filled if any `low[k] <= edge`
   - bearish filled if any `high[k] >= edge`
3. **Deepest wins** — among all valid unfilled gaps, pick:
   - bullish → the **lowest** edge (deepest retrace = best buy price)
   - bearish → the **highest** edge (best sell price)

Scanned from a start time (`lastChochTime` for CH_R, `lastContBosTime` for BS_R) forward to now.

> **Button:** `FVG` — 3-state, amber rectangles, auto-removed when filled.

### 2.10 Dealing Range % (DRange)

How big the current swing range is relative to yesterday's range. **This is the position-sizing sanity check** — a small dealing range % means the structure is tight relative to normal daily movement.

```
DRange % = (swingHigh − swingLow) / (prevDailyHigh − prevDailyLow) × 100
```

Plotted as two line segments projected **6 candles into the future** at swingHigh and swingLow, with the % labelled **below in an uptrend / above in a downtrend**.

> **Button:** `DRNG` — on by default. Also implemented in `ThrustStructure.pine`.

### 2.11 Swing Retracement (S.RT) — 67% level

```
BULLISH   retrace = highestHigh − (highestHigh − bosSwingLow) × 2/3
BEARISH   retrace = lowestLow   + (bosSwingHigh − lowestLow)  × 2/3
```

Measured from the swing that produced the last BOS/CHOCH. This is the entry level for the `±BOS` limit pattern.

> **Button:** `S.RT` — dashed line.

### 2.12 VS Trend — measured move target

```
BULLISH   if tFlow == 1 and close > swingHigh:  target = close + (close − swingLow)
BEARISH   if tFlow == 2 and close < swingLow:   target = close − (swingHigh − close)
```

Disappears when conditions no longer hold. Useful as a **TP reference**, not an entry.

> **Button:** `VS.TR` — red extending line.

### 2.13 Close-Trend (`ctrend`) — the M5 engine

A separate, candle-close-based trend tracker (ported from Pine `ctrend()`). Unlike the thrust engine it uses **only closes vs. opens** — no pivots.

**Pattern detection** (per closed bar):

```
BUY PATTERN    close > last_down_candle.open
                 → snapshot that down candle as last_dn_pattern_*
                 → flow = 1

SELL PATTERN   close < last_up_candle.open
                 → snapshot that up candle as last_up_pattern_*
                 → flow = 2
```

**Trend flip:**

```
cstrend 1 → 2   when close < last_dn_pattern_c   (buy-pattern's down-candle close)
cstrend 2 → 1   when close > last_up_pattern_c   (sell-pattern's up-candle close)
```

**Candlestate** (0–4) classifies the current candle:

| Value | In uptrend (`cstrend==1`) | In downtrend (`cstrend==2`) |
|---|---|---|
| 4 | close < last_dn_pattern_c (**trend breaking**) | close > last_up_pattern_c (**trend breaking**) |
| 1 | new buy pattern formed | new sell pattern formed |
| 2 | up candle (with trend) | down candle (with trend) |
| 3 | down candle (against trend) | up candle (against trend) |

**Protective levels** maintained per side: `last_dn_sl` (running low), `last_up_sl` (running high), plus `*_pattern_range` = the pattern candle's open-to-protective-extreme distance.

> **Button:** `C.TR▲m5` / `C.TR▼m5` in the alerts panel — Discord TTS on every flip, and the triggering M5 candle gets a translucent maroon zone (last 5 days backfilled, `CTREND_MARK_DAYS`).
>
> **Reusable:** `CTrendState` + `CTrendUpdate(tf, state, backfill)` — declare another state to track any timeframe.

---

## 3 · Daily & session structure

### 3.1 Previous daily range — the master unit

```
prevDailyRange = high[D1,1] − low[D1,1]
```

This single number scales the entire risk model (§4) and the DRange %.

### 3.2 D.MTX — daily matrix levels

Levels derived from the previous day's range, plotted on the current day:

| Level | Formula |
|---|---|
| −50 | `prevLow − range/2` |
| −25 | `prevLow − range/4` |
| 25 | `prevLow + range/4` |
| 33 | `prevLow + range/3` |
| 66 | `prevLow + 2·range/3` |
| 75 | `prevLow + 3·range/4` |
| 125 | `prevHigh + range/4` |
| 150 | `prevHigh + range/2` |

> **Buttons:** `D.MTX` (lines), `D.MTX☆` (live % position label), `W.MTX` (same on weekly).

### 3.3 D.STK — daily stalk zones

The two zones where you *stalk* for entries. **Which pair is active depends on the previous daily candle's direction.**

| Prev candle | Upper zone | Lower zone |
|---|---|---|
| **Bull** (close ≥ open) | `prevHigh` → `prevHigh + range·0.25` (**100 → 125**) | `prevLow + range·0.25` → `prevLow + range·0.33` (**25 → 33**) |
| **Bear** (close < open) | `prevLow + range·0.66` → `prevLow + range·0.75` (**66 → 75**) | `prevLow − range·0.25` → `prevLow` (**−25 → 0**) |

> **Button:** `D.STK` — 3-state (off / all 3mo / today only). Alert on first entry into each zone per day.

### 3.4 D.150 — extension levels

```
150% level = prevHigh + range × 0.50
−50% level = prevLow  − range × 0.50
```

First touch each day fires an alert. These are exhaustion references.

### 3.5 Session levels

| Tool | Definition |
|---|---|
| `D.OR` | Opening-range high/low (first hour of session) |
| `W.OR` | First hour of the week |
| `S.HL` | Full-session high/low |
| `D.BX` / `W.BX` | Filled box of each day's / week's H-L range |
| `S.GAP` | Gap between session close and next open |
| `D.LVL` | Prev-day OHLC + derived levels; tracks the **active up-candle low** (support) and **down-candle high** (resistance) — these are what `S.BRK` alerts on |

---

## 4 · Risk model

### 4.1 The four inputs

| Preset | Values | Variable |
|---|---|---|
| **Risk $** | `500`, `1000`, `1500`, custom (keyboard, ≤7 digits) | `g_riskValues[g_riskIndex]` |
| **SL Range %** | `0.25`, `0.33`, `0.50`, `1.00` | `g_slPctValues[g_slPctIndex]` |
| **R:R** | `1.0`, `2.0`, `3.0` | `g_rrValues[g_rrIndex]` |
| **Split** | `1`–`9` orders | `g_orderSplit` |

### 4.2 SL distance

```
slDistance = prevDailyRange × slPct
```

> This is the default SL for the D_MTX / R_FV-style patterns. **Structure-based patterns override it** with a swing level — see the catalog.

### 4.3 TP distance

```
tpDistance = slDistance × rrRatio
TP         = entry + direction × tpDistance
```

For structure-based entries, `slDistance` is recomputed as `|entry − SL|` first, so R:R stays honest.

### 4.4 Lot sizing

```
lossPerLot = (slDistance / tickSize) × tickValue
lots       = riskMoney / lossPerLot
lots       = floor(lots / lotStep) × lotStep      ← rounds DOWN
lots       = clamp(lots, lotMin, lotMax)
```

**Consequence worth internalising:** risk is fixed in dollars; lot size floats. A wider structural SL automatically gives you a smaller position. That is the mechanism doing your risk control — don't fight it by widening SL after sizing.

### 4.5 Order split

```
splitLots = floor((lots / splitCount) / lotStep) × lotStep
```

Each child order carries the full SL/TP. Total risk ≈ the preset (minus rounding).

### 4.6 Equity guards

| Guard | Trigger | Action |
|---|---|---|
| **EQ TP** | `equity ≥ baseline × (1 + pct/100)` | Close **all** positions, disarm both guards |
| **EQ SL** | `equity ≤ baseline × (1 − pct/100)` | Close **all** positions, disarm both guards |

`baseline` = account **balance** snapshot at arm time. Adjust in ±0.1% / ±1.0% steps.

---

## 5 · Entry pattern catalog

**How every entry works:** clicking a button *arms* it — three draggable lines (Entry / SL / TP) appear. **Nothing is sent to the broker until you press Enter.** Click the same button again to disarm.

**Auto-recalculate:** all armed orders re-run their recipe on (a) each new M15 bar and (b) a 3-second intra-bar throttle — so entries track live price and new structure. Dragging the SL line sets `slManualOverride` and **freezes all auto-updates permanently** for that setup.

**Hidden mode (`H`):** Limit and Stop rows each have an `H` toggle. When on, the order is not sent to the broker — the EA watches price and fires a **market** order when the entry level is touched. Lines render dotted.

### 5.1 Quick reference

| # | Pattern | Buttons | Type | Gate | Entry | SL |
|---|---|---|---|---|---|---|
| 1 | **D_MTX Market** | `±D_MTX` (mkt) | Market | none | Ask/Bid | SL Range |
| 2 | **Swing Market** | `±SWING` | Market | trend match | Ask/Bid | opposite swing |
| 3 | **UFV Reversion** | `±UFV` | Market | anti-trend + overshoot | Ask/Bid | full reversal leg |
| 4 | **D_MTX Limit** | `±D_MTX` (lmt) | Limit | none | price ∓ SL Range | SL Range |
| 5 | **D_STK Limit** | `±D_STK` | Limit | none | fixed daily % | fixed daily % |
| 6 | **BOS Retrace** | `±BOS` | Limit | trend match | 67% retrace *or* extreme candle | BOS swing |
| 7 | **CHOCH Retrace** | `±CH_R` | Limit | fresh CHOCH + wick FVG | deepest unfilled FVG | opposite swing |
| 8 | **BOS Retrace FVG** | `±BS_R` | Limit | continuation BOS + wick FVG | deepest unfilled FVG | opposite swing |
| 9 | **D_MTX Stop** | `±D_MTX` (stp) | Stop | none | price ± SL Range | SL Range |
| 10 | **CHOCH Stop** | `±CHOCH` | Stop | anti-trend | swing high/low | SL Range *or* opposite swing |
| 11 | **CHOCH Continuation** | `±CH_C` | Stop | trend + counter-flow + BOS armed | swing high/low | opposite swing |
| 12 | **BS_BO Breakout** | `±BS_BO` | Stop | trend match (with) | extreme since BOS | BOS opposite swing |
| 13 | **CH_BO Breakout** | `±CH_BO` | Stop | anti-trend (against) | extreme since BOS | BOS opposite swing |

### 5.2 By thesis — pick your bucket first

| Thesis | Patterns | Use when your plan says… |
|---|---|---|
| **A. With-trend continuation** | `SWING` mkt, `±BOS` lmt, `±BS_R` lmt, `±BS_BO` stop, `±CH_C` stop | "trend is established, I want to join pullbacks or breakouts" |
| **B. Post-reversal** | `±CH_R` lmt | "structure just flipped; I want the first retrace of the new trend" |
| **C. Reversal anticipation** | `±CHOCH` stop, `±CH_BO` stop | "I think this trend is done; put me in on the break that confirms it" |
| **D. Mean reversion** | `±UFV` mkt | "price is overextended outside the range; fade it" |
| **E. Level-based** | `±D_STK` lmt, `±D_MTX` (any) | "I'm trading yesterday's range, not intraday structure" |

---

### 5.3 Pattern detail

#### 1 · D_MTX Market — `±D_MTX` (market row)

| | |
|---|---|
| **Gate** | none — always available |
| **Entry** | Ask (buy) / Bid (sell) |
| **SL** | `entry ∓ (prevDailyRange × slPct)` |
| **TP** | `entry ± (slDistance × R:R)` |
| **Auto** | entry tracks Ask/Bid every 3 s |

Baseline "just get me in with correct size" entry. No structural opinion.

#### 2 · Swing Market — `±SWING`

| | |
|---|---|
| **Gate** | `+SWING` needs `tTrend == 1`; `−SWING` needs `tTrend == 2` |
| **Entry** | Ask / Bid |
| **SL** | swing low (buy) / swing high (sell) |
| **TP** | `entry ± (\|entry − SL\| × R:R)` |

Market entry with a **structural** stop. Position size shrinks automatically as the swing gets further away.

#### 3 · UFV Reversion — `±UFV`

| | |
|---|---|
| **Gate** | `−UFV`: `tTrend == 1` **and** `bid > swingHigh` · `+UFV`: `tTrend == 2` **and** `ask < swingLow` |
| **Entry** | Bid (sell) / Ask (buy) |
| **SL** | `−UFV`: `entry + range`, where `range = highestHigh(since swingLowTime) − swingLow`<br>`+UFV`: `entry − range`, where `range = swingHigh − lowestLow(since swingHighTime)` |
| **TP** | `entry ∓ (\|SL − entry\| × R:R)` |

Fades an *unfair* excursion outside the dealing range. **SL is intentionally very wide** — one full reversal leg — so lot size will be small. That's the design.

#### 4 · D_MTX Limit — `±D_MTX` (limit row)

| | |
|---|---|
| **Gate** | none |
| **Entry** | buy: `Ask − slDistance` · sell: `Bid + slDistance` (pull back one SL-range) |
| **SL** | `entry ∓ slDistance` |
| **TP** | `entry ± slDistance × R:R` |

#### 5 · D_STK Limit — `±D_STK`

**Ignores the SL Range and R:R presets** — all three prices come from yesterday's range.

| Prev candle | Direction | Entry | SL | TP |
|---|---|---|---|---|
| Bull | **+D_STK** buy | 33 (`prevLow + range/3`) | 0 (`prevLow`) | 100 (`prevHigh`) |
| Bull | **−D_STK** sell | 100 (`prevHigh`) | 150 (`prevHigh + range/2`) | 33 |
| Bear | **+D_STK** buy | 0 (`prevLow`) | −50 (`prevLow − range/2`) | 67 (`prevLow + 2·range/3`) |
| Bear | **−D_STK** sell | 67 | 100 (`prevHigh`) | 0 (`prevLow`) |

Pure daily-range mean reversion. Pairs with the `D.STK` zone alert.

#### 6 · BOS Retrace — `±BOS`

| | |
|---|---|
| **Gate** | trend match + a BOS exists |
| **Entry** | **mode 0:** 67% retrace of the BOS leg (S.RT level)<br>**mode ● :** high/low of the *extreme candle* since BOS |
| **SL** | BOS swing low (buy) / swing high (sell) |
| **TP** | the extreme since BOS (highest high / lowest low) — naturally ≈2:1 |
| **Toggle** | 3-state: 67% → extreme → off |

#### 7 · CHOCH Retrace — `±CH_R`

| | |
|---|---|
| **Gate** | `lastChochTime != 0` · no continuation BOS after it · direction matches `lastChochIsHigh` · **an unfilled wick FVG exists** |
| **Entry** | deepest unfilled wick-FVG edge since the CHOCH (§2.9) |
| **SL** | swing low (buy) / swing high (sell) |
| **TP** | `entry ± (\|entry − SL\| × R:R)` |

The first retrace after structure flips. **Greys out when no qualifying FVG exists** — that's a real signal, not a bug.

#### 8 · BOS Retrace FVG — `±BS_R`

| | |
|---|---|
| **Gate** | `lastContBosTime != 0` · no CHOCH after it · direction matches `lastContBosIsHigh` · **unfilled wick FVG exists** |
| **Entry** | deepest unfilled wick-FVG edge since that continuation BOS |
| **SL** | swing low / swing high |
| **TP** | R:R preset |

Same mechanic as CH_R but in an *established* leg rather than a fresh reversal. **CH_R and BS_R are mutually exclusive by construction** — whichever event is more recent decides which one is live.

#### 9 · D_MTX Stop — `±D_MTX` (stop row)

| | |
|---|---|
| **Entry** | buy: `Ask + slDistance` · sell: `Bid − slDistance` |
| **SL / TP** | SL Range / R:R presets |

#### 10 · CHOCH Stop — `±CHOCH`

| | |
|---|---|
| **Gate** | `+CHOCH` needs `tTrend == 2` · `−CHOCH` needs `tTrend == 1` (**anti-trend**) |
| **Entry** | swing high (buy) / swing low (sell) — the level whose break *is* the CHOCH |
| **SL** | **mode 0:** `entry ∓ slDistance` · **mode ● :** opposite swing |
| **TP** | R:R on `\|entry − SL\|` |
| **Auto** | ✅ re-tracks the latest swing every M15 bar (`A` badge) |

You're pre-positioned for the reversal: if the swing breaks, the trend has flipped and you're already in.

#### 11 · CHOCH Continuation — `±CH_C`

| | |
|---|---|
| **Gate** | `+CH_C`: `tTrend == 1` **and** `tFlow == 2` **and** `check4UpBos` **and** `ask < swingHigh`<br>`−CH_C`: `tTrend == 2` **and** `tFlow == 1` **and** `check4DnBos` **and** `bid > swingLow` |
| **Entry** | swing high (buy) / swing low (sell) |
| **SL** | swing low (buy) / swing high (sell) |
| **TP** | R:R |

After a CHOCH established the new trend, price counter-flowed. This buys the resumption. The `price still inside range` condition prevents arming after the move already went.

#### 12 · BS_BO Breakout — `±BS_BO` *(with trend)*

| | |
|---|---|
| **Gate** | `+BS_BO` needs `tTrend == 1` · `−BS_BO` needs `tTrend == 2` |
| **Entry** | highest high since BOS swing high (buy) / lowest low since BOS swing low (sell) |
| **SL** | BOS swing low (buy) / BOS swing high (sell) |
| **TP** | R:R |

Betting the BOS extreme breaks again = continuation.

#### 13 · CH_BO Breakout — `±CH_BO` *(against trend)*

| | |
|---|---|
| **Gate** | `+CH_BO` needs `tTrend == 2` · `−CH_BO` needs `tTrend == 1` |
| **Entry / SL / TP** | **identical mechanics to BS_BO** |

Same recipe, mirrored gate. Because the trend is opposite, the break at that entry level constitutes a **CHOCH** rather than a continuation BOS. Use when you want to be in on the reversal confirmation.

---

## 6 · Trade management tools

### 6.1 Matrices — 3 draggable lines, fires once, auto-disarms

Every matrix fires when **any one** of: `bid ≥ aboveLine`, `ask ≤ belowLine`, `time ≥ timeLine`.

| Matrix | Button | Action on trigger | Line colour |
|---|---|---|---|
| Exit | `EXIT.MTX` | close **all** positions on symbol | blue |
| Partials | `PRT.MTX` | close **50%** | teal |
| Breakeven | `BE.MTX` | move all SL → entry | gold |
| Cancel | `CNCL.MTX` | delete all pending orders | amber |

Lines are seeded at `mid ± slDistance`; time line at 23:59 (only on H4 and below).

### 6.2 Trailing

| Button | Level source | Behaviour |
|---|---|---|
| `TRL H1` | M15 thrust: swing low (long) / swing high (short) | **visual line only** |
| `TRL H4` | H4 thrust swings | **visual line only** |
| `H.TRL` | active trail line | closes all positions when price **touches** — broker SL untouched |
| `TRAIL` | active trail line | **physically moves SL**; only in the protective direction, never widens |

`TRL H1` and `TRL H4` are mutually exclusive; `H.TRL` / `TRAIL` require one of them active.

### 6.3 Manual tools

| Button | Action |
|---|---|
| `30% / 50% / 70%` | partial close of all positions on symbol |
| `CLOSE SYM` | close symbol positions (with randomised SL nudge if in profit) |
| `CLOSE ALL` | close everything, all symbols |
| `CANCEL` | delete all pendings + disarm hidden orders |
| `MOVE BE` | all SL → entry |
| `SET SL` / `SET TP` | draggable line, **Enter** applies to every position on symbol |
| `+LOT` | add at market using avg SL/TP of existing positions, sized by Risk preset |

### 6.4 Smart TP — pace tracker

Predicts the day's range and scores whether you're **ahead of schedule**.

```
t = (now − dayStart) / (dayEnd − dayStart)          time progress  0→1
p = (bid − redLevel) / (greenLevel − redLevel)      TP progress
score = p² / t
```

Levels (current day, from prev day's range): bull prev → green 125 / red 25 · bear prev → green 75 / red −25.

| Score | Meaning | Action |
|---|---|---|
| ≥ 2.5 | HEAVY TP | way ahead — take 50-70% off |
| ≥ 1.5 | MOD TP | comfortably ahead — ~30% |
| ≥ 1.0 | LIGHT TP | slightly ahead — 10-20% |
| < 1.0 | HOLD | on pace or behind |
| p < 0 | BEHIND | below the red line |
| t < 0.10 | WAIT | too early to score |

---

## 7 · Alerts

**Format (single source — `AlertMsg()`):**

```
<emoji> <TAG> | <SpokenSymbol> | <event>
```

No raw prices — keeps the Discord TTS short. `SpokenSymbol()` maps tickers to speakable names ("Bitcoin", "Nasdaq", "Euro").

| Tag | Button | Fires when | Dedup key |
|---|---|---|---|
| `S.BRK` | `S.BRK` | price breaks the active D.LVL support/resistance | per-level boolean |
| `CHCH` | `CHCH` | price breaks swing against trend | **swing pivot time** |
| `D.STK` | `DSTK` | first entry into a stalk zone that day | daily boolean |
| `D.150` | `150` | first touch of 150% / −50% that day | daily boolean |
| `H4.FLOW` | `H4FC` | H4 flow direction flips | previous flow |
| `C.TREND` | `C.TR▲m5` | M5 close-trend flips | `cstrend` value |
| `EQ TP` / `EQ SL` | — | equity guard hit | disarms on fire |
| `H.TRAIL` | — | hidden trail touched | one-shot |
| `TEST` | `TEST` | manual | — |

---

## 8 · Machine-readable state

For building the game-plan layer, these are the values to read:

```mq5
// ── M15 thrust ──
int      g_tt_tTrend;            // 1 bullish, 2 bearish
int      g_tt_tFlow;             // 1 up, 2 down
double   g_tt_swingHigh,  g_tt_swingLow;
datetime g_tt_swingHighTime, g_tt_swingLowTime;
bool     g_tt_check4UpBos, g_tt_check4DnBos;
double   g_tt_flowLevel, g_tt_vsLevel;   bool g_tt_vsValid;

// last-event records (decide CH_R vs BS_R)
datetime g_tt_lastChochTime;   bool g_tt_lastChochIsHigh;
datetime g_tt_lastContBosTime; bool g_tt_lastContBosIsHigh;
double   g_tt_lastBosSwH, g_tt_lastBosSwL;
datetime g_tt_lastBosSwHTime, g_tt_lastBosSwLTime;

// ── H4 thrust ──
int    g_h4_tTrend, g_h4_tFlow;
double g_h4_swingHigh, g_h4_swingLow;

// ── M5 close-trend ──
g_ctrM5.cstrend;      // 1 up, 2 down
g_ctrM5.flow;         // 1 buy pattern, 2 sell pattern
g_ctrM5.candlestate;  // 0-4
g_ctrM5.last_dn_pattern_c, g_ctrM5.last_up_pattern_c;   // the flip levels

// ── risk presets ──
g_riskValues[g_riskIndex];  g_slPctValues[g_slPctIndex];  g_rrValues[g_rrIndex];
g_orderSplit;

// ── helpers ──
double GetPrevDailyRange();
double CalcSLDistance();
double CalcLotSize(double slDistance);
bool   IsOrderBtnAvailable(string btn);   // ← the availability oracle
void   HandleXxxOrderButton(int dir);     // ← arms a pattern programmatically
```

`IsOrderBtnAvailable()` already encodes every gate in §5 — the game-plan engine can call it to list which patterns are legal *right now*.

---

## 9 · Game-plan scaffold (next build)

Sketch of what we're building on top of this — **not yet implemented**.

**Session inputs (user, before the session):**

| Field | Options |
|---|---|
| Directional bias | Long only / Short only / Both / Stand aside |
| Thesis buckets allowed | A continuation · B post-reversal · C reversal · D mean-reversion · E level-based (§5.2) |
| Max trades | integer |
| Max loss for session | $ or % |
| Risk per trade | one of the presets |
| Required confluence | e.g. "H4 trend must agree", "DRange % must exceed N" |
| Session window | time range where entries are permitted |

**What the EA then does:**

1. Continuously evaluates `IsOrderBtnAvailable()` for every pattern.
2. Filters that list by the plan's bias / buckets / window / confluence.
3. Shows only the legal patterns as a shortlist — everything else greyed.
4. Enforces the caps: blocks new entries past max trades or max session loss.
5. Logs each taken trade against the plan for review.

**Design principle:** the plan is set *before* the session and the EA enforces it during. The point is to move the risk decision out of the moment of temptation.

---

*Generated from `RiskManager.mq5`. When code changes, update this file — it is the spec the game-plan layer will be built against.*
