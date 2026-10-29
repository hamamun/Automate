# Autotrade — stage 2 design record

**Status: design record for the signal stage. Not implemented yet.**

This file records the decisions taken while planning stage 2 (trend, regime, score,
signal) and the reasoning behind each one. It sits alongside `automate.md`, which remains
the original plan. Where this file differs from `automate.md`, this file is the later
decision and says why.

Stage 1 (discovery, self-configuration, market and session status) is built, merged and
verified in MetaEditor with 0 errors. Stage 2 does not exist in code yet.

---

## 1. Scope

**In stage 2:** per lane, on each closed bar of its own timeframe:

- a filtered price level and per-bar slope, with the uncertainty of both
- a trend direction and how long it has been in that direction
- a regime label and how long *it* has lasted
- three independent votes, a score, and a signed signal

**Not in stage 2:** entries, stops, targets, lot size, orders, the diary. Those are stage 3
and later. The panel will say `SIGNAL ONLY` so this can never be mistaken for a trading
build.

---

## 2. Locked decisions

| # | Decision | Why |
|---|---|---|
| D1 | Regime window is **time-equalised across lanes** | 20 bars is 100 minutes on M5 and 10 hours on M30, so the three labels would describe three different markets and disagree for reasons unrelated to price. SimpleEA hit this exact defect and fixed it the same way. |
| D2 | An **AGE** column is added to the panel | The honest answer to "how long will this last" is the age of the current state against its own history, not a predicted switch bar. |
| D3 | No forward prediction of "the bar it changes" | No tool can do this. See section 8. |
| D4 | Votes stay **separate and visible**, never multiplied together | `v1 × v2 × v3` collapses to binary and hides which vote disagreed, which is the most useful diagnostic available. |
| D5 | The regime label **never vetoes** a signal | Per `automate.md`. It is context. If it ever gains teeth that is a separate, explicit decision. |
| D6 | No user inputs, including for stage 2 | Constants are internal candidates, documented in section 9. |
| D7 | Trend = **Kalman slope**, pending the Ehlers comparison in section 10 | Gives slope as a state with known variance, which the projection needs. |
| D8 | Everything is **causal** — closed bars only, no future-smoothed values | A number on screen must never be built from a bar that had not finished. |

---

## 3. The measurement stack

Three layers, each used by more than one consumer. This is why stage 2 is built in one
piece rather than split.

### 3.1 Noise

```
changes[i]  = close[i] - close[i-1]           last 20 closed bars
medianAbs   = median( |changes| )             the typical size of a bar
sigma       = 1.4826 x median( |changes - median(changes)| )   robust standard deviation
R           = max( sigma^2 , tickSize^2 )     floor at one tick squared
```

The floor matters: in a dead market `sigma` collapses and the filter would decide price is
perfectly predictable. One tick squared is the smallest believable measurement noise.

### 3.2 Deadbands

```
trendBand = max( 0.10 x tickSize, 0.05 x medianAbs )
moveBand  = max( 1.00 x tickSize, 0.10 x medianAbs )
```

A vote may only be non-zero when the measurement clears its band. Without this a flat
symbol produces a constant stream of signals.

### 3.3 Efficiency ratio — two of them, deliberately

| Name | Window | Used by | Why this window |
|---|---|---|---|
| `ER_fast` | 20 bars of the lane | the filter's process noise `q` | q must react within a couple of hours; a 5-day window cannot |
| `ER_regime` | time-equalised, section 4 | the Steady / Mixed / Choppy label | the label must describe the same market on all three lanes |

`automate.md` used one ER for both. Splitting them is a deliberate change: coupling the
regime label to the fast window made the label jitter every few bars, and coupling `q` to a
5-day window made the filter react a day late.

---

## 4. Windows, and why they are equalised

### 4.1 The problem

| Lane | 20 bars is | 128 hours is |
|---|---|---|
| M5 | 100 minutes | 1536 bars |
| M15 | 5 hours | 512 bars |
| M30 | 10 hours | 256 bars |

A 20-bar ER on M5 samples a coffee break; on M30 it samples half a trading day. Comparing
those three numbers is comparing three different questions.

### 4.2 The decision

Votes that must react quickly stay **per-lane in bars**. The regime label becomes
**per-lane in hours**, so all three describe the same stretch of market.

| Quantity | Unit | M5 | M15 | M30 |
|---|---|---|---|---|
| `ER_fast` window | bars | 20 | 20 | 20 |
| momentum window | bars | 2 | 2 | 2 |
| structure window | bars | 20 | 20 | 20 |
| `ER_regime` window | **hours** | 128 h → 1536 bars | 128 h → 512 bars | 128 h → 256 bars |
| minimum closed bars | bars | 1600 | 640 | 400 |
| history pulled | bars | 1800 | 800 | 500 |

128 hours is 5.3 days: enough to span every weekday session at least once. This is a
**candidate**, not a law — it is the number SimpleEA arrived at and the one I would test
first.

**Consequence:** stage 1 showed `M5 100259 bars` on the user's terminal, so history depth is
not a problem in practice. On a symbol with shallow history the lane shows `DATA WAIT`
rather than reading a regime from half a window.

---

## 5. The filter (trend vote)

Two-state local linear filter. State is **price level** and **per-bar slope**.

```
predict :  level += slope
           P = F P F' + Q ,  F = [[1,1],[0,1]]
           Q = q . R . [[0.25, 0.5],
                        [0.5,  1.0]]
update  :  H = [1, 0],  measurement is the closed price
           K = P H' / (H P H' + R)
           state += K (close - level)
           P = (I - K H) P
q       =  0.02 + 0.18 x ER_fast
```

Seeded from the first available closed price, slope zero, and a positive covariance so the
first update can move the state. `P` is carried explicitly as three numbers (`p00`, `p01`,
`p11`), kept symmetric, and floored at `1e-12` so it stays a valid covariance.

**Trend vote:** `+1` if `slope > trendBand`, `-1` if `slope < -trendBand`, else `0`.

The filtered slope is also the basis of the forward projection in section 7, and `sqrt(p11)`
is the honest uncertainty of that slope — the number that decides whether a slope is worth
believing at all.

---

## 6. The other two votes

**Momentum** — the signed two-bar close change against `moveBand`. Fast, deliberately crude,
and independent of the filter.

**Structure** — the signed 20-bar close change against `moveBand`, then checked against
confirmed 3-bar pivots (one closed bar on each side):

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

---

## 7. Regime

```
ER_regime = |close[now] - close[now - N]| / SUM |close[i] - close[i-1]|     N = hours window

Steady  if ER_regime >= 0.30
Mixed   if ER_regime >= 0.15
Choppy  otherwise
```

Computed on the lane's own bars over an equalised span, so M5/M15/M30 report the same
market. **Context only.** It does not block, mute or downgrade a signal (D5). A valid BUY
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

**Age tracking.** For each lane, and separately for trend direction and for regime label:

- count how many consecutive bars the current state has lasted
- keep the last 200 completed run lengths for that lane and state
- report the current age, the median completed run, and the 80th percentile

Panel cell: `6/11` = this state is 6 bars old, the median completed run was 11.

This answers the user's question — *how long will it last, how unusual is this* — from the
symbol's own history, with no inputs and no pretence of knowing the switch bar. It also
self-adapts per symbol and per lane, because it is measured, not configured.

States tracked:

| Tracked | Resets when |
|---|---|
| trend UP / DOWN / FLAT | the trend vote changes value |
| regime Steady / Mixed / Choppy | the regime label changes |

### 8.3 Forward projection — deferred to a later stage

The filter's **predict step** is the one defensible forward number: project `k` bars ahead
(`level + k·slope`) with the covariance widening as `k` grows, and draw it as a cone. It
degrades honestly the further it looks.

It is deferred because a cone is only meaningful against a target, and targets are stage 3
(entries, stops, TP). Measuring it now would produce a picture with nothing to measure
against.

---

## 9. Constants — all internal, all candidates

| Constant | Value | Meaning |
|---|---|---|
| `CHANGE_WINDOW` | 20 | bars for the noise estimate and the deadbands |
| `PIVOT_WING` | 1 | 3-bar pivot: one closed bar each side |
| `STRUCTURE_PERIOD` | 20 | net-movement window |
| `MOMENTUM_PERIOD` | 2 | two-bar close change |
| `ER_FAST_PERIOD` | 20 | fast efficiency ratio, drives `q` |
| `REGIME_HOURS` | 128 | equalised regime span |
| `ER_STEADY` / `ER_MIXED` | 0.30 / 0.15 | regime boundaries |
| `Q_BASE` / `Q_SCALE` | 0.02 / 0.18 | process noise, `q = Q_BASE + Q_SCALE x ER_fast` |
| `MAD_TO_SIGMA` | 1.4826 | median absolute deviation to standard deviation |
| `TREND_BAND` | `max(0.10 tick, 0.05 x medianAbs)` | slope deadband |
| `MOVE_BAND` | `max(1.00 tick, 0.10 x medianAbs)` | momentum and structure deadband |
| `HOUR_MIN_DAYS` | 5 | distinct days before the hour scale is used |
| `AGE_HISTORY` | 200 | completed runs kept per state |

None of these is a user input (D6). Each is a starting candidate to be replaced only by a
measurement.

---

## 10. Trend: Kalman slope versus Ehlers bandpass

`automate.md` specifies a Kalman filter. SimpleEA uses Ehlers Precision Trend. Both are
available and both are defensible; they fail in different ways.

### 10.1 What each actually is

**Ehlers Precision Trend** — a bandpass built from two 3-pole high-pass filters,
`Trend = HP3(P, L1) - HP3(P, L2)`, with `L1`/`L2` adapted from a measured dominant cycle
(a zero-crossing count over 120 bars, clamped to 14–36, with `L1 = 6.25 x L2` clamped to
90–225). Its **sign** is the trend vote.

**Kalman, two states** — an explicit model of level and slope with a covariance. The
filtered **slope** is the trend vote.

### 10.2 Where each is stronger

| Property | Ehlers bandpass | Kalman (2-state) |
|---|---|---|
| Lag at a turn | **better** — high-pass differencing is designed to remove lag | worse — a random-walk-slope model smooths the turn |
| Slope as a quantity | not available; only the sign of a filtered difference | **better** — slope is a state, with its own variance |
| Forward projection | via cycle phase, cruder | **better** — predict step gives level ± sqrt(P), widening with k |
| Adapting to changing noise | fixed periods, cycle-adaptive only | **better** — `R` is measured from the data |
| Tuning constants | ~6 (`L1`, `L2`, ratio 6.25, cycle clamp 14–36, 120-bar lookback, 40-bar cycle filter) | ~4, all derived from measured noise |
| Behaviour in a dead market | tends to a small oscillation | needs the tick-squared floor or it over-trusts a flat price |
| Already run against a real broker | yes, inside SimpleEA | no, in any of these repos |

### 10.3 The honest verdict

**Neither has a validated edge**, and nothing in any of the four repositories proves one.
There is no backtest of either in `SimpleEA`, `Emtt`, `Autotrader` or `Predict_X`, and
`automate.md` states plainly that no backtest has been performed.

What can be said without a backtest:

- **Kalman is the better fit for this project**, because the design needs slope as a number
  with an uncertainty, and needs the predict step for section 8.3. Ehlers cannot supply
  either without bolting extra machinery on.
- **Ehlers is likely faster at turns.** That matters, and it is the one real risk of the
  Kalman choice.

**Mitigation, not a coin flip:** the momentum and structure votes do not depend on the
filter, so the score can turn before the slope does. That is part of why three votes are
kept rather than one.

**The decision stays reversible.** The trend vote is one function. If validation shows the
Kalman slope missing turns that the Ehlers sign catches, vote 1 can be swapped without
touching the other two, the regime, the age tracking or the panel.

**How to settle it empirically** — stage 2 ships with a comparison written to the Experts
log, not to the panel: on every closed bar, log both `sign(Kalman slope)` and
`sign(Ehlers trend)`. After a week of bars that disagree count is a fact, not an opinion.
Whichever wins the disagreement test is kept and the other removed.

---

## 11. Panel

One column added to the `automate.md` sketch. Column positions shift accordingly.

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

| Column | Character | Contents |
|---|---|---|
| TF | 1 | `M5` `M15` `M30` |
| TREND | 8 | `UP` `DOWN` `FLAT` |
| AGE | 15 | `current/median` in bars, `-` until history exists |
| REGIME | 22 | `Steady` `Mixed` `Choppy` |
| SCORE | 31 | `3/3` … `0/3` |
| SIGNAL | 38 | `BUY` `SELL` `NO SIGNAL` — 10 wide, because the longest value plus one separating space needs 10 |
| TRADE STATUS | 48 | `SIGNAL ONLY`, `DATA WAIT` |

Still blank: the auto-trading flag, every row of the plan block, exposure, diary.

Colour: TREND and SIGNAL carry direction colour; REGIME is plain text; AGE and TRADE
STATUS are dim. Text always carries the meaning.

---

## 12. What will not be built

| Not built | Reason |
|---|---|
| A predicted bar for a regime or trend change | no honest estimator exists, section 8.1 |
| A "probability of winning" | agreement of correlated measurements is not a probability |
| ATR in any entry, stop or target | prohibited by `automate.md` |
| Per-symbol-class window lengths | would make forex and gold different strategies; class adapts the noise floor and deadband, not the window |
| Multiplied votes | hides which vote disagreed |
| A regime veto | D5, and it is a separate decision if ever wanted |
| Self-learning that rewrites the signal | out of scope; the diary stays observational |

---

## 13. Validation before stage 3

1. `python3 tools/preflight.py Automate.mq5` — clean.
2. Compile in MetaEditor — 0 errors, 0 warnings.
3. Synthetic series through the extracted maths: up, down, flat, mean-reverting, zigzag, and
   a Gaussian random walk. Assertions: trend sign correct; flat gives no votes; covariance
   stays positive definite; the swing veto fires and a missing swing pair does not.
4. On the live chart: M5/M15/M30 regime labels should usually agree, because they now
   measure the same span. Persistent disagreement is a bug, not a market condition.
5. `2/3` and `1/3` must actually occur. If every signal is `3/3`, two votes are copies.
6. AGE medians must be plausible for the timeframe and must not be zero.
7. Log both trend implementations for a week and compare disagreement (section 10.3).

---

## 14. Open questions

| # | Question | Status |
|---|---|---|
| Q1 | Regime window equalised | **decided**, 128 h candidate |
| Q2 | AGE column | **decided**, added |
| Q3 | Kalman slope or Ehlers bandpass for the trend vote | **proposed Kalman**, reversible, to be settled by the disagreement log |
| Q4 | Should AGE also be tracked for the SIGNAL itself | open |
| Q5 | Should regime boundaries be per-class | open — currently one set for every symbol |
