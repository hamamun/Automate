#!/usr/bin/env python3
"""
Which regime measure actually works on real candles?

The shipped measure is z = net move / (sd of bar changes * sqrt(span)),
with fixed cuts at 2.0 and 1.0. On real data z never gets that far, so
the panel reads Choppy almost always.

This script compares candidates on the same candles and, more to the
point, checks whether the labels mean anything: does "Steady" predict a
stronger forward move than "Choppy"?

    python3 tools/regime_compare.py <dir-with-*.feather>

Analysis only. Nothing here changes the EA.
"""

import glob
import math
import os
import sys

import numpy as np
import pyarrow.feather as f

Z_STEADY = 2.0
Z_MIXED = 1.0
CAL_WINDOW = 500          # bars of z history used to learn this symbol's scale


def drift_z(c, span):
    n = len(c)
    out = np.full(n, np.nan)
    d = np.diff(c, prepend=c[0])
    S1 = np.concatenate(([0.0], np.cumsum(d)))
    S2 = np.concatenate(([0.0], np.cumsum(d * d)))
    for e in range(span, n):
        b = e - span
        s1 = S1[e + 1] - S1[b]
        s2 = S2[e + 1] - S2[b]
        mean = s1 / span
        var = (s2 - span * mean * mean) / (span - 1)
        if var > 0:
            out[e] = (c[e] - c[b]) / (math.sqrt(var) * math.sqrt(span))
    return out


def rolling_scale(z, w):
    """Robust spread of z over the last w bars - this symbol's own size of z."""
    n = len(z)
    out = np.full(n, np.nan)
    for e in range(w, n):
        win = z[e - w + 1:e + 1]
        win = win[~np.isnan(win)]
        if len(win) < w // 2:
            continue
        mad = np.median(np.abs(win - np.median(win)))
        out[e] = mad / 0.6745 if mad > 0 else np.nan
    return out


def labels(score, hi, lo):
    """0 = Steady, 1 = Mixed, 2 = Choppy, from |score| against two cuts."""
    a = np.abs(score)
    return np.where(a >= hi, 0, np.where(a >= lo, 1, 2))


def report(name, lab, close, span, start, horizon):
    """Judge a label by signed continuation, not by how far price travels.

    direction = sign of the drift z at that bar. continuation = forward move
    x direction, in units of typical noise over the horizon. A label that
    means something should show Steady > Choppy here.
    """
    lab = lab[start:].astype(int)
    px = close[start:]
    n = len(lab)
    dist = [100 * np.mean(lab == k) for k in (0, 1, 2)]
    scale = np.median(np.abs(np.diff(close))) * math.sqrt(horizon)

    out = []
    for k in (0, 1, 2):
        idx = np.where(lab == k)[0]
        idx = idx[(idx + horizon) < n]
        if len(idx) < 50:
            out.append("   -   ")
            continue
        d = np.sign(close[start + idx] - close[start + idx - span])
        move = (px[idx + horizon] - px[idx]) * d / scale
        hit = 100 * np.mean(move[d != 0] > 0)
        med = float(np.median(move[d != 0]))
        out.append(f"{med:+.2f}/{hit:4.0f}%")
    print(f"  {name:<26} Steady {dist[0]:5.1f}%  Mixed {dist[1]:5.1f}%  "
          f"Choppy {dist[2]:5.1f}%   " + "  ".join(out))


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else "/tmp/data"
    files = sorted(p for p in glob.glob(os.path.join(d, "*.feather"))
                   if "UNITTEST" not in p)

    spans = {}
    for path in files:
        t = f.read_table(path).to_pydict()
        c = np.asarray(t["close"], float)
        if len(c) < 1700:
            continue
        spans[os.path.basename(path).replace("-5m.feather", "")] = c

    print(f"{len(spans)} pairs\n")
    print("legend: the three groups are Steady / Mixed / Choppy, each shown as")
    print("  median signed continuation in noise-units / hit rate %.")
    print("  A label that works shows Steady clearly above Choppy.\n")

    for pair, c in list(spans.items()):
        span = 1536
        z = drift_z(c, span)
        start = span + 50
        print(f"{pair}  (z sd {np.nanstd(z[start:]):.2f})")
        H = 288   # 24 hours forward
        report("A. fixed cuts 2.0 / 1.0", labels(z, Z_STEADY, Z_MIXED), c, span, start, H)

        scale = rolling_scale(z, CAL_WINDOW)
        zn = z / scale
        ok = ~np.isnan(zn)
        first = max(start, int(np.argmax(ok)))
        report("B. own-scale cuts 2.0 / 1.0", labels(zn, Z_STEADY, Z_MIXED), c, span, first, H)

        q = np.nanquantile(np.abs(z[start:]), [0.75, 0.95])
        report(f"C. own quantiles {q[0]:.2f}/{q[1]:.2f}",
               labels(z, q[1], q[0]), c, span, start, H)
        print()


if __name__ == "__main__":
    main()
