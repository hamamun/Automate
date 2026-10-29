# Automate — stage 1: discovery and market status

`Automate.mq5` is the first stage of the EA described in [automate.md](automate.md).
It knows nothing about trading yet: **it reads the symbol, configures itself and reports the
market state.** No signals, no orders, no positions, no diary.

**No inputs.** Attach it and it works out everything on its own.

## Install

1. Copy `Automate.mq5` into `MQL5/Experts/`.
2. Compile it in MetaEditor (F7).
3. Attach it to any chart, on any timeframe.
4. MT5's Algo Trading button is not needed for this stage — nothing is sent to the broker.

## What it does

**1. Discovery.** Reads the chart symbol exactly as the broker names it (suffix included),
plus its description, folder path, base/profit currency, calculation mode, digits, point,
tick size and tick value, volume min/max/step, stop and freeze levels, and the account
currency and margin mode. Nothing is typed in, nothing is assumed.

**2. Classification.** Decides whether the symbol is forex, metal, index, energy, crypto,
stock, or other, using several independent hints that must agree:

- the symbol name (`XAU`, `BTC`, `US500`, `WTI`, `EURUSD` …);
- the broker's folder path (`Metals\`, `Indices\`, `Crypto\`, `Forex\` …);
- the base/profit currencies;
- the calculation mode;
- the description and exchange sector/industry.

The label is then cross-checked against the real price. If the evidence is weak, contested
or contradicted by the price, the panel says `Other/Unknown` or `… (unconfirmed)` and uses
the general profile. It never blocks, and it never silently pretends to be sure.

**3. Self-configuration.** The class sets the starting parameters — stop buffer in ticks,
spread gate multiple, warm-up bars. Entry, stop, target and lot size are *not* set here:
those are derived from the symbol itself in a later stage, so gold and EURUSD need no
separate settings.

**4. Session awareness.** The EA measures the symbol's typical bar movement for each of the
24 broker-server hours, using up to 10 days of M5 history, and compares the current hour
with recent behaviour:

| Current hour vs recent | Adjustment |
|---|---|
| below 60 % (thin) | +2 buffer ticks, spread gate × 1.25 |
| 60–140 % (typical) | base profile |
| above 140 % (fast) | spread gate × 1.10 |

This is what makes the configuration genuinely time-of-day aware without asking you for a
timezone.

**5. Market status.** The broker's published session table is read per weekday, including
multiple sessions and sessions that cross midnight. Each outcome gets its own honest name:

| Shown | Meaning |
|---|---|
| `MARKET OPEN` | inside a published session, quote is fresh |
| `MARKET CLOSED` | outside the table, with the next open time and countdown |
| `OPEN - STALE QUOTE` | inside a session but no fresh quote |
| `DISCONNECTED` | terminal is not connected |
| `TRADING UNAVAILABLE` | the broker disabled the symbol |
| `MARKET STATUS UNKNOWN` | no session table published and the quote is old |

When closed, the panel says **MARKET CLOSED** and "Nothing to do while the market is
closed". The discovery lines below stay visible on purpose: you need them to check the
classification while the market is shut.

**6. Named sessions.** Tokyo 09:00–18:00, London 08:00–17:00 and New York 08:00–17:00 in
each city's local time, with the EU and US daylight-saving rules applied. This needs real
UTC, so:

- **live:** the server offset is derived and sanity-checked (15-minute grid, ±14 h) and the
  label is marked `(est.)`;
- **Strategy Tester:** real UTC cannot be known, so the line reads `Session: unknown` instead
  of inventing a label. The broker's session table still decides open/closed normally.

## The panel

The layout is the interface sketch from `automate.md` section 7. Fields whose data does
not exist yet are drawn as labels with blank values, so the frame stays the same from stage
to stage and only the values fill in.

```text
 AUTOMATE    EURUSDm  |  Forex  |  Hedging  |
 MARKET OPEN | Session: London (est.) | Spread: 8.0 pts

 TF     TREND  REGIME   SCORE  SIGNAL  TRADE STATUS
 M5
 M15
 M30

 Selected:                    Entry:
 SL:                          TP:
 Entry timing:                TP estimate:
 Size:                         Planned risk:
 Combined exposure:
 Diary:                        Unknown future costs:

 DISCOVERY
 Description  Euro vs US Dollar
 Path         Standard\Forex\EURUSDm
 Calc mode    Forex   |   sector: Undefined
 Currencies   EUR / USD   account USD
 Price        1.11307 / 1.11315   digits 5
 Tick         0.00001   value 1.00 USD
 Volume       0.01 - 200.00   step 0.01   stops 0 pts
 Data         synced   M5 100259   M15 10013   M30 10036

 SELF-CONFIG
 Class        Forex   (path, name, ccy, calc, desc)
 Warm-up      200 bars   ready
 Stop buffer  2 ticks beyond a swing
 Spread gate  2.0 x typical   typical 8.0 pts (5 samples)
 Hour 9       16.0 pts (12 days)   recent 15.0 pts (195 bars)
 Adjust       typical hour x1.07 -> base profile

 BROKER SESSIONS
 Published    6 entries / week, 1 today
 Today        00:00-24:00
 Days         Sun Mon Tue Wed Thu Fri

 No signals, no orders, no positions in this build.
```

Columns match the sketch exactly: the timeframe table starts at characters 1, 8, 15, 24, 31
and 39, and the two-column block puts its right column at character 30.

**Blank by design, not by accident:** the auto-trading flag, every trend / regime / score /
signal column, the whole selected-plan block, exposure and the diary belong to later stages.
They are present so the panel does not keep changing shape.

### Look and feel

- Same palette as SimpleEA: background `C'48,48,48'`, Consolas 10, white title, lime up,
  tomato down, silver neutral; amber for HOLD reasons and red for alerts.
- Row pitch is SimpleEA's `font size + 11` px, so both panels look identical at the same
  font size. On a chart too short for that the pitch tightens automatically, never below the
  measured text height plus two pixels.
- The market state carries colour on its own row while the session and spread beside it stay
  silver, so a red `MARKET CLOSED` does not turn the whole line red.
- Width and height are measured from the text actually drawn. There are no panel inputs:
  no X/Y, no width, no font size.
- A full-day session reads `00:00-24:00` rather than the misleading `00:00-00:00`.

## What to check while testing

- The class label matches what the instrument really is.
- `Description`, `Path` and `Calc mode` match the broker's specification window.
- `MARKET OPEN` / `MARKET CLOSED` agrees with the broker's own trading hours.
- On a weekend or holiday, `MARKET CLOSED` appears with a sensible next open.
- A 24-hour symbol (crypto) never shows closed.
- On a stock or index, the weekday list should not include Saturday/Sunday.
- In the Strategy Tester, `Session` reads `unknown` — that is correct, not a bug.
- After a few minutes the spread baseline fills in (`typical x pts (n samples)`).
- The `Adjust` line changes when the server hour changes.

## Limits, stated honestly

- **No trading.** This build cannot place, modify or close anything.
- The session table is the broker's. Holidays and one-off closures are not in it, so a
  holiday can still read `MARKET OPEN` until the quote goes stale.
- Named sessions are labels only. They never decide whether trading is allowed.
- The clock used for session reasoning is the broker's own last tick time while a feed is
  live, and the running server clock once the feed has stopped for more than five minutes —
  otherwise a closed market would freeze the "next open in …" countdown.
- The server's UTC offset is snapped to the nearest 15 minutes and rejected only if it is
  more than two minutes off that grid, because the two clocks are never sampled at exactly
  the same instant.
- Classification is a scoring heuristic over broker metadata. Unusual names fall back to
  `Other/Unknown` with the general profile, by design.
- The hour profile is held in memory only; it needs about five distinct days of that hour
  before it is used, and it starts over when the terminal restarts.
- Spread baseline samples accumulate while the EA runs; nothing is written to disk.

## Next stage (not in this build)

The three lanes (M5 / M15 / M30), the Kalman signal, plan calculation, execution and the
diary described in `automate.md` are deliberately absent. They come after this stage is
verified on your broker.
