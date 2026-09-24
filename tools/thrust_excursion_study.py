"""
Thrust-excursion study — how far price projects after leaving fair value.

Pulls bars straight from your RUNNING MT5 terminal (no TradingView, no export),
rebuilds the H1 thrust structure (the 4x M15 window), finds each break of the
swing range ("leaving fair value" = a BOS), and measures how far price extends
past the break, normalized to  R = excursion / fair-value-range.

For every breakout it records:
  R_a / R_b / R_c  max favorable excursion (R) under three stop rules:
                     a = until price closes back inside the range
                     b = until the opposite BOS (the whole leg)
                     c = a fixed N-bar horizon
  MAE_b            max ADVERSE excursion (R) during the rule-b leg  (stop sizing)
  vs_outcome       first-passage of the VS trade: did +1R (VS target) hit before
                     -1R (opposite swing)? -> win / loss / open
  htf_agree        was the higher-timeframe (H4) thrust pointing the SAME way at
                     the breakout? (the usual runner-vs-fade separator)
  hour             breakout hour (broker time) for your own session cross-tabs

Setup:
  pip install MetaTrader5 pandas numpy      (matplotlib optional, for histograms)
  - MT5 terminal open and logged in.
  - Put your exact MT5 symbol names in SYMBOLS below.
  Run:  python thrust_excursion_study.py
"""

import os
import sys
import json
import base64
import urllib.request
import numpy as np
import pandas as pd
import MetaTrader5 as mt5

# ─── Config ──────────────────────────────────────────────────────────────────
# Point this at the exact terminal you're logged into (helps with -6 auth
# errors and picks the right one when several MT5s are installed). "" = auto.
MT5_PATH  = r""   # e.g. r"C:\Program Files\OANDA MetaTrader 5\terminal64.exe"
SYMBOLS   = ["XAUUSD", "US30.cash", "NAS100.cash", "USOIL.cash"]  # <- your names
TIMEFRAME = mt5.TIMEFRAME_M15   # M15 window == the H1 thrust
N_BARS    = 60000               # bars to pull per symbol (as far back as MT5 has)
HORIZON_C = 20                  # bars for stop rule (c)
MAX_SCAN  = 1000                # cap forward scan per event (bars)
DROP_INCOMPLETE = True          # NaN out rules whose stop didn't trigger before data end
OUT_CSV   = "thrust_events.csv"
PLOTS     = True                # save R-distribution histograms if matplotlib is present
TARGETS   = [0.5, 1.0, 1.5, 2.0, 3.0]   # R levels for the hit-rate table

# Local bar cache so re-runs (and offline analysis tweaks) don't re-hit MT5.
CACHE_DIR = os.path.join(os.path.dirname(__file__), "bars_cache")
REFRESH   = False               # True = ignore cache and re-pull everything from MT5

# `--push` sends the RESULTS (not the raw bars) to the 7r4d3 bridge Studies page.
BRIDGE_URL = os.environ.get("RM_BRIDGE", "https://7r4d3.net")
TOKEN      = os.environ.get("RM_TOKEN", "")   # bridge token; keep it out of the file


# ─── Thrust structure — mirrors the Pine logic. Lagging pivots => no lookahead ─
def thrust_core(high, low, times=None):
    n = len(high)
    swingHigh = np.full(n, np.nan)
    swingLow  = np.full(n, np.nan)
    tTrend    = np.ones(n, dtype=int)   # 1 = up, 2 = down

    hHold = lHold = np.nan
    sHigh = sLow  = np.nan
    trnd, flw = 1, 1
    ckUp = ckDn = False
    events = []

    for i in range(n):
        if i >= 4:
            isLP = low[i]  <= low[i-1]  and low[i]  <= low[i-2]  and low[i]  <= low[i-3]  and low[i]  <= low[i-4]
            isHP = high[i] >= high[i-1] and high[i] >= high[i-2] and high[i] >= high[i-3] and high[i] >= high[i-4]
            hh4  = high[i-4:i].max()
            ll4  = low[i-4:i].min()
        else:
            isLP = isHP = False
            hh4 = ll4 = np.nan

        if isLP: lHold = low[i]
        if isHP: hHold = high[i]

        if not np.isnan(ll4):
            if flw == 1 and low[i] < ll4:
                sHigh, flw, ckUp = hHold, 2, True
            if flw == 2 and high[i] > hh4:
                sLow,  flw, ckDn = lHold, 1, True
            if flw == 1 and low[i] < ll4:
                sHigh, flw, ckUp = hHold, 2, True

            if ckUp and not np.isnan(sHigh) and high[i] > sHigh:
                ckUp = False; trnd = 1
                if not np.isnan(sLow):
                    events.append(dict(idx=i, time=(times[i] if times is not None else i),
                                       dir="up", breakLevel=sHigh, rangeSize=sHigh - sLow))
            if ckDn and not np.isnan(sLow) and low[i] < sLow:
                ckDn = False; trnd = 2
                if not np.isnan(sHigh):
                    events.append(dict(idx=i, time=(times[i] if times is not None else i),
                                       dir="down", breakLevel=sLow, rangeSize=sHigh - sLow))

        swingHigh[i], swingLow[i], tTrend[i] = sHigh, sLow, trnd

    return swingHigh, swingLow, tTrend, events


# ─── Per-event metrics: one forward pass gets MFE(a/b/c), MAE, VS first-passage ─
def measure(high, low, close, trend, ev):
    n = len(high)
    i0, lvl, rng, up = ev["idx"], ev["breakLevel"], ev["rangeSize"], ev["dir"] == "up"
    ev_trend = trend[i0]
    res = dict(R_a=np.nan, R_b=np.nan, R_c=np.nan, MAE_b=np.nan,
               vs_outcome="open", vs_bars=np.nan)
    if rng is None or rng <= 0:
        return res

    target = lvl + rng if up else lvl - rng    # VS = +1R
    stop   = lvl - rng if up else lvl + rng    # opposite swing = -1R
    mfe = mae = 0.0
    got_a = got_b = got_c = got_vs = False
    end = min(n, i0 + MAX_SCAN)
    for j in range(i0, end):
        fav = (high[j] - lvl) if up else (lvl - low[j])
        adv = (lvl - low[j]) if up else (high[j] - lvl)
        if fav > mfe: mfe = fav
        if adv > mae: mae = adv

        if not got_vs and j > i0:
            hit_t = (high[j] >= target) if up else (low[j] <= target)
            hit_s = (low[j] <= stop)    if up else (high[j] >= stop)
            if hit_t and not hit_s:
                res["vs_outcome"], res["vs_bars"], got_vs = "win", j - i0, True
            elif hit_s:                                  # both same bar => stop first (conservative)
                res["vs_outcome"], res["vs_bars"], got_vs = "loss", j - i0, True

        if not got_a and j > i0 and ((close[j] < lvl) if up else (close[j] > lvl)):
            res["R_a"], got_a = mfe / rng, True
        if not got_c and (j - i0) >= HORIZON_C:
            res["R_c"], got_c = mfe / rng, True
        if not got_b and j > i0 and trend[j] != ev_trend:
            res["R_b"], res["MAE_b"], got_b = mfe / rng, mae / rng, True

        if got_a and got_b and got_c and got_vs:
            break

    if not DROP_INCOMPLETE:
        if not got_a: res["R_a"] = mfe / rng
        if not got_c: res["R_c"] = mfe / rng
        if not got_b: res["R_b"], res["MAE_b"] = mfe / rng, mae / rng
    return res


# ─── Higher-timeframe (H4) trend at each breakout, no lookahead ──────────────
def add_htf_agreement(ev_df, m15):
    h1 = (m15.set_index("time")
              .resample("1h")
              .agg({"open": "first", "high": "max", "low": "min", "close": "last"})
              .dropna()
              .reset_index())
    if len(h1) < 10:
        ev_df["htf_trend"] = np.nan
        ev_df["htf_agree"] = np.nan
        return ev_df
    _, _, h1_trend, _ = thrust_core(h1["high"].to_numpy(float), h1["low"].to_numpy(float))
    # index H1 trend by the bar's CLOSE time so an event only sees closed H1 bars
    h1_ref = pd.DataFrame({"close_time": h1["time"] + pd.Timedelta(hours=1),
                           "htf_trend": h1_trend}).sort_values("close_time")
    merged = pd.merge_asof(ev_df.sort_values("time"), h1_ref,
                           left_on="time", right_on="close_time", direction="backward")
    merged["htf_agree"] = ((merged["dir"] == "up") & (merged["htf_trend"] == 1)) | \
                          ((merged["dir"] == "down") & (merged["htf_trend"] == 2))
    return merged


# ─── Reporting ───────────────────────────────────────────────────────────────
def _stat_line(name, s):
    s = pd.Series(s).dropna()
    if len(s) == 0:
        print(f"    {name:<16} n=0"); return
    print(f"    {name:<16} n={len(s):<5} mean={s.mean():.2f}R  med={s.median():.2f}R  "
          f">=1R={100*(s>=1).mean():.0f}%  >=2R={100*(s>=2).mean():.0f}%  "
          f"p90={s.quantile(.9):.2f}R  max={s.max():.2f}R")


def report(ev_df, title):
    print(f"\n{'='*78}\n{title}   (events={len(ev_df)})\n{'='*78}")

    for direction in ("all", "up", "down"):
        sub = ev_df if direction == "all" else ev_df[ev_df["dir"] == direction]
        print(f"\n  {direction.upper()}  (n={len(sub)})")
        _stat_line("(a) reenter",  sub["R_a"])
        _stat_line("(b) oppBOS",   sub["R_b"])
        _stat_line(f"(c) {HORIZON_C}bars", sub["R_c"])
        _stat_line("MAE (rule b)", sub["MAE_b"])

    # VS trade (target +1R vs stop -1R), resolved events only
    vs = ev_df[ev_df["vs_outcome"].isin(["win", "loss"])]
    if len(vs):
        wr = (vs["vs_outcome"] == "win").mean()
        print(f"\n  VS TRADE (+1R target / -1R stop):  n={len(vs)}  win={100*wr:.0f}%  "
              f"expectancy={2*wr-1:+.2f}R  median bars-to-resolve={vs['vs_bars'].median():.0f}")

    # HTF (H4) agreement split — usually the runner/fade separator
    if "htf_agree" in ev_df and ev_df["htf_agree"].notna().any():
        print("\n  H4-TREND AGREEMENT (rule b):")
        _stat_line("agree",    ev_df.loc[ev_df["htf_agree"] == True,  "R_b"])
        _stat_line("disagree", ev_df.loc[ev_df["htf_agree"] == False, "R_b"])
        vs_a = vs[vs["htf_agree"] == True]; vs_d = vs[vs["htf_agree"] == False]
        if len(vs_a): print(f"    VS win | agree    = {100*(vs_a['vs_outcome']=='win').mean():.0f}%  (n={len(vs_a)})")
        if len(vs_d): print(f"    VS win | disagree = {100*(vs_d['vs_outcome']=='win').mean():.0f}%  (n={len(vs_d)})")

    # Target hit-rate table (share of legs whose rule-b MFE reached each level)
    rb = ev_df["R_b"].dropna()
    if len(rb):
        print("\n  TARGET HIT-RATE (rule b leg):")
        for t in TARGETS:
            print(f"    reached {t:>3.1f}R : {100*(rb >= t).mean():.0f}%")

    # Does a wider fair-value range project further?
    if ev_df["rangeSize"].notna().sum() > 6:
        q = ev_df["rangeSize"].quantile([.33, .66])
        print("\n  BY RANGE SIZE (rule b):")
        _stat_line("small", ev_df.loc[ev_df["rangeSize"] <= q.iloc[0], "R_b"])
        _stat_line("mid",   ev_df.loc[(ev_df["rangeSize"] > q.iloc[0]) & (ev_df["rangeSize"] <= q.iloc[1]), "R_b"])
        _stat_line("large", ev_df.loc[ev_df["rangeSize"] > q.iloc[1], "R_b"])


def make_plots(ev_df):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from io import BytesIO
    except Exception:
        print("\n(matplotlib not installed — skipping histograms)")
        return None
    rb = ev_df["R_b"].dropna()
    if len(rb) == 0:
        return None
    fig, ax = plt.subplots(1, 2, figsize=(12, 4))
    ax[0].hist(rb.clip(upper=6), bins=40, color="#4B0082", alpha=0.8)
    ax[0].axvline(1, color="green", ls="--", label="VS (1R)")
    ax[0].set_title("R excursion (rule b, all)"); ax[0].set_xlabel("R"); ax[0].legend()
    if "htf_agree" in ev_df:
        a = ev_df.loc[ev_df["htf_agree"] == True, "R_b"].dropna().clip(upper=6)
        d = ev_df.loc[ev_df["htf_agree"] == False, "R_b"].dropna().clip(upper=6)
        ax[1].hist([a, d], bins=30, label=["H4 agree", "H4 disagree"],
                   color=["#1b7a1b", "#8a1c1c"], alpha=0.8)
        ax[1].axvline(1, color="black", ls="--")
        ax[1].set_title("R by H4 agreement"); ax[1].set_xlabel("R"); ax[1].legend()
    fig.tight_layout()
    fig.savefig("thrust_R_hist.png", dpi=110)
    buf = BytesIO(); fig.savefig(buf, format="png", dpi=110); plt.close(fig)
    print("\nHistograms saved to thrust_R_hist.png")
    return "data:image/png;base64," + base64.b64encode(buf.getvalue()).decode()


# ─── Structured result for the 7r4d3 Studies page (mirrors the printed report) ─
def _stat(series):
    s = pd.Series(series).dropna()
    if len(s) == 0:
        return None
    return dict(n=int(len(s)), mean=round(float(s.mean()), 3), median=round(float(s.median()), 3),
                p90=round(float(s.quantile(.9)), 3), hit1=round(float((s >= 1).mean()), 3),
                hit2=round(float((s >= 2).mean()), 3), max=round(float(s.max()), 3))


def build_block(ev_df):
    byDir = {}
    for d in ("all", "up", "down"):
        sub = ev_df if d == "all" else ev_df[ev_df["dir"] == d]
        byDir[d] = {"a": _stat(sub["R_a"]), "b": _stat(sub["R_b"]),
                    "c": _stat(sub["R_c"]), "mae": _stat(sub["MAE_b"])}
    vs = ev_df[ev_df["vs_outcome"].isin(["win", "loss"])]
    vs_block = None
    if len(vs):
        wr = float((vs["vs_outcome"] == "win").mean())
        vs_block = dict(n=int(len(vs)), win=round(wr, 3), expectancy=round(2 * wr - 1, 3),
                        medBars=float(vs["vs_bars"].median()))
    htf = None
    if "htf_agree" in ev_df and ev_df["htf_agree"].notna().any():
        vs_a = vs[vs["htf_agree"] == True]; vs_d = vs[vs["htf_agree"] == False]
        htf = dict(agreeR=_stat(ev_df.loc[ev_df["htf_agree"] == True, "R_b"]),
                   disagreeR=_stat(ev_df.loc[ev_df["htf_agree"] == False, "R_b"]),
                   vsWinAgree=round(float((vs_a["vs_outcome"] == "win").mean()), 3) if len(vs_a) else None,
                   vsWinDisagree=round(float((vs_d["vs_outcome"] == "win").mean()), 3) if len(vs_d) else None)
    rb = ev_df["R_b"].dropna()
    targets = {str(t): round(float((rb >= t).mean()), 3) for t in TARGETS} if len(rb) else None
    byRange = None
    if ev_df["rangeSize"].notna().sum() > 6:
        q = ev_df["rangeSize"].quantile([.33, .66])
        byRange = dict(
            small=_stat(ev_df.loc[ev_df["rangeSize"] <= q.iloc[0], "R_b"]),
            mid=_stat(ev_df.loc[(ev_df["rangeSize"] > q.iloc[0]) & (ev_df["rangeSize"] <= q.iloc[1]), "R_b"]),
            large=_stat(ev_df.loc[ev_df["rangeSize"] > q.iloc[1], "R_b"]))
    return dict(events=int(len(ev_df)), byDir=byDir, vs=vs_block, htf=htf,
                targets=targets, byRange=byRange)


def push_result(result):
    if not TOKEN:
        print("  --push skipped: set RM_TOKEN in the environment first"); return
    data = json.dumps(result).encode()
    req = urllib.request.Request(BRIDGE_URL.rstrip("/") + "/api/studies", data=data, method="POST",
                                 headers={"Content-Type": "application/json",
                                          "Authorization": "Bearer " + TOKEN})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(f"  pushed to {BRIDGE_URL} -> {r.read().decode()[:120]}")
    except Exception as e:
        print(f"  push failed: {e}")


# ─── Bar loading (cache-first, so analysis tweaks don't re-hit MT5) ──────────
def cache_path(sym):
    return os.path.join(CACHE_DIR, sym.replace("/", "_").replace("\\", "_") + ".pkl")

def load_or_pull(sym):
    if os.path.exists(cache_path(sym)) and not REFRESH:
        return pd.read_pickle(cache_path(sym)), True
    rates = mt5.copy_rates_from_pos(sym, TIMEFRAME, 0, N_BARS)
    if rates is None or len(rates) == 0:
        return None, False
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    os.makedirs(CACHE_DIR, exist_ok=True)
    df.to_pickle(cache_path(sym))
    return df, False


# ─── Main ────────────────────────────────────────────────────────────────────
def main():
    push = "--push" in sys.argv
    need_pull = REFRESH or any(not os.path.exists(cache_path(s)) for s in SYMBOLS)

    if need_pull:
        ok = mt5.initialize(path=MT5_PATH) if MT5_PATH else mt5.initialize()
        if not ok:
            err = mt5.last_error()
            print("initialize() failed:", err)
            if err and err[0] == -6:
                print("  -6 Authorization failed - usually one of:\n"
                      "   1. ELEVATION MISMATCH (most common): run this script at the SAME\n"
                      "      Windows privilege as the terminal - either both normal, or both\n"
                      "      'Run as administrator'. A terminal opened as admin won't talk to a\n"
                      "      normal Python (and vice-versa).\n"
                      "   2. Set MT5_PATH to the exact terminal64.exe you're logged into.\n"
                      "   3. That terminal must be open and logged in to your account.")
            return
        ti = mt5.terminal_info()
        if ti is not None:
            print(f"connected: {ti.name}  logged_in={ti.connected}  path={ti.path}")
        for s in SYMBOLS:
            mt5.symbol_select(s, True)

    per_symbol, all_events = {}, []
    for sym in SYMBOLS:
        m15, cached = load_or_pull(sym)
        if m15 is None:
            print(f"\n{sym}: no data (not cached / MT5 returned none)"); continue
        H = m15["high"].to_numpy(float); L = m15["low"].to_numpy(float)
        C = m15["close"].to_numpy(float); T = m15["time"].to_numpy()
        _, _, trend, events = thrust_core(H, L, T)
        rows = [{**ev, **measure(H, L, C, trend, ev), "symbol": sym,
                 "hour": pd.Timestamp(ev["time"]).hour} for ev in events]
        ev_df = pd.DataFrame(rows)
        if len(ev_df) == 0:
            print(f"\n{sym}: {len(m15)} bars, 0 breakouts"); continue
        ev_df = add_htf_agreement(ev_df, m15)
        print(f"\n{sym}: {len(m15)} bars ({'cached' if cached else 'pulled'}), {len(events)} breakouts")
        report(ev_df, sym)
        per_symbol[sym] = ev_df
        all_events.append(ev_df)

    if need_pull:
        mt5.shutdown()
    if not all_events:
        return

    pooled = pd.concat(all_events, ignore_index=True)
    report(pooled, "POOLED — all symbols")
    chart = make_plots(pooled) if PLOTS else None
    if OUT_CSV:
        pooled.to_csv(OUT_CSV, index=False)
        print(f"\nPer-event data -> {OUT_CSV} ({len(pooled)} rows) for your own cross-tabs.")

    if push:
        result = dict(
            name="thrust-excursion",
            created=pd.Timestamp.now(tz="UTC").isoformat(),
            config=dict(symbols=SYMBOLS, timeframe="M15", horizon_c=HORIZON_C, n_bars=N_BARS,
                        stop_rules="a=reenter b=oppBOS c=Nbars"),
            pooled=build_block(pooled),
            perSymbol={s: build_block(df) for s, df in per_symbol.items()},
            chartPng=chart,
        )
        push_result(result)


if __name__ == "__main__":
    main()
