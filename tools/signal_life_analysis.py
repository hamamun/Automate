#!/usr/bin/env python3
"""
Signal lifetime study for the Automate engine.

Question: does a BUY/SELL signal have a shelf life, and does the regime
column help predict when it ends?

Everything here mirrors Automate.mq5 exactly - same windows, same votes,
same thresholds - and runs on real Binance 5-minute candles.

    python3 tools/signal_life_analysis.py <dir-with-*.feather>
"""

import glob
import math
import os
import sys

import numpy as np
import pyarrow.feather as f

# ---- constants, copied from Automate.mq5 --------------------------------
CHANGE_WINDOW = 20
TREND_PERIOD = 30
STRUCTURE_PERIOD = 20
MOMENTUM_PERIOD = 2
TREND_BAND_X = 0.20
MOVE_BAND_X = 0.50
MOVE_BAND_TICKS = 1.0
Z_STEADY = 2.0
Z_MIXED = 1.0
MIN_BARS = 1537          # span + 1 for M5


def rolling_slope(c, k):
    n = len(c)
    out = np.zeros(n)
    P1 = np.concatenate(([0.0], np.cumsum(c)))
    idx = np.arange(n, dtype=float)
    P2 = np.concatenate(([0.0], np.cumsum(idx * c)))
    kk = float(k)
    sum_i = kk * (kk - 1) / 2.0
    den = kk * sum(i * i for i in range(k)) - sum_i * sum_i
    for e in range(k - 1, n):
        base = e - k + 1
        s1 = P1[e + 1] - P1[base]
        s2 = P2[e + 1] - P2[base]
        out[e] = (kk * (s2 - base * s1) - sum_i * s1) / den if den > 0 else 0.0
    return out


def rolling_median_abs_change(c, w):
    n = len(c)
    out = np.zeros(n)
    d = np.abs(np.diff(c, prepend=c[0]))
    for e in range(w, n):
        out[e] = float(np.median(d[e - w + 1:e + 1]))
    return out


def drift_z(c, span):
    n = len(c)
    out = np.zeros(n)
    d = np.diff(c, prepend=c[0])
    S1 = np.concatenate(([0.0], np.cumsum(d)))
    S2 = np.concatenate(([0.0], np.cumsum(d * d)))
    for e in range(span, n):
        b = e - span
        s1 = S1[e + 1] - S1[b]
        s2 = S2[e + 1] - S2[b]
        mean = s1 / span
        var = (s2 - span * mean * mean) / (span - 1)
        if var <= 0:
            continue
        out[e] = (c[e] - c[b]) / (math.sqrt(var) * math.sqrt(span))
    return out


def structure_vote(close, high, low, med, tick, n):
    band = MOVE_BAND_X * med * math.sqrt(STRUCTURE_PERIOD)
    floor = MOVE_BAND_TICKS * tick
    if band < floor:
        band = floor
    move = close[n - 1] - close[n - 1 - STRUCTURE_PERIOD]
    if abs(move) <= band:
        return 0
    low_last = low_prev = high_last = high_prev = 0.0
    n_low = n_high = 0
    for j in range(n - 2, 0, -1):
        if low[j] <= low[j - 1] and low[j] <= low[j + 1]:
            if n_low == 0:
                low_last = low[j]
            elif n_low == 1:
                low_prev = low[j]
            n_low += 1
        if high[j] >= high[j - 1] and high[j] >= high[j + 1]:
            if n_high == 0:
                high_last = high[j]
            elif n_high == 1:
                high_prev = high[j]
            n_high += 1
        if n_low >= 2 and n_high >= 2:
            break
    if move > band:
        if n_low >= 2 and low_last < low_prev:
            return 0
        return 1
    if n_high >= 2 and high_last > high_prev:
        return 0
    return -1


def run_engine(path):
    t = f.read_table(path).to_pydict()
    close = [float(x) for x in t["close"]]
    high = [float(x) for x in t["high"]]
    low = [float(x) for x in t["low"]]
    n = len(close)
    if n < MIN_BARS + 50:
        return None

    c = np.asarray(close)
    tick = float(np.median(np.abs(np.diff(c)))) * 0.1 or 1e-8
    med = rolling_median_abs_change(c, CHANGE_WINDOW)
    slope = rolling_slope(c, TREND_PERIOD)
    z = drift_z(c, MIN_BARS - 1)

    sig = np.zeros(n, dtype=int)
    trend = np.zeros(n, dtype=int)
    regime = np.full(n, -1, dtype=int)

    for e in range(MIN_BARS, n):
        m = med[e] if med[e] > 0 else tick
        ratio = slope[e] / m
        tv = 1 if ratio > TREND_BAND_X else (-1 if ratio < -TREND_BAND_X else 0)

        band = MOVE_BAND_X * m * math.sqrt(MOMENTUM_PERIOD)
        if band < MOVE_BAND_TICKS * tick:
            band = MOVE_BAND_TICKS * tick
        dv = c[e] - c[e - MOMENTUM_PERIOD]
        mv = 1 if dv > band else (-1 if dv < -band else 0)

        sv = structure_vote(close, high, low, m, tick, e + 1)
        score = tv + mv + sv

        trend[e] = tv
        sig[e] = 1 if score >= 2 else (-1 if score <= -2 else 0)
        az = abs(z[e])
        regime[e] = 0 if az >= Z_STEADY else (1 if az >= Z_MIXED else 2)

    return dict(sig=sig, trend=trend, regime=regime, close=c, z=z, start=MIN_BARS)


def collect_runs(arr, start):
    runs = []
    cur, length, first = arr[start], 1, start
    for i in range(start + 1, len(arr)):
        if arr[i] == cur:
            length += 1
        else:
            runs.append((cur, length, first))
            cur, length, first = arr[i], 1, i
    runs.append((cur, length, first))
    return runs


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "/tmp/data"
    files = sorted(p for p in glob.glob(os.path.join(d, "*.feather"))
                   if "UNITTEST" not in p)

    sig_lens, trend_lens = [], []
    per_pair = []
    overlap_hit = overlap_tot = 0
    hazard = {}
    z_at_start = []          # (z, run length) at the moment a signal starts
    fwd_by_age = {}          # age -> list of signed forward moves
    regime_counts = {}
    zsd = []

    for path in files:
        res = run_engine(path)
        if res is None:
            continue
        sig, trend, regime, close, z = (res["sig"], res["trend"], res["regime"],
                                        res["close"], res["z"])
        start = res["start"]
        name = os.path.basename(path).replace("-5m.feather", "")

        sruns = [r for r in collect_runs(sig, start) if r[0] != 0]
        truns = [r for r in collect_runs(trend, start) if r[0] != 0]
        if not sruns:
            continue

        lens = [r[1] for r in sruns]
        sig_lens += lens
        trend_lens += [r[1] for r in truns]
        s = sorted(lens)
        per_pair.append((name, len(s), s[len(s) // 2],
                         sum(1 for x in s if x == 1) / len(s),
                         sum(1 for x in s if x <= 2) / len(s)))

        for v, L, first in sruns:
            for tv, tl, tf in truns:
                if tv == v and tf <= first and tf + tl - 1 >= first + L - 1:
                    overlap_hit += 1
                    break
            overlap_tot += 1
            z_at_start.append((abs(z[first]), L))

        for i in range(start, len(sig)):
            if regime[i] >= 0:
                regime_counts[regime[i]] = regime_counts.get(regime[i], 0) + 1
        zsd.append((name, float(np.std(z[start:]))))

        # hazard, pooled across pairs
        for a in range(1, 26):
            risk = sum(1 for x in lens if x >= a)
            ended = sum(1 for x in lens if x == a)
            hazard.setdefault(a, [0, 0])
            hazard[a][0] += risk
            hazard[a][1] += ended

        # forward move from a bar inside a still-active signal, by its age
        m_series = np.abs(np.diff(close, prepend=close[0]))
        for v, L, first in sruns:
            for age in range(1, min(L, 10) + 1):
                i = first + age - 1
                for h in (3, 10):
                    j = i + h
                    if j >= len(close):
                        continue
                    scale = np.median(m_series[max(0, i - 60):i + 1])
                    if scale <= 0:
                        continue
                    move = (close[j] - close[i]) / (scale * math.sqrt(h))
                    fwd_by_age.setdefault((age, h), []).append(v * move)

    # ------------------------------ report ------------------------------
    sig_lens.sort()
    n = len(sig_lens)
    print(f"real 5-minute candles: {len(files)} pairs, {n} signal runs\n")

    print("1. HOW LONG DOES A SIGNAL LAST?")
    print(f"   median {sig_lens[n // 2]} bars | "
          f"1-bar {100 * sum(1 for x in sig_lens if x == 1) / n:.0f}% | "
          f"2 bars or less {100 * sum(1 for x in sig_lens if x <= 2) / n:.0f}% | "
          f"p90 {sig_lens[int(n * .9)]} | longest {sig_lens[-1]}")
    tl = sorted(trend_lens)
    print(f"   trend runs, same data: median {tl[len(tl) // 2]} bars, "
          f"p90 {tl[int(len(tl) * .9)]}")
    print()
    print(f"   {'pair':<10} {'runs':>6} {'median':>7} {'1-bar':>7} {'<=2 bars':>9}")
    for name, cnt, med, one, two in sorted(per_pair):
        print(f"   {name:<10} {cnt:>6} {med:>7} {100 * one:>6.0f}% {100 * two:>8.0f}%")

    print()
    print("2. DOES AN OLD SIGNAL END SOONER THAN A YOUNG ONE?")
    print("   (chance it ends on the very next bar)")
    for a in sorted(hazard):
        risk, ended = hazard[a]
        if risk >= 100:
            print(f"   age {a:>2}: {100 * ended / risk:4.1f}%   at risk {risk}")
    y = (hazard[1][1] + hazard[2][1]) / (hazard[1][0] + hazard[2][0])
    o = sum(hazard[a][1] for a in range(6, 11)) / sum(hazard[a][0] for a in range(6, 11))
    print(f"   age 1-2: {100 * y:.1f}%     age 6-10: {100 * o:.1f}%"
          f"     -> older is {'MORE' if o < y else 'LESS'} persistent")

    print()
    print("3. IS A SIGNAL JUST A SLICE OF A TREND?")
    print(f"   {100 * overlap_hit / max(1, overlap_tot):.1f}% of signal runs sit entirely "
          f"inside one trend run")
    print(f"   trend runs median {tl[len(tl) // 2]} bars vs signal median "
          f"{sig_lens[n // 2]} bars")

    print()
    print("4. DOES THE REGIME COLUMN HELP?")
    tot = sum(regime_counts.values())
    for code, nm in ((0, "Steady"), (1, "Mixed"), (2, "Choppy")):
        c = regime_counts.get(code, 0)
        print(f"   {nm:<7} {100 * c / tot:6.2f}% of bars")
    print(f"   drift z spread on these pairs: "
          f"{min(x[1] for x in zsd):.2f} to {max(x[1] for x in zsd):.2f} "
          f"(a random walk gives 1.00)")
    zs = sorted(z_at_start)
    cut = [x[0] for x in zs]
    q = np.quantile(cut, [0.25, 0.75])
    lo = [L for zz, L in z_at_start if zz <= q[0]]
    hi = [L for zz, L in z_at_start if zz >= q[1]]
    lo.sort(); hi.sort()
    print(f"   signal life when drift is weak  (lowest quarter):  median {lo[len(lo) // 2]}")
    print(f"   signal life when drift is strong (highest quarter): median {hi[len(hi) // 2]}")

    print()
    print("5. IF I ENTER ON AN ALREADY-OLD SIGNAL, IS IT STILL GOOD?")
    print("   hit rate = moved in the signal's favour; median = size in bar-sizes")
    for h in (3, 10):
        print(f"   horizon {h} bars:")
        for age in range(1, 7):
            xs = fwd_by_age.get((age, h), [])
            if len(xs) <= 100:
                continue
            med = float(np.median(xs))
            hit = sum(1 for x in xs if x > 0) / len(xs)
            se = math.sqrt(hit * (1 - hit) / len(xs))
            print(f"     age {age}: hit {100 * hit:4.1f}% "
                  f"(+/-{100 * 1.96 * se:4.1f})   median {med:+6.3f}   n={len(xs)}")

    print()
    print("6. WHAT WOULD A FIXED EXPIRY ACTUALLY CUT?")
    for exp in (2, 3, 5, 10):
        cut = sum(1 for x in sig_lens if x > exp)
        print(f"   expiry {exp:>2} bars: {100 * cut / n:4.1f}% of signals would be "
              f"stopped early")


if __name__ == "__main__":
    main()
