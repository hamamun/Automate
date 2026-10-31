#!/usr/bin/env python3
"""
Does the SCORE last, and can a conventional indicator tell us how long?

The question is NOT which way price goes. It is:

    given the score I see now, what is the chance it is still the same
    score N bars from here?

That is a persistence question, and unlike direction it can be answered
honestly: a run that has already lasted 8 bars has demonstrably different
prospects from one that just appeared.

Method
------
  event      score[t] stays equal to score[t] for the next N bars
  baseline   empirical rate by (age of the current run, score value)
  extended   the same, plus a conventional indicator set
  test       trained on one era, scored on the other - never in-sample

    python3 tools/score_persistence.py <dir-with-*.feather>
"""

import glob
import math
import os
import sys

import numpy as np
import pyarrow.feather as f

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import signal_life_analysis as S

N_BARS = 3           # "will it last this many more bars" (CLI overridable)
TARGET = "score"     # "score" or "signal"


# ----------------------------------------------------------------------
#  indicators - all causal, all ending at bar t
# ----------------------------------------------------------------------
def ema(x, span):
    a = 2.0 / (span + 1.0)
    out = np.empty_like(x)
    out[0] = x[0]
    for i in range(1, len(x)):
        out[i] = a * x[i] + (1 - a) * out[i - 1]
    return out


def rsi(c, n=14):
    d = np.diff(c, prepend=c[0])
    up = np.where(d > 0, d, 0.0)
    dn = np.where(d < 0, -d, 0.0)
    au = ema(up, n)
    ad = ema(dn, n)
    rs = np.where(ad > 0, au / np.maximum(ad, 1e-12), 100.0)
    return 100.0 - 100.0 / (1.0 + rs)


def atr(high, low, close, n=14):
    pc = np.roll(close, 1)
    pc[0] = close[0]
    tr = np.maximum(high - low, np.maximum(np.abs(high - pc), np.abs(low - pc)))
    return ema(tr, n)


def adx(high, low, close, n=14):
    up = np.diff(high, prepend=high[0])
    dn = -np.diff(low, prepend=low[0])
    plus = np.where((up > dn) & (up > 0), up, 0.0)
    minus = np.where((dn > up) & (dn > 0), dn, 0.0)
    a = atr(high, low, close, n)
    with np.errstate(divide="ignore", invalid="ignore"):
        pdi = 100.0 * ema(plus, n) / np.maximum(a, 1e-12)
        mdi = 100.0 * ema(minus, n) / np.maximum(a, 1e-12)
        dx = 100.0 * np.abs(pdi - mdi) / np.maximum(pdi + mdi, 1e-12)
    return ema(dx, n)


def bollinger_width(c, n=20):
    out = np.zeros(len(c))
    sd = np.zeros(len(c))
    for i in range(n - 1, len(c)):
        seg = c[i - n + 1:i + 1]
        sd[i] = seg.std()
    out = 4.0 * sd / np.maximum(c, 1e-12)      # 2 sd each side
    return out


def stoch(high, low, close, n=14):
    out = np.zeros(len(close))
    for i in range(n - 1, len(close)):
        hh = high[i - n + 1:i + 1].max()
        ll = low[i - n + 1:i + 1].min()
        out[i] = 100.0 * (close[i] - ll) / max(hh - ll, 1e-12)
    return out


def cci(high, low, close, n=20):
    tp = (high + low + close) / 3.0
    out = np.zeros(len(close))
    for i in range(n - 1, len(close)):
        seg = tp[i - n + 1:i + 1]
        m = seg.mean()
        md = np.abs(seg - m).mean()
        out[i] = (tp[i] - m) / max(0.015 * md, 1e-12)
    return out


def macd_hist(c):
    m = ema(c, 12) - ema(c, 26)
    s = ema(m, 9)
    return m - s


# ----------------------------------------------------------------------
#  data
# ----------------------------------------------------------------------
def build(path):
    t = f.read_table(path).to_pydict()
    close = [float(x) for x in t["close"]]
    high = [float(x) for x in t["high"]]
    low = [float(x) for x in t["low"]]
    n = len(close)
    if n < S.MIN_BARS + 200:
        return None

    c = np.asarray(close)
    h = np.asarray(high)
    l = np.asarray(low)
    tick = float(np.median(np.abs(np.diff(c)))) * 0.1 or 1e-8
    med = S.rolling_median_abs_change(c, S.CHANGE_WINDOW)
    slope = S.rolling_slope(c, S.TREND_PERIOD)

    score = np.zeros(n, dtype=int)
    for e in range(S.MIN_BARS, n):
        m = med[e] if med[e] > 0 else tick
        ratio = slope[e] / m
        tv = 1 if ratio > S.TREND_BAND_X else (-1 if ratio < -S.TREND_BAND_X else 0)
        band = max(S.MOVE_BAND_X * m * math.sqrt(S.MOMENTUM_PERIOD),
                   S.MOVE_BAND_TICKS * tick)
        dv = c[e] - c[e - S.MOMENTUM_PERIOD]
        mv = 1 if dv > band else (-1 if dv < -band else 0)
        score[e] = tv + mv + S.structure_vote(close, high, low, m, tick, e + 1)

    a14 = atr(h, l, c, 14)
    a50 = atr(h, l, c, 50)
    bbw = bollinger_width(c, 20)
    bbw_rank = np.zeros(n)
    for i in range(200, n):
        bbw_rank[i] = np.mean(bbw[i - 199:i + 1] <= bbw[i])

    feats = {
        "age":        None,                       # filled below
        "abs_score":  np.abs(score).astype(float),
        "rsi":        np.abs(rsi(c) - 50.0) / 50.0,
        "adx":        adx(h, l, c) / 100.0,
        "atr_ratio":  a14 / np.maximum(a50, 1e-12),
        "bb_width":   bbw_rank,
        "stoch":      np.abs(stoch(h, l, c) - 50.0) / 50.0,
        "cci":        np.abs(cci(h, l, c)) / 200.0,
        "macd":       np.abs(macd_hist(c)) / np.maximum(a14, 1e-12),
    }

    # age of the current score run
    age = np.zeros(n)
    last = score[0]
    run = 0
    for i in range(n):
        if score[i] == last:
            run += 1
        else:
            run = 1
            last = score[i]
        age[i] = run
    feats["age"] = age

    return score, feats, c


def make_events(score, n_horizon):
    """1.0 if the current run of this score lasts at least n more bars.

    This is a survival question, not a recurrence one: "will the run I am
    in keep going", not "will the value come back later". The difference
    matters - states recur, so the naive comparison reads almost flat.
    """
    n = len(score)
    y = np.full(n, np.nan)

    # run id and age for every bar
    run_end = np.zeros(n, dtype=int)
    i = n - 1
    while i >= 0:
        j = i
        while j > 0 and score[j - 1] == score[i]:
            j -= 1
        run_end[j:i + 1] = i
        i = j - 1

    for t in range(S.MIN_BARS, n):
        end = run_end[t]
        y[t] = 1.0 if (end - t) >= n_horizon else 0.0
    return y


# ----------------------------------------------------------------------
#  logistic regression (IRLS, ridge) - no sklearn in this sandbox
# ----------------------------------------------------------------------
def fit_logit(X, y, l2=1.0, iters=40):
    n, d = X.shape
    Xb = np.hstack([np.ones((n, 1)), X])
    w = np.zeros(d + 1)
    R = l2 * np.eye(d + 1)
    R[0, 0] = 0.0
    for _ in range(iters):
        z = Xb @ w
        p = 1.0 / (1.0 + np.exp(-np.clip(z, -30, 30)))
        W = np.maximum(p * (1 - p), 1e-9)
        grad = Xb.T @ (p - y) + R @ w
        H = (Xb * W[:, None]).T @ Xb + R
        try:
            step = np.linalg.solve(H, grad)
        except np.linalg.LinAlgError:
            break
        w -= step
        if np.max(np.abs(step)) < 1e-8:
            break
    return w


def predict(w, X):
    Xb = np.hstack([np.ones((len(X), 1)), X])
    return 1.0 / (1.0 + np.exp(-np.clip(Xb @ w, -30, 30)))


def auc(y, p):
    order = np.argsort(p)
    ranks = np.empty_like(order, dtype=float)
    ranks[order] = np.arange(1, len(p) + 1)
    pos = y == 1
    n1 = pos.sum()
    n0 = len(y) - n1
    if n1 == 0 or n0 == 0:
        return float("nan")
    return (ranks[pos].sum() - n1 * (n1 + 1) / 2) / (n1 * n0)


def logloss(y, p):
    p = np.clip(p, 1e-9, 1 - 1e-9)
    return -np.mean(y * np.log(p) + (1 - y) * np.log(1 - p))


def main():
    global N_BARS, TARGET
    d = sys.argv[1] if len(sys.argv) > 1 else "/tmp/data"
    if len(sys.argv) > 2:
        N_BARS = int(sys.argv[2])
    if len(sys.argv) > 3:
        TARGET = sys.argv[3]
    files = sorted(p for p in glob.glob(os.path.join(d, "*.feather"))
                   if "UNITTEST" not in p)
    new = [p for p in files if any(k in p for k in ("BTC_USDT", "XRP_USDT"))]
    old = [p for p in files if p not in new]

    print(f"{len(files)} pairs; {len(old)} from 2018, {len(new)} from 2025\n")

    def gather(paths):
        rows = []
        for p in paths:
            r = build(p)
            if r is None:
                continue
            score, feats, c = r
            if TARGET == "signal":
                score = np.where(score >= 2, 1, np.where(score <= -2, -1, 0))
            y = make_events(score, N_BARS)
            ok = ~np.isnan(y)
            cols = [feats[k][ok] for k in feats]
            rows.append((np.column_stack(cols), y[ok], score[ok],
                         os.path.basename(p).replace("-5m.feather", "")))
        if not rows:
            return None, None, None
        X = np.vstack([r[0] for r in rows])
        y = np.concatenate([r[1] for r in rows])
        sc = np.concatenate([r[2] for r in rows])
        return X, y, sc

    Xo, yo, sco = gather(old)
    Xn, yn, scn = gather(new)
    names = ["age", "abs_score", "rsi", "adx", "atr_ratio", "bb_width",
             "stoch", "cci", "macd"]

    print(f"event: {TARGET} run lasts at least {N_BARS} more bars")
    print(f"  base rate 2018: {100*yo.mean():.1f}%   "
          f"2025: {100*yn.mean():.1f}%   n={len(yo)}/{len(yn)}\n")

    # ---- does the score value itself change persistence? ----
    print(f"persistence by {TARGET}, pooled:")
    for k in range(-3, 4):
        sel = scn == k
        if sel.sum() > 100:
            print(f"  {TARGET} {k:+d} : {100*yn[sel].mean():5.1f}%   n={sel.sum()}")
    print()

    # ---- does age already explain it? (the honest baseline) ----
    print("persistence by age of the current run, pooled:")
    for lo, hi in ((1, 1), (2, 3), (4, 6), (7, 10), (11, 20), (21, 999)):
        sel = (Xo[:, names.index("age")] >= lo) & (Xo[:, names.index("age")] <= hi)
        if sel.sum() > 100:
            print(f"  age {lo:>2}-{hi if hi < 999 else '+':>3} : {100*yo[sel].mean():5.1f}%   n={sel.sum()}")

    # ---- in-sample: do indicators add anything on top of age? ----
    print("\nmodel comparison (trained 2018, tested 2025):")
    for label, cols in (("age + score only", ["age", "abs_score"]),
                        ("+ conventional indicators", names)):
        idx = [names.index(c) for c in cols]
        mu, sd = Xo[:, idx].mean(0), Xo[:, idx].std(0) + 1e-12
        Xtr = (Xo[:, idx] - mu) / sd
        Xte = (Xn[:, idx] - mu) / sd
        w = fit_logit(Xtr, yo)
        ptr = predict(w, Xtr)
        pte = predict(w, Xte)
        print(f"  {label:<28} test AUC {auc(yn, pte):.4f}   "
              f"logloss {logloss(yn, pte):.4f}   (train AUC {auc(yo, ptr):.4f})")

    print("\nfeature weights from the full model (standardised, 2018 train):")
    idx = list(range(len(names)))
    mu, sd = Xo.mean(0), Xo.std(0) + 1e-12
    w = fit_logit((Xo - mu) / sd, yo)
    for nm, ww in sorted(zip(names, w[1:]), key=lambda x: -abs(x[1])):
        print(f"  {nm:<12} {ww:+.3f}")


if __name__ == "__main__":
    main()
