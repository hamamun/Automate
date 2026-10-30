# Automate — stage 2: discovery, market status and the signal engine

`Automate.mq5` is the EA described in [automate.md](automate.md), built in stages.
**It still cannot trade.** No orders, no positions, no stops, no lot size, no diary — the
panel says `SIGNAL ONLY` so this can never be mistaken for a trading build.

There are **no inputs**. Attach it and it works everything out on its own.

| Stage | State | What it added |
|---|---|---|
| 1 | merged | symbol discovery, self-classification, self-configuration, market status, named sessions |
| 2 | **this build** | per-lane TREND, AGE, REGIME, SCORE and SIGNAL on M5 / M15 / M30 |
| 3 | not started | entries, stops, targets, lot size, execution, diary |

Design decisions and the measurements behind them are recorded in
[autotrade.md](autotrade.md).

## Install

1. Copy `Automate.mq5` into `MQL5/Experts/`.
2. Compile it in MetaEditor (F7).
3. Attach it to any chart, on any timeframe.
4. MT5's Algo Trading button is not needed — nothing is sent to the broker.

## The panel

```text
 AUTOMATE    XAUUSDm  |  Metal  |  Hedging
 MARKET OPEN | Session: London | Spread: 240.0 pts

 TF     TREND  AGE    REGIME   SCORE  SIGNAL    TRADE STATUS
 M5     UP     6/11   Steady   3/3    BUY       SIGNAL ONLY
 M15    UP     2/11   Mixed    2/3    BUY       SIGNAL ONLY
 M30    DOWN   14/11  Choppy   1/3    NO SIGNAL SIGNAL ONLY

 Selected:                    Entry:
 SL:                          TP:
 Entry timing:                TP estimate:
 Size:                         Planned risk:
 Combined exposure:
 Diary:                        Unknown future costs:
```

Columns are fixed at characters **1, 8, 15, 22, 31, 38 and 48**. The panel sizes itself to
the text it actually draws; there are no X/Y/width/font inputs.

## Reading the five columns

### TREND — which way, and how strongly

UP / DOWN / FLAT. Measured as the least-squares slope of the last 30 closed bars, divided
by the median size of one bar. That division is why one internal constant works on gold at
3 500 and EURUSD at 1.08 — the answer is always "how many ordinary bars per bar is this
moving".

`FLAT` is a real answer, not a missing one. On a driftless market the vote is FLAT roughly
half the time, because on a random walk there usually is no trend to report.

### AGE — how long the current trend has lasted

Two numbers in bars: **this run / typical run**.

| Cell | Meaning |
|---|---|
| `6/11` | 6 bars old; past trends on this lane usually lasted 11 — still young |
| `14/11` | 14 bars old, past ones lasted 11 — overdue |
| `1/-` | one bar old; no finished runs yet to compare against |

The median is measured from that symbol's own history on that timeframe, so it adapts by
itself. At attach the EA replays the vote over 400 already-closed bars to seed this, so the
median is meaningful from the first second instead of after a day.

This is the honest answer to *"how long will this last"*: how long it has lasted, against
how long it usually does. There is **no** predicted bar number — see the limits below.

### REGIME — what kind of market, on a like-for-like span

`Steady` / `Mixed` / `Choppy`, from the standardised net move over **128 hours**:

```
z = (close now - close 128h ago) / (sd of bar changes x sqrt(bars in 128h))
Steady if |z| >= 2.0    Mixed if |z| >= 1.0    Choppy otherwise
```

`z` is `N(0,1)` for a driftless series at *any* window length, which is the only reason the
three lanes can be compared: M5 reads 1 536 bars, M15 reads 512, M30 reads 256, all the
same 128 hours. Measured, the three agree 94.5 % of the time on one series. Persistent
disagreement on a live chart is a bug, not a market condition.

**Regime never blocks a signal.** A valid BUY in Choppy is still shown as BUY.

### SCORE — agreement, never a probability

Three independent measurements, each `+1 / 0 / -1`:

| Vote | Measures |
|---|---|
| trend | regression slope over 30 bars |
| momentum | 2-bar close change |
| structure | 20-bar net move, withdrawn if swing lows are making lower lows |

`3/3` … `0/3` is the size of the sum, so it says **how many of the three agree**, not how
likely anything is. The votes are never multiplied: keeping them separate is what makes
`2/3` a real, recurring state instead of a binary.

`SIGNAL` is `BUY` at `>= 2`, `SELL` at `<= -2`, otherwise `NO SIGNAL`.

### TRADE STATUS — two possible values

| Value | Meaning |
|---|---|
| `SIGNAL ONLY` | the lane is working; **no order is placed** |
| `DATA WAIT` | not enough closed bars on that timeframe yet |

`ORDER PLACED` / `PENDING` / `BLOCKED` belong to stage 3, when something can actually be
sent. Until then this column exists to say plainly that nothing is.

## What it also does (carried over from stage 1)

**Discovery.** Reads the symbol exactly as the broker names it, plus description, folder
path, currencies, calc mode, digits, point, tick size and value, volume limits, stop and
freeze levels, account currency and margin mode.

**Classification.** Decides forex / metal / index / energy / crypto / stock / other from
several independent hints that must agree — name, path, currencies, calc mode, description,
sector. The label is cross-checked against the real price; when the evidence is weak the
panel says `Other/Unknown` or `… (unconfirmed)` and uses the general profile.

**Hour adjustment.** Measures typical bar movement for each of the 24 broker-server hours
and compares the current hour with recent behaviour:

| Current hour vs recent | Adjustment |
|---|---|
| below 60 % (thin) | +2 buffer ticks, spread gate × 1.25 |
| 60–140 % (typical) | base profile |
| above 140 % (fast) | spread gate × 1.10 |

**Market status**, from the broker's own session table, read per weekday with multiple
sessions and midnight crossings:

| Shown | Meaning |
|---|---|
| `MARKET OPEN` | inside a published session, quote is fresh |
| `MARKET CLOSED` | outside the table, with next open time and countdown |
| `OPEN - STALE QUOTE` | inside a session but no fresh quote |
| `DISCONNECTED` | terminal is not connected |
| `TRADING UNAVAILABLE` | the broker disabled the symbol |
| `MARKET STATUS UNKNOWN` | no session table published and the quote is old |

**Named sessions.** Tokyo 09:00–18:00, London 08:00–17:00, New York 08:00–17:00 in local
time with EU and US daylight-saving rules. In the Strategy Tester real UTC cannot be known,
so the line reads `Session: unknown` rather than inventing a label.

## Experts log

The panel shows the layout; the numbers behind it go to the **Experts** tab:

```
Automate stage 2 - signal engine on XAUUSDm PERIOD_M5
  description : Gold vs US Dollar
  path        : Metals\XAUUSDm
  ...
  M5   trend UP 6/11, regime Steady 22/38, z=2.31, slope ratio 0.284,
       votes 1 1 1, score 3, BUY
  M30  trend DOWN 14/11, regime Choppy 5/38, z=-0.42, slope ratio -0.211,
       votes -1 0 0, score -1, NO SIGNAL
  Ehlers vs slope: 812 agree, 96 disagree (89.4% agree) over 908 closed bars
```

Printed at attach, hourly, and the moment a lane first comes alive.

## Before compiling

```bash
python3 tools/preflight.py Automate.mq5
```

Checks unbalanced braces and parentheses, duplicate file-scope declarations, duplicate
functions, unresolved calls, argument counts, invalid struct fields, stray `input` lines,
unused functions and non-ASCII text. It does not replace MetaEditor — it only makes the
cheap mistakes visible before you compile.

## What to check while testing

On the chart:

- `TREND` on all three lanes is not permanently `FLAT`.
- `AGE` shows a real median (`6/11`), not `1/-` forever. It should be populated at once.
- `SCORE` shows values other than `3/3` — if every row is always `3/3`, two votes are
  copies of each other and the score is meaningless.
- `SIGNAL` shows `NO SIGNAL` reasonably often. A panel that always says BUY is broken.
- `REGIME` agrees across M5 / M15 / M30 most of the time.
- `TRADE STATUS` reads `SIGNAL ONLY` on all three lanes.

In the **Experts** tab:

- Lanes report `DATA WAIT - history not loaded yet` on a symbol with shallow history,
  rather than reading a regime from half a window.
- The `Ehlers vs slope` agreement figure. **Near 50 % is expected and is the point** — that
  number is the evidence that the bandpass does not track direction. Much higher reopens
  the design decision.

## Limits, stated honestly

- **No trading.** This build cannot place, modify or close anything.
- **No predicted switch bar.** There is no reliable estimator of *when* a trend or regime
  changes. First-passage time, OU half-life, Markov dwell and Ehlers cycle all return a
  *duration*, never a date — and with no drift the expected first-passage time is literally
  infinite. AGE is what was built instead, and it says so.
- **No forward price projection.** The Kalman predict step would have given one; it was
  dropped when the filter was. Nothing is claimed in its place.
- **Direction has no measured edge.** `SimpleEA`'s own harness found pure direction is a
  coin flip (48–52 % on liquid FX), and the same test reproduced that here: the Ehlers
  bandpass scores 49.7–51.3 % against the next 20 bars. The score is an agreement count,
  not a probability and not a performance claim.
- **The Ehlers bandpass is still in the file but is not a vote.** Its sign is counted
  against the trend vote and logged, so the claim above can be checked on your broker's
  data instead of mine.
- **AGE history is in memory only.** It is rebuilt by replay at every attach; nothing is
  written to disk. Restarting the terminal restarts the learning.
- **Minimum history per lane.** The terminal must hold **1 939** closed M5 bars, **915** M15
  or **852** M30, because the 128-hour regime span and the 400-bar AGE replay must both fit.
  A lane short of that reports `DATA WAIT` and keeps retrying.
- The session table is the broker's, so a holiday can still read `MARKET OPEN` until the
  quote goes stale.
- Classification is a scoring heuristic over broker metadata; unusual names fall back to
  `Other/Unknown` by design.

## Next stage (not in this build)

Entries, stops, targets, lot size, execution and the diary. When they arrive,
`TRADE STATUS` gains `ORDER PLACED`, `PENDING` and `BLOCKED`, and `SIGNAL ONLY` remains only
where auto-trading is switched off for a lane.
