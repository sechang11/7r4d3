"""
Thrust-excursion study — how far price projects after leaving fair value.

Pulls bars straight from your RUNNING MT5 terminal (no TradingView, no export),
rebuilds the H1 thrust structure (the 4x M15 window), finds each break of the
swing range ("leaving fair value" = a BOS), and measures how far price extends
past the break, normalized to  R = excursion / fair-value-range,  under three
stop rules so you don't have to pick one up front:

  (a) until price closes back INSIDE the range        (clean initial impulse)
  (b) until the OPPOSITE break of structure (BOS)      (whole leg)
  (c) a fixed N-bar horizon                            (time-boxed)

Setup:
  pip install MetaTrader5 pandas numpy
  - MT5 terminal open and logged in (this connects to it).
  - Put your exact MT5 symbol names in SYMBOLS below.
  Run:  python thrust_excursion_study.py
"""

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

# ─── Config ──────────────────────────────────────────────────────────────────
SYMBOLS   = ["XAUUSD", "US30.cash", "NAS100.cash", "USOIL.cash"]  # <- your names
TIMEFRAME = mt5.TIMEFRAME_M15   # M15 window == the H1 thrust
N_BARS    = 60000               # bars to pull per symbol (as far back as MT5 has)
HORIZON_C = 20                  # bars for stop rule (c)
DROP_INCOMPLETE = True          # ignore events whose stop didn't trigger before data end
OUT_CSV   = "thrust_events.csv" # per-event dump (set None to skip)


# ─── MT5 bar pull ────────────────────────────────────────────────────────────
def load_bars(symbol):
    mt5.symbol_select(symbol, True)
    rates = mt5.copy_rates_from_pos(symbol, TIMEFRAME, 0, N_BARS)
    if rates is None or len(rates) == 0:
        print(f"  ! no data for {symbol}: {mt5.last_error()}")
        return None
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    return df


# ─── Thrust structure — mirrors the Pine logic exactly ───────────────────────
# Pivots are lagging (current bar vs the 4 prior), so nothing here peeks ahead.
def compute_structure(df):
    high = df["high"].to_numpy(dtype=float)
    low  = df["low"].to_numpy(dtype=float)
    n = len(df)

    swingHigh = np.full(n, np.nan)
    swingLow  = np.full(n, np.nan)
    tTrend    = np.ones(n, dtype=int)   # 1 = up, 2 = down

    hHold = lHold = np.nan
    sHigh = sLow  = np.nan
    trnd, flw = 1, 1
    ckUp = ckDn = False

    events = []   # each break of the range = "leaving fair value"

    for i in range(n):
        if i >= 4:
            isLP = low[i]  <= low[i-1]  and low[i]  <= low[i-2]  and low[i]  <= low[i-3]  and low[i]  <= low[i-4]
            isHP = high[i] >= high[i-1] and high[i] >= high[i-2] and high[i] >= high[i-3] and high[i] >= high[i-4]
            hh4  = high[i-4:i].max()   # == ta.highest(high,4)[1]
            ll4  = low[i-4:i].min()    # == ta.lowest(low,4)[1]
        else:
            isLP = isHP = False
            hh4 = ll4 = np.nan

        if isLP: lHold = low[i]
        if isHP: hHold = high[i]

        if not np.isnan(ll4):
            # down thrust / up thrust / down thrust again (matches Pine's repeat)
            if flw == 1 and low[i] < ll4:
                sHigh, flw, ckUp = hHold, 2, True
            if flw == 2 and high[i] > hh4:
                sLow,  flw, ckDn = lHold, 1, True
            if flw == 1 and low[i] < ll4:
                sHigh, flw, ckUp = hHold, 2, True

            # BOS = the break of the swing => price leaves fair value
            if ckUp and not np.isnan(sHigh) and high[i] > sHigh:
                ckUp = False
                trnd = 1
                if not np.isnan(sLow):
                    events.append(dict(idx=i, time=df["time"].iloc[i], dir="up",
                                       breakLevel=sHigh, rangeSize=sHigh - sLow))
            if ckDn and not np.isnan(sLow) and low[i] < sLow:
                ckDn = False
                trnd = 2
                if not np.isnan(sHigh):
                    events.append(dict(idx=i, time=df["time"].iloc[i], dir="down",
                                       breakLevel=sLow, rangeSize=sHigh - sLow))

        swingHigh[i], swingLow[i], tTrend[i] = sHigh, sLow, trnd

    df["swingHigh"], df["swingLow"], df["tTrend"] = swingHigh, swingLow, tTrend
    return df, events


# ─── Measure the R-excursion of one event under all three stop rules ─────────
def measure(df, ev):
    high  = df["high"].to_numpy(dtype=float)
    low   = df["low"].to_numpy(dtype=float)
    close = df["close"].to_numpy(dtype=float)
    trend = df["tTrend"].to_numpy()
    n = len(df)

    i0  = ev["idx"]
    lvl = ev["breakLevel"]
    rng = ev["rangeSize"]
    up  = ev["dir"] == "up"
    ev_trend = trend[i0]
    if rng is None or rng <= 0:
        return dict(R_a=np.nan, R_b=np.nan, R_c=np.nan)

    mfe = 0.0
    out = dict(a=None, b=None, c=None)
    j = i0
    while j < n and any(v is None for v in out.values()):
        exc = (high[j] - lvl) if up else (lvl - low[j])
        if exc > mfe:
            mfe = exc
        if out["a"] is None and j > i0 and ((close[j] < lvl) if up else (close[j] > lvl)):
            out["a"] = mfe                                   # closed back inside
        if out["b"] is None and j > i0 and trend[j] != ev_trend:
            out["b"] = mfe                                   # opposite BOS
        if out["c"] is None and (j - i0) >= HORIZON_C:
            out["c"] = mfe                                   # horizon reached
        j += 1

    # stop never triggered before data ran out -> incomplete
    def to_R(v):
        if v is None:
            return (mfe / rng) if not DROP_INCOMPLETE else np.nan
        return v / rng
    return dict(R_a=to_R(out["a"]), R_b=to_R(out["b"]), R_c=to_R(out["c"]))


# ─── Reporting ───────────────────────────────────────────────────────────────
def report(ev_df):
    def line(name, s):
        s = s.dropna()
        if len(s) == 0:
            print(f"    {name:<10} n=0")
            return
        print(f"    {name:<10} n={len(s):<5} mean={s.mean():.2f}R  median={s.median():.2f}R  "
              f"std={s.std():.2f}  >=1R={100*(s>=1).mean():.0f}%  >=2R={100*(s>=2).mean():.0f}%  "
              f"p90={s.quantile(.9):.2f}R  max={s.max():.2f}R")

    rules = {"a": "reenter", "b": "oppBOS", "c": f"{HORIZON_C}bars"}
    for direction in ("all", "up", "down"):
        sub = ev_df if direction == "all" else ev_df[ev_df["dir"] == direction]
        print(f"\n  {direction.upper()}  (events={len(sub)})")
        for k, label in rules.items():
            line(f"({k}) {label}", sub[f"R_{k}"])

    # extra cut: does a bigger fair-value range project further? (rule b)
    print("\n  BY RANGE SIZE (rule b, oppBOS):")
    q = ev_df["rangeSize"].quantile([.33, .66])
    buckets = [("small", ev_df["rangeSize"] <= q.iloc[0]),
               ("mid",   (ev_df["rangeSize"] > q.iloc[0]) & (ev_df["rangeSize"] <= q.iloc[1])),
               ("large", ev_df["rangeSize"] > q.iloc[1])]
    for name, mask in buckets:
        line(name, ev_df.loc[mask, "R_b"])


# ─── Main ────────────────────────────────────────────────────────────────────
def main():
    if not mt5.initialize():
        print("initialize() failed:", mt5.last_error()); return

    all_events = []
    for sym in SYMBOLS:
        df = load_bars(sym)
        if df is None:
            continue
        df, events = compute_structure(df)
        rows = []
        for ev in events:
            r = measure(df, ev)
            rows.append({**ev, **r, "symbol": sym})
        ev_df = pd.DataFrame(rows)
        n_ok = ev_df["R_b"].notna().sum() if len(ev_df) else 0
        print(f"\n{sym}: {len(df)} bars, {len(events)} breakouts ({n_ok} with a completed rule-b leg)")
        if len(ev_df):
            report(ev_df)
            all_events.append(ev_df)

    mt5.shutdown()

    if all_events and OUT_CSV:
        out = pd.concat(all_events, ignore_index=True)
        out.to_csv(OUT_CSV, index=False)
        print(f"\nPer-event data written to {OUT_CSV} ({len(out)} rows) — "
              f"open in Excel/pandas for histograms and your own cross-tabs.")


if __name__ == "__main__":
    main()
