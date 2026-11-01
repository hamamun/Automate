# Automate — stage 4: plans, and the orders that follow them

`Automate.mq5` is the EA planned in [automate.md](automate.md), built in stages. Where the
two disagree, [autotrade.md](autotrade.md) is the later decision.

**It plans a trade per lane, and sends it when it is allowed to.** Each lane works out an
entry, a stop, a target and a size from its own bars, and the panel prints the plan and the
order separately. A resting limit is repriced when the structure moves and cancelled when
the plan dies. An open position is never touched: its stop and target sit at the broker.

Eight switches, and nothing else:

| Input | Default | What it does |
|---|---|---|
| `Autotrading (master switch)` | on | the one switch that has to be on for any order to be sent |
| `Allow M5 autotrade` | on | that lane may place, reprice and cancel |
| `Allow M15 autotrade` | on | same, M15 |
| `Allow M30 autotrade` | on | same, M30 |
| `Trailstop enable` | on | declared; the trail engine is not built yet |
| `Diary details` | off | opens a second panel |
| `Tweak` | off | arms one bounded self-tweak (nothing to tweak yet) |
| `Minimum lot` | off | clamps a size up to the broker's smallest instead of refusing the trade |

The inputs say what the EA *may* do. The terminal has its own veto: with MT5's Algo Trading
button off, nothing can be sent and the panel says `Autotrading: ON - terminal is blocking
it` in red instead of failing quietly. Attaching the EA sends nothing either: the first
order waits for one closed bar of that lane. No indicator period, band or threshold is ever
an input.

## The diary

Every signal run is checked once, three bars later, and the result is written to one file
per account and symbol. Trend and regime runs are checked when they end. A filled trade is
graded when it closes. The diary only ever watches: it sends nothing, and nothing it
stores is read back by the signal engine.

```
 Diary   today   S2/S1/S0       W1/W0/W0       L0/W1/W0
         all     S38/S31/S12    W4/W2/W1       L1/W3/W0
 Health: saved | Tweak: off
```

| Column | Means |
|---|---|
| `S` | signal runs the diary has checked |
| `W` | filled trades that closed **in profit**, after swap and commission |
| `L` | filled trades that closed **at a loss**, after swap and commission |

`W` and `L` are counted on the lane that placed the trade, and they are read back from the
file at attach, so they survive a restart. A trade that closed exactly flat is written down
but counted as neither.

Each graded trade is one line in the file:

```
2026.11.01 14:35,M5,TRADE,123456789,BUY,0.02,2.14,1
```

time, lane, `TRADE`, position ticket, side, lot, net money, won. The money is the sum of
profit, swap and commission on every deal of that position, so it is what the account
actually gained or lost — not an estimate, and not the broker's floating figure.

| Stage | State | What it added |
|---|---|---|
| 1 | merged | symbol discovery, self-classification, self-configuration, market status, named sessions |
| 2 | merged | per-lane TREND, REGIME, SCORE and SIGNAL on M5 / M15 / M30, with a measured forward horizon on trend and regime |
| 3 | merged | one planned trade per lane — entry, stop, target and size — in its own table |
| 4 | **this build** | one master and three per-lane switches; the plan is sent, repriced and cancelled; a second table shows the order at the broker; every closed trade is graded into the diary |
| 5 | not started | trailing stop, TP1/TP2 |

Design decisions and the measurements behind them are recorded in
[autotrade.md](autotrade.md).

## Install

1. Copy `Automate.mq5` into `MQL5/Experts/`.
2. Compile it in MetaEditor (F7).
3. Attach it to any chart, on any timeframe.
4. To let it trade, turn MT5's Algo Trading button on as well; with it off the panel says
   the terminal is blocking, and nothing is sent.

## The panel

```text
 AUTOMATE    XAUUSDm  |  Metal  |  Hedging
 MARKET OPEN | Session: London | Spread: 240.0 pts

 AUTOMATE    XAUUSDm  |  Metal  |  Hedging
 MARKET OPEN | Session: London | Spread: 240.0 pts

 TF     TREND         REGIME          SCORE  SIGNAL
 M5     UP 6/30%L     Steady 12/45%L  3/3    BUY 24%
 M15    FLAT 9/88%L   Mixed 40/62%L   2/3    NO SIGNAL
 M30    DOWN 14/35%L  Choppy 3/12%L   1/3    NO SIGNAL

 TF   DIR  ENTRY    LOT   TP               SL               STATE
 M5   BUY  2461.35  0.02  2467.10  (575)   2458.90  (245)   PLAN
 M15  SELL 2460.00  0.01  2471.20  (1120)  2455.40  (460)   PLAN
 M30  --   --       --    --               --               --

 Open Trade  (USD)                               Autotrading: OFF
 M5   Open BUY   Entry 2461.35     Lot 0.02    P/L     +2.14
      Bid 2461.10     Ask 2461.30     To TP 575 pts
      TP 2467.10  (+11.50)   SL 2458.90  (-4.90)   TP1 --  TP2 --
 M15  Limit SELL Entry 2462.40     Lot 0.01    P/L        --
      Bid 2461.10     Ask 2461.30     To Entry 110 pts
      TP 2471.20  (+8.80)    SL 2455.40  (-7.00)   TP1 --  TP2 --
 M30  --

 Diary   today   S2/S1/S0       W1/W0/W0       L0/W1/W0
         all     S38/S31/S12    W4/W2/W1       L1/W3/W0
 Health: saved | Tweak: off
```

Every line starts with one space. After it, the lane table puts TF / TREND / REGIME / SCORE
/ SIGNAL at characters **2, 9, 23, 39 and 46**; the plan table puts TF / DIR / ENTRY / LOT
/ TP / SL / STATE at **2, 7, 12, 21, 27, 44 and 61**; and the `Open Trade` group keeps the
same lines under each lane while an order exists. The Autotrading status sits at the right
edge of that group's heading. The panel sizes itself to the text it actually draws; there
are no X/Y/width/font inputs.

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

**A row can read UP and Choppy at once.** `TREND` is the last 30 bars; `REGIME` is the last
24 hours. A market that rallied all morning after a flat night is `UP` on the trend and
`Choppy` on the day, and both are true. The hover says the reading — the net move in
standard deviations against the two thresholds — so a `Choppy` row explains why it is not
`Steady`.

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

## The plan table

One row per lane, three rows always, dashes when a lane has nothing to do. This table is
what the signal **wants** on the bar that just closed. It is not the order; the order has
its own table below.

| Cell | Means |
|---|---|
| `DIR` | the direction the signal is asking for |
| `ENTRY` | where the plan would enter — the market price at 3/3, the resting price of the limit at 2/3 |
| `LOT` | the size, rounded down |
| `TP` | the one target price, and its distance from the entry in points |
| `SL` | the stop price, and its distance from the entry in points |
| `STATE` | what the plan is |

| STATE | Means |
|---|---|
| `PLAN` | a complete plan exists on this bar |
| `HOLD` | a direction exists, but no usable plan — the reason is printed on the row |
| `--` | no BUY or SELL on this lane |

**The plan is rebuilt on every closed bar, on every lane**, whether or not that lane holds
an order. A lane can therefore show `HOLD` while an older position still runs: the plan
moved on, the position did not. Neither of those closes or alters the position.

The order that actually exists is in the next table, where it can be `Open` or `Limit`.

**HOLD is a refusal, not a failure.** The plan is thrown away and named, rather than filled
in with a guess. The reason is printed on the row itself, where the numbers would have
been — and repeated in the Experts log when it changes:

```
 TF   DIR  ENTRY    LOT   TP               SL               STATE
 M15  BUY  no plan: no swing to hide the stop behind        HOLD
```

The reasons it can give:

| Reason | Why |
|---|---|
| `market closed` | the market is not simply open, so no plan is built at all |
| `no price grid` | the symbol reports no tick size or point, so nothing can be priced |
| `no live quote` | Ask or Bid is missing, so there is no price to build on |
| `spread too wide` | the spread is past the gate, so the round trip costs too much |
| `structure needs more history` | too few closed bars to read swings |
| `no swing to rest the limit on` | a 2/3 limit needs a confirmed swing on its own side |
| `no swing to hide the stop behind` | every trade needs confirmed structure behind its stop |
| `stop on the wrong side` | the structure found is on the wrong side of the entry |
| `stop inside the broker minimum` | the broker would reject a stop that close |
| `not enough history to measure a target` | too few closed bars on this timeframe to replay one |
| `too few like this to measure a target` | fewer than 30 replays found a stop to measure from |
| `measured target too small` | the median replay was stopped before it moved this way at all |
| `target on the wrong side` | the opposing swing is behind the entry |
| `target does not clear the spread` | the target would not pay for the round trip |
| `target inside the broker minimum` | the broker would reject a target that close |
| `risk budget below the minimum lot` | 0.5 % of equity cannot buy the smallest size |
| `margin cannot be calculated` | the broker would not return a margin requirement |
| `not enough free margin` | the broker would refuse the order |

## The order at the broker

A second table sits directly under the plan, same three lanes, same order. A lane with
nothing at the broker is one line of dashes; a lane that holds something gets three:

| Line | Shows |
|---|---|
| 1 | `Open BUY` or `Limit SELL`, the entry, the lot, and the live P/L (profit plus swap, in the account currency; commission is not included) |
| 2 | the broker's Bid and Ask, and the distance in points to the target — or to the entry while the limit rests |
| 3 | the target and the stop with what each is worth at this size if it is reached, then `TP1 --  TP2 --` |

The money in brackets on line 3 is the value **if that price is reached**. `TP1 --  TP2 --`
stays empty because this build has one target only.

### What the EA does with an order

Decisions that need the plan happen on a **closed bar**; a resting limit is also watched
**once a second**, because three of its reasons to die can happen between bars:

| Situation | Checked | What the EA does |
|---|---|---|
| The EA has just been attached | bar | the plan is shown, nothing is sent; the first send waits for one closed bar |
| A lane is allowed and flat, the plan is valid | bar | send it — a market order at 3/3, a limit at 2/3 |
| The limit rests and the structure moves | bar | **modify** it to the new entry, stop and target |
| The plan dies — `HOLD`, a flip, no signal, or the trend gate | bar | **cancel** the limit |
| The plan upgrades to 3/3 while a limit rests | bar | **cancel only**; a market order may go on a later bar, never the same one |
| The lane, or the master switch, is turned off | **second** | cancel that lane's resting limit at once |
| The limit reaches 3 × its timeframe (M5 15 min, M15 45, M30 90) | **second** | **cancel** — it gives up on the clock, not at the next bar |
| The market walks through the price it rests at | **second** | **cancel** — it is no longer a limit order in any useful sense |
| A position is open | — | **nothing.** Its stop and target are held at the broker |
| A fill or a close happens | second | adopted, so the table does not wait for the bar |

The once-a-second watch touches a resting limit and nothing else. It never sends, never
reprices, and never looks at an open position; it also does nothing at all while the market
is closed or the quote is stale.

Repricing is a modify and not a cancel-and-send because a modify cannot partly fill. A
cancel is never trusted on the first reply: the lane is only cleared once the broker
confirms the order is gone, and a cancel that is not confirmed is simply tried again on the
next second.

### One idea at a time, and when it is released

A lane will not buy the same direction on the same trend twice in a row. It remembers the
trend and the signal it traded, and stays quiet while both are unchanged — otherwise it
would re-enter on every bar for as long as the signal lasted.

**A winning close releases that hold.** If a trade closed in profit — the target, or any
close that left money after swap and commission — the lane is free again. The trend and the
signal are still standing, the plan still builds, and the **next closed bar** places a fresh
order if every gate passes. The release is decided where the money is read, from the
position's own deals, so it cannot be fooled by a floating figure a second before the close.

**A losing close does not.** A stop-out keeps the idea spent, so the lane does not buy the
level it was just wrong about. It waits for the signal or the trend to change.

Being right about direction and still losing to costs counts as a loss here, because that is
what the account did.

The trade is closed, so the release is noticed within a second, but the re-entry itself is
still a bar-close decision: a new order at the first second of the next bar.

### Autotrading status

The heading of that table ends with one of three states:

| Reads | Means |
|---|---|
| `Autotrading: OFF` | the master switch is off: no new order anywhere, resting limits cancelled, open positions left alone |
| `Autotrading: ON` | orders may be sent on the lanes that are allowed |
| `Autotrading: ON - terminal is blocking it` | the switch is on but MT5 will not let an expert send; turn on Algo Trading |

Turning one lane off cancels that lane's resting limit and stops it placing anything new.
It does **not** touch a position that lane already holds.

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
Automate stage 4 - plans and autotrade on XAUUSDm PERIOD_M5
  description : Gold vs US Dollar
  path        : Metals\XAUUSDm
  ...
  M5   trend UP 6 bars left (30%), age 14 | regime Steady 12 bars left (45%),
       age 22 | z=2.31 slope 0.284 | votes 1 1 1 score 3 BUY
  M30  trend DOWN 21 bars left (35%), age 39 | regime Choppy 3 bars left (12%),
       age 28 | z=-0.42 slope -0.211 | votes -1 0 0 score -1 NO SIGNAL
  Ehlers vs slope: 812 agree, 96 disagree (89.4% agree) over 908 closed bars
```

Printed at attach, hourly, and the moment a lane first comes alive. The plan is **not**
logged - it lives on the chart, in the plan table, because it changes with every new bar
and a log that repeated it would bury the discovery dump. Orders are logged, one line each:
what was sent, repriced or cancelled, with the prices.

## Before compiling

```bash
python3 tools/preflight.py Automate.mq5
```

Checks unbalanced braces and parentheses, duplicate file-scope declarations, duplicate
functions, unresolved calls, argument counts, invalid struct fields, stray `input` lines,
unused functions, non-ASCII text, whether every scan of the terminal's orders and positions
compares the symbol, whether the once-a-second path still only cancels limits, and whether
any global or `#define` is used above the line that declares it (MQL5 has no hoisting, and
the compiler blames the use rather than the cause). It does not replace MetaEditor — it only
makes the cheap mistakes visible before you compile.

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
- Both trade tables keep three rows and the panel width never jumps as states change.
- The plan table reads `PLAN` where a plan builds, `HOLD` where it cannot, and `--` where
  there is no signal.
- `HOLD` prints its reason on the row and never shows a made-up price.
- The `Open Trade` heading carries `Autotrading:` in dim grey, lime or red, and red only
  when the master switch is on and MT5's Algo Trading is off.
- With a lane switched off, its row in `Open Trade` is dashes and its resting limit is
  gone; a position it already held keeps running.
- Close a trade — let the stop or the target take it — and within a second the diary's `W`
  or `L` on that lane moves by one, and the Experts tab prints
  `Diary: M5 BUY 0.02 closed, net +2.14`.
- The diary's `Health:` line reads `saved`. `last write failed` or `off` in red means the
  file is not being written.
- Switch a lane off while a limit is resting: the `Open Trade` row goes to dashes within a
  second, not at the next bar, and the Experts tab says `waiting order cancelled`.

In the **Experts** tab:

- Lanes report `DATA WAIT - history not loaded yet` on a symbol with shallow history,
  rather than reading a regime from half a window.
- The `Ehlers vs slope` agreement figure. **Near 50 % is expected and is the point** — that
  number is the evidence that the bandpass does not track direction. Much higher reopens
  the design decision.

## Limits, stated honestly

- **One order per lane, and only the EA's own.** Orders carry a magic number per lane, so
  a manual trade on the same symbol is invisible to it and is never modified or closed.
- **One chart per symbol.** The EA matches its orders by magic *and* by symbol; two charts
  on the same symbol would share magic numbers and each would see the other's trade. The
  diary's exclusive file lock refuses the second one (`Health: off`), but the chart still
  runs — run this EA on one chart per symbol.
- **A resting limit can be repriced; a position cannot.** The stop and target go to the
  broker with the order, and an open position is left exactly as the broker holds it.
- **A cancel is retried, not assumed.** The lane clears only after the broker confirms the
  order is gone; until then the panel keeps showing it.
- **One target, no partial closes.** TP1/TP2 belong to the trailing stop. The broker gets
  entry, stop and target in a single request.
- **A plan never invents a price.** If the structure a stop needs is not there, the lane
  reads `HOLD` and says why. The same goes for a target the replay cannot measure: a refusal
  that names its reason, never an estimate.
- **The same size for 2/3 and 3/3.** Score predicts how far price travels, not which way:
  median `|move|` measured 0.633 bars at 2/3 against 0.840 at 3/3. A stronger score does
  not earn a bigger position.
- **The target is a median, not a promise.** 400 replayed bars, at least 30 cases of the
  same setup, 50th percentile, then capped before the opposing swing. When that median
  comes back at **zero** - the replay was stopped before it moved this way even once - the
  lane reads `HOLD` and says `measured target too small`, rather than putting a target on
  the entry and calling it a plan. On a quiet lane that is the usual reason a 3/3 shows no
  plan, and it is a measurement that ran and refused, not missing history.
- **`W` and `L` are money, not prices.** A trade is a win when the position closed with
  more money than it opened with, after swap and commission. Being right about direction
  and still losing to costs counts as a loss, because that is what the account did.
- **A trade closed while the EA was not running is not graded.** The grade is taken when
  the EA sees its position disappear; if the chart was closed or the terminal was off at
  that moment, the line is never written and the counts do not move. Graded lines in the
  file are read back at attach, so what has already been written is never lost — and a
  trade is never counted twice.
- **Break-even is neither a win nor a loss.** A position that closed exactly flat is
  written down and left out of both counts.
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

The trailing stop — the `Trailstop enable` switch is already there, with nothing behind it
yet — and with it TP1/TP2 and partial closes. The self-tweak stays declared and empty.
