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

## Run it locally

```bash
npm start
```

No dependencies, no build step. Defaults to `http://127.0.0.1:8787`, bound to
loopback only — nothing is exposed to your network.

## Connect the EA

1. **MetaTrader → Tools → Options → Expert Advisors → Allow WebRequest for listed URL**
   Add: `http://127.0.0.1:8787`
2. On the chart, open the EA properties and set:
   - `InpBridgeURL` = `http://127.0.0.1:8787`
   - `InpBridgeToken` = your `RM_TOKEN` (leave blank if running locally without one)
   - `InpStatePostSec` = `3` (default)
3. Re-attach the EA. The header pill should go green within a few seconds.

Leaving `InpBridgeURL` blank disables the bridge entirely — zero network activity.

---

## Authentication

Every `/api/*` route is guarded by a shared secret in the `RM_TOKEN` environment
variable. `/api/health` is deliberately public so platform health checks work; it
exposes nothing but "a server is up" and the contract version.

| Client | How it presents the token |
|---|---|
| EA | `Authorization: Bearer <InpBridgeToken>` header on each POST |
| Browser | prompts once, stores in `localStorage`, re-prompts on any 401 |

Comparison is constant-time, so the token can't be recovered by timing responses.

**Fail-safe:** if `HOST` is anything other than loopback and `RM_TOKEN` is unset,
the server **refuses to start**. An open `/api/commands` would let anyone queue
commands your EA executes — that must never be reachable unauthenticated.

Generate a token with:

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"
```

---

## Deploying to Railway

The app is a plain Node server, so Nixpacks builds it from the root
`package.json` with no extra config. `railway.json` sets the start command and
points health checks at `/api/health`.

**1 · Set variables** (Railway → your service → Variables):

| Variable | Value | Why |
|---|---|---|
| `RM_TOKEN` | long random string | **required** — the server refuses to boot without it |
| `RM_DATA_DIR` | `/data` | see the volume note below |

Railway injects `PORT` automatically — don't set it. `HOST` is detected: the
server binds `0.0.0.0` when it sees a PaaS environment (Railway, Render, Fly,
Heroku, Cloud Run) and loopback otherwise. Set `HOST` explicitly only if you
need to override that.

> **If the health check fails with "service unavailable":** check the deploy
> logs. Either the server refused to boot because `RM_TOKEN` is missing (it says
> so in a large banner), or it bound loopback — the startup line prints the
> address and whether a PaaS was detected.

**2 · Add a volume.** Railway's filesystem is **ephemeral**: every redeploy wipes
it. Mount a volume at `/data` and set `RM_DATA_DIR=/data`, otherwise your saved
plan and the entire command journal vanish on each deploy. (The state snapshot
doesn't matter — the EA re-posts within seconds.)

**3 · Point the EA at it:**
- `InpBridgeURL` = `https://<your-app>.up.railway.app`
- `InpBridgeToken` = the same `RM_TOKEN`
- Whitelist that https URL under **Tools → Options → Expert Advisors**

Railway terminates TLS, so the token is never sent in the clear.

> **Consider a tunnel instead.** If you only want to reach the dashboard from
> your phone, Cloudflare Tunnel or Tailscale gives you that while the server
> stays bound to loopback with no public attack surface at all. Railway is the
> better fit when MetaTrader itself runs on a VPS.

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

All routes below require the token except `/api/health`.

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

There are four independent gates between a click in the browser and lines on
your chart. Any one of them stops it.

| # | Gate | Where |
|---|---|---|
| 1 | **ARM REMOTE** toggle, off on every page load | browser |
| 2 | Valid `RM_TOKEN` | server |
| 3 | Command dispatched **once**; a retried poll returns `null` | server |
| 4 | `InpAllowRemote = false` by default | EA |
| 5 | `IsOrderBtnAvailable()` must still agree | EA |

**The only remote action is `arm`** — it draws the entry/SL/TP lines. There is
deliberately no remote "send order": pressing Enter on the chart stays a
physical act. The point of this system is fewer impulsive entries, not more
convenient ones.

The EA acks every command with an outcome, and the whole lifecycle
(queued → dispatched → ack) lands in `data/journal.jsonl`.

### Trade counting

`session.tradesTodayAll` / `tradesTodaySymbol` come from the EA's own trade
history — **not** from a counter the web app increments. That means trades you
place by clicking the chart (the ones most likely to be impulsive) count against
the plan's cap exactly like remote arms do.

The plan snapshots the count at activation (`tradesAtActivation`), so activating
mid-session counts from that moment rather than from midnight.

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
| Game-plan builder + enforcement | ✅ web-side |
| Auth (`RM_TOKEN`) + fail-safe bind | ✅ |
| Railway deploy config | ✅ |
| EA command poller (`arm` only, opt-in) | ✅ |
| Trade count from EA history | ✅ |
| Definitions extractor (MQL → JSON) | ⬜ next |
| TS engine port + conformance harness | ⬜ |
| EA-side hard enforcement of the plan | ⬜ |
