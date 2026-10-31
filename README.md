# Automate — stage 3: entry, stop, target and size

`Automate.mq5` is the EA planned in [automate.md](automate.md), built in stages. Where the
two disagree, [autotrade.md](autotrade.md) is the later decision.

**It plans trades and does not send them.** Each lane works out an entry, a stop, a target
and a size from its own bars, and the panel prints all four with the state `PLAN`. The
send sits behind a compile-time constant that is `false`, so nothing reaches the broker.

Three switches exist, all off by default and all safe to leave off: `Diary details` opens
a second panel, `Tweak` arms one bounded self-tweak (nothing to tweak yet), and
`Minimum lot` clamps a size up to the broker's smallest instead of refusing the trade. No
indicator period, band or threshold is ever an input.

## The diary

Every signal run is checked once, three bars later, and the result is written to one file
per account and symbol. Trend and regime runs are checked when they end. The diary only
ever watches: it sends nothing, and nothing it stores is read back by the signal engine.

```
 Diary   today   S2/S1/S0       W0/W0/W0       L0/W0/L0
         all     S38/S31/S12    W0/W0/W0       L0/W0/L0
 Health: no trades yet | Tweak: off
```

`S` counts signals and the counts are live. `W` and `L` mean **filled trades**, so they read
0: the diary grades signals today, and trade grading arrives with the trailing stop.

| Stage | State | What it added |
|---|---|---|
| 1 | merged | symbol discovery, self-classification, self-configuration, market status, named sessions |
| 2 | merged | per-lane TREND, REGIME, SCORE and SIGNAL on M5 / M15 / M30, with a measured forward horizon on trend and regime |
| 3 | **this build** | one planned trade per lane — entry, stop, target and size — in its own table; trading is off at compile time |
| 4 | not started | trailing stop, TP1/TP2, sending trades, grading filled trades in the diary |

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

 TF     TREND         REGIME          SCORE  SIGNAL
 M5     UP 6/30%L     Steady 12/45%L  3/3    BUY 24%
 M15    FLAT 9/88%L   Mixed 40/62%L   2/3    NO SIGNAL
 M30    DOWN 14/35%L  Choppy 3/12%L   1/3    NO SIGNAL

 TF   DIR  ENTRY    SL               TP               LOT   STATE
 M5   BUY  2461.35  2458.90  (245)   2467.10  (575)   0.02  PLAN
 M15  SELL 2460.00  2455.40  (460)   2471.20  (1120)  0.01  PLAN
 M30  --   --       --               --               --    --

 Diary   today   S2/S1/S0       W0/W0/W0       L0/W0/L0
         all     S38/S31/S12    W0/W0/W0       L0/W0/L0
 Health: no trades yet | Tweak: off
```

Every line starts with one space. After it, the lane table puts TF / TREND / REGIME / SCORE
/ SIGNAL at characters **2, 9, 23, 39 and 46**, and the trade table puts TF / DIR / ENTRY /
SL / TP / LOT / STATE at **2, 7, 12, 21, 38, 55 and 61**. The panel sizes itself to the
text it actually draws; there are no X/Y/width/font inputs.

## Reading the four measurements

### TREND — which way, and how much longer

`UP 6/30%L` reads three things:

| Part | Means |
|---|---|
| `UP` | the trend is up right now |
| `6` | about **6 more closed bars** from the last one — the forward horizon |
| `30%` | 30 % of the trend's whole life is still ahead |
| `L` | left — applies to both numbers above |

The two numbers are one estimate told twice. 6 bars left at 30 % means the trend's
whole life is about 20 bars, so it is already 14 bars old. They can never disagree.

**How it is measured.** The EA stores the length of every completed trend on that lane
— up to 200 of them — and asks a specific question:

> Of the past trends that already reached this age, how much longer did they run?

The median of those survivors is the bar count. That is why it changes as a trend ages:
a 2-bar-old trend and a 40-bar-old trend have different histories behind them.

**When there is no number.** Two different reasons, told apart on the panel:

| Cell | Means |
|---|---|
| `UP Max` | this trend has already run longer than any trend on record — there is nothing honest to predict |
| `UP` | too few past trends got this far yet — usually the first hours after attaching |

Both explain themselves on hover. `Max` is the interesting one: it means you are in
unusual territory, not that the EA is still warming up.

**Merged from AGE.** An older build had a separate AGE column showing `14/11`
(age / typical length). It was removed: the surviving-run figure above already contains
the age, so the AGE column was showing the same thing twice.

### REGIME — what kind of market, and how much longer

`Steady 12/45%L` — same two forward numbers, measured on regime runs instead of trend
runs. `Steady` / `Mixed` / `Choppy` come from the standardised net move over **24 hours**:

```
z = (close now - close 24h ago) / (sd of bar changes x sqrt(bars in 24h))
Steady if |z| >= 2.0    Mixed if |z| >= 1.0    Choppy otherwise
```

`z` is `N(0,1)` for a driftless series at *any* window length, which is the only reason
the three lanes can be compared: M5 reads 288 bars, M15 96, M30 48 — all the same
24 hours.

**Why 24 hours and not longer.** The first build used 128 hours. That is 1 536 bars on
M5, so one reading and the next are nearly the same number (autocorrelation 0.98+), and
the column read `Choppy` on every bar. Lengthening the window does not fix that — at any
span beyond a day, these markets genuinely do not drift. The variance ratio, the standard
random-walk test, sits at 0.04–0.36 on crypto pairs where 1.0 is a random walk. At 24
hours liquid pairs produce roughly 15 / 13 / 70 and the label actually moves.

**On a choppy instrument `Choppy` is the correct answer, not a fault.**

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

### SIGNAL — direction, and how long it is likely to stay

`BUY 24%` reads: BUY, and a **24 % chance this signal is still standing in 3 bars**.
No percentage means there is not enough history yet — you get plain `BUY` or `SELL`.

The number is counted from this symbol's own past signals, not from a fixed rule. It
rises as a signal ages (roughly 17 % at one bar old, 30 % at five), because a signal that
has already lasted tends to keep lasting.

**Why there is no `L` on it.** In TREND and REGIME, `%L` means *share of life left*. Here
the percentage answers a different question — will it still be standing — so it is shown
as a plain percent, and the hover spells it out.

**What it does not mean.** It is not strength, and not a reason to trade. Measured on
real candles, the signal is no better at predicting direction when the number is high.
It tells you how long the label is likely to stay lit.

## The trade table

One row per lane, three rows always, dashes when a lane has nothing to do.

| Cell | Means |
|---|---|
| `ENTRY` | where the trade enters — the market price at 3/3, the resting price of the limit at 2/3 |
| `SL` | the stop price, and its distance from the entry in points |
| `TP` | the one target price, and its distance from the entry in points |
| `LOT` | the size, rounded down |
| `STATE` | what that lane is doing right now |

| STATE | Means |
|---|---|
| `PLAN` | a complete plan is ready; **nothing was sent** |
| `WAIT` | a limit order is resting at the broker |
| `OPEN` | a position is live, with its stop and target held at the broker |
| `HOLD` | a direction exists, but no valid plan — hover for the reason |
| `--` | no BUY or SELL on this lane |

In this build, a lane whose plan builds reads `PLAN`, because trading is off; a lane whose
plan cannot be built reads `HOLD`. The others appear the moment trading is turned on.

**HOLD is a refusal, not a failure.** The plan is thrown away and named, rather than filled
in with a guess. The reasons it can give:

| Reason | Why |
|---|---|
| `no live quote` | Ask or Bid is missing, so there is no price to build on |
| `spread too wide` | the spread is past the gate, so the round trip costs too much |
| `structure needs more history` | too few closed bars to read swings |
| `no swing to rest the limit on` | a 2/3 limit needs a confirmed swing on its own side |
| `no swing to hide the stop behind` | every trade needs confirmed structure behind its stop |
| `stop on the wrong side` | the structure found is on the wrong side of the entry |
| `stop too close to the spread` | the stop would not clear the cost of the round trip |
| `stop inside one normal bar` | the stop would sit inside ordinary noise |
| `stop inside the broker minimum` | the broker would reject a stop that close |
| `not enough history for a target` | fewer than 30 replays of this setup exist yet |
| `target on the wrong side` | the opposing swing is behind the entry |
| `target does not clear the spread` | the target would not pay for the round trip |
| `target inside the broker minimum` | the broker would reject a target that close |
| `risk budget below the minimum lot` | 0.5 % of equity cannot buy the smallest size |
| `not enough free margin` | the broker would refuse the order |

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
Automate stage 3 - plans and execution on XAUUSDm PERIOD_M5
  description : Gold vs US Dollar
  path        : Metals\XAUUSDm
  ...
  M5   trend UP 6 bars left (30%), age 14 | regime Steady 12 bars left (45%),
       age 22 | z=2.31 slope 0.284 | votes 1 1 1 score 3 BUY
  M30  trend DOWN 21 bars left (35%), age 39 | regime Choppy 3 bars left (12%),
       age 28 | z=-0.42 slope -0.211 | votes -1 0 0 score -1 NO SIGNAL
  Ehlers vs slope: 812 agree, 96 disagree (89.4% agree) over 908 closed bars
```

Printed at attach, hourly, and the moment a lane first comes alive. The trade plan is
**not** logged - it lives on the chart, in the trade table, because it changes with every
new bar and a log that repeated it would bury the discovery dump.

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
- `TREND` and `REGIME` show a forward number (`UP 6/30%L`), not a bare label. A bare label
  for hours means the run history did not seed at attach; `UP Max` is a real reading.
- Hovering a TREND or REGIME cell shows the plain-language explanation.
- `SCORE` shows values other than `3/3` — if every row is always `3/3`, two votes are
  copies of each other and the score is meaningless.
- `SIGNAL` shows `NO SIGNAL` reasonably often. A panel that always says BUY is broken.
- `REGIME` agrees across M5 / M15 / M30 most of the time.
- The trade table keeps three rows and the panel width never jumps as states change.
- `STATE` reads `PLAN` where a plan builds, `HOLD` where it cannot, and `--` where there is
  no signal.
- `HOLD` explains itself on hover and never shows a made-up price.

In the **Experts** tab:

- Lanes report `DATA WAIT - history not loaded yet` on a symbol with shallow history,
  rather than reading a regime from half a window.
- The `Ehlers vs slope` agreement figure. **Near 50 % is expected and is the point** — that
  number is the evidence that the bandpass does not track direction. Much higher reopens
  the design decision.

## Limits, stated honestly

- **Trading is off.** `TRADING_LIVE` is `false` in the source. Plans are still built, sized
  and shown; the gate sits immediately before the send, so no order can leave the terminal.
  Turning it on is one word and one recompile, deliberately not an input — it cannot be
  flipped on a chart by accident.
- **One target, no partial closes.** TP1/TP2 belong to the trailing stop. The broker gets
  entry, stop and target in a single request, and nothing is moved afterwards.
- **A plan never invents a price.** If the structure a stop needs is not there, the lane
  reads `HOLD` and says why. The same goes for a target with too little history: a refusal,
  never an estimate.
- **The same size for 2/3 and 3/3.** Score predicts how far price travels, not which way:
  median `|move|` measured 0.633 bars at 2/3 against 0.840 at 3/3. A stronger score does
  not earn a bigger position.
- **The target is a median, not a promise.** 400 replayed bars, at least 30 cases of the
  same setup, 50th percentile, then capped before the opposing swing.
- **`W` and `L` still read 0.** The diary grades signals today; filled trades are not
  graded yet, and nothing else is counted as a win or a loss.
- **No predicted switch bar.** `6/30%L` is a median remaining length from that lane's own
  history, never a date. First-passage time, OU half-life, Markov dwell and Ehlers cycle all
  return a *duration*, never a date — and with no drift the expected first-passage time is
  literally infinite.
- **The percent sits high for most of a run.** Measured over 26 728 bars: median 55 % left,
  only 4.9 % of bars below 20 %. It is a warning light near the end, not a countdown.
- **The answer is wide, not tight.** Run lengths are heavy-tailed, so the cell shows one
  number but the hover gives the interquartile range - often something like "18 to 96 more".
- **The signal percentage is about duration, not quality.** Median reading is 19 %,
  and it was calibrated on real candles: predicted 20.1 % against 18.4 % actual in one
  sample, 22.9 % against 24.4 % in another.
- **Some bars carry no number.** Coverage grows as history builds: about 70 % of bars in the
  first ~2 000, 85–92 % after that, and effectively 100 % once the 400-run history is full.
  A bare `UP` means not enough past runs got this far; `UP Max` means the run is longer than
  anything on record.
- **No forward price projection.** The Kalman predict step would have given one; it was
  dropped when the filter was. Nothing is claimed in its place.
- **Direction has no measured edge.** `SimpleEA`'s own harness found pure direction is a
  coin flip (48–52 % on liquid FX), and the same test reproduced that here: the Ehlers
  bandpass scores 49.7–51.3 % against the next 20 bars. The score is an agreement count,
  not a probability and not a performance claim.
- **The Ehlers bandpass is still in the file but is not a vote.** Its sign is counted
  against the trend vote and logged, so the claim above can be checked on your broker's
  data instead of mine.
- **Run history is in memory only.** It is rebuilt by replaying 800 closed bars at every
  attach, so the panel is populated immediately, but nothing is written to disk. The last
  400 completed runs per lane are kept; older ones are dropped.
- **Minimum history per lane.** The terminal must hold **1 089** closed M5 bars, **897** M15
  or **849** M30, because the 24-hour regime span and the 800-bar history replay must both
  fit. A lane short of that reports `DATA WAIT` and keeps retrying.
- The session table is the broker's, so a holiday can still read `MARKET OPEN` until the
  quote goes stale.
- Classification is a scoring heuristic over broker metadata; unusual names fall back to
  `Other/Unknown` by design.

## Next stage (not in this build)

The trailing stop, and with it TP1/TP2 and partial closes. Grading filled trades goes into
the diary at the same time, so `W` and `L` stop reading 0. Turning trading on stays a manual
edit of `TRADING_LIVE` followed by a recompile — never a switch on the chart.
