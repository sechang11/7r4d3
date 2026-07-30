# Multi-Instance Design

**Status:** design agreed, not yet implemented.

## The deployment shape

| Level | Cardinality | Identity |
|---|---|---|
| MT5 terminal instance | many | exactly **one trading account** each |
| Chart within a terminal | ~10 | one **symbol** each |
| EA | one per chart | one per (account, symbol) |

So an EA instance is uniquely identified by **`account:symbol`**. Because a
terminal maps to exactly one account, and a chart to one symbol, that pair is
sufficient — no chart IDs or machine names needed as the primary key.

## The problem this fixes

The bridge is currently single-tenant:

```js
let latestState = null;   // one slot - last writer wins
```

With ten EAs posting every ~3 s they overwrite each other continuously. The
dashboard flickers between symbols, and — worse — the game plan's trade and loss
caps read from whichever EA posted most recently, which makes them meaningless.

## Design

### 1 · State keyed by instance

EA adds to the state payload:

```
"account": { "login": 1234567, "server": "OANDA-Live", "currency": "USD" }
"chartId": 130... 
```

Server replaces the single slot with a map keyed `login:symbol`, each entry
carrying its own `lastSeenAt`. Staleness is per instance.

**Collision detection:** if a payload arrives for an existing key with a
*different* `chartId` while the existing entry is still fresh, flag it in the UI.
That means two charts of the same symbol on the same account are fighting — a
misconfiguration worth surfacing rather than silently corrupting.

### 2 · Plan scope — the sharp edge

**Account-level, not per-EA.** This is not a preference; the alternative is
broken:

- `AccountInfoDouble(ACCOUNT_EQUITY)` is **account-wide**. Ten EAs each
  enforcing "max $1,000 session loss" against the same equity figure does not
  give you a $1,000 cap — every instance trips at the same moment, or none does.
  The cap is only coherent as one account-level limit.
- `CountTradesToday(false)` already counts every symbol, so the trade cap is
  naturally account-wide too.

Therefore:

| Setting | Scope | Why |
|---|---|---|
| Max session loss | **account** | equity is account-wide |
| Max trades | **account** | with optional per-symbol sub-cap later |
| Baseline equity snapshot | **account** | taken once when the plan activates |
| Session window | account | one trading session |
| Bias (long/short/both/stand aside) | **per symbol** | long one instrument, short another |
| Allowed thesis buckets | **per symbol** | structure differs per instrument |
| Min dealing range | per symbol | it is a per-instrument measure |
| Require H4 agreement | per symbol | per-instrument structure |

Storage: `plans/<login>.json` holding account-level caps plus a
`symbols: { "EURUSD": { bias, buckets, ... } }` map, with a `default` block for
symbols not explicitly configured.

### 3 · EA-side enforcement

`FetchPlan()` requests `/api/plan?login=<n>&symbol=<s>` and receives the
account-level caps merged with that symbol's overrides — so `PlanBlockReason()`
and `PlanSessionLockReason()` need no structural change.

### 4 · Dashboard

- Account selector (when more than one account is posting)
- Grid of that account's symbols: trend, DRange %, permitted-pattern count,
  P&L, staleness — one row per EA
- Click a symbol to open the existing detail view
- Account-level caps edited once; per-symbol bias/buckets edited per row
- A single account-level lock banner, since a hit cap stops every symbol

### 5 · Config distribution (removes per-chart pasting)

With ten charts per terminal, pasting credentials into each is both tedious and
the reason secrets keep ending up in files.

- `/api/config` returns the Discord webhook from a **server env var**
- EA uses it whenever `InpDiscordWebhook` is blank
- Rotating the webhook becomes one env-var change instead of ten dialogs, and it
  then exists in zero charts, templates, source files or binaries

That leaves only `InpBridgeURL` + `InpBridgeToken` per chart, which can be baked
into a **private, uncommitted** chart template. See `tools/README.md` — the
committed `default.tpl` is deliberately sanitised; keep a separate local copy
with credentials for your own deployment.

## Build order

1. **Instance identity** (§1) — without it, ten EAs actively break the caps
2. **Per-account plans + per-symbol overrides** (§2, §3)
3. **Dashboard multi-instance view** (§4)
4. **`/api/config`** (§5)

## Contract version

This changes the state contract shape, so bump `RM_VERSION` and
`CONTRACT_VERSION` together — the dashboard's mismatch banner exists precisely to
catch a stale EA posting the old single-tenant shape.
