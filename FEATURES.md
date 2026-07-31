# RiskManager.mq5 — Feature Documentation

**File:** `RiskManager.mq5` (v6.00)
**Platform:** MetaTrader 5 Expert Advisor (MQL5)
**Primary timeframe:** M15 (signal chart)

A risk-management trading dashboard with pre-visualised entry/SL/TP lines, market-structure analysis (M15 + H4 thrust systems), matrix-based exit/partial/cancel triggers, trailing stops, Discord webhook alerts, and a heavy chart-tools panel.

> **Secrets:** `InpDiscordWebhook` defaults to blank on purpose — set it in the EA properties dialog after attaching. It is never committed. Keep your own copy in `LOCAL_SECRETS.txt` (gitignored). Blank = Discord alerts silently disabled.

---

## Table of Contents

1. [Input parameters](#input-parameters)
2. [Order entry & risk sizing](#order-entry--risk-sizing)
3. [Order types](#order-types)
4. [Hidden orders](#hidden-orders)
5. [Auto-follow & CHOCH auto-update](#auto-follow--choch-auto-update)
6. [SL / TP management](#sl--tp-management)
7. [Smart TP](#smart-tp)
8. [Partials & full-close buttons](#partials--full-close-buttons)
9. [Matrix automation (Exit / Partials / BE / Cancel)](#matrix-automation)
10. [Trailing stops](#trailing-stops)
11. [Equity TP / SL](#equity-tp--sl)
12. [Chart tools panel](#chart-tools-panel)
13. [H1 Thrust system](#h1-thrust-system-m15-bars)
14. [H4 Thrust system](#h4-thrust-system-h1-bars-4-bar-window)
15. [Discord alert system](#discord-alert-system)
16. [Dashboard & interaction](#dashboard--interaction)
17. [Event handlers](#event-handlers)
18. [Internal subsystems](#internal-subsystems)

---

## Input parameters

Only **one** user-configurable input is exposed when attaching the EA:

| Input | Type | Default | Purpose |
|---|---|---|---|
| `InpDiscordWebhook` | string | `""` (set per-chart) | Webhook for `SendDiscordAlert()`. If blank, alerts silently no-op. |
| `InpBridgeURL` | string | `""` (blank = off) | Web-app bridge base URL, e.g. `http://127.0.0.1:8787`. See [webapp/README.md](webapp/README.md). |
| `InpStatePostSec` | int | `3` | Seconds between state POSTs to the bridge. |

Everything else (risk presets, SL %, RR ratios, lookback windows, panel layout, colour palette) is set via `#define` constants or in-code arrays — change them in source if you need different defaults.

---

## Order entry & risk sizing

### Risk presets (`RM_Risk_0..3`)
- Buttons select a fixed dollar risk from `g_riskValues = {500, 1000, 1500, 0}`.
- `RM_Risk_3` is the **CUSTOM** slot — clicking it enters keyboard-input mode (`g_customRiskEditing`), accepting digits 0-9 (up to 7), Backspace, Enter to confirm, Escape to cancel. The button face shows `$<typed>_` while editing.
- Selecting a preset live-updates lot size on any active order lines via `RecalcFromLines()`.

### SL % range presets (`RM_SlPct_0..3`)
- Distance of SL line from entry as % of price: `g_slPctValues = {0.25, 0.33, 0.50, 1.00}`.
- Manually dragging the SL line sets `g_slManualOverride = true`, freezing the preset out until lines are reset.

### Risk/Reward ratios (`RM_RR_0..2`)
- TP distance = RR × SL distance: `g_rrValues = {1.0, 2.0, 3.0}`.

### Order split (`RM_BtnSplit`)
- Click to enter split-edit mode; press 1–9 to split risk into N equal orders. Each child order is tagged with comment `1/N`, `2/N`, … in the broker comment field.
- Button face shows `SPLIT`, `x2`, `x3`, etc. While editing it shows `SPLIT ?_`.

---

## Order types

All order buttons (except the close/cancel ones) draw three draggable horizontal lines (entry/SL/TP) on the chart. Press **Enter** to execute; click any other order button or delete a line to abandon.

### Plain market orders
| Button | Direction | Notes |
|---|---|---|
| `RM_BuyMkt` | Long market | Entry pinned to ask; armed for auto-follow if held |
| `RM_SellMkt` | Short market | Entry pinned to bid |

### Plain limit / stop orders
| Button | Direction | Notes |
|---|---|---|
| `RM_BuyLmt` / `RM_SellLmt` | Limit | Respect `g_isHiddenLmt` toggle |
| `RM_BuyStp` / `RM_SellStp` | Stop  | Respect `g_isHiddenStp` toggle |

### Trend-gated specialty orders
These are coloured grey (`CLR_BTN_PLC`) when the H1 Thrust trend (`g_tt_tTrend`: 1=bullish, 2=bearish) doesn't match — clicking does nothing.

| Button | Description |
|---|---|
| `RM_BuyMktSw` / `RM_SellMktSw` | **Swing market** — only fires with trend |
| `RM_BuyStpCH` / `RM_SellStpCH` | **CHOCH stop** — placed *against* current trend, anticipating reversal. Three-state toggle: off → SL-range entry → swing-SL entry (auto-tracks latest swing on each M15 bar via `UpdateChochOrder()`) |
| `RM_BuyLmtBOS` / `RM_SellLmtBOS` | **BOS limit** — pullback into a confirmed BOS leg. `g_bosLmtMode` toggles 67% retrace ↔ extreme-candle retrace |
| `RM_BuyStpBK` / `RM_SellStpBK` | **Breakout stop** — entry at swing high (long) / swing low (short) in trend direction |
| `RM_BuyLmtDK` / `RM_SellLmtDK` | **Daily stalk limit** — entry inside the previous-day stalk zone. Bull-prev-close picks 100-125% / 25-33%; bear-prev-close picks 75-66% / 0 to -25% |
| `RM_BuyLmtFV` / `RM_SellLmtFV` | **R_FV limit** — entry at current swing high (sell) / swing low (buy) computed by the thrust system |

`g_orderType` codes the broker-side intent: `0`=market, `1`=limit, `2`=stop. `g_orderDir` is `+1` long / `-1` short.

---

## Hidden orders

Hidden orders are armed locally but never sent to the broker until price actually touches the entry. While armed, the order lines render dotted instead of solid.

| Button | Toggle | Effect |
|---|---|---|
| `RM_HiddenLmt` | `g_isHiddenLmt` | Subsequent `RM_*Lmt` buttons place hidden limits |
| `RM_HiddenStp` | `g_isHiddenStp` | Subsequent `RM_*Stp` buttons place hidden stops |

Active state colour: `CLR_BTN_HIDDEN_ON` (red). `g_hiddenOrderArmed` becomes true after Enter; `CheckHiddenOrder()` (called every tick) submits the real order when bid/ask reaches the entry line, then deletes the lines.

---

## Auto-follow & CHOCH auto-update

### Auto-follow (`g_autoOrderActive`, `g_autoOrderBtn`)
When a market order's lines are kept on chart instead of being executed, the entry line continuously snaps to current price each tick. The originating button's text gains an ` auto` suffix to indicate the mode is active. Pressing Enter executes; clicking any other order button or deleting a line cancels.

### CHOCH auto-update (`g_chochOrderActive`)
When a CHOCH stop button is set to swing-SL mode, `UpdateChochOrder()` (run from `OnTimer()` whenever the M15 bar count advances) re-computes the latest swing high/low and slides the entry line to it.

---

## SL / TP management

### Order-line objects
Three named horizontal lines created by every order button:

| Variable | Object name | Colour |
|---|---|---|
| `g_entryLineName` | `RM_Entry` | `CLR_ENTRY_LINE` (gold/beige) |
| `g_slLineName`    | `RM_SL`    | `CLR_SL_LINE` (red) |
| `g_tpLineName`    | `RM_TP`    | `CLR_TP_LINE` (green) |

All three are pre-selected (`OBJPROP_SELECTED=true`) so the user can drag them immediately. Dragging any line triggers `RecalcFromLines()` to update lot size and RR; dragging SL specifically sets `g_slManualOverride`. `g_linesActive` tracks whether order-prep lines exist.

### Set SL / Set TP — adjust live positions
| Button | State | Behaviour |
|---|---|---|
| `RM_SetSL` | `g_setSLActive` | Spawns one draggable red dashed line (`RM_SetSL_Line`); pressing Enter applies the dragged price as SL to **every** open position on the symbol |
| `RM_SetTP` | `g_setTPActive` | Same, green dashed line (`RM_SetTP_Line`), applies as TP |

The two are mutually exclusive — turning one on cancels the other.

### Move-to-breakeven button
`RM_MoveBE` immediately sets every open position's SL to its open price (no line, no drag).

---

## Smart TP

Toggle: `RM_SmartTP` cycling `g_smartTPMode` 0 → 1 (today) → 2 (all days, ~93 daily bars) → 0. Button face: `SMART TP` / `SM.TP ●` / `SM.TP ★`.

For each tracked day, four objects are created:

| Object | Colour | Role |
|---|---|---|
| `RM_SmTP_Level_<idx>` | green (`CLR_SMTP_GREEN`) | TP target — draggable |
| `RM_SmTP_Entry_<idx>` | beige (`CLR_SMTP_BEIGE`) | anchor (entry) — draggable |
| `RM_SmTP_Trend_<idx>` | dashed beige | diagonal reference (read-only) |
| `RM_SmTP_SL_<idx>`    | red    | SL at level − 10% margin — draggable |

There's also a per-day **score label** (`RM_SmTP_Score`) showing `Pace × Progress × 100`:
- *Pace* = fraction of completed candles where close > beige
- *Progress* = (close − beige) / (green − beige)

### Smart TP keyboard shortcuts (when active)
| Keys | Effect (Δ = 1% of prev day's range) |
|---|---|
| Ctrl + ↑ / ↓ | Move green ±Δ |
| Shift + ↑ / ↓ | Move beige ±Δ |
| Ctrl + Shift + ↑ / ↓ | Move red SL ±Δ |
| Ctrl + Shift + / | Swap green and beige |

---

## Partials & full-close buttons

| Button | Action |
|---|---|
| `RM_Partial30` / `RM_Partial50` / `RM_Partial70` | Close 30/50/70% of total open lots on the symbol (pro-rata across positions) |
| `RM_CloseSym` | Close all positions on this symbol, nudging SL by 1 pip first to ensure fill |
| `RM_CloseAll` | Immediate market close of every position on the symbol |
| `RM_CancelAll` | Delete every pending order on the symbol |
| `RM_AddLot` | Add to existing position with current risk/SL settings |

All are immediate — no confirmation dialog.

---

## Matrix automation

Each "matrix" is three draggable lines (above-price, below-price, vertical-time on H1 and below) that fire **once** when any single condition is hit, then disable themselves.

| Button | State | Lines | Action on trigger |
|---|---|---|---|
| `RM_ExitMatrix`     | `g_exitMatrixActive`    | `RM_ExitAbove` / `RM_ExitBelow` / `RM_ExitTime`   | Close **all** positions |
| `RM_PartialsMatrix` | `g_partialMatrixActive` | `RM_PartAbove` / `RM_PartBelow` / `RM_PartTime`   | Close **50%** |
| `RM_BeMtx`          | `g_beMtxActive`         | `RM_BeAbove` / `RM_BeBelow` / `RM_BeTime`         | Move all SL → entry (BE) |
| `RM_CnclMtx`        | `g_cnclMtxActive`       | `RM_CnclAbove` / `RM_CnclBelow` / `RM_CnclTime`   | Cancel all pending orders |

Polling lives in `CheckExitMatrix()`, `CheckPartialsMatrix()`, `CheckBeMtx()`, `CheckCnclMtx()` — all called from `OnTick()`. Line colours: exit = blue (`CLR_EXIT_LINE`), partials = teal (`CLR_PART_LINE`), BE = entry-gold, cancel = amber (`CLR_CNCL_LINE`).

---

## Trailing stops

Four independent modes, each on its own button:

| Button | State | Variable | Behaviour |
|---|---|---|---|
| `RM_BtnTrailH1`    | `g_trailH1Active`     | `g_trailH1Level` | Visual line at H1 swing high/low — does **not** modify SL |
| `RM_BtnTrailH4`    | `g_trailH4Active`     | `g_trailH4Level` | Visual line at H4 swing high/low |
| `RM_BtnHTrail`     | `g_hiddenTrailActive` | `g_hiddenTrailLevel` | Dotted red line; `CheckHiddenTrail()` (OnTick) market-closes the position when price touches it. Broker-side SL is untouched |
| `RM_BtnAutoTrail`  | `g_autoTrailActive`   | (uses H1 level)  | Physically `PositionModify()`'s every position's SL to the trail level |

Updates run in `UpdateTrailH1()`, `UpdateTrailH4()`, `UpdateAutoTrail()`, `UpdateHiddenTrail()` from `OnTimer()`.

---

## Equity TP / SL

Closes all positions when account equity hits a configurable % above (TP) or below (SL) the **balance snapshot** taken when the label was armed.

| Button | Function |
|---|---|
| `RM_EqTPLbl` / `RM_EqSLLbl` | Click to arm/disarm. Snapshot stored in `g_eqBaseline` |
| `RM_EqTPP01` / `RM_EqTPM01` | TP target ±0.1% |
| `RM_EqTPP10` / `RM_EqTPM10` | TP target ±1.0% |
| `RM_EqSLP01` / `RM_EqSLM01` | SL distance ±0.1% |
| `RM_EqSLP10` / `RM_EqSLM10` | SL distance ±1.0% |

Trigger: `CheckEquityTPSL()` from `OnTick()`. Sends Discord alerts (`✅ EQ TP` / `🛑 EQ SL`) on hit. Both can be armed simultaneously — first to fire disarms both.

---

## Chart tools panel

Right-side analytical overlays. All update from `OnTimer()`.

| Button | State | What it draws |
|---|---|---|
| `RM_BtnOR`    | `g_orActive`        | Opening-range high/low (first hour of the session) |
| `RM_BtnSHL`   | `g_sessHLActive`    | Full-session high/low extending right |
| `RM_BtnDBX`   | `g_dailyBoxActive`  | Filled box per daily H/L range |
| `RM_BtnWBX`   | `g_weeklyBoxActive` | Filled box per weekly H/L range |
| `RM_BtnWOR`   | `g_weeklyORActive`  | First-hour-of-week range; tracked in `g_worHigh/g_worLow/g_worStartTime/g_worWeekOpen/g_worRectIdx/g_worHasRange` |
| `RM_BtnDMX`   | `g_dailyMtxActive`  | Previous day's H/L overlaid on today |
| `RM_BtnWMX`   | `g_weeklyMtxActive` | Previous week's H/L overlaid on this week |
| `RM_BtnD150`  | `g_daily150Active`  | 150% / -50% extensions of yesterday's range |
| `RM_BtnSGAP`  | `g_sessGapActive` (default ON)  | Session-gap rectangles |
| `RM_BtnSBRK`  | `g_sessBrkActive`   | Session-breaker watch (alert source for S.BRK) |
| `RM_BtnDLVL`  | `g_dailyLvlActive`  | Prev-day OHLC + derived levels |
| `RM_BtnDSTK`  | `g_dStkMode` (0/1/2) | **Daily stalk zones**: bull prev → 100-125% & 25-33%; bear prev → 75-66% & 0 to -25%. Lookback 3d (today) / 93d (all). Button face `D.STK` / `D.STK★` / `D.STK●` |
| `RM_BtnMLVL`  | `g_dmxLabelActive`  | Right-anchored % label for current price location inside the D.STK matrix; large 28pt font (42pt + `!` if inside a stalk zone), colour shifts (lime/red/green/brown) |
| `RM_BtnSMX`   | `g_smxActive` (default ON) | M15 swing-matrix label (current swing H/L → next target) |
| `RM_BtnH4MX`  | `g_h4MtxActive` (default ON) | H4 swing-matrix label |

---

## H1 Thrust system (M15 bars)

A full market-structure engine running on `TT_LOOKBACK = 6240` M15 bars (~13 weeks × 5d × 96 bars). State drives a lot of the trend-gated order buttons via `g_tt_tTrend` and `g_tt_tFlow`.

Core swing/pivot state: `g_tt_swingHigh/Low`, `g_tt_swingHighTime/LowTime`, `g_tt_highPH/lowPH` (pivots), `g_tt_highTH/lowTH` (pivot times), `g_tt_check4UpBos/DnBos`, `g_tt_lastBars`, `g_tt_flowLevel`, `g_tt_vsLevel/vsValid`, `g_tt_lastBosSwH/L/Time/SwHTime/SwLTime`. Arrays: `g_tt_thrLines[]`, `g_tt_pivMarks[]`, `g_tt_swDots[]`, `g_tt_bosLabels[]`.

| Button | State | Meaning |
|---|---|---|
| `RM_BtnPIVT` | `g_tt_pivotActive` | Plot dots at every detected pivot high/low |
| `RM_BtnTHRS` | `g_tt_thrustActive` | Diagonal **thrust lines** — green=BOS confirmed, maroon=CHOCH, olive=pending |
| `RM_BtnBOS`  | `g_tt_bosActive`    | Highlight Break-of-Structure events |
| `RM_BtnCHCH` | `g_tt_chochActive`  | Highlight Change-of-Character (reversal) events |
| `RM_BtnFLOW` | `g_tt_flowActive`   | Extending line at current flow level (most recent swing extreme) |
| `RM_BtnSWNG` | `g_tt_swingMode` (0/1/2) | 0=off, 1=connecting lines, 2=dots coloured by last thrust |
| `RM_BtnVSTR` | `g_tt_vsActive`     | **VS measured-move target**: bull = close + (close − swingLow); bear = close − (swingHigh − close) |
| `RM_BtnFVAL` | `g_tt_fvMode` (0/1/2) | Fair-value channel between current swing H/L; subtle/solid forest-green fill |
| `RM_BtnFVGP` | `g_tt_fvgMode` (0/1/2) | Fair-value **gaps** (amber rectangles); auto-removed when filled |
| `RM_BtnBOSC` | `g_tt_bosCountActive` | Sequential BOS counter labels; resets on CHOCH |
| `RM_BtnSRET` | `g_tt_sretActive`     | 67% retracement of last BOS leg (dashed line) |

Plotting routines: `UpdateThrust()` (from `OnTimer()`) → `PlotTTThrust()`, `PlotTTFlow()`, `PlotTTSwing()`, `PlotTTVs()`, `PlotTTFairValue()`, `PlotTTFairValueGap()`, `PlotTTBosCount()`, `PlotTTSRet()`.

---

## H4 Thrust system (H1 bars, 4-bar window)

Same algorithm running on H1 bars with a 4-bar lookback (`H4_LOOKBACK = 1560` H1 bars ≈ 3 months) — captures H4-equivalent swings without needing to switch chart timeframe.

| Button | State | Meaning |
|---|---|---|
| `RM_BtnH4TH` | `g_h4_active` (default ON) | Master H4 thrust display |
| `RM_BtnH4FC` | `g_h4_flowActive` (default ON) | H4 flow line with arrow indicator (`H4.F▲` / `H4.F▼`) |

H4-specific state: `g_h4_tFlow`, `g_h4_tTrend`, `g_h4_swingHigh/Low + Time`, `g_h4_highPH/lowPH + TH`, `g_h4_check4UpBos/DnBos`, `g_h4_thrCount`, `g_h4_prevFlow`, `g_h4_flowLevel`, `g_h4_lastBosSwH/L`, `g_h4_thrLines[]`. Driver: `UpdateH4Thrust()` from `OnTimer()`.

---

## Discord alert system

`SendDiscordAlert(message)` ([RiskManager.mq5:1831](RiskManager.mq5:1831)) posts a JSON payload (`username:"RiskManager", tts:true, content:<msg>`) via `WebRequest()` to `InpDiscordWebhook`. **TTS is enabled on every alert** — Discord will read it aloud.

| Button | State | Trigger |
|---|---|---|
| `RM_BtnAltSBRK` | `g_alertSBRK` | New candle breaks above the up-close support / below the down-close resistance tracked in `g_alert_activeUpLow` / `g_alert_activeDownHigh` (`g_alert_upLowAlerted` / `g_alert_dnHighAlerted` deduplicate per-level) |
| `RM_BtnAltCHCH` | `g_alertCHCH` | Price breaches the swing level stored in `g_alert_chchLevel` (deduplicated by `g_alert_chchAlerted`) |
| `RM_BtnAltDSTK` | `g_alertDSTK` | First candle to enter today's upper or lower D.STK zone (`g_alert_dstkUpperAlerted` / `g_alert_dstkLowerAlerted`, reset by day-of-year `g_alert_dstkDay`) |
| `RM_BtnAltD150` | `g_alertD150` | First touch of yesterday's 150% / -50% extension (same daily-reset pattern via `g_alert_d150Day`) |
| `RM_BtnAltH4FC` | `g_alertH4FC` (default ON) | Every H4 flow direction flip (deduplicated by `g_alert_h4fcLastFlow`) |
| `RM_BtnAltTEST` | — | Sends a randomised humorous test phrase, useful for verifying webhook + TTS |

Equity TP/SL hits also call `SendDiscordAlert` directly (✅ / 🛑 messages).

Detection routines: `CheckSBRKAlert()`, `CheckCHCHAlert()`, `CheckDSTKAlert()`, `CheckD150Alert()` from `OnTick()`; H4 flow change detected in `UpdateAlertLevels()` from `OnTimer()`.

---

## Dashboard & interaction

### Hide / show
- `RM_BtnHide` toggles `g_dashboardHidden` — every panel object is hidden but the hide button itself stays visible so the dashboard can be restored.
- Pressing **X** on the chart toggles the same flag.

### Hover
- `OnChartEvent(CHARTEVENT_MOUSE_MOVE)` calls a hover handler that swaps each button between its `GetBtnNormalColor()` and `GetBtnHoverColor()`.
- Buttons register their bounds in `g_btnNames[]` / `g_btnX[]` / `g_btnY[]` / `g_btnW[]` / `g_btnH[]` (max `MAX_BTNS = 100`) when created via `RegisterBtn()`.

### Layout constants
Origin `(PANEL_X=30, PANEL_Y=30)`. Buttons `BTN_W=180, BTN_H=46`. Gaps `BTN_GAP=8, ROW_GAP=6, SECTION_GAP=12`. Dark-blue palette — `CLR_PANEL_BG=C'14,14,22'`, sections `C'24,26,38'`, ON `C'25,118,210'`, BUY `C'0,150,80'`, SELL `C'195,35,35'`, etc.

Those numbers are **design pixels**, not final ones. Each layout constant expands to `UI(n)`, which multiplies by `g_uiScale = chartHeight / UI_REF_H` (`UI_REF_H = 1300`, a maximised terminal on a 2560×1440 desktop), clamped to `0.55 … 1.60`. The panel therefore holds a constant ~62% of chart height instead of overflowing a smaller screen.

- `InpUIScale` (default `0` = auto) pins a fixed scale when you want one.
- `UpdateUiScale()` runs in `OnInit()` before `BuildDashboard()`, and again on `CHARTEVENT_CHART_CHANGE` — which rebuilds only if the scale actually moved, since that event also fires on every scroll and zoom.
- `LINE_WIDTH` is deliberately **not** scaled: entry/SL/TP thickness is a chart-drawing concern.

### Keyboard input modes
| Mode | Trigger | Keys |
|---|---|---|
| Custom risk     | Click `RM_Risk_3` | 0-9, Backspace, Enter, Escape |
| Order split     | Click `RM_BtnSplit` | 1-9, Escape |
| Trade execution | Order lines exist | Enter |
| Set SL/TP apply | `RM_SetSL` or `RM_SetTP` armed | Enter |
| Dashboard       | anywhere | X |
| Smart TP nudges | `g_smartTPMode > 0` | Ctrl/Shift + ↑/↓, Ctrl+Shift+/ |

---

## Event handlers

| Handler | Approx. line | Role |
|---|---|---|
| `OnInit()`     | ~7917 | Build dashboard, init state, prime thrust computations |
| `OnDeinit()`   | ~8117 | Wipe EA-created chart objects, persist matrix state via `SaveMatrixGV` |
| `OnTick()`     | ~8763 | Hidden orders, all matrix triggers, equity TP/SL, S.BRK / CHCH / D.STK / D150 alerts, label tickers, auto-follow, hidden trail |
| `OnTimer()`    | ~8783 | Most heavy work: live info, sessions, daily/weekly boxes, matrices, levels, stalk, labels, M15 + H4 thrust, trailing stops, alert-level tracking, CHOCH order auto-update, Smart TP scoring |
| `OnChartEvent()` | ~8162 | Mouse hover, key handling, button clicks (huge dispatch), order-line drag → `RecalcFromLines()` |

---

## Internal subsystems

### Hidden-order execution flow
1. User toggles `RM_HiddenLmt` or `RM_HiddenStp` on.
2. Clicks an order button — three lines appear, dotted.
3. Adjusts lines, presses Enter — `ExecuteTrade()` sees the hidden flag, sets `g_hiddenOrderArmed = true`, leaves the lines on chart.
4. `CheckHiddenOrder()` (every tick) compares bid/ask to entry and submits the broker order when touched.
5. Lines are deleted once the real order is live.

### Smart TP scoring
For each tracked day:
- *Pace* = closed candles where `close > beige` ÷ total closed candles
- *Progress* = `(close − beige) / (green − beige)`
- Score = `Pace × Progress × 100`, displayed in the per-day score label and refreshed in `CheckSmartTPScore()` from `OnTimer()`.

### Thrust algorithm (M15 + H4)
1. Walk back the lookback window, locate pivot highs/lows.
2. A *thrust* = close beyond the active swing level in the direction of `g_tt_tFlow`.
3. Two consecutive same-direction thrusts → **BOS** (continuation, green).
4. A thrust against current flow → **CHOCH** (reversal, maroon); flips trend, resets BOS counter.
5. Pending swings without confirmation render olive.

### Matrix triggers
Every matrix uses the same 3-condition OR pattern: `bid ≥ above`, `ask ≤ below`, or `time ≥ time-line`. First condition to fire triggers the action and disables the matrix.

### Lot sizing
`lots = risk_dollars / (point_distance × point_value)`, clamped to symbol min/max and snapped to volume step. Used by every order button before submitting.

---

## Flagged items

- **Hardcoded webhook URL** at [RiskManager.mq5:14](RiskManager.mq5:14) — see security note at top.
- **Placeholder buttons** with names matching `RM_Plc*`, `RM_RP_*`, `RM_TP_*`, `RM_AP_*` are reserved/non-functional UI slots.
- The `_snippet.txt` file in the project directory is unrelated to this EA.
- `DailyStalk.pine` and `ThrustStructure.pine` appear to be the Pine Script (TradingView) sources that the D.STK and Thrust systems were ported from.

### Bridge cadence

`WebRequest` is synchronous. Posting used to run from `OnTick` at a flat 3 s,
which spent roughly **14% of every tick** on network I/O — on the same handler
as the exit / partials / BE / cancel matrices, the equity guards and the hidden
trail. Those calls now run from `OnTimer`, so a slow response delays a label
rather than a stop.

The interval follows what the chart is doing (`BridgeMode()`):

| Mode | When | Posts |
|---|---|---|
| `ACTIVE` | position open, order armed, or any matrix live | every `InpStatePostSec` (5 s) |
| `STALK` | you pressed **STALK** | on each **M1** close |
| `IDLE` | flat and unattended — the default | on each **M5** close |

Aligning the slow modes to candle closes rather than a rolling timer means a
snapshot always describes a completed bar. A mode change posts immediately, so
opening a position never waits five minutes to appear.

The EA reports `mode` and `postSec` in the payload, and the server sizes its
staleness window as `max(15 s, postSec × 2.5)`. Without that, an idle chart on
M5 pacing would read as permanently offline — and an active chart is still held
to the 15 s floor, because one missing its beat really is a fault.
