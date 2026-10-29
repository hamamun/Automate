# Automate — a simple, self-configuring MT5 Expert Advisor

**Status: implementation plan, will build step by step the EA.** It includes the decisions already made, recommended starting rules, and the checks needed to build them. The proposed signal, target and forecasting methods everythin will be tested by user and confirmed its functionality accordingly.
**Hard rules:** 1. No fallback will be applicable here. 2. no fabricated items will be used. this will be the tools to real money trade so no falsification or fallback is allowed everything has to work.

**Quick reading:** Section 1 gives the idea, section 5 explains risk, and section 7 shows the proposed interface. Section 9 is mainly for the future coding chat.

## 1. The idea

Automate should feel familiar to a SimpleEA user, but be a new, lightweight EA with a more responsive view of current price movement. Attach it to an MT5 chart and it should discover the symbol, broker rules, account and market conditions itself. No symbol list, indicator periods, session times or broker settings should need to be entered by the user.

The EA works on three independent lanes for the chart's symbol:

| Lane | Purpose | Starting analysis horizon |
|---|---|---|
| **M5** | Scalping; generally shorter targets | 4 M5 bars, about 20 minutes |
| **M15** | Short-term trading | 6 M15 bars, about 90 minutes |
| **M30** | Intraday trading | 8 M30 bars, about 4 hours |

These horizons are starting settings for calculating and evaluating plans, **not deadlines for closing an open position**. Market conditions differ, so a longer horizon does not guarantee a larger target on every signal.

**Already decided:**

- Automatic trading and all three lanes start **ON**, with controls to turn them off. MT5's own Algo Trading permission must also be enabled; the EA cannot turn it on for the user.
- Each lane may have one active trade idea for the same symbol. **M5, M15 and M30 may each hold a position simultaneously**, including in different directions when the account permits it. A waiting entry occupies its lane too.
- Each position has **one main TP and one initial broker-side SL**. No TP1/TP2 partial exits, trailing stop or time-based forced exit in version 1. A custom trailing stop can be designed later.
- Keep BUY/SELL signals separate from permission to trade. A valid BUY can still show `HOLD: spread`, for example; the HOLD does not change the signal to SELL or erase it.
- Do not use ATR multipliers to set entry, TP or SL. Do not add a required manual commission input.
- Keep the SimpleEA-style learning diary, but do not let a small amount of trade history silently veto a signal or rewrite the strategy.
- These features should be automatic and responsive, not buried under many restrictive filters. Broker, account, margin, valid-order and protective-stop checks still apply.

## 2. What Automate discovers automatically

On startup and when conditions change, read the current MT5 environment:

- The exact chart symbol and suffix, description, currencies, contract and calculation mode, tick size, price digits, volume minimum/maximum/step, stops and freeze levels, permitted order types and expiry modes.
- Broker/company and server, account currency, equity, free margin, trading permissions and whether the account supports **hedging**. Never assume the broker or account from source code or from a symbol name.
- The symbol's broker-published trading sessions, current quote and spread. Observe recent completed price bars to adapt to that particular instrument and timeframe.
- A best-effort asset label such as forex, metal, index, energy, stock or crypto, using MT5 metadata. Broker naming varies: if classification is unclear, display `Other/Unknown` and use the general data-driven profile instead of blocking solely because of the label.

The source of SimpleEA shows how it reads MT5 and separates lanes; it does **not** reveal which broker or account is currently connected to the user's terminal. Automate should discover those facts at runtime; the user does not need to supply them.

### Market open, closed and sessions

- Use the broker's trade sessions, symbol trade mode, server time, connection/quote freshness and the broker's actual response. Support daily breaks, multiple sessions and sessions crossing midnight.
- If the symbol is genuinely closed, show **Market Closed** and do not start new trades. Keep any already-open position's broker-side SL/TP in place. A timer must refresh the panel even if no new ticks arrive.
- Do not falsely call every problem `Market Closed`: show `Disconnected`, `Stale quote`, `Trading unavailable` or `Market status unknown` as appropriate. An unsafe or unknown trading state holds new entries, with the reason visible.
- Show Asia/Tokyo, Europe/London, America/New York or overlaps when the UTC time and daylight-saving conversion can be determined reliably. For a consistent convention, use Tokyo 09:00–18:00, London 08:00–17:00 and New York 08:00–17:00 in each city's local time. These are informative labels, not proof that this broker's symbol is open. The broker's own schedule decides availability.
- Live UTC depends on the terminal computer's clock; mark a live session label as estimated if the clock cannot be independently verified. In the MT5 Strategy Tester, `TimeGMT()` equals simulated server time, so it cannot by itself reconstruct historical UTC. If the historical offset is unavailable, show `Session: unknown` rather than inventing a label. Do not block a valid signal just because the named session is unknown.
- Adapt to session conditions using recent observations grouped by **broker-server hour**; fall back to the general recent data when that hour has too little history. This works without a user-entered timezone and keeps the adaptation usable in both live operation and tests. Do not make Asia/London/New York a mandatory entry filter.

## 3. Signals: responsive, explainable and forward-looking

**Recommended starting design—not a tested claim of superiority:** use a small, causal **two-state Kalman-style filter** to estimate the current price level and its movement per bar. Combine it with short-term momentum and recent price structure. The three measurements all come from price and are correlated; agreement is **not** a probability of winning.

For each lane, update once when a bar closes and make a fresh decision for the next bar:

1. **Trend vote:** the filter's current slope points up or down.
2. **Momentum vote:** the latest two-bar price movement points up or down.
3. **Structure vote:** recent net movement and available confirmed swings support up or down.

Two or three votes in one direction give **BUY** or **SELL**. Fewer than two aligned votes gives **NO SIGNAL**. Show `2/3` or `3/3` as agreement, never as a win percentage. An optional intrabar `EARLY` preview may change before the bar closes; do not trade it as a confirmed signal.

Show **Steady**, **Mixed** or **Choppy** as context, using a simple 20-bar efficiency ratio and current price conditions. Suggested initial boundaries are 0.30 and 0.15; these are unvalidated settings, not market laws. A regime label, a higher-timeframe disagreement, a session name or a small learning diary should **not by itself** veto a valid signal. Required execution and safety checks remain in force.

This is forward-looking in the modest sense that the live filter projects the current movement into coming bars; it does not simply vote from old trade outcomes. It uses past prices, as every price-based model must, and it cannot know the future. Use filtered information available at the time—not a smoothed value calculated using future bars.

## 4. Entry, TP, SL and validity

When a signal is confirmed, calculate and display its proposed plan before sending an order. Show the signal even if a plan is not currently executable, along with the reason and any levels that can be calculated honestly.

### Entry recommendation

- **3/3 agreement:** use a market order at a fresh executable quote: **Ask for BUY**, **Bid for SELL**. The signal is eligible during the current bar; a later bar requires a fresh calculation. Create at most one trade idea for that lane and signal bar; only retry a definitive rejection after checking that no order or position was created.
- **2/3 agreement:** place a fixed pullback limit at a suitable recent **confirmed** support for BUY or resistance for SELL. Use the appropriate quote side. If there is no valid entry level, keep the signal visible and show why the order is on HOLD.
- Do not silently turn a limit into a market order, chase it by repeatedly moving the price, or open a second idea in the same lane. Request cancellation of a waiting limit on expiry, an opposite confirmed signal, or a confirmed close beyond its original SL in the wrong direction. Also request cancellation if its entry-to-TP distance no longer clears the current spread. A neutral signal alone does not erase it. Cancellation is not complete until the broker confirms it, and the order might fill first.

A proposed limit is valid for **three timeframe periods** from the start of the execution bar: normally 15 minutes for M5, 45 for M15 or 90 for M30. Show the exact broker-server expiry time. This is elapsed clock time, so a market break or missing bars can make it different from three actual traded candles.

Use broker-enforced exact expiry when supported. If only a longer-lived order can be placed, a local watchdog may request cancellation at the intended time, but the panel must say **Local expiry only — order can remain active if MT5 or the connection is down**. Never mark it cancelled until confirmed. Reconcile it on restart. If neither a supported order nor a safe plan can be made, show HOLD rather than inventing one.

### Stop and target

The following is an **initial, testable calculation**, not a validated profit formula:

1. **SL:** use a recent confirmed invalidation swing beyond the entry, with a small buffer based on the current spread and the broker's tick size. If necessary, use an actual recent 20-bar extreme on the protective side as a fallback. For a limit, the swing used for entry cannot also be the invalidation swing; the stop must be beyond it. If there is no defensible level, show HOLD.
2. **TP:** measure the symbol's typical completed-bar price displacement over the lane's 4/6/8-bar horizon. Use the median of up to 60 recent, non-overlapping horizon-length close-to-close moves, using only data available at the signal. Set one target in the signal direction using that measured distance. If a confirmed opposing swing lies closer, cap the target just before it. If no opposing swing is ahead, the measured move is the fallback, so breakouts are not automatically blocked simply for lack of an old swing.
3. Align entry, TP and SL to the actual tick grid and check the executable quote sides, broker stop/freeze distances and order rules. Do not widen a level merely to pass a check without rebuilding the plan and recalculating risk.
4. As an extra conservative screen, the **main TP's** entry-to-target distance must exceed the current spread. This is a screen, not a second spread charge or a guarantee that profit exceeds commission and slippage. If a valid target cannot clear it, display `HOLD: TP does not clear spread`.

For Bid-based bars, buy exits are checked against Bid and sell exits against Ask; convert chart structure to the relevant live quote side rather than pretending both sides are identical. For Last-price bars, historical Bid/Ask levels cannot be reconstructed reliably from Last alone: treat structure as approximate, verify it against live quotes, and hold if the quote basis needed to make a valid plan is unavailable. Do not assume all symbols have the same pip size.

**Important:** the median move is a price-distance heuristic, not a target-hit probability. It may be too small or too large in changing conditions and needs comparison against alternatives. M5 is intended to seek shorter scalping moves, but the broker's spread and actual market data determine whether any particular plan is viable.

### When might entry or TP occur?

Show a **rough forecast**, separately from order validity:

- For a market plan, entry is attempted now at a valid fresh quote, not on a guaranteed later bar.
- For a limit, estimate the bar of a possible **price touch** only when the current projected movement points toward the limit. Otherwise show `Entry timing: unclear`. A touch is not necessarily a broker fill. The actual order expiry is the separate three-period clock described above.
- For TP, project the current filtered movement toward the target and show an estimated bar only when the movement points toward it. For a pending order, the TP clock starts **after an actual fill**. If movement is too small, points away, or the projection lies outside the analysis horizon, show `TP timing: unclear/outside horizon` rather than fabricate a bar.
- Label every such number `estimate`, not a promise or a probability. Spread, price reversals, gaps, fills and the competing SL can invalidate the projection. Update the estimate as conditions change, without moving the original TP/SL.
- Record forecasts and actual results separately. Only add a confidence range or TP-hit percentage later if enough properly tracked observations and out-of-sample calibration support it. Count TP-first, SL-first and still-open outcomes separately; do not treat stopped-out trades as if they were still capable of hitting TP. Insufficient forecast history must not block a valid trade.

### A small worked example — illustration only

Suppose an imaginary EURUSD quote is Bid `1.10000`, Ask `1.10010`; the tick is `0.00001`. The M5 signal is BUY `3/3`. A confirmed support is `1.09920`, a resistance is `1.10140`, and the measured 4-bar move is `0.00120`.

| Item | Example calculation |
|---|---|
| Market entry | BUY at Ask = `1.10010` |
| SL | Support minus the `0.00010` spread buffer = `1.09910` |
| TP | Entry plus `0.00120` = `1.10130`; this is before resistance, so no cap is needed |
| Planned price distances | 10 pips to SL; 12 pips from entry to TP; current spread is 1 pip |
| TP projection | If the filtered Bid speed were +4 pips/bar and stayed constant, Bid has 13 pips to TP: roughly **bar 4**, not a guarantee |

For a USD account with $1,000 equity, if the broker's calculation says one lot would lose $100 at this stop, a 1% budget is $10 and the example volume is `0.10` lot. Actual contract rules, rounding, costs, fill and stop execution vary; Automate must ask MT5 to calculate them rather than assume these values.

## 5. Risk and automatic trading controls

**Recommended default: 1% of current equity per position**, not a claim that 1% is universally correct. It is a commonly discussed risk-sizing starting point. Do not automatically increase the percentage for a `3/3` score.

Provide simple optional controls; their defaults should work without the user configuring them:

| Control | Default | Meaning |
|---|---|---|
| Auto trading | ON | Permit new EA trades when MT5 and safety checks allow. |
| M5 / M15 / M30 | All ON | Any lane can separately be switched off. |
| Sizing mode | **1% equity** | Calculate the volume from planned entry-to-SL loss in account currency. The percentage may be changed. |
| Percentage bypass | Available, OFF | Choose broker **minimum lot** without applying the percentage cap; no amount needs to be entered. |
| Fixed lot | Optional | Use a user-selected lot size instead of a percentage cap, subject to the broker's valid volume rules. |

Use MT5's account-currency profit and margin calculations, the correct direction and executable entry, and round volume **down** to a valid step. If the minimum lot exceeds the percentage budget, show the reason; do not silently exceed the budget. The user can deliberately choose minimum-lot or fixed-lot mode if they accept the larger risk. Those modes **bypass the percentage cap, not broker, margin, stop or order checks**, and cannot guarantee that every signal will trade.

Three simultaneous 1%-sized ideas can have roughly **3% combined planned exposure**, even more after gaps, slippage and costs. Show estimated gross exposure for open positions and pending orders, without assuming opposite positions cancel the risk. For an open position, estimate additional loss from the current executable close quote to its SL; for a pending order, estimate loss from its planned entry to SL. Sum these without netting and label any unprotected or uncalculable part `unknown`. There is no separate aggregate percentage cap in this starting design. Actual loss can exceed any estimate. If future commission or fees are unknown, say `unknown` rather than assume zero; record the actual commission, fee and swap when attributable.

The confirmed three-independent-position behavior requires a **hedging account**. On a netting account, display `HOLD: hedging account required` for new entries; magic numbers cannot create three independent positions there. If the account restricts opposite hedges, hold the conflicting order and show why. Detect this automatically—do not ask the user to identify the account type.

Turning off the master or a lane stops its new entries and requests cancellation of its waiting orders; existing positions retain their broker SL/TP. If MT5 permission or connectivity prevents cancellation, warn that the order may still fill. Never claim it was cancelled without broker confirmation.

## 6. Learning, without hidden restrictions

Keep a small, SimpleEA-style diary for each symbol and lane:

- Record the signal time, score, regime, forecast, planned entry/SL/TP and estimated risk.
- Record whether an order was rejected, expired, cancelled, partially filled or filled; capture actual entry, exit and attributable profit, commission, swap and fee. Join the broker's deals to the correct position; a price touch is not a fill. Distinguish TP, SL, manual close, liquidation and still-open outcomes rather than calling every profitable close a TP.
- Show simple health information such as actual closed-trade count, wins/losses and net result, clearly separated from hypothetical observations. `Learning 8/30`, for example, is an informational label only, **not a 30-trade requirement for entries**.
- Initially, this diary observes and reports. Like the reviewed SimpleEA diary, it does not secretly alter signals, TP, SL, risk or the ON/OFF switches. Any later self-adjusting learning must be a separately tested feature.

## 7. Suggested interface

One compact panel on any chart timeframe, showing all three lanes for the attached symbol. Numbers below are **fictional**, not a live signal:

```text
 AUTOMATE    EURUSDm  |  Forex  |  Hedging  |  AUTO ON
 Market OPEN | Session: London / New York (est.) | Spread: 1.0 pip

 TF     TREND  REGIME   SCORE  SIGNAL  TRADE STATUS
 M5     UP     Steady    3/3    BUY     MARKET READY
 M15    DOWN   Mixed     2/3    SELL    LIMIT WAIT
 M30    UP     Steady    2/3    BUY     HOLD: minimum lot > risk

 Selected: M5 BUY             Entry: 1.10010 (market)
 SL: 1.09910                  TP:    1.10130
 Entry timing: now            TP estimate: ~bar 4 (uncertain)
 Size: 0.10 lot               Planned risk: ~$10 / 1% equity
 Combined exposure: estimate for all open/pending lanes
 Diary: learning 8/30         Unknown future costs: commission/fees
```

Use clear colors for direction and status, but always include text. Show actual order/position state and the first HOLD reason, not just a green signal. Allow the user to select a lane to inspect its plan and optionally draw its entry/SL/TP on the chart. Keep `Market Closed` prominent when appropriate. The panel should stay readable on smaller chart windows.

## 8. SimpleEA compared with the proposed Automate

| | Current SimpleEA | Automate starting plan |
|---|---|---|
| Lanes | M5, M15, M30; independent position ownership on hedging | Same, including three simultaneous positions on one symbol |
| Signal | Ehlers-based trend, rate of change and structure | Small adaptive level/slope filter, momentum and structure; test whether it actually improves anything |
| Trade permission | Direction and HOLD can be shown separately | Preserve that distinction, with fewer non-safety vetoes |
| Targets | Three calculated levels; TP3 is the main target | One main broker TP and one SL; no partial exits or ATR-multiplier levels |
| Risk default | 0.5% of balance, doubled for score 3; alternative sizing available | Recommended 1% of equity per lane; no score multiplier; explicit minimum/fixed-lot alternatives |
| Learning | Diary and health are observational | Retain observational learning; forecast calibration kept separate |
| Future bar | No guaranteed future entry or TP bar | Advisory projection only; `unclear` when it cannot honestly be estimated |

## 9. Notes for the coding chat

**Instruction:** Build a new MQL5 EA called `Automate` from this document in the new repository. Treat the items marked “already decided” as requirements. Use the numerical rules below as the initial implementation candidates, not as claims of an established edge. Do not ask for the broker, symbol, account type, session times, position count or indicator settings: detect them as described. Keep the code small, explainable and testable. Do not add a required external service, DLL, manual commission field, ATR-based price plan, partial exits or trailing stop.

### A concrete starting algorithm

- Work on `_Symbol` with explicit `PERIOD_M5`, `PERIOD_M15` and `PERIOD_M30`, independently of the chart timeframe. Request at least **200 closed bars** per lane for initial state; load more when available for the 60 movement windows and up to about ten server-days for the optional hour profile. Show `DATA WAIT` when real required bar data are missing; do not use a trade-outcome sample floor as a gate.
- Use a two-state local linear filter: state is price level and per-bar slope; predict the next state using the previous level plus slope, then update with the next **closed** price. Seed level from the first available closed price, slope at zero and a positive covariance. A small fixed 2×2 implementation is enough; do not run a heavy optimizer or use future-smoothed values.
- Estimate current noise from the median absolute deviation of the last 20 one-bar close changes, scaled by 1.4826; floor its variance at one tick squared. If at least five distinct days of same-server-hour data exist, blend that hour's scale with the recent scale; otherwise use recent scale alone. A reproducible starting model uses transition matrix `[[1,1],[0,1]]`, measurement `[1,0]`, measurement variance `R` from that noise estimate, and process covariance `q × R × [[0.25,0.5],[0.5,1]]`, where `q = 0.02 + 0.18 × efficiency_ratio`. Clip the ratio to 0–1. Use numerically stable covariance updates. These constants are candidates for testing, not user inputs or proof of an edge.
- For reproducible starting deadbands, take the median absolute one-bar close change over the last 20 completed bars. For momentum and structure use `max(one tick, 0.10 × that median)`; for per-bar trend slope use `max(one tenth of a tick, 0.05 × that median)`. Values outside the deadband vote up or down; otherwise the vote is neutral.
- Momentum is the signed two-bar close change. For structure, use the signed 20-bar close change; for a BUY vote, when two confirmed swing lows exist, also require the newer low not to be lower than the older one. For a SELL vote, when two confirmed swing highs exist, require the newer high not to be higher. A missing pair of swings does not itself veto the structure vote; missing actual price history does. Start with three-bar pivots confirmed only after the right-hand bar closes. A `2-of-3` majority produces a direction; `3-of-3` is stronger agreement, not a probability.
- For the TP displacement, take `abs(close[end] - close[start])` for each completed, non-overlapping 4/6/8-bar window, as applicable; use the median of up to the latest 60. With 200 bars, M30 has fewer than 30 such windows: use what is available rather than imposing a 30-observation veto. Zero/invalid movement or missing data is a genuine plan problem, not permission to invent a target.
- For a Bid-chart example, translate a BUY limit at Bid support to an Ask entry using the current spread; a SELL limit triggers on Bid resistance. A long stop uses a protective Bid swing below entry less the buffer; a short stop uses the protective Bid swing plus the current spread and buffer. Treat a nearby opposing swing already between the current exit quote and entry as an obstruction, not as something that can be ignored. Spread can change, so these are snapshot approximations and all levels must be checked again against live broker rules.
- For a simple timing projection, divide the distance to the relevant executable quote-side level by the current filtered movement per bar, rounding up to a bar number only when the movement points toward that level. Limit-entry timing uses the quote that would trigger the entry; TP timing uses the quote that would close the position and starts after fill. Mark it as a constant-speed scenario, not first-passage probability or a calibrated interval. Never force-close a position at the forecast horizon.

### Execution and recovery requirements

- Keep one managed idea per `(account, symbol, lane)`: normally one pending entry or one position. A partial fill can temporarily leave both a position and residual order; reconcile and resolve that state without opening another idea. Use stable, lane-specific magic identifiers and always filter by symbol. Never modify another EA's or a manual trade's orders or positions. Prevent two chart instances in the same terminal from sending the same idea; detect duplicate ownership and hold for reconciliation. A terminal-local lock does **not** coordinate separate terminals: in version 1 run only one active terminal per account/symbol and warn about this limitation.
- Persist an idea's identity and request state before submitting; on restart reconcile stored state with broker orders, deals and positions before allowing a new entry. If the state cannot be saved or resolved safely, hold the affected lane rather than risk a duplicate.
- Read actual account mode and broker properties at runtime. Refresh quotes and calculations before submitting. Validate volume steps—including non-decimal steps—price ticks, order types, stops, freeze levels, current spread, margin and trading permissions. Include known costs when possible, disclose unknown costs, and recalculate risk after rounding or any changed level. `OrderCalcMargin` is only an estimate and does not itself account for current positions and pending orders; also check the request and broker result.
- Read commission rules from MT5 when available. No rules returned or an error is not proof that the broker charges zero; leave future costs unknown when they cannot be estimated.
- Always request the initial broker-side SL and TP. If attached protection is unsupported, do not deliberately place an unprotected trade. If a filled position is found without its requested protection, raise an `UNPROTECTED` alert, pause new entries in that lane and attempt to attach the original protection; report failure instead of claiming it is safe. Treat API return, server acceptance, actual deals and open positions as different things. Check retcodes, handle rejection and partial fills, cancel an unwanted residual where possible, and reconcile before retrying an uncertain request or creating a replacement.
- Broker expiry is preferred. A local expiry/cancel watchdog is explicitly weaker when offline; show that limitation and reconcile after restart. Cancellation, fill and expiry can race, so keep the lane occupied until the broker state is resolved. Preserve existing positions and their broker-side protections when the EA restarts or trading is switched off.
- Do not claim that a server-side pending order cannot fill before a local spread or cancellation check; it can. Do not assume an SL fills at its requested price. Show all material uncertainties.

### Validation plan

The user decides when to perform the tests. Before relying on the EA:

1. **Compile in MetaEditor.** Add automated tests for BUY/SELL quote sides, tick and volume rounding, non-decimal steps, stop and margin failure, missing data, invalid spread, zero movement, market closure, session breaks, DST/unknown tester timezone and unsupported expiry.
2. Test placement, rejection, requotes, partial fills, simultaneous lanes, opposite-hedge restrictions, netting HOLD, local-only expiry, cancellation/fill races, restarts and multiple chart instances. Use broker retcodes and actual deal history, not just API booleans.
3. On the same broker and dates, compare Automate, SimpleEA and a simple baseline with real-tick Strategy Tester data, realistic spread, costs and request delay. Measure each lane and combined exposure. Record signal count and every HOLD reason so a supposedly responsive EA is not quietly filtering everything.
4. Use chronological development, forward periods and a final untouched later holdout; compute features only from information available then. Log all tried variants and prevent overlapping outcome windows from leaking across evaluation boundaries. Compare forecast bar accuracy, fill rate, TP-first, SL-first, still-open/expired counts, net results and drawdown. A historical touch is not a live fill.
5. Test across several symbols, sessions, costs and market conditions; stress wider spreads, slippage, gaps and outages. The user can then choose whether to run a forward demo and whether to trade live. None of these checks guarantees future performance.

## 10. References and context

- SimpleEA source reviewed at commit `1385785629a8ac3c471e8ca2da8517ad580437bc`: https://github.com/hamamun/SimpleEA/blob/1385785629a8ac3c471e8ca2da8517ad580437bc/SimpleAdvisor.mq5
- MQL5 local-linear Kalman library, October 2026: https://www.mql5.com/en/code/78795 — an implementation reference, not evidence that this proposed strategy is profitable.
- MQL5 competing-risks discussion: https://www.mql5.com/en/articles/23928 — TP and SL are competing outcomes; still-open positions are different.
- CME position-sizing discussion: https://www.cmegroup.com/education/courses/trade-and-risk-management/proper-position-size — 1% is a suggested starting point here, not a universal rule.
- MT5 account and symbol properties: https://www.mql5.com/en/docs/constants/environment_state/accountinformation and https://www.mql5.com/en/docs/constants/environment_state/marketinfoconstants
- MT5 broker sessions and tester UTC limitation: https://www.mql5.com/en/docs/marketinformation/symbolinfosessiontrade and https://www.mql5.com/en/docs/dateandtime/timegmt
- MT5 pending-order expiry, order-profit and commission calculations: https://www.mql5.com/en/book/automation/experts/experts_pending_expiration, https://www.mql5.com/en/docs/trading/ordercalcprofit and https://www.mql5.com/en/docs/marketinformation/symbolinfocommissions
- MT5 Strategy Tester: https://www.metatrader5.com/en/terminal/help/algotrading/testing

**No Automate code, MetaEditor compilation, MT5 backtest or live-broker validation has been performed for this plan.**
