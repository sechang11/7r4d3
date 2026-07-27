# RiskManager Web Bridge

Companion web app for the RiskManager EA.

```
MT5/MT4 EA ──POST /api/state (every 3s)──►  bridge  ──►  browser
           ◄─GET  /api/commands/next ──────┘
```

**Architectural rule:** the EA is the single source of truth for all live
computation. This app renders the EA's state and never recomputes engine logic.
If you want a new value on screen, add it to `BuildStateJson()` in the EA — not
to `app.js`.

---

## Run it

```bash
node webapp/server.mjs
```

No dependencies, no build step. Defaults to `http://127.0.0.1:8787`, bound to
loopback only — nothing is exposed to your network. Override with `PORT` / `HOST`.

## Connect the EA

1. **MetaTrader → Tools → Options → Expert Advisors → Allow WebRequest for listed URL**
   Add: `http://127.0.0.1:8787`
2. On the chart, open the EA properties and set:
   - `InpBridgeURL` = `http://127.0.0.1:8787`
   - `InpStatePostSec` = `3` (default)
3. Re-attach the EA. The header pill should go green within a few seconds.

Leaving `InpBridgeURL` blank disables the bridge entirely — zero network activity.

---

## Version safety

The EA stamps `RM_VERSION` into every snapshot. The server holds
`CONTRACT_VERSION`. If they disagree the dashboard shows a red banner and tells
you the payload may be misaligned, rather than quietly rendering wrong numbers.

**When you change the state contract, bump both:**

| Where | Constant |
|---|---|
| `RiskManager.mq5` / `.mq4` | `#define RM_VERSION "x.y"` |
| `webapp/server.mjs` | `const CONTRACT_VERSION = 'x.y'` |

---

## Endpoints

| Method | Path | Used by | Purpose |
|---|---|---|---|
| POST | `/api/state` | EA | push state snapshot |
| GET | `/api/state` | web | read snapshot + freshness + version check |
| GET | `/api/commands/next` | EA | poll for one pending command |
| POST | `/api/commands/ack` | EA | report the outcome |
| POST | `/api/commands` | web | queue a command |
| GET | `/api/commands` | web | recent command log |
| GET/POST | `/api/plan` | web | load / save the session game plan |
| GET | `/api/health` | — | liveness + contract version |

### Command safety

- Every command gets a unique incrementing id.
- `/api/commands/next` dispatches a command **once** and flips it to
  `dispatched`. A duplicate or retried poll returns `null`, so a network retry
  can never double-fire an order.
- The EA acks by id; results land in `data/journal.jsonl`.
- The dashboard's **ARM REMOTE** toggle is off on every page load. While
  disarmed, clicking a pattern does nothing.

---

## Files

```
webapp/
  server.mjs          zero-dep bridge + static host
  public/
    index.html        dashboard shell
    app.js            renderer (NO engine logic — by design)
    style.css         palette mirrors the EA's #define colours
  data/
    plan.json         saved session game plan
    journal.jsonl     append-only command + plan audit trail
```

---

## Status

| Piece | State |
|---|---|
| EA → state snapshot | ✅ `BuildStateJson()` / `PostState()` |
| Bridge server | ✅ |
| Live dashboard | ✅ |
| Command queue + idempotency | ✅ server-side |
| EA command poller | ⬜ next |
| Definitions extractor (MQL → JSON) | ⬜ |
| TS engine port + conformance harness | ⬜ |
| Game-plan builder + enforcement | ⬜ |
