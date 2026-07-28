# Execution Footprint — Audit & Reduction List

**Goal:** the order flow this EA produces should look like a person trading with tools, because that is what it is — a human presses Enter for every discretionary entry. What gives it away is not *that* tools are used, but that the **execution mechanics are unnaturally uniform**: identical lot sizes, stops on exact ticks, TPs at exact multiples, and several paths that react at machine speed.

Most of the changes below double as better trading practice — not resting stops on the obvious tick, not always risking a round number.

> **Read this first.** Footprint shaping is a *detection* question, not a *compliance* one. If you're on a funded/prop account whose terms restrict automated tools, none of this changes whether you're within those terms — that's a decision to make on its own merits before touching any of it. On your own retail account with your own capital, most brokers permit EAs outright and this is mostly about not being misclassified as latency/arbitrage flow.

---

## 1 · What the broker can and cannot see

| Visible to the broker | Not visible |
|---|---|
| Order time (ms), price, volume, SL, TP | The web bridge — that traffic never touches them |
| Order **modifications** and their timestamps | Chart objects, lines, labels, panels |
| Comment field, magic number, slippage setting | Your game plan, buckets, caps |
| Fill latency — the gap between a level being touched and the order arriving | Discord alerts |
| Terminal build, login IP, session pattern | Which button you clicked |
| MT5 server-side journal often records the **EA filename** | The MQL source |

Everything actionable is therefore in **order flow**, not in the dashboard or the web app.

---

## 2 · Audit — current signatures

Ranked by how strongly each reads as automated.

| # | Signature | Where | Strength |
|---|---|---|---|
| 1 | **Split orders are N *identical* lots at the *identical* price in the same loop iteration** — same millisecond | `ExecuteTrade()` — `splitLots` computed once, reused | 🔴 Very strong. No human fires 3 identical tickets in the same tick. |
| 2 | **Lot size is fully deterministic** — `floor(risk / lossPerLot)` to lot step. Same risk + same SL distance ⇒ byte-identical volume, every time | `CalcLotSize()` | 🔴 Strong. Repeats across trades and across days. |
| 3 | **SL/TP sit on exact structural levels** — SL precisely at the swing low, to the tick | all `Handle*OrderButton()` | 🔴 Strong, and separately bad for you: that's where everyone's stops cluster. |
| 4 | **TP is an exact multiple of SL** — R:R of exactly 1.000 / 2.000 / 3.000 | `tpDist = slDist * rrRatio` | 🟠 Strong. Exact ratios essentially never occur by hand. |
| 5 | **Machine-speed reactions.** Hidden orders, 4 matrices, equity guards and hidden trail all fire on tick, sub-100 ms after a level is touched | `OnTick()` → `CheckHiddenOrder`, `CheckExitMatrix`, `CheckPartialsMatrix`, `CheckBeMtx`, `CheckCnclMtx`, `CheckEquityTPSL`, `CheckHiddenTrail` | 🟠 Strong. These are the paths with **no human in the loop**. |
| 6 | **Pending orders modified exactly on M15 boundaries** — a perfectly periodic `OrderModify` every 900 s | `UpdateChochOrder()` (`bars != g_chochLastBars`) | 🟠 Strong. Periodicity is trivially detectable. |
| 7 | **Auto-trail moves SL the instant the swing level changes** | `UpdateAutoTrail()` → `TrailSLToLevel()` | 🟡 Moderate |
| 8 | **Equity guards close everything at an exact percentage** of a balance snapshot | `CheckEquityTPSL()` | 🟡 Moderate |
| 9 | **Round risk amounts** — $500 / $1,000 / $1,500 produce suspiciously tidy risk-per-trade | `g_riskValues[]` | 🟢 Weak but free to fix |
| 10 | **EA filename may appear in the broker's server-side journal** | — | 🟢 Weak; rename if it matters |

### Already mitigated

| Signature | Status |
|---|---|
| Order comment (`"RM Market Buy"` etc.) | ✅ empty string |
| Magic number `123456` | ✅ `0` — matches manual one-click orders |
| Slippage `20` points | ✅ `5` — in normal manual range |
| Webhook URL in source/binary | ✅ removed |

### Existing precedent for randomisation

`CloseSymWithSLNudge()` already rolls a 75% chance and a random 20–80% fraction before nudging the SL. So this codebase already accepts randomised execution — the helpers and the pattern exist.

---

## 3 · Reduction list

Each item notes its **cost**, because several of these trade expectancy for uniformity and that should be a conscious choice.

### Tier 1 — high impact, low cost

**1.1 · Stagger and vary split orders**
Currently `splitLots` is computed once and sent N times in a tight loop.
- Vary each slice: e.g. 40% / 35% / 25% of total rather than 33/33/33, jittered per trade.
- Insert a randomised gap between slices (0.5–5 s).
- For limits/stops, offset each slice's price slightly instead of stacking on one tick.
*Cost:* negligible. Arguably better fills.

**1.2 · Jitter the lot size**
Apply ±1–3% random variation to `lots` *before* the lot-step floor, so repeated setups don't produce byte-identical volume.
*Cost:* risk per trade varies by ±1–3%. Immaterial.

**1.3 · Offset stops off the exact structural level**
Place SL a randomised 2–10 points beyond the swing rather than exactly on it.
*Cost:* marginally wider stop ⇒ marginally smaller position. **Also protects you from stop-hunt clusters**, so this is likely net positive.

**1.4 · Jitter R:R**
Compute TP at `rr × (1 ± 0.02–0.05)` instead of exactly 2.000.
*Cost:* tiny expectancy noise, symmetric.

**1.5 · Non-round risk presets**
`$500 / $1,000 / $1,500` → e.g. `$480 / $970 / $1,460`, or jitter ±2% per trade.
*Cost:* none.

### Tier 2 — the machine-speed paths

These are where there is genuinely no human, and they're the most honest tell.

**2.1 · Delay hidden-order fills**
`CheckHiddenOrder()` fires a market order the tick a level is touched. Add a randomised 0.5–4 s delay, plus a small random price tolerance so it doesn't trigger on the exact tick.
*Cost:* real slippage. This is the one with a genuine price.

**2.2 · Delay matrix triggers**
Exit / partials / BE / cancel matrices fire instantly. Add a randomised 1–8 s delay and a small tolerance band around each line.
*Cost:* small adverse move risk on exits. **Consider exempting the exit matrix** — delaying a protective exit to look human is a bad trade.

**2.3 · Break the M15 periodicity of `UpdateChochOrder()`**
Instead of modifying the pending order the instant a new bar opens, wait a randomised 10–200 s into the bar.
*Cost:* none.

**2.4 · Jitter auto-trail**
Only move the SL once it has cleared the new level by a random margin, and add a random delay.
*Cost:* slightly looser trail.

**2.5 · Add tolerance to equity guards**
Trigger between e.g. 95–100% of the configured percentage rather than exactly at it.
*Cost:* the cap becomes approximate — **arguably the wrong trade** for a risk-control feature. Probably skip.

### Tier 3 — cosmetic

**3.1 · Rename the compiled EA** — the MT5 server journal often logs the expert name.
**3.2 · Human-plausible session windows** — the game plan already has `windowStart` / `windowEnd`. Trading only during plausible hours is free and already built.
**3.3 · Vary the count** — not every session needs the same number of trades. The plan's `maxTrades` is a ceiling, not a target.

---

## 4 · Not worth doing

| Idea | Why not |
|---|---|
| Jitter the bridge POST / command-poll cadence | Broker cannot see this traffic at all |
| Randomise chart object updates | Chart objects are local only |
| Randomise alert timing | Discord traffic never reaches the broker |
| Obfuscate the MQL source | Nobody at the broker reads your source |
| Route through a "residential" IP | Adds risk and complexity; order flow is the signal, not the IP |

---

## 5 · Honest limits

**The strongest anti-bot property is already true and free:** every discretionary entry requires a human keypress. The `arm → drag → Enter` flow produces naturally irregular timing that no amount of randomisation could synthesise. The auto-firing paths in §2 item 5 are the only ones without that, which is exactly why they're the priority.

**Randomisation does not make automation undetectable.** It removes *uniformity*, which is the cheapest signal to detect. Sustained sub-second reactions, perfect discipline, and 24/5 presence remain visible regardless. Nothing here changes that, and treating jitter as a cloak would be a mistake.

**Some of these cost money.** Tier 2.1 and 2.2 buy uniformity with slippage. Tier 2.5 buys it with a weaker risk cap, which contradicts the point of the whole project. Choose deliberately rather than applying everything.

**The remote-command path is a separate signature.** If `InpAllowRemote` is on, entries can originate from a browser click with ~1 s of round-trip. That pattern — regular polling plus fast reaction — is more machine-like than anything in the list above. It's off by default; leaving it off is the simplest mitigation.

---

## 6 · Suggested order of work

1. **1.1 Split staggering** — biggest single tell, no downside
2. **1.2 Lot jitter** and **1.5 non-round risk** — trivial, immediate
3. **1.3 Stop offset** — helps footprint *and* fill quality
4. **2.3 CHOCH periodicity** — free
5. **1.4 R:R jitter** — free
6. **2.1 / 2.4** — only if you accept the slippage
7. Skip **2.5**; consider exempting the exit matrix from **2.2**

*Nothing in this list has been implemented yet — this is the audit.*
