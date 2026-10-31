# Autotrade — stage 2 design record

**Status: design record, updated after measurement. Stage 2 is implemented.**

This file records the decisions taken while planning stage 2 (trend, regime, score,
signal) and the reasoning behind each one. It sits alongside `automate.md`, which remains
the original plan. Where this file differs from `automate.md`, this file is the later
decision and says why.

Stage 1 (discovery, self-configuration, market and session status) is built, merged and
verified in MetaEditor with 0 errors. Stage 2 is built in the same file; the panel now
carries TREND, REGIME, SCORE and SIGNAL.

Sections 5, 7, 9 and 10 were rewritten after the trend filter was measured rather than
argued about. What changed and why is in section 10.4 - the short version is that the
Ehlers bandpass turned out not to measure direction at all, so the trend vote is built
from a regression slope and the bandpass is kept as a logged comparison.

---

## 1. Scope

**In stage 2:** per lane, on each closed bar of its own timeframe:

- a trend direction and how long it has been in that direction
- a regime label and how long *it* has lasted
- three independent votes, a score, and a signed signal

**Not in stage 2:** entries, stops, targets, lot size, orders, the diary. Those are stage 3
and later. The panel says `SIGNAL ONLY` so this can never be mistaken for a trading build.

---

## 2. Locked decisions

| # | Decision | Why |
|---|---|---|
| D1 | Regime window is **time-equalised across lanes** | 20 bars is 100 minutes on M5 and 10 hours on M30, so the three labels would describe three different markets and disagree for reasons unrelated to price. SimpleEA hit this exact defect and fixed it the same way. |
| D2 | TREND and REGIME each show **bars left and % of life left**, measured not predicted | The honest answer to "how long will this last" is that lane's own run history, conditioned on how far the run has already got. Not a predicted switch bar. |
| D3 | No forward prediction of "the bar it changes" | No tool can do this. See section 8. |
| D4 | Votes stay **separate and visible**, never multiplied together | `v1 × v2 × v3` collapses to binary and hides which vote disagreed, which is the most useful diagnostic available. |
| D5 | The regime label **never vetoes** a signal | Per `automate.md`. It is context. If it ever gains teeth that is a separate, explicit decision. |
| D6 | **No per-item inputs.** A small set of technical inputs is allowed, but only ones the owner asks for by name | Every window, band, threshold and period self-configures, so there is never an input per indicator. The few inputs that do exist are switches and limits, not tuning knobs - see 2.1. Today the EA declares **none**. |
| D7 | Trend = **regression slope over 30 bars**, in units of a typical bar | Measured, not argued: it beats both Kalman and the Ehlers bandpass on every test in section 10.4. |
| D8 | Everything is **causal** — closed bars only, no future-smoothed values | A number on screen must never be built from a bar that had not finished. |

### 2.1 What the input rule actually means

Earlier drafts of this section said "no inputs at all". That was too strong, and wrong.

The rule is about **tuning knobs**, not about switches:

| Not allowed | Allowed |
|---|---|
| a period for each indicator | one switch that arms a bounded self-tweak |
| a band per timeframe | a cap on how far a self-tweak may move a value |
| a threshold the user is expected to optimise | a display toggle |
| anything that must be set correctly before the EA behaves | anything safe to leave at its default forever |

**A permitted input must satisfy all three:**

1. the default is the correct setting for a new user - leaving it alone is never wrong;
2. it switches or bounds behaviour, it does not define a measurement;
3. the owner asked for it by name, in the chat, before it was written.

Everything else self-configures. Today the EA declares **zero inputs**, and that number
only changes when the owner asks. The first one expected is the `Tweak` switch discussed
in section 6.3.

An input also has a real cost worth stating: changing one restarts the EA and wipes the
in-memory run history, so its panel is cold for the first minutes. That is another reason
to keep the count near zero.

---

## 3. The measurement stack

Three layers, each used by more than one consumer. This is why stage 2 is built in one
piece rather than split.

### 3.1 The size of an ordinary bar

```
changes[i] = close[i] - close[i-1]            last 20 closed bars
med        = median( |changes| )              the typical size of a bar
```

`med` is the only scale the engine needs. Every threshold below is expressed as a
multiple of it, which is what lets one constant serve gold at 3 500 and EURUSD at 1.08.
The Kalman draft also carried a robust `sigma` and a measurement-noise `R`; with the
filter gone both had no consumer and were removed.

### 3.2 Deadbands

```
trendBand(ratio)  = 0.20                       in units of med, section 5
moveBand(horizon) = max( 1.00 x tickSize, 0.50 x med x sqrt(horizon) )
```

A vote may only be non-zero when the measurement clears its band. Without this a flat
symbol produces a constant stream of signals.

The move band is scaled by `sqrt(horizon)` because a 2-bar move and a 20-bar move are not
the same size. A fixed multiple of a single bar's movement - the original draft - sat far
below the natural width of both, so neither vote ever abstained.

### 3.3 One drift score, replacing two efficiency ratios

The earlier draft had two efficiency ratios: `ER_fast` fed the Kalman filter's process
noise, `ER_regime` fed the regime label. The filter is gone (section 10.4), so `ER_fast`
had no consumer and was deleted rather than kept "in case".

`ER_regime` was also replaced. Measurement showed a plain efficiency ratio is **not
comparable across window lengths**, which destroys the point of equalising: over 1536 bars
a driftless walk produces `ER x sqrt(N)` of 0.60, over 256 bars the same walk produces
1.08. A threshold that means "trending" on M30 means "noise" on M5.

The replacement is the standardised net move:

```
z = ( close[now] - close[now - N] ) / ( sd(bar changes over N) x sqrt(N) )
```

For a driftless series `z` is `N(0,1)` **at any N**, so the same threshold is meaningful on
all three lanes. `|z|` also has a plain reading: 2.0 means the move over the span is two
standard deviations of what no-drift would produce.

Measured, 400 windows each (section 13 repeats this):

| Underlying market | mean abs(z) | Steady | Mixed | Choppy |
|---|---|---|---|---|
| pure noise | 0.79 | 4.5 % | 27.0 % | 68.5 % |
| weak drift | 1.30 | 20.2 % | 41.2 % | 38.5 % |
| medium drift | 3.03 | 83.8 % | 13.5 % | 2.8 % |
| strong drift | 7.32 | 100.0 % | 0.0 % | 0.0 % |

That is a label that means something: on noise it nearly always says Choppy.

---

## 4. Windows, and why they are equalised

### 4.1 The problem

| Lane | 20 bars is | 24 hours is |
|---|---|---|
| M5 | 100 minutes | 288 bars |
| M15 | 5 hours | 96 bars |
| M30 | 10 hours | 48 bars |

A 20-bar ER on M5 samples a coffee break; on M30 it samples half a trading day. Comparing
those three numbers is comparing three different questions.

### 4.2 The decision

Votes that must react quickly stay **per-lane in bars**. The regime label becomes
**per-lane in hours**, so all three describe the same stretch of market.

| Quantity | Unit | M5 | M15 | M30 |
|---|---|---|---|---|
| momentum window | bars | 2 | 2 | 2 |
| structure window | bars | 20 | 20 | 20 |
| drift span for `z` | **hours** | 24 h → 288 bars | 24 h → 96 bars | 24 h → 48 bars |
| closed bars loaded | bars | 289 | 97 | 49 |


**24 hours, revised down from 128 on evidence.** The first build used 128 hours. Measured
on real 5-minute candles that is 1 536 bars, and two neighbouring readings are almost the
same number - lag-1 autocorrelation 0.98 to 0.999 - so a whole file yielded only about
**13 independent observations**. The practical result was a column that read `Choppy` on
100 % of bars.

That reading was not a bug. At 128 hours these markets genuinely do not drift: the
variance ratio, the canonical random-walk test (Lo-MacKinlay 1988), came in at **0.04 to
0.36** on the crypto pairs, where 1.0 means a random walk and below 1 means mean
reversion. Price snaps back faster than a random walk would, so a two-sigma drift almost
never occurs.

At 24 hours the same thresholds behave as designed. On liquid pairs the split comes out at
**18.5 / 12.8 / 68.7** and **13.1 / 14.3 / 72.5**, close to the intended 5 / 20 / 75, and
the label changes on 1 to 3 % of bars instead of never. Illiquid pairs still read `Choppy`
almost always, which is the correct description of them.

**Consequence:** the history a lane needs falls with it - 1 089 closed M5 bars instead of
2 337.

**Consequence:** stage 1 showed `M5 100259 bars` on the user's terminal, so history depth is
not a problem in practice. On a symbol with shallow history the lane shows `DATA WAIT`
rather than reading a regime from half a window.

---

## 5. The trend vote

```
slope  = least-squares slope of close over the last 30 closed bars   (price per bar)
med    = median |bar change| over the last 20 closed bars            (price per bar)
ratio  = slope / med                                                 (dimensionless)

trendVote = +1  if ratio >  0.20
          = -1  if ratio < -0.20
          =  0  otherwise
```

Dividing by `med` is what makes this work on any symbol without a setting: gold at 3 500
and EURUSD at 1.08 both come out as "how many ordinary bars per bar did this move".

### 5.1 Choosing the window and the band

Two things had to be picked, so both were measured. The score is the fraction of bars
where the vote's sign matched the next 20-bar move, and the run length is how many bars
the vote holds before it changes - which matters because the remaining-life figure is built on it.

| Slope window | Band | FLAT | median run | hit at 20 bars |
|---|---|---|---|---|
| 20 | 0.10 | 11 % | 6 | 74.6 % |
| 20 | 0.20 | 22 % | 8 | 78.1 % |
| 30 | 0.20 | 26 % | 12 | **77.8 %** |
| 50 | 0.10 | 18 % | 17 | 73.0 % |
| 50 | 0.20 | 32 % | 19 | 77.3 % |
| 100 | 0.20 | 38 % | 18 | 72.4 % |

A 20-bar window with a 0.10 band produces a vote that changes every ~6 bars. That is
accurate enough, but a remaining-life figure built on a six-bar flicker says nothing. The chosen setting is
**30 bars, band 0.20**: twice the run length of the original guess, the best measured hit
rate at the 20-bar horizon, at the cost of more FLAT.

### 5.2 What FLAT means

On pure noise the vote is FLAT about half the time (UP 26.7 %, DOWN 23.7 %, FLAT 49.7 %,
300 windows). That is not a defect - on a random walk there usually is no trend, and
saying so is the correct answer. With drift present the same setting is decisive:

| Underlying market | UP | DOWN | FLAT |
|---|---|---|---|
| pure noise | 26.7 % | 23.7 % | 49.7 % |
| weak drift | 47.3 % | 9.3 % | 43.3 % |
| strong drift | 97.0 % | 0.0 % | 3.0 % |

### 5.3 What happened to forward projection

With no state covariance there is no cone to draw. The one forward number available -
Ehlers' own rate of change - is computed and logged, but it measured as a coin flip
(section 10) and is not shown on the panel. Section 8.3 records what is deferred.

---

## 6. The other two votes

**Momentum** — the signed two-bar close change against `moveBand(2)`. Fast, deliberately crude,
and independent of the filter.

**Structure** — the signed 20-bar close change against `moveBand(20)`, then checked
against confirmed 3-bar pivots (one closed bar on each side):

- a BUY vote is withdrawn when the two most recent confirmed swing lows are making lower lows
- a SELL vote is withdrawn when the two most recent swing highs are making higher highs
- a missing swing pair does **not** withdraw the vote — only a missing price history does

This is the vote that must stay genuinely independent. SimpleEA's source notes that its
third vote used to be a copy of its first, which is why 2/3 could never occur and every
trade became a market order. The same failure is available here if structure is ever
"helpfully" derived from the filter output.

### Score and signal

```
score  = trendVote + momentumVote + structureVote      range -3 .. +3
signal = +1 (BUY)  if score >= +2
       = -1 (SELL) if score <= -2
       =  0        otherwise
```

The panel shows `3/3`, `2/3`, `1/3`, `0/3` — **agreement, never a probability**.

Measured on synthetic data during design: a Gaussian random walk reaches 3/3 in roughly a
third of trials. That is the number to keep in mind whenever the panel looks confident.

### 6.1 "Signal confidence" — what was tested and what was refused

The score is **locked** and does not change. The question asked of it was narrower: can
anything tell us **how long the current score will last**?

**Conventional indicators were tested and refused.** Nine features — RSI, ADX, ATR ratio,
Bollinger width, Stochastic, CCI, MACD histogram, plus the run's age and the score itself —
were put through a logistic model and trained on one era, tested on another.

| Split | score + age | adding indicators |
|---|---|---|
| 2018 -> 2025 | AUC 0.624 | AUC 0.657 (helps) |
| 2025 -> 2018 | AUC 0.663 | AUC 0.653 (hurts) |

The improvement **reverses when the eras are swapped**, so it is noise, not signal. The
model is also badly calibrated out of sample: the fifth of bars it rated most likely to
persist came true 35.5 % of the time against a 45.1 % prediction, while the fifth it rated
least likely came true **more** often than predicted (15.6 % against 8.9 %).

A confidence percentage built on that would be a confident-looking number with no
foundation. That is the same failure as the 128-hour regime span, caught before shipping.

**What does carry information is the score itself**, counted directly with no model:

| Score | lasts 3 more bars (2018) | (2025) |
|---|---|---|
| +3 / -3 | 10.1 % / 10.6 % | 18.4 % / 17.4 % |
| +2 / -2 | 5.5 % / 5.3 % | 6.7 % / 6.0 % |
| +1 / -1 | 4.0 % / 3.4 % | 3.5 % / 3.4 % |
| 0 | 4.3 % | 2.3 % |

The ordering is monotonic and holds in both eras: **an extreme score is the stickiest
state, a moderate one the least durable.** The level differs by era (roughly 10 % against
17 % for 3/3), so any display must be coarse.

| Signal | lasts 5 more bars (2018) | (2025) |
|---|---|---|
| BUY / SELL | 8.5 % / 9.0 % | 14.1 % / 9.1 % |
| NO SIGNAL | 37.6 % | 30.8 % |

**Decision:** no indicator-based confidence is built. If a persistence figure is ever
shown, it comes from counting this table in the EA's own run history - the machinery for
which already exists - and it belongs in the hover text as a rough band, never as a
precise percentage on the panel.

### 6.2 What was built instead: the SIGNAL cell carries a durability figure

The user asked for the percentage to sit on the signal rather than on the score, and
chose durability over a strength score. That is what ships.

```
SIGNAL cell    SELL 22%     ->  22% chance this SELL is still standing in 3 bars
               SELL         ->  not enough history to say
               NO SIGNAL    ->  nothing to expire, unchanged
```

**The estimator** - no model, no fitted coefficients, one division:

```
P = runs that reached (age + 3) / runs that reached age
```

Counted over this lane's own completed signal runs, up to 400 of them, and only reported
when at least 12 runs are at risk. Because it is counted locally, the era problem in 6.1
dissolves: a symbol whose signals last longer reports a higher number without any
constant being touched.

**Measured on real candles**, 15 012 signal bars:

| Quantity | Result |
|---|---|
| bars showing a percentage | 79 % |
| median reading | 19 % |
| 90th percentile | 32 % |
| widest cell | `BUY 100%` = 10 of 10 characters |
| calibration, 2018 | predicted 20.1 %, happened 18.4 % |
| calibration, 2025 | predicted 22.9 %, happened 24.4 % |

The figure rises with age as it should - 17 % at one bar old, 30 % at five - because a
run that has already lasted is more likely to keep lasting.

**Why the percent has no `L`.** In TREND and REGIME, `%L` means *share of life left*. In
SIGNAL it means *chance of still standing*. One letter cannot carry two meanings in one
row, so the signal cell shows a bare percent and the hover spells out which question is
being answered.

**What it does not say.** It is not strength and not a reason to trade. It says how long
the label is likely to stay lit. Measured separately, the score predicts the *size* of the
next move but not its direction, and no confidence number changes that.

---

### 6.3 The armed self-tweak - proposed, not built

The owner's design, recorded here so it can be reviewed before any code exists.

The EA never changes a constant on its own. Instead it **raises a check**, and a person
arms the change:

```
1. diary finds a problem        -> panel:  Check: Cost Watch
2. owner sets Tweak = true      -> EA applies ONE bounded change
3. panel confirms               -> Tweak done: gate 1.4 -> 1.6
4. owner sets Tweak = false     -> EA keeps the new value, resumes watching
```

Four rules make it safe, and all four are required:

| Rule | Why |
|---|---|
| **One change per arming** | a forgotten switch cannot turn into permanent self-tuning |
| **Bounded range and a small step** | `1.4 -> 1.6`, never `1.4 -> 5`; the cap is internal and not an input |
| **The new value is written to the diary file** | changing an input restarts the EA and rebuilds run history in memory; without persistence the tweak would silently vanish |
| **Logged with a before and after row** | the diary must show what the EA was like before the change, not only after |

This is the one place a user input is expected (§2.1). It is a switch, it is safe to leave
`false` forever, and it was requested by the owner rather than invented here.

**The honest risk, stated once.** A tweak is chosen by looking at past data. That exact
method failed in this project already: a model fitted on 2018 scored worse than useless on
2025, with coefficients that changed sign. Bounded steps limit the damage; they do not
make the direction of a tweak reliable. The first few should be treated as experiments,
with the before/after visible in the diary.

---

## 7. Regime

```
z = standardised net move over the equalised span, section 3.3

Steady  if |z| >= 2.0
Mixed   if |z| >= 1.0
Choppy  otherwise
```

Computed on the lane's own bars over an equalised span, so M5/M15/M30 describe the same
stretch of market. Measured on one 5-minute series aggregated to 15 and 30 minutes
(200 trials): **all three lanes agree 94.5 % of the time, two of three 6.0 %, all three
different 1.0 %.** Persistent disagreement on a live chart is therefore a bug, not a
market condition.

**Context only.** The label does not block, mute or downgrade a signal (D5). A valid BUY
in Choppy is still shown as BUY.

---

## 8. Age, and the honest version of "future bars"

### 8.1 What is refused

There is no reliable estimator of **the bar on which a trend or regime changes**. Three
legitimate tools exist and every one of them returns a *duration*, never a date:

| Tool | Gives | Honest limit |
|---|---|---|
| First-passage time (inverse Gaussian) | expected bars to a level, `E[τ] = a/ν`, `Var = aσ²/ν³` | **with zero drift the expected time is infinite** — the maths says a driftless move has no reliable arrival time |
| OU / AR(1) half-life | `ln(2)/κ`, bars for a deviation to halve | a time scale, not a switch bar |
| Markov dwell time | `1/(1-p_ii)` from an empirical transition matrix | an average, never a date |
| Ehlers dominant cycle | cycle length in bars from Hilbert phase | "anticipating" turning points, in Ehlers' own wording, not predicting them |

Even with real drift the median first-passage time sits far below the mean and the spread is
enormous. "Bar 4" can be arithmetically correct and practically useless.

### 8.2 What is built instead

**Remaining life, measured against the lane's own history.** For each lane, and
separately for trend direction and for regime label:

- count how many consecutive bars the current state has lasted - its age
- keep the last 200 completed run lengths for that lane and state
- report **how many more bars it should run**, and that as a share of its whole life

**Seeded, not learned from zero.** Measuring found that a cold start leaves the median
empty for 538 bars - 45 hours on M5 and **11 days on M30** - which makes the column useless
for its first week. So at attach each lane replays the vote over 400 already-closed bars it
has loaded. This is not look-ahead: every bar in the replay is finished, and the vote at
bar *i* uses only bars before *i*, so the replay produces exactly the numbers the EA would
have printed had it been running. Verified against ground truth - a 400-bar replay gives
the same age and the same median as an EA that had tracked every bar from the start.

Cost is one pass per lane at attach: about 1.5 M operations in total, once.

**How the remaining life is computed - and the version that was rejected.**

The obvious formula is *typical run length minus age*. It was measured before being
written: **it returns zero on 65 % of bars**. A number that reads zero two-thirds of
the time is not a forecast, it is a dead cell.

The question that works is different. Instead of asking how long runs *usually* are,
ask:

> Of the past runs that **already reached this age**, how much longer did they go?

Those are the survivors. Their median residual is the bars-left figure, and it never
returns zero because it is conditioned on having got this far. Measured on the same
data: **0 % zeros, median 21 bars.**

```
barsLeft = median( run - age )  over stored runs where run > age
pctLeft  = 100 x barsLeft / (age + barsLeft)
```

The two displayed numbers are therefore one estimate, not two.

**Coverage.** Six survivors are required before a claim is made, and the last 400
completed runs are kept per lane. Coverage grows as that history fills, measured on
the real vote logic:

| bars since attach | carries a number |
|---|---|
| 0 - 2 000 | 69 % |
| 4 000 - 8 000 | 85 - 87 % |
| 10 000 - 12 000 | 92 % |
| once the 400-run history is full | ~100 % |

**The two ways a cell can come back empty are not the same thing**, and the panel
distinguishes them:

| Cell | Cause |
|---|---|
| `UP Max` | the run is already longer than every run on record |
| `UP` | fewer than six past runs got this far |

`Max` is a real reading about an unusual run; a bare label is mainly a cold-start
condition. Both explain themselves on hover. The condition for `Max` is exact -
age >= the longest stored run - which also means zero survivors, so a cell can never
show a number and `Max` at the same time.

**What the numbers actually look like.** Same run:

| Statistic | p25 | median | p75 | extreme |
|---|---|---|---|---|
| bars left | 19 | 81 | 113 | 295 |
| % of life left | 43 % | 55 % | 68 % | 95 % |

| Threshold | Share of bars |
|---|---|
| below 10 % left | 0.0 % |
| below 20 % left | 4.9 % |
| below 50 % left | 38.3 % |

The percent never reaches zero and sits above half most of the time. That is the shape
of the real thing - a run that has lasted this long really does tend to last - but it
means the percent is a **warning light near the end**, not a countdown to watch from
the start. Written down here so nobody is surprised by it later.

**How wide the answer is.** The run distribution is heavy-tailed, so the median alone
would overstate precision. The tooltip also gives the interquartile range of the same
survivors, e.g. *"Similar past runs went on for 18 to 96 more."* The panel cell keeps
the single number; the spread lives one hover away.

Panel cell: `6/11` = this state is 6 bars old, the median completed run was 11.

This answers the user's question — *how long will it last, how unusual is this* — from the
symbol's own history, with no tuning knobs and no pretence of knowing the switch bar. It also
self-adapts per symbol and per lane, because it is measured, not configured.

States tracked:

| Tracked | Resets when |
|---|---|
| trend UP / DOWN / FLAT | the trend vote changes value |
| regime Steady / Mixed / Choppy | the regime label changes |

### 8.3 Forward projection — deferred, and now for a better reason

The earlier plan projected `level + k x slope` with a widening covariance from a Kalman
filter. There is no Kalman filter any more, and measurement (section 10.4) showed the only
other forward number available - Ehlers' rate of change - is a coin flip. Drawing a cone
from either would be decoration.

What is kept is the honest one: the current run against its own history. That answers
*how long has this lasted and how unusual is that* without claiming to know the date. A
cone comes back in stage 3, where there is a target for it to be measured against.

---

## 9. Constants — all internal, all candidates

| Constant | Value | Meaning |
|---|---|---|
| `CHANGE_WINDOW` | 20 | bars for the typical-bar size `med` |
| `TREND_PERIOD` | 30 | regression window for the trend vote |
| `STRUCTURE_PERIOD` | 20 | net-move window for the structure vote |
| `MOMENTUM_PERIOD` | 2 | two-bar close change |
| `PIVOT_WING` | 1 | 3-bar pivot: one closed bar each side |
| `REGIME_HOURS` | 24 | equalised drift span |
| `Z_STEADY` / `Z_MIXED` | 2.0 / 1.0 | regime boundaries in standard deviations |
| `TREND_BAND_X` | 0.20 | trend deadband, in units of `med` |
| `MOVE_BAND_X` | 0.50 | move deadband = `0.50 x med x sqrt(horizon)` |
| `MOVE_BAND_TICKS` | 1.00 | floor of the move deadband, in ticks |
| `AGE_HISTORY` | 400 | completed runs kept per state |
| `MIN_REMAIN_SAMPLES` | 6 | surviving runs needed before a remaining life is claimed |
| `SIGNAL_DURA_BARS` | 3 | "still standing this many bars on" |
| `MIN_DURA_SAMPLES` | 12 | runs at risk before a signal durability is claimed |
| `SEED_BARS` | 800 | closed bars replayed at attach so the history is warm |
| `TREND_L1` / `TREND_L2` | 150 / 24 | Ehlers bandpass, comparison log only |

None of these is a user input (D6, 2.1) - they are internal and not exposed. Each is a
starting candidate to be replaced only by a measurement, never by a user's opinion at
first run.

**Why `MOVE_BAND_X` is 0.50 and not 0.10.** The earlier draft used
`max(1 tick, 0.10 x med)`. But `med` is the size of a *one-bar* move, while the momentum
vote looks at two bars and the structure vote at twenty. A deadband of 0.10 bars against a
move that is naturally 1.4 or 4.5 bars wide almost never triggered, so both votes were
effectively `sign(net move)` with no filter at all. Scaling by `sqrt(horizon)` puts the
band at half the size a driftless market would produce, which is what a deadband should be.

---

## 10. Trend: what was measured, and what it changed

### 10.1 The three candidates

| Candidate | What it is |
|---|---|
| **Kalman, two states** | explicit model of level and slope with a covariance; the filtered slope is the vote |
| **Ehlers Precision Trend** | bandpass from two 3-pole high-pass filters, `HP(P,L1) - HP(P,L2)`; the sign is the vote |
| **Regression slope** | least-squares slope over 30 bars, divided by the typical bar |

### 10.2 Why measurement replaced argument

Two rounds of advice were given on properties - Kalman first, then Ehlers - and both were
opinion. So the three were put on the same synthetic data and scored the only way that
matters: **does the sign at bar *t* match the direction of the next *h* bars?**

Thirty runs per cell, 1 400 bars each, warm-up 500 bars. 50 % is a coin flip.

| Market | h | Ehlers | Ehlers ROC | net 20 bars |
|---|---|---|---|---|
| driftless walk | 20 | 49.7 % | 49.6 % | 48.7 % |
| AR(1) momentum, phi 0.40 | 20 | 50.1 % | 51.3 % | 49.9 % |
| regime-switching drift | 20 | 51.3 % | 49.7 % | **73.6 %** |
| same, swings of 20-50 bars | 5 | 72.3 % | 47.1 % | **78.2 %** |
| same, swings of 150-400 bars | 5 | 52.1 % | 48.6 % | **84.7 %** |

A second test asked whether the sign tracks a *constant* drift:

| Underlying drift | Ehlers | net 20 bars |
|---|---|---|
| weak | 50.0 % | 59.2 % |
| medium | 50.0 % | 74.2 % |
| strong | 51.7 % | **99.2 %** |

### 10.3 The finding

**The Ehlers bandpass does not measure direction.** Its sign is a coin flip against
persistent drift, and it only works when the swing is *faster* than its own passband
(72 % at 20-50-bar swings, 52 % at 150-400-bar swings). That is not a tuning problem: the
filter is a difference of two high-passes, so it has a double zero at zero frequency and
therefore removes exactly the slow drift a trend column is supposed to report. It is a
cycle-phase oscillator being asked to do a direction job.

This is not a surprising result in hindsight. `SimpleEA`'s own research harness reported
"pure direction is a coin flip, 48-52 % hit on liquid FX" - the same number, from the same
indicator, measured on real data instead of synthetic.

The Kalman slope was never reachable: no repository in the family has a working one, so
there was nothing to compare it against.

### 10.4 The decision

**Trend vote = regression slope, section 5.** It beat both other candidates on every row
of every test, it needs no fitting, and it is one subtraction and one division per bar.

**The Ehlers bandpass is still built**, because a claim should be checkable on the user's
own broker rather than on my synthetic series. On every closed bar the EA compares
`sign(Ehlers trend)` with the trend vote, counts agreements, and prints the tally to the
Experts log once an hour:

```
Ehlers vs slope: 812 agree, 96 disagree (89.4% agree) over 908 closed bars
```

The expectation from the table above is close to 50 % agreement on a quiet symbol. If the
live chart shows clearly better than that, the measurement in this section was wrong for
that instrument and the bandpass earns its place back. That is the reversal test, and it
costs one line to read.

### 10.5 What is genuinely lost

The Kalman predict step was the only defensible forward projection, and it is gone with
the filter. No replacement is claimed. Section 8.3 records the consequence honestly: the
panel reports duration-so-far, not duration-remaining.

---

## 11. Panel

AGE is gone. TREND and REGIME each carry the forward number instead, so one row
answers the only question worth asking of a live panel: **how much longer**.

```text
 AUTOMATE    XAUUSDm  |  Metal  |  Hedging
 MARKET OPEN | Session: London | Spread: 240.0 pts

 TF     TREND         REGIME          SCORE  SIGNAL    TRADE STATUS
 M5     UP 6/30%L     Steady 12/45%L  3/3    BUY 24%   SIGNAL ONLY
 M15    FLAT 9/88%L   Mixed 40/62%L   2/3    NO SIGNAL SIGNAL ONLY
 M30    DOWN Max     Choppy 3/12%L   1/3    NO SIGNAL SIGNAL ONLY

 Selected:                    Entry:
 SL:                          TP:
 Entry timing:                TP estimate:
 Size:                         Planned risk:
 Combined exposure:
 Diary:                        Unknown future costs:
```

`6/30%L` = about 6 more bars from the last closed bar, and 30 % of the run's life
still ahead. `L` = left, and it applies to both numbers. `Max` = this run is already
longer than any run on record for that lane, so no number is claimed.

| Column | Character | Width | Contents |
|---|---|---|---|
| TF | 1 | 7 | `M5` `M15` `M30` |
| TREND | 8 | 14 | `UP 6/30%L`, `UP Max`, or just `UP` |
| REGIME | 22 | 16 | `Steady 12/45%L`, `Steady Max`, or just the label |
| SCORE | 38 | 7 | `3/3` … `0/3` |
| SIGNAL | 45 | 10 | `BUY` `SELL` `NO SIGNAL` |
| TRADE STATUS | 55 | - | `SIGNAL ONLY`, `DATA WAIT` |

The header is unchanged from the earlier draft apart from losing AGE. Widest line is
67 characters. A cell that would exceed its column drops the bar count first, then
the estimate, so alignment cannot break.

### 11.1 How the two numbers relate

`barsLeft` is a median. The percent is that same median against the run's implied
whole life:

```
total  = age + barsLeft
pctLeft = 100 x barsLeft / total
```

So 6 bars left at age 14 is 30 % of a 20-bar life. The two never disagree, because
one is computed from the other.

### 11.2 Why the numbers are not constant per timeframe

There is no per-lane horizon setting. The horizon is whatever that lane's own runs
do. On a quiet symbol the trend turns every 6 bars; on a strong one it runs 40. The
panel reports what it measures, which is the only version that can be right on both.

### 11.3 Hover text is the only explanation

The panel carries no legend, by request. Each cell explains itself on hover:

| Hover | Shows |
|---|---|
| TREND cell | "M5 trend UP. About 6 more bars (30 min). 30% of its life left - a total of about 20 bars, 14 already used." |
| REGIME cell | "M5 regime Steady. About 12 more bars (1 h). 45% of its life left - ..." |
| SCORE cell | "2 of 3 votes agree. Trend 1, momentum 1, structure 0." |
| SIGNAL cell | "BUY or SELL needs 2 of the 3 votes to agree." |
| TRADE STATUS | "Nothing is sent to the broker in this build." |

The SIGNAL hover reads: *"SELL has stood for 2 bars. Of the past SELL runs on this symbol
that reached this age, 22% were still standing 3 bars later. Counted from this symbol's
own history, not a fixed rule."*

The `Max` hover reads: *"M30 trend DOWN has already run 61 bars - longer than any run in
its history (longest 58). Shown as Max: no honest estimate of what is left."*

When a run has already outlasted every run in its history the tooltip says so
plainly instead of inventing a number:

> "M5 trend UP has already run 121 bars - longer than any run in its history
> (longest 118). No honest estimate of what is left."

Colour: TREND and SIGNAL carry direction colour; REGIME, SCORE and TRADE STATUS are
plain. Text always carries the meaning.

---

## 12. What will not be built

| Not built | Reason |
|---|---|
| An exact bar number for the turn | only a median remaining length is claimed, never a date |
| A forward price projection | dropped with the Kalman filter, nothing claimed in its place |
| A "probability of winning" | agreement of correlated measurements is not a probability |
| ATR in any entry, stop or target | prohibited by `automate.md` |
| Per-symbol-class window lengths | would make forex and gold different strategies; the tick floor and the deadband carry the symbol difference, the window does not |
| Multiplied votes | hides which vote disagreed |
| A regime veto | D5, and it is a separate decision if ever wanted |
| Self-learning that rewrites the signal | out of scope; the diary stays observational |
| Indicator-based signal confidence | tested and refused, section 6.1 - the gain reverses when the eras swap |

---

## 13. Validation

1. `python3 tools/preflight.py Automate.mq5` - clean.
2. Compile in MetaEditor - 0 errors, 0 warnings.
3. Calibration tables, produced before the constants were written into the EA:
   - regime label - 400 windows, section 3.3;
   - trend vote, window and band - section 5.1, band response - section 5.2;
   - three lanes on one series - 94.5 % agreement, section 7.
4. A bar-by-bar simulation of the finished engine - the same code path the EA runs, ages
   included - over 13 200 bars of regime-switching price:

   | Quantity | Result |
   |---|---|
   | trend vote | UP 39.8 %, DOWN 34.3 %, FLAT 26.0 %, median run **12 bars** |
   | regime | Steady 81.1 %, Mixed 11.4 %, Choppy 7.5 %, median run **38 bars** |
   | score | every value from -3 to +3 occurs, -3 16.9 %, +3 20.2 % |
   | signal | fires on 63.4 % of bars |
   | remaining-life coverage | 69 % at attach, 85-92 % mid, ~100 % with full history |
   | remaining-life zeros | 0.0 % - the rejected formula gave 64.8 % |
   | widest rendered cell | TREND 12 of 14, REGIME 15 of 16 |
   | signal durability shown | 79 % of signal bars, median 19 %, range 1-65 % |
   | signal durability calibration | 20.1 % predicted vs 18.4 % actual (2018); 22.9 vs 24.4 (2025) |

   Persistence study, on real candles (section 6.1): nine conventional indicators failed
   to improve the score's own durability estimate out of sample - AUC went 0.624 -> 0.657
   in one direction and 0.663 -> 0.653 in the other - and the fitted model was
   miscalibrated in the test era. The score value alone separates persistence cleanly:
   3/3 lasts three more bars about 10 % of the time against 4 % for 1/3.

   Both remaining-life estimates are populated on ~99 % of bars, which is what the
   column needs to mean anything. Every score occurs, so `2/3` and `1/3` are real states and the three votes
   are not copies of each other.

   The 63.4 % signal rate looks high and is: this series spends half its life in a strong
   drift, and three votes measuring recent direction agree in a drift. On pure noise the
   same engine fires on about 47 % of bars. That is the correct behaviour for an agreement
   count at a 2-of-3 threshold, and it is exactly why the panel says `SIGNAL ONLY` rather
   than implying an edge.
5. On the live chart: M5/M15/M30 regime labels should usually agree, because they now
   measure the same span. Persistent disagreement is a bug, not a market condition.
6. Confirm in the Experts log that the lanes report `DATA WAIT` on a symbol with shallow
   history rather than reading a regime from half a window.
7. Read `Ehlers vs slope` in the Experts log after a day. Near 50 % agreement confirms
   section 10.4 on this broker's data; much higher reopens the decision.

---

## 14. Open questions

| # | Question | Status |
|---|---|---|
| Q1 | Regime window equalised | **decided** at 24 h - 128 h was tested and could not resolve a label |
| Q2 | How to show duration on the panel | **decided** - `bars/%L` inside TREND and REGIME; a separate AGE column was built first and then removed as redundant |
| Q3 | Kalman slope or Ehlers bandpass for the trend vote | **decided against both** - regression slope measured better, section 10. Ehlers kept as a logged comparison |
| Q4 | Should the SIGNAL also carry a remaining life | open - the code tracks TREND and REGIME runs only; signal is not tracked as a run |
| Q5 | Should regime boundaries be per-class | open - currently one set for every symbol. The measurement says no: `z` is scale-free |
