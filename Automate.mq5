//+------------------------------------------------------------------+
//|  Automate.mq5                                                    |
//|                                                                  |
//|  STAGE 3 - entry, stop, target, size and the trade table.        |
//|                                                                  |
//|  What this build does:                                           |
//|    * reads the attached chart symbol and everything the broker   |
//|      publishes about it (path, description, contract rules);     |
//|    * classifies it (forex / metal / index / energy / crypto /    |
//|      stock / other), cross-checks that label against the real    |
//|      price and falls back to a general profile when unsure;      |
//|    * derives its own starting parameters from the class and      |
//|      from measured recent behaviour (per broker-server-hour);    |
//|    * reports market state - open / closed / disconnected /       |
//|      stale / trading unavailable / unknown - and the named       |
//|      session (Tokyo / London / New York) when real UTC can be    |
//|      established honestly;                                       |
//|    * measures M5, M15 and M30 independently on closed bars and   |
//|      reports TREND, REGIME, a three-vote SCORE and a SIGNAL,     |
//|      each with a forward horizon taken from that lane's own      |
//|      completed runs;                                             |
//|    * plans one trade per lane from that lane's own structure: a  |
//|      market entry at 3/3, or a limit resting on the nearest      |
//|      confirmed swing at 2/3; a stop behind confirmed structure;  |
//|      and one target measured by replaying the same setup over    |
//|      the lane's history. No structure, no trade - the panel      |
//|      says which piece was missing;                               |
//|    * sizes the plan from equity and the stop distance, rounded   |
//|      down, after checking the broker's lot and margin limits;    |
//|    * records what the panel claimed in an observational diary.   |
//|                                                                  |
//|  TRADING IS OFF.                                                 |
//|    TRADING_LIVE is a compile-time constant and it is false. The  |
//|    plan is still built, sized and shown - STATE reads PLAN - but |
//|    the gate sits immediately before OrderSend and nothing        |
//|    reaches the broker. Turning it on has to be a deliberate act: |
//|    change that one word and recompile.                           |
//|                                                                  |
//|  Three switches, all off by default and all safe to leave off:   |
//|  diary details, the tweak switch (nothing to tweak yet) and      |
//|  minimum lot (clamp a size up instead of refusing the trade).    |
//|  Everything else is discovered or measured.                      |
//+------------------------------------------------------------------+
#property copyright "Automate"
#property version   "1.30"
#property description "Automate stage 3: self-discovery, market and session status, trend / regime / score / signal per timeframe, and a planned trade per timeframe - entry, stop, target and size."
#property description "Three switches, all off by default. Trading is off at compile time, so no order can be sent. Attach to any chart and timeframe."

//==================================================================
//  INTERNAL CONSTANTS  (deliberately not inputs)
//==================================================================
#define EA_STAGE            "stage 3 - plans and execution"
#define PANEL_PREFIX        "AUT_"
#define PANEL_X             10
#define PANEL_Y             20
#define PANEL_PAD           10
#define FONT_NAME           "Consolas"
#define FONT_SIZE           10
#define LABEL_W             13
#define MAX_SESSIONS        64
#define SPREAD_SAMPLES      240
#define HOUR_MAX_VALUES     256

#define PROFILE_REFRESH_SEC 600     // rebuild the hour profile every 10 min
#define SESSION_REFRESH_SEC 300     // re-read the broker session table
#define SPREAD_SAMPLE_SEC   5       // spread sampling interval
#define STALE_MINUTES       5.0     // a quote older than this is stale
#define DRAW_MIN_MS         250     // never repaint faster than this

//  Stage 2.  Every threshold below was calibrated on synthetic series
//  before it was written down; the calibrations are in autotrade.md.
#define LANE_COUNT          3       // M5, M15, M30
#define CHANGE_WINDOW       20      // bars for the typical-bar size
#define TREND_PERIOD        30      // regression window for the trend vote
#define STRUCTURE_PERIOD    20      // net-move window for the structure vote
#define MOMENTUM_PERIOD     2       // two-bar close change
//  24 hours, not 128.  A 128-hour span on M5 is 1536 bars, so two
//  neighbouring readings are almost the same number: measured on real
//  candles it gave only ~13 independent observations in a whole file,
//  and the column read Choppy on 100% of bars - correctly, because at
//  that distance price is not drifting.  At 24 hours the same thresholds
//  produce the split they were designed for (5/20/75) on liquid pairs,
//  and the span still means the same 24 hours on every lane.
#define REGIME_HOURS        24      // equalised drift span, in hours
#define Z_STEADY            2.0     // regime boundary, standard deviations
#define Z_MIXED             1.0     // regime boundary, standard deviations
#define TREND_BAND_X        0.20    // trend deadband, in units of a typical bar
#define MOVE_BAND_X         0.50    // move deadband = X * med * sqrt(horizon)
#define MOVE_BAND_TICKS     1.00    // floor of the move deadband, in ticks
#define AGE_HISTORY         400     // completed runs kept per state
#define MIN_REMAIN_SAMPLES  6       // runs that outlived this age needed
#define SIGNAL_DURA_BARS    3       // "still standing this many bars on"
#define MIN_DURA_SAMPLES    12      // runs at risk before a durability is claimed
                                    // before a remaining life is claimed
#define SEED_BARS           800     // closed bars replayed at attach so AGE
                                    // has a median from the first second
#define TREND_L1            150     // Ehlers bandpass long period, log only
#define TREND_L2            24      // Ehlers bandpass short period, log only
#define PI_D                3.14159265358979323846

//  Colours - SimpleEA's palette, plus amber for HOLD reasons and red
//  for alerts.  Text always carries the meaning; colour only
//  reinforces it.
const color CLR_BG      = C'48,48,48';
const color CLR_BORDER  = C'96,96,96';
const color CLR_TITLE   = clrWhite;
const color CLR_TEXT    = clrSilver;
const color CLR_LABEL   = C'150,150,150';
const color CLR_VALUE   = clrWhite;
const color CLR_SECTION = C'120,180,220';
const color CLR_OK      = clrLime;
const color CLR_HOLD    = clrOrange;
const color CLR_ALERT   = clrRed;
const color CLR_DIM     = C'150,150,150';

//==================================================================
//  INPUTS
//==================================================================
//  Two, both switches, both false by default.  Neither defines a
//  measurement and neither has to be set correctly: leaving both off
//  is a complete, correct configuration.  See autotrade.md 2.1.
input bool InpDiaryDetails = false;   // Diary details
input bool InpTweakArm     = false;   // Tweak (arm one self-tweak)
input bool InpMinLot       = false;   // Minimum lot

//  Array indices for the classifier.  Plain integers on purpose: the
//  scoring code stays readable and free of enum/int conversions.
#define A_OTHER   0
#define A_FOREX   1
#define A_METAL   2
#define A_INDEX   3
#define A_ENERGY  4
#define A_CRYPTO  5
#define A_STOCK   6
#define A_COUNT   7

//==================================================================
//  TYPES
//==================================================================
enum ENUM_MARKET_CODE
{
   MS_OPEN        = 0,
   MS_CLOSED      = 1,
   MS_OFFLINE     = 2,
   MS_UNAVAILABLE = 3,
   MS_UNKNOWN     = 4,
   MS_STALE       = 5
};

//  Everything read from the terminal about this symbol.
struct SymbolFacts
{
   string   name;
   string   desc;
   string   path;
   string   baseCur;
   string   profitCur;
   string   sector;
   string   industry;
   int      digits;
   int      calcMode;
   int      tradeMode;
   int      spreadPts;
   double   point;
   double   tickSize;
   double   tickValue;
   double   bid;
   double   ask;
   double   spreadPrice;
   double   volMin;
   double   volMax;
   double   volStep;
   long     stopsLevel;
   long     freezeLevel;
   bool     hasQuote;
   bool     synced;
   datetime quoteTime;
};

//  The self-built configuration for this symbol.
struct AssetProfile
{
   int      clsIndex;     // A_FOREX, A_METAL, ...
   string   label;        // "Metal" / "Metal (unconfirmed)" / ...
   string   basis;        // which evidence decided it
   bool     unconfirmed;  // label kept for the user, general profile used
   int      warmupBars;   // closed bars required before any analysis
   int      bufferTicks;  // stop buffer beyond a confirmed swing
   double   spreadGateX;  // hold if spread > this x typical
   bool     sessionAware;
   string   note;         // what the session adjustment did
};

//  Current market state and its human wording.
struct MarketState
{
   ENUM_MARKET_CODE code;
   string   headline;     // "MARKET OPEN" / "MARKET CLOSED" / ...
   string   detail;       // "until 23:59 server" / "next open Mon 01:05"
   string   modeNote;     // "broker allows BUY only", "" when normal
   color    clr;
   datetime nextOpen;
   bool     hasSessions;
   bool     currentOpen;
};

//  One broker trading session, flattened to "which weekday + seconds".
struct SessionRec
{
   int   dow;       // 0 = Sunday ... 6 = Saturday
   int   startSec;  // seconds after server midnight
   int   durSec;    // length; may cross midnight
};

//  One timeframe's reading.  Recomputed only when a new bar of that
//  timeframe has closed, so a ticking chart costs nothing.
struct LaneState
{
   ENUM_TIMEFRAMES tf;
   string   name;
   bool     ready;
   datetime lastBar;     // open time of the last bar processed
   int      needBars;    // closed bars this lane requires
   int      haveBars;    // closed bars the terminal actually has
   int      trend;       // -1 DOWN / 0 FLAT / +1 UP
   double   slopeRatio;  // slope in units of a typical bar
   int      regime;      // 0 Steady / 1 Mixed / 2 Choppy
   double   zValue;      // standardised net move over the equalised span
   int      vMom;        // momentum vote
   int      vStr;        // structure vote
   int      score;       // trend + momentum + structure, -3 .. +3
   int      signal;      // -1 SELL / 0 none / +1 BUY
   int      trendAge;
   int      regimeAge;
   int      signalAge;
   int      signalDuraPct;  // chance this signal still stands N bars on
   bool     signalDuraOk;
   int      trendLeft;      // bars left, median of runs that outlived the age
   int      trendLeftPct;   // that as a share of the run's whole life
   int      trendLo;        // lower quartile of those residuals
   int      trendHi;        // upper quartile
   int      regimeLeft;
   int      regimeLeftPct;
   int      regimeLo;
   int      regimeHi;
   bool     trendLeftOk;    // false = not enough survived runs to say
   bool     regimeLeftOk;
   int      ehSign;      // Ehlers bandpass sign, comparison log only
};

//==================================================================
//  GLOBAL STATE
//==================================================================
SymbolFacts  g_f;
AssetProfile g_base;   // what classification decided, untouched
AssetProfile g_p;      // g_base plus this hour's adjustment
MarketState  g_m;

string g_line[];       // panel text, one entry per drawn line
color  g_lineClr[];    // colour per drawn line
int    g_lineSegFrom[];// first segment index of a coloured line, -1 = plain
int    g_lineSegN[];   // how many segments that line has
string g_segText[];    // segment text, concatenated into g_line[]
color  g_segClr[];     // segment colour
string g_segTip[];     // hover text for that segment, "" = none
int    g_drawn = 0;    // labels currently on the chart

SessionRec g_sess[MAX_SESSIONS];
int        g_sessCount = 0;

double g_hourMove[24];   // median |close-to-close| per server hour
int    g_hourDays[24];   // distinct days observed for that hour
double g_recentMove = 0; // median |close-to-close| of recent bars
int    g_recentN    = 0;

double g_spr[24][SPREAD_SAMPLES];  // running spread samples per hour
int    g_sprN[24];

//  Stage 2 state.  Two channels per lane - 0 trend, 1 regime - each
//  keeping AGE_HISTORY completed run lengths.  Flattened into one
//  array because MQL5 cannot pass a single row of a 2-D array by
//  reference.
LaneState g_lane[LANE_COUNT];

//  Three tracked states per lane: 0 = trend, 1 = regime, 2 = signal.
#define CH_PER_LANE   3
#define RUN_CHANNELS  LANE_COUNT * CH_PER_LANE

int g_runHist[RUN_CHANNELS * AGE_HISTORY];
int g_runCount[RUN_CHANNELS];
int g_runNow[RUN_CHANNELS];
int g_runPrev[RUN_CHANNELS];
#define RUN_UNSET  -99

int g_ehAgree    = 0;   // Ehlers bandpass agreed with the trend vote
int g_ehDisagree = 0;   // ... and did not

datetime g_lastProfile  = 0;
datetime g_lastSessions = 0;
datetime g_lastSample   = 0;

//  Vocabulary used by the classifier.  Kept as data so the rules can
//  be read and changed in one place.
string ISO_CCY     = "USD|EUR|GBP|JPY|CHF|AUD|NZD|CAD|SEK|NOK|DKK|PLN|CZK|HUF|TRY|ZAR|MXN|BRL|INR|CNH|CNY|KRW|SGD|HKD|THB|IDR|MYR|PHP|RUB|ILS|AED|SAR|RON|BGN|HRK|ISK|CLP|COP|PEN|ARS|NGN|KES|EGP|PKR|BDT|LKR|VND|TWD";
string METAL_CODE  = "XAU|XAG|XPT|XPD|XRH";
string CRYPTO_CODE = "BTC|ETH|XRP|LTC|BCH|ETC|ADA|SOL|DOT|DOGE|SHIB|BNB|AVAX|TRX|XLM|ATOM|NEAR|APT|ARB|MATIC|LINK|TON|USDT|USDC";

string METAL_TOK   = "XAU|XAG|XPT|XPD|GOLD|SILVER|PLATINUM|PALLADIUM";
string CRYPTO_TOK  = "BTC|ETH|XRP|LTC|BCH|DOGE|SHIB|BNB|SOLUSD|SOLUSDT|AVAX|ADA|DOT|TRX|XLM|USDT|USDC|CRYPTO";
string ENERGY_TOK  = "WTI|BRENT|USOIL|UKOIL|CRUDE|NATGAS|NGAS|XNG|XBR|XTI|HEATING|GASOLINE|OIL";
string INDEX_TOK   = "US500|SP500|SPX|NAS100|NASDAQ|US100|USTEC|NDX|US30|DJ30|DOW|DJIA|US2000|RUSSELL|DE30|DE40|GER30|GER40|DAX|UK100|FTSE|JP225|NIKKEI|HK50|HSI|AUS200|ASX200|F40|CAC|EU50|STOXX|ES35|IBEX|IT40|SWI20|SMI|VIX";

string STOCK_PATH  = "STOCK|STOCKS|SHARE|SHARES|EQUIT|ETF";
string FOREX_PATH  = "FOREX|CURRENC";
string CRYPTO_PATH = "CRYPTO|DIGITAL";
string METAL_PATH  = "METAL|METALS|PRECIOUS";
string ENERGY_PATH = "ENERG|OIL|OILS|COMMODIT";
string INDEX_PATH  = "INDEX|INDEXES|INDICES";

string SECTOR_STOCK   = "TECHNOLOGY|FINANCIAL|HEALTH|CONSUMER|INDUSTRIAL|UTILIT|MATERIAL|TELECOM|REAL ESTATE|ENERGY";
string INDUSTRY_STOCK = "SOFTWARE|BANK|PHARM|RETAIL|SEMICONDUCTOR|APPAREL|AUTO|MINING|AEROSPACE|INSURANCE|BEVERAGE|AIRLINE";

//==================================================================
//  SMALL UTILITIES
//==================================================================
string Spaces(int n)
{
   string s = "";
   for(int i = 0; i < n; i++) s += " ";
   return(s);
}

string Pad(string text, int width)
{
   int n = StringLen(text);
   if(n >= width) return(text);
   return(text + Spaces(width - n));
}

//  "Label   value" with one leading space, used by every detail line.
string L(string label, string value)
{
   return(" " + Pad(label, LABEL_W) + value);
}

string Upper(string s)
{
   string t = s;
   StringToUpper(t);
   return(t);
}

//  Case-insensitive substring match against a '|' separated list.
//  A plain substring hit is intentional: broker names glue the code
//  together with suffixes ("XAUUSDm", "US500.cash").
bool HasToken(string hay, string packed)
{
   if(hay == "" || packed == "") return(false);
   string parts[];
   int n = StringSplit(packed, '|', parts);
   for(int i = 0; i < n; i++)
      if(StringLen(parts[i]) > 0 && StringFind(hay, parts[i]) >= 0) return(true);
   return(false);
}

//  Exact match against a '|' separated list (used for currency codes).
bool EqualsAny(string s, string packed)
{
   if(s == "" || packed == "") return(false);
   string parts[];
   int n = StringSplit(packed, '|', parts);
   for(int i = 0; i < n; i++)
      if(s == parts[i]) return(true);
   return(false);
}

double MedianOfArray(double &data[])
{
   int n = ArraySize(data);
   if(n <= 0) return(0.0);
   double tmp[];
   ArrayResize(tmp, n);
   ArrayCopy(tmp, data);
   ArraySort(tmp);
   if((n % 2) == 1) return(tmp[n / 2]);
   return(0.5 * (tmp[n / 2 - 1] + tmp[n / 2]));
}

string Hhmm(long sec)
{
   long s = sec % 86400;
   if(s < 0) s += 86400;
   return(StringFormat("%02d:%02d", (int)(s / 3600), (int)((s % 3600) / 60)));
}

string HumanDelta(datetime from, datetime to)
{
   long d = (long)to - (long)from;
   if(d <= 0) return("now");
   long days = d / 86400;
   long rem  = d % 86400;
   long h    = rem / 3600;
   long m    = (rem % 3600) / 60;
   if(days > 0) return(StringFormat("%dd %dh", (int)days, (int)h));
   if(h > 0)    return(StringFormat("%dh %dm", (int)h, (int)m));
   return(StringFormat("%dm", (int)m));
}

string WeekdayName(int dow)
{
   switch(dow)
   {
      case 0: return("Sun");
      case 1: return("Mon");
      case 2: return("Tue");
      case 3: return("Wed");
      case 4: return("Thu");
      case 5: return("Fri");
      case 6: return("Sat");
   }
   return("?");
}

string WeekdayShort(datetime t)
{
   MqlDateTime st;
   TimeToStruct(t, st);
   return(WeekdayName(st.day_of_week));
}

//==================================================================
//  STRUCT COPY
//==================================================================
//  AssetProfile contains strings, so it is a complex structure.
//  Copy it field by field rather than relying on structure
//  assignment, which is not portable across MQL5 builds.
void CopyProfile(const AssetProfile &src, AssetProfile &dst)
{
   dst.clsIndex     = src.clsIndex;
   dst.label        = src.label;
   dst.basis        = src.basis;
   dst.unconfirmed  = src.unconfirmed;
   dst.warmupBars   = src.warmupBars;
   dst.bufferTicks  = src.bufferTicks;
   dst.spreadGateX  = src.spreadGateX;
   dst.sessionAware = src.sessionAware;
   dst.note         = src.note;
}

//==================================================================
//  CLOCK
//==================================================================
datetime ServerNow()
{
   datetime tc = TimeCurrent();       // broker's own last tick time
   datetime ts = TimeTradeServer();   // keeps running offline

   if(tc <= 0) return(ts);
   if(ts <= 0) return(tc);

   long drift = (long)ts - (long)tc;
   if(drift < 0) drift = -drift;

   //  Within five minutes they describe the same moment, so the
   //  broker's tick time is preferred.  Beyond that the tick feed has
   //  stopped and only the running clock can still be used.
   if(drift <= 300) return(tc);
   return(ts);
}

//==================================================================
//  DISCOVERY - read what the terminal already knows
//==================================================================
void DiscoverSymbol(SymbolFacts &f)
{
   f.name      = _Symbol;
   f.desc      = SymbolInfoString(_Symbol, SYMBOL_DESCRIPTION);
   f.path      = SymbolInfoString(_Symbol, SYMBOL_PATH);
   f.baseCur   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   f.profitCur = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);
   f.sector    = SymbolInfoString(_Symbol, SYMBOL_SECTOR_NAME);
   f.industry  = SymbolInfoString(_Symbol, SYMBOL_INDUSTRY_NAME);

   f.digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   f.calcMode  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
   f.tradeMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   f.point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   f.tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   f.tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

   f.volMin    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   f.volMax    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   f.volStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   f.stopsLevel  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   f.freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);

   f.synced = SymbolIsSynchronized(_Symbol);
   UpdateQuote(f);
}

//  Quote-only refresh, cheap enough to run on every tick.
void UpdateQuote(SymbolFacts &f)
{
   MqlTick t;
   bool got = SymbolInfoTick(_Symbol, t);
   f.hasQuote = got;

   if(got && t.bid > 0.0 && t.ask > 0.0)
   {
      f.bid = t.bid;
      f.ask = t.ask;
      f.quoteTime = (datetime)t.time;
   }
   else
   {
      f.bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      f.ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   }

   f.spreadPrice = (f.ask > 0.0 && f.bid > 0.0) ? (f.ask - f.bid) : 0.0;
   f.spreadPts   = (f.point > 0.0) ? (int)MathRound(f.spreadPrice / f.point) : 0;
}

string CalcModeText(int mode)
{
   ENUM_SYMBOL_CALC_MODE m = (ENUM_SYMBOL_CALC_MODE)mode;
   switch(m)
   {
      case SYMBOL_CALC_MODE_FOREX:             return("Forex");
      case SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE: return("Forex, no leverage");
      case SYMBOL_CALC_MODE_CFD:               return("CFD");
      case SYMBOL_CALC_MODE_CFDINDEX:          return("CFD index");
      case SYMBOL_CALC_MODE_CFDLEVERAGE:       return("CFD, leverage");
      case SYMBOL_CALC_MODE_FUTURES:           return("Futures");
      case SYMBOL_CALC_MODE_EXCH_STOCKS:       return("Exchange stocks");
      case SYMBOL_CALC_MODE_EXCH_FUTURES:      return("Exchange futures");
   }
   return("Mode " + IntegerToString(mode));
}

string AccountModeText()
{
   ENUM_ACCOUNT_MARGIN_MODE m = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   switch(m)
   {
      case ACCOUNT_MARGIN_MODE_RETAIL_HEDGING: return("Hedging");
      case ACCOUNT_MARGIN_MODE_RETAIL_NETTING: return("Netting");
      case ACCOUNT_MARGIN_MODE_EXCHANGE:       return("Exchange");
   }
   return("Account ?");
}

//==================================================================
//  CLASSIFICATION - decide what this symbol is
//==================================================================
string ClassLabel(int idx)
{
   switch(idx)
   {
      case A_FOREX:  return("Forex");
      case A_METAL:  return("Metal");
      case A_INDEX:  return("Index");
      case A_ENERGY: return("Energy");
      case A_CRYPTO: return("Crypto");
      case A_STOCK:  return("Stock");
   }
   return("Other/Unknown");
}

//  The starting parameters per class.  Only values that genuinely
//  differ between instruments live here; entry, stop, target and lot
//  size are derived from the symbol itself, never from this table.
void ApplyBaseProfile(int idx, AssetProfile &p)
{
   p.clsIndex     = idx;
   p.warmupBars   = 200;
   p.sessionAware = true;

   switch(idx)
   {
      case A_FOREX:  p.bufferTicks = 2;  p.spreadGateX = 2.0; break;
      case A_METAL:  p.bufferTicks = 5;  p.spreadGateX = 2.0; break;
      case A_INDEX:  p.bufferTicks = 8;  p.spreadGateX = 2.5; break;
      case A_ENERGY: p.bufferTicks = 8;  p.spreadGateX = 2.5; break;
      case A_CRYPTO: p.bufferTicks = 20; p.spreadGateX = 3.0; break;
      case A_STOCK:  p.bufferTicks = 10; p.spreadGateX = 2.5; break;
      default:       p.bufferTicks = 5;  p.spreadGateX = 2.0; break;
   }
}

//  A label is only believed when the price behaves like it.  A metal
//  priced like EURUSD, or "forex" priced like gold, is a broker naming
//  quirk - keep the name visible, use the general profile.
bool BehaviourAgrees(int idx, const SymbolFacts &f, string &why)
{
   double px = 0.5 * (f.bid + f.ask);
   if(px <= 0.0) return(true);            // no quote yet: nothing to check

   if(idx == A_FOREX)
   {
      if(px > 500.0) { why = StringFormat("price %.2f is not FX-like", px); return(false); }
      if(px < 0.05)  { why = StringFormat("price %.5f is not FX-like", px); return(false); }
   }
   if(idx == A_METAL && px < 1.0)
   {
      why = StringFormat("price %.4f is too low for metal", px);
      return(false);
   }
   if(idx == A_INDEX && px < 20.0)
   {
      why = StringFormat("price %.2f is too low for an index", px);
      return(false);
   }
   return(true);
}

void ClassifySymbol(const SymbolFacts &f, AssetProfile &p)
{
   string nm  = Upper(f.name);
   string pth = Upper(f.path);
   string dsc = Upper(f.desc);
   string bas = Upper(f.baseCur);
   string pft = Upper(f.profitCur);
   string sec = Upper(f.sector);
   string ind = Upper(f.industry);

   int    sc[A_COUNT];
   string ev[A_COUNT];
   for(int i = 0; i < A_COUNT; i++)
   {
      sc[i] = 0;
      ev[i] = "";
   }

   // ---- name and path are the strongest broker-specific hints ----
   if(HasToken(nm, CRYPTO_TOK))   { sc[A_CRYPTO] += 4; ev[A_CRYPTO] += "name, "; }
   if(HasToken(nm, METAL_TOK))    { sc[A_METAL]  += 4; ev[A_METAL]  += "name, "; }
   if(HasToken(nm, ENERGY_TOK))   { sc[A_ENERGY] += 4; ev[A_ENERGY] += "name, "; }
   if(HasToken(nm, INDEX_TOK))    { sc[A_INDEX]  += 4; ev[A_INDEX]  += "name, "; }
   if(HasToken(pth, CRYPTO_PATH)) { sc[A_CRYPTO] += 4; ev[A_CRYPTO] += "path, "; }
   if(HasToken(pth, METAL_PATH))  { sc[A_METAL]  += 4; ev[A_METAL]  += "path, "; }
   if(HasToken(pth, ENERGY_PATH)) { sc[A_ENERGY] += 3; ev[A_ENERGY] += "path, "; }
   if(HasToken(pth, INDEX_PATH))  { sc[A_INDEX]  += 4; ev[A_INDEX]  += "path, "; }
   if(HasToken(pth, STOCK_PATH))  { sc[A_STOCK]  += 3; ev[A_STOCK]  += "path, "; }
   if(HasToken(pth, FOREX_PATH))  { sc[A_FOREX]  += 3; ev[A_FOREX]  += "path, "; }

   // ---- the name itself: EURUSD, GBPJPY, USDJPYm ... ----
   //  Two ISO codes glued together is strong evidence even when the
   //  broker files the symbol in an unhelpful folder.  Crypto and
   //  metal codes are excluded first so BTCUSD and XAUUSD never land
   //  here, and a 4-letter quote like USDT blocks the rule.
   bool nameFx = false;
   if(StringLen(nm) >= 6 && !HasToken(nm, CRYPTO_TOK) && !HasToken(nm, METAL_TOK))
   {
      string h1 = StringSubstr(nm, 0, 3);
      string h2 = StringSubstr(nm, 3, 3);
      if(EqualsAny(h1, ISO_CCY) && EqualsAny(h2, ISO_CCY)) nameFx = true;
   }
   if(nameFx)
   {
      sc[A_FOREX] += 4;
      ev[A_FOREX] += "name, ";
   }

   // ---- currency codes: two ISO codes means an FX pair ----
   bool baseIso   = EqualsAny(bas, ISO_CCY);
   bool profitIso = EqualsAny(pft, ISO_CCY);
   if(baseIso && profitIso)
   {
      sc[A_FOREX] += 2;
      ev[A_FOREX] += "ccy, ";
   }
   if(EqualsAny(bas, METAL_CODE))  { sc[A_METAL]  += 4; ev[A_METAL]  += "base, "; }
   if(EqualsAny(bas, CRYPTO_CODE)) { sc[A_CRYPTO] += 4; ev[A_CRYPTO] += "base, "; }

   // ---- calculation mode ----
   if(f.calcMode == (int)SYMBOL_CALC_MODE_FOREX ||
      f.calcMode == (int)SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)
   {
      sc[A_FOREX] += 2;
      ev[A_FOREX] += "calc, ";
      sc[A_METAL] += 1;                       // metals are usually Forex-calculated
   }
   if(f.calcMode == (int)SYMBOL_CALC_MODE_CFDINDEX)
   {
      sc[A_INDEX] += 3;
      ev[A_INDEX] += "calc, ";
   }
   if(f.calcMode == (int)SYMBOL_CALC_MODE_EXCH_STOCKS)
   {
      sc[A_STOCK] += 3;
      ev[A_STOCK] += "calc, ";
   }
   if(f.calcMode == (int)SYMBOL_CALC_MODE_FUTURES)
   {
      sc[A_ENERGY] += 1;
   }

   // ---- description and exchange metadata ----
   if(HasToken(dsc, "GOLD|SILVER|PLATINUM|PALLADIUM"))  { sc[A_METAL]  += 3; ev[A_METAL]  += "desc, "; }
   if(HasToken(dsc, "BITCOIN|ETHEREUM|CRYPTO|DOGECOIN")){ sc[A_CRYPTO] += 3; ev[A_CRYPTO] += "desc, "; }
   if(HasToken(dsc, "CRUDE|BRENT|NATURAL GAS|WTI|OIL")) { sc[A_ENERGY] += 3; ev[A_ENERGY] += "desc, "; }
   if(HasToken(dsc, "INDEX|INDICES"))                   { sc[A_INDEX]  += 2; ev[A_INDEX]  += "desc, "; }
   if(HasToken(dsc, " VS "))                            { sc[A_FOREX]  += 1; ev[A_FOREX]  += "desc, "; }
   if(HasToken(sec, SECTOR_STOCK))                      { sc[A_STOCK]  += 2; ev[A_STOCK]  += "sector, "; }
   if(HasToken(ind, INDUSTRY_STOCK))                    { sc[A_STOCK]  += 2; ev[A_STOCK]  += "industry, "; }

   // ---- pick the winner, but only when it clearly leads ----
   int best = A_OTHER, bestScore = 0, second = 0;
   for(int c = A_FOREX; c <= A_STOCK; c++)
   {
      if(sc[c] > bestScore)
      {
         second    = bestScore;
         bestScore = sc[c];
         best      = c;
      }
      else if(sc[c] > second)
      {
         second = sc[c];
      }
   }

   p.note = "";

   //  Weak or contested evidence is not a classification.  The general
   //  profile is used and the panel says so; nothing is blocked.
   if(bestScore < 4 || (bestScore - second) < 2)
   {
      ApplyBaseProfile(A_OTHER, p);
      p.label       = ClassLabel(A_OTHER);
      p.basis       = (bestScore > 0 ? "weak evidence only" : "no reliable evidence");
      p.unconfirmed = true;
      return;
   }

   ApplyBaseProfile(best, p);
   p.label       = ClassLabel(best);
   p.unconfirmed = false;

   string basis = ev[best];
   if(StringLen(basis) >= 2 && StringSubstr(basis, StringLen(basis) - 2, 2) == ", ")
      basis = StringSubstr(basis, 0, StringLen(basis) - 2);
   p.basis = basis;

   string why = "";
   if(!BehaviourAgrees(best, f, why))
   {
      //  Keep the likely name visible so the user can judge it, but do
      //  not trust it for sizing: use the general profile instead.
      ApplyBaseProfile(A_OTHER, p);
      p.label       = ClassLabel(best) + " (unconfirmed)";
      p.basis       = basis + "; " + why;
      p.unconfirmed = true;
   }
}

//==================================================================
//  MEASURED BEHAVIOUR - recent and per server-hour typical movement
//==================================================================
void BuildHourProfile()
{
   for(int h = 0; h < 24; h++)
   {
      g_hourMove[h] = 0.0;
      g_hourDays[h] = 0;
   }
   g_recentMove = 0.0;
   g_recentN    = 0;

   MqlRates r[];
   int n = CopyRates(_Symbol, PERIOD_M5, 0, 3200, r);
   if(n < 30) return;
   ArraySetAsSeries(r, true);           // r[0] is the newest bar

   double   vals[24][HOUR_MAX_VALUES];
   int      cnt[24];
   datetime lastDay[24];
   for(int h = 0; h < 24; h++)
   {
      cnt[h] = 0;
      lastDay[h] = 0;
   }

   double recent[];
   ArrayResize(recent, 0);

   for(int i = 0; i < n - 1; i++)
   {
      double d = MathAbs(r[i].close - r[i + 1].close);
      if(!MathIsValidNumber(d) || d <= 0.0) continue;

      MqlDateTime st;
      TimeToStruct(r[i].time, st);
      int h = st.hour;
      if(h < 0 || h > 23) continue;

      if(cnt[h] < HOUR_MAX_VALUES)
      {
         vals[h][cnt[h]] = d;
         cnt[h] = cnt[h] + 1;
      }

      //  Distinct-day count per hour: the bars are contiguous, so a
      //  change of date inside one hour's bucket means a new day.
      datetime dayStart = (datetime)(((long)r[i].time / 86400) * 86400);
      if(lastDay[h] != dayStart)
      {
         lastDay[h] = dayStart;
         g_hourDays[h] = g_hourDays[h] + 1;
      }

      if(i < 200)
      {
         int k = ArraySize(recent);
         ArrayResize(recent, k + 1);
         recent[k] = d;
      }
   }

   for(int h = 0; h < 24; h++)
   {
      if(cnt[h] <= 0)
      {
         g_hourMove[h] = 0.0;
         continue;
      }
      double tmp[];
      ArrayResize(tmp, cnt[h]);
      for(int k = 0; k < cnt[h]; k++) tmp[k] = vals[h][k];
      g_hourMove[h] = MedianOfArray(tmp);
   }

   if(ArraySize(recent) > 0)
   {
      g_recentMove = MedianOfArray(recent);
      g_recentN    = ArraySize(recent);
   }
}

//  Spread samples: an in-memory baseline for "is this spread normal
//  for this symbol at this hour?".  Nothing is written to disk.
void SampleSpread()
{
   if(g_f.point <= 0.0 || g_f.spreadPts <= 0) return;

   datetime now = ServerNow();
   if(g_lastSample > 0 && (now - g_lastSample) < SPREAD_SAMPLE_SEC) return;
   g_lastSample = now;

   MqlDateTime st;
   TimeToStruct(now, st);
   int h = st.hour;
   if(h < 0 || h > 23) return;

   int c = g_sprN[h];
   if(c < SPREAD_SAMPLES)
   {
      g_spr[h][c] = (double)g_f.spreadPts;
      g_sprN[h] = c + 1;
   }
   else
   {
      //  Shift left and append: keeps the newest samples, cheap at 240.
      for(int i = 1; i < SPREAD_SAMPLES; i++) g_spr[h][i - 1] = g_spr[h][i];
      g_spr[h][SPREAD_SAMPLES - 1] = (double)g_f.spreadPts;
   }
}

double SpreadBaseline(int hour, int &samples)
{
   samples = 0;

   if(hour >= 0 && hour < 24 && g_sprN[hour] > 0)
   {
      double tmp[];
      ArrayResize(tmp, g_sprN[hour]);
      for(int i = 0; i < g_sprN[hour]; i++) tmp[i] = g_spr[hour][i];
      samples = g_sprN[hour];
      return(MedianOfArray(tmp));
   }

   //  Fall back to every hour sampled so far.
   double all[];
   int total = 0;
   for(int h = 0; h < 24; h++)
   {
      for(int i = 0; i < g_sprN[h]; i++)
      {
         int k = ArraySize(all);
         ArrayResize(all, k + 1);
         all[k] = g_spr[h][i];
         total++;
      }
   }
   samples = total;
   if(total <= 0) return(0.0);
   return(MedianOfArray(all));
}

//==================================================================
//  SESSIONS - read the broker's own trading session table
//==================================================================
void ReadSessions()
{
   g_sessCount = 0;

   for(int d = 0; d < 7; d++)
   {
      uint idx = 0;
      datetime from = 0, to = 0;

      while(g_sessCount < MAX_SESSIONS &&
            SymbolInfoSessionTrade(_Symbol, (ENUM_DAY_OF_WEEK)d, idx, from, to))
      {
         long dur = (long)to - (long)from;

         MqlDateTime fs;
         TimeToStruct(from, fs);
         long startSec = (long)fs.hour * 3600 + (long)fs.min * 60 + (long)fs.sec;

         //  A session may be published as ending on the following day
         //  (22:00 -> 02:00): the duration is then still correct.  Some
         //  servers publish an end of 00:00 on the same date instead,
         //  which shows up as a negative duration and means "+1 day".
         if(dur < 0) dur += 86400;
         if(dur > 2 * 86400) dur = 2 * 86400;

         //  A 24-hour session is sometimes published as 00:00 -> 00:00
         //  with no end date.  A zero-length day can only mean full day.
         if(dur == 0 && startSec == 0) dur = 86400;

         g_sess[g_sessCount].dow      = d;
         g_sess[g_sessCount].startSec = (int)startSec;
         g_sess[g_sessCount].durSec   = (int)dur;
         g_sessCount++;

         idx++;
      }
   }
}

//  Is the symbol tradable at this server time?  Handles multiple
//  sessions per day and sessions that cross midnight.
bool IsOpenNow(datetime serverNow, datetime &untilEnd)
{
   untilEnd = 0;
   if(g_sessCount <= 0) return(false);

   MqlDateTime st;
   TimeToStruct(serverNow, st);
   int  dow  = st.day_of_week;
   long secs = (long)serverNow % 86400;

   bool open = false;

   for(int i = 0; i < g_sessCount; i++)
   {
      long start  = (long)g_sess[i].startSec;
      long end    = start + (long)g_sess[i].durSec;
      long offset = -1;

      if(g_sess[i].dow == dow)                offset = 0;
      else if(g_sess[i].dow == (dow + 6) % 7) offset = 86400;   // yesterday's tail
      else                                    continue;

      long at = secs + offset;
      if(at >= start && at < end)
      {
         //  End of this occurrence, expressed as an absolute time.
         datetime e = (datetime)((long)serverNow + (end - at));
         if(untilEnd == 0 || e > untilEnd) untilEnd = e;
         open = true;
      }
   }

   return(open);
}

//  Next moment the symbol opens, scanning up to a full week ahead.
datetime NextOpenTime(datetime serverNow)
{
   if(g_sessCount <= 0) return(0);

   MqlDateTime st;
   TimeToStruct(serverNow, st);
   int  dow      = st.day_of_week;
   long secs     = (long)serverNow;
   long dayStart = secs - (secs % 86400);

   datetime best = 0;

   for(int off = 0; off <= 8; off++)
   {
      for(int i = 0; i < g_sessCount; i++)
      {
         if(g_sess[i].dow != (dow + off) % 7) continue;

         datetime cand = (datetime)(dayStart + (long)off * 86400 + (long)g_sess[i].startSec);
         if((long)cand <= secs) continue;
         if(best == 0 || cand < best) best = cand;
      }
   }

   return(best);
}

int CountSessionsForDay(int dow)
{
   int c = 0;
   for(int i = 0; i < g_sessCount; i++)
      if(g_sess[i].dow == dow) c++;
   return(c);
}

//  How many session entries does the broker publish today, and what
//  are the first two windows?
//  One session window as text.  A full-day session ends exactly at
//  midnight, which Hhmm() would print as 00:00 - reading like a
//  zero-length window.  Print the end of the day as 24:00 instead.
string SessionRange(int startSec, int durSec)
{
   long start = (long)startSec;
   long end   = start + (long)durSec;

   string left = Hhmm(start);

   if(durSec >= 86400) return(left + "-24:00");
   if(end == 86400)    return(left + "-24:00");
   return(left + "-" + Hhmm(end));
}

string TodayWindows(int dow, int maxShown)
{
   string s = "";
   int shown = 0;

   for(int i = 0; i < g_sessCount; i++)
   {
      if(g_sess[i].dow != dow) continue;
      if(shown >= maxShown) { s += ", ..."; break; }

      s += (shown > 0 ? ", " : "");
      s += SessionRange(g_sess[i].startSec, g_sess[i].durSec);
      shown++;
   }

   if(s == "") s = "none";
   return(s);
}

string WeekdayList()
{
   string s = "";
   for(int d = 0; d < 7; d++)
      if(CountSessionsForDay(d) > 0) s += WeekdayName(d) + " ";
   if(s == "") s = "none";
   return(s);
}

//==================================================================
//  UTC and named sessions
//==================================================================
//  Day-of-week arithmetic for the two daylight-saving rules.  This is
//  calendar math on UTC, not broker data.
datetime NthSundayOfMonth(int year, int month, int nth)
{
   MqlDateTime st;
   st.year = year; st.mon = month; st.day = 1;
   st.hour = 0; st.min = 0; st.sec = 0;

   datetime first = StructToTime(st);
   MqlDateTime f;
   TimeToStruct(first, f);

   int add = (7 - f.day_of_week) % 7;   // days until the first Sunday
   int day = 1 + add + (nth - 1) * 7;

   st.day = day;
   return(StructToTime(st));
}

datetime LastSundayOfMonth(int year, int month)
{
   int dim[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
   bool leap = ((year % 4 == 0 && year % 100 != 0) || (year % 400 == 0));
   int last = dim[month - 1] + ((month == 2 && leap) ? 1 : 0);

   MqlDateTime st;
   st.year = year; st.mon = month; st.day = last;
   st.hour = 0; st.min = 0; st.sec = 0;

   datetime d = StructToTime(st);
   MqlDateTime x;
   TimeToStruct(d, x);

   return((datetime)((long)d - (long)x.day_of_week * 86400));
}

bool EuSummerTime(datetime utc)
{
   MqlDateTime st;
   TimeToStruct(utc, st);
   datetime start = (datetime)((long)LastSundayOfMonth(st.year, 3) + 3600);
   datetime end   = (datetime)((long)LastSundayOfMonth(st.year, 10) + 3600);
   return(utc >= start && utc < end);
}

bool UsSummerTime(datetime utc)
{
   MqlDateTime st;
   TimeToStruct(utc, st);
   datetime start = (datetime)((long)NthSundayOfMonth(st.year, 3, 2) + 7 * 3600);
   datetime end   = (datetime)((long)NthSundayOfMonth(st.year, 11, 1) + 6 * 3600);
   return(utc >= start && utc < end);
}

//  Real UTC is only usable live.  In the Strategy Tester TimeGMT() is
//  the simulated server clock, so the offset cannot be recovered and
//  the honest answer is "unknown".
bool ResolveUtc(datetime serverNow, datetime &utcNow, string &srcNote)
{
   srcNote = "";
   utcNow  = 0;

   if(MQLInfoInteger(MQL_TESTER) != 0)
   {
      srcNote = "tester time - UTC unknown";
      return(false);
   }

   datetime g = TimeGMT();
   if(g <= 0)
   {
      srcNote = "GMT unavailable";
      return(false);
   }

   long raw = (long)serverNow - (long)g;

   //  A real broker offset sits on a 15-minute grid inside +/-14h.
   //  The two clocks are not sampled at the same instant, so snap to
   //  the grid and reject the reading only when it is more than two
   //  minutes away from it - a genuine non-grid offset, not lag.
   long off  = (long)MathRound((double)raw / 900.0) * 900;
   long slack = raw - off;
   if(slack < 0) slack = -slack;

   if(slack > 120 || off < -14 * 3600 || off > 14 * 3600)
   {
      srcNote = "server offset not verifiable";
      return(false);
   }

   utcNow = g;

   long absOff = (off < 0 ? -off : off);
   long oh = absOff / 3600;
   long om = (absOff % 3600) / 60;

   if(off == 0)     srcNote = "server clock is UTC";
   else if(off < 0) srcNote = StringFormat("server clock is UTC-%d:%02d", (int)oh, (int)om);
   else             srcNote = StringFormat("server clock is UTC+%d:%02d", (int)oh, (int)om);

   return(true);
}

//  Tokyo 09:00-18:00, London 08:00-17:00, New York 08:00-17:00 in
//  each city's own local time.  Informational only: the broker's own
//  session table decides availability, never this label.
string SessionLabel(datetime utcNow)
{
   int lonOff = EuSummerTime(utcNow) ? 3600 : 0;
   int nyOff  = UsSummerTime(utcNow) ? -4 * 3600 : -5 * 3600;

   long tokyoSec = ((long)utcNow + 9 * 3600) % 86400;
   long lonSec   = ((long)utcNow + lonOff) % 86400;
   long nySec    = ((long)utcNow + nyOff) % 86400;

   bool tokyo  = (tokyoSec >= 9 * 3600 && tokyoSec < 18 * 3600);
   bool london = (lonSec   >= 8 * 3600 && lonSec   < 17 * 3600);
   bool ny     = (nySec    >= 8 * 3600 && nySec    < 17 * 3600);

   string s = "";
   if(tokyo)  s += "Tokyo";
   if(london) s += (s == "" ? "" : " / ") + "London";
   if(ny)     s += (s == "" ? "" : " / ") + "New York";

   if(s == "") s = "between sessions";
   return(s);
}

//==================================================================
//  MARKET STATE
//==================================================================
string TradeModeNote(int mode)
{
   ENUM_SYMBOL_TRADE_MODE m = (ENUM_SYMBOL_TRADE_MODE)mode;
   switch(m)
   {
      case SYMBOL_TRADE_MODE_DISABLED:  return("symbol disabled by broker");
      case SYMBOL_TRADE_MODE_LONGONLY:  return("broker allows BUY only");
      case SYMBOL_TRADE_MODE_SHORTONLY: return("broker allows SELL only");
      case SYMBOL_TRADE_MODE_CLOSEONLY: return("close only - no new orders");
   }
   return("");
}

void RefreshMarket()
{
   datetime serverNow = ServerNow();

   bool connected = (TerminalInfoInteger(TERMINAL_CONNECTED) != 0);
   bool stale = true;
   double ageMin = 0.0;

   if(g_f.hasQuote && g_f.quoteTime > 0)
   {
      ageMin = (double)((long)serverNow - (long)g_f.quoteTime) / 60.0;
      stale  = (ageMin > STALE_MINUTES);
   }

   datetime until = 0;
   bool openNow = IsOpenNow(serverNow, until);

   g_m.hasSessions = (g_sessCount > 0);
   g_m.currentOpen = openNow;
   g_m.modeNote    = TradeModeNote(g_f.tradeMode);
   g_m.nextOpen    = 0;

   if(!connected)
   {
      g_m.code     = MS_OFFLINE;
      g_m.headline = "DISCONNECTED";
      g_m.detail   = "terminal is not connected - no quotes, no trading";
      g_m.clr      = CLR_ALERT;
      return;
   }

   if(g_f.tradeMode == (int)SYMBOL_TRADE_MODE_DISABLED)
   {
      g_m.code     = MS_UNAVAILABLE;
      g_m.headline = "TRADING UNAVAILABLE";
      g_m.detail   = "the broker has disabled this symbol";
      g_m.clr      = CLR_HOLD;
      return;
   }

   if(g_sessCount > 0)
   {
      if(openNow)
      {
         if(stale)
         {
            g_m.code     = MS_STALE;
            g_m.headline = "OPEN - STALE QUOTE";
            g_m.detail   = StringFormat("no fresh quote for %d min", (int)ageMin);
            g_m.clr      = CLR_HOLD;
         }
         else
         {
            g_m.code     = MS_OPEN;
            g_m.headline = "MARKET OPEN";
            g_m.detail   = "trading until " + Hhmm((long)until % 86400) +
                           " server (" + WeekdayShort(until) + ")";
            g_m.clr      = CLR_OK;
         }
         return;
      }

      g_m.code     = MS_CLOSED;
      g_m.headline = "MARKET CLOSED";
      g_m.clr      = CLR_ALERT;

      datetime next = NextOpenTime(serverNow);
      g_m.nextOpen = next;
      if(next > 0)
         g_m.detail = "next open " + WeekdayShort(next) + " " +
                      TimeToString(next, TIME_DATE | TIME_MINUTES) +
                      " server (in " + HumanDelta(serverNow, next) + ")";
      else
         g_m.detail = "no scheduled open found in the published table";
      return;
   }

   //  No published session table for this symbol: quotes are the only
   //  evidence available, so say exactly that instead of guessing.
   if(stale)
   {
      g_m.code     = MS_UNKNOWN;
      g_m.headline = "MARKET STATUS UNKNOWN";
      g_m.detail   = StringFormat("no session table; last quote %d min old", (int)ageMin);
      g_m.clr      = CLR_HOLD;
      return;
   }

   g_m.code     = MS_OPEN;
   g_m.headline = "MARKET OPEN";
   g_m.detail   = "no session table published - quote is live";
   g_m.clr      = CLR_OK;
}

//==================================================================
//  STAGE 2 - THE SIGNAL ENGINE
//==================================================================
//  Three independent measurements per lane, a score, a signal, and
//  the age of the current state against its own history.  Everything
//  is computed on CLOSED bars only, and nothing here can send an
//  order.
//
//  The trend vote is a regression slope divided by the size of an
//  ordinary bar, so the same constant works on gold at 3500 and on
//  EURUSD at 1.08.  The Ehlers bandpass is still computed, but only
//  to be counted against the vote in the Experts log - measured, its
//  sign is a coin flip against direction.  autotrade.md section 10.
//==================================================================

//------------------------------------------------------------------
//  Bar geometry - how much history a lane needs
//------------------------------------------------------------------
int RegimeBarsFor(ENUM_TIMEFRAMES tf)
{
   int secs = PeriodSeconds(tf);
   if(secs <= 0) secs = 300;
   int mins = secs / 60;
   if(mins <= 0) mins = 1;
   int bars = (int)((REGIME_HOURS * 60) / mins);
   if(bars < 20) bars = 20;
   return(bars);
}

//------------------------------------------------------------------
//  Closed bars, oldest first
//------------------------------------------------------------------
bool LoadLane(ENUM_TIMEFRAMES tf, int count,
              double &close[], double &high[], double &low[])
{
   double sc[], sh[], sl[];
   ArraySetAsSeries(sc, true);
   ArraySetAsSeries(sh, true);
   ArraySetAsSeries(sl, true);

   //  start_pos 1 is the most recently CLOSED bar.  The forming bar is
   //  never read, which is what makes the panel non-repainting (D8).
   if(CopyClose(_Symbol, tf, 1, count, sc) < count) return(false);
   if(CopyHigh (_Symbol, tf, 1, count, sh) < count) return(false);
   if(CopyLow  (_Symbol, tf, 1, count, sl) < count) return(false);

   ArrayResize(close, count);
   ArrayResize(high,  count);
   ArrayResize(low,   count);
   ArraySetAsSeries(close, false);
   ArraySetAsSeries(high,  false);
   ArraySetAsSeries(low,   false);

   //  In series view sc[0] is the newest, so the oldest closed bar sits
   //  at sc[count-1] and belongs at index 0 of the chronological array.
   for(int i = 0; i < count; i++)
   {
      close[i] = sc[count - 1 - i];
      high[i]  = sh[count - 1 - i];
      low[i]   = sl[count - 1 - i];
   }
   return(true);
}

//------------------------------------------------------------------
//  Layer 1 - the size of an ordinary bar
//------------------------------------------------------------------
//  end is the INDEX of the last closed bar to use, not a count.  That
//  lets the same maths run over any point in the loaded history, which
//  is what the AGE replay needs.
double MedianAbsChange(const double &close[], int end)
{
   if(end < CHANGE_WINDOW) return(0.0);
   double ch[];
   ArrayResize(ch, CHANGE_WINDOW);
   int base = end - CHANGE_WINDOW + 1;
   for(int i = 0; i < CHANGE_WINDOW; i++)
      ch[i] = MathAbs(close[base + i] - close[base + i - 1]);
   return(MedianOfArray(ch));
}

//------------------------------------------------------------------
//  Layer 2 - the trend vote
//------------------------------------------------------------------
double RegressionSlope(const double &close[], int end, int k)
{
   if(k < 2 || end < k - 1) return(0.0);
   int base = end - k + 1;
   double mx = (k - 1) / 2.0;

   double my = 0.0;
   for(int i = 0; i < k; i++) my += close[base + i];
   my /= (double)k;

   double num = 0.0, den = 0.0;
   for(int i = 0; i < k; i++)
   {
      double dx = (double)i - mx;
      num += dx * (close[base + i] - my);
      den += dx * dx;
   }
   return(den > 0.0 ? num / den : 0.0);
}

int TrendVoteFrom(double ratio)
{
   if(ratio >  TREND_BAND_X) return(1);
   if(ratio < -TREND_BAND_X) return(-1);
   return(0);
}

//------------------------------------------------------------------
//  Layer 3 - the other two votes
//------------------------------------------------------------------
double HorizonBand(double med, double tick, int horizon)
{
   double band   = MOVE_BAND_X * med * MathSqrt((double)horizon);
   double floorB = MOVE_BAND_TICKS * tick;
   if(band < floorB) band = floorB;
   return(band);
}

int MomentumVoteFrom(const double &close[], int n, double med, double tick)
{
   if(n <= MOMENTUM_PERIOD + 1) return(0);
   double band = HorizonBand(med, tick, MOMENTUM_PERIOD);
   double d    = close[n - 1] - close[n - 1 - MOMENTUM_PERIOD];
   if(d >  band) return(1);
   if(d < -band) return(-1);
   return(0);
}

//  Net 20-bar move, then withdrawn when the confirmed swing structure
//  contradicts it.  Pivots are 3-bar: one closed bar on each side.  A missing swing pair does NOT withdraw the vote -
//  only a missing price history does.  This vote must stay genuinely
//  independent of the trend vote, or 2/3 can never occur.
int StructureVoteFrom(const double &close[], const double &high[],
                      const double &low[], int n, double med, double tick)
{
   if(n <= STRUCTURE_PERIOD + 2) return(0);

   double band = HorizonBand(med, tick, STRUCTURE_PERIOD);
   double move = close[n - 1] - close[n - 1 - STRUCTURE_PERIOD];
   if(MathAbs(move) <= band) return(0);

   double lowLast = 0.0, lowPrev = 0.0, highLast = 0.0, highPrev = 0.0;
   int    nLow = 0, nHigh = 0;

   for(int j = n - 2; j >= 1; j--)
   {
      if(low[j] <= low[j - 1] && low[j] <= low[j + 1])
      {
         if(nLow == 0)      lowLast = low[j];
         else if(nLow == 1) lowPrev = low[j];
         nLow++;
      }
      if(high[j] >= high[j - 1] && high[j] >= high[j + 1])
      {
         if(nHigh == 0)      highLast = high[j];
         else if(nHigh == 1) highPrev = high[j];
         nHigh++;
      }
      if(nLow >= 2 && nHigh >= 2) break;
   }

   if(move > band)
   {
      if(nLow >= 2 && lowLast < lowPrev) return(0);
      return(1);
   }
   if(nHigh >= 2 && highLast > highPrev) return(0);
   return(-1);
}

//------------------------------------------------------------------
//  Layer 4 - regime, on an equalised span
//------------------------------------------------------------------
//  z = net move / (sd of bar changes * sqrt(span)).  For a driftless
//  series z is N(0,1) at ANY span, which is exactly what the lanes
//  need: the same threshold means the same thing on M5 and on M30.
double DriftZ(const double &close[], int end, int span)
{
   if(span < 20 || end < span) return(0.0);
   int base = end - span;

   double sum = 0.0;
   for(int i = 1; i <= span; i++)
      sum += close[base + i] - close[base + i - 1];
   double mean = sum / (double)span;

   double var = 0.0;
   for(int i = 1; i <= span; i++)
   {
      double d = (close[base + i] - close[base + i - 1]) - mean;
      var += d * d;
   }
   var /= (double)(span - 1);
   if(var <= 0.0) return(0.0);

   double net = close[end] - close[base];
   return(net / (MathSqrt(var) * MathSqrt((double)span)));
}

int RegimeCodeOf(double z)
{
   double az = MathAbs(z);
   if(az >= Z_STEADY) return(0);
   if(az >= Z_MIXED)  return(1);
   return(2);
}

string RegimeText(int code)
{
   if(code == 0) return("Steady");
   if(code == 1) return("Mixed");
   return("Choppy");
}

//------------------------------------------------------------------
//  Layer 5 - the age of the current state
//------------------------------------------------------------------
void PushRun(int ch, int run)
{
   if(run <= 0) return;
   int base = ch * AGE_HISTORY;
   if(g_runCount[ch] < AGE_HISTORY)
   {
      g_runHist[base + g_runCount[ch]] = run;
      g_runCount[ch]++;
      return;
   }
   for(int i = 1; i < AGE_HISTORY; i++)
      g_runHist[base + i - 1] = g_runHist[base + i];
   g_runHist[base + AGE_HISTORY - 1] = run;
}

void TrackState(int ch, int state)
{
   if(g_runPrev[ch] == state)
   {
      g_runNow[ch]++;
      return;
   }
   if(g_runPrev[ch] != RUN_UNSET) PushRun(ch, g_runNow[ch]);
   g_runPrev[ch] = state;
   g_runNow[ch]  = 1;
}

//  How much longer should this state run?
//
//  Not "typical length minus age" - measured on synthetic data that
//  reads zero on 65% of bars and tells you nothing.  The question asked
//  here is the right one: of the past runs that ALREADY REACHED this
//  age, how much longer did they go?  That never returns zero, and it
//  tightens as the run ages, which is the whole point.
//
//  barsLeft is the median of those survivors.  pctLeft is that same
//  median against the run's implied whole life (age + barsLeft), so
//  6 bars left at age 14 is 30% of a 20-bar life - the two numbers
//  always agree with each other.
bool RemainingRun(int ch, int age, int &barsLeft, int &pctLeft,
                   int &loLeft, int &hiLeft)
{
   barsLeft = 0;
   pctLeft  = 0;
   loLeft   = 0;
   hiLeft   = 0;

   int cnt = g_runCount[ch];
   if(cnt < MIN_REMAIN_SAMPLES) return(false);

   int base = ch * AGE_HISTORY;
   int res[];
   int n = 0;
   for(int i = 0; i < cnt; i++)
   {
      int r = g_runHist[base + i] - age;
      if(r <= 0) continue;                 // that run did not outlive this age
      ArrayResize(res, n + 1);
      res[n] = r;
      n++;
   }
   if(n < MIN_REMAIN_SAMPLES) return(false);   // too few survivors to claim anything

   ArraySort(res);
   int med = res[n / 2];
   if(med < 1) med = 1;

   //  The spread is reported alongside the median, because a median of a
   //  heavy-tailed run distribution hides how wide the answer really is.
   loLeft = res[n / 4];
   hiLeft = res[(3 * n) / 4];
   if(loLeft < 1) loLeft = 1;
   if(hiLeft < loLeft) hiLeft = loLeft;

   int total = age + med;
   int pct   = (total > 0 ? (int)MathRound(100.0 * (double)med / (double)total) : 0);
   if(pct < 1)  pct = 1;
   if(pct > 99) pct = 99;

   barsLeft = med;
   pctLeft  = pct;
   return(true);
}

//  How likely is the current signal to still be standing in a few bars?
//
//  This is the one forward question about a signal that can be answered
//  honestly.  Direction cannot be - measured on real candles the score
//  predicts the size of the next move but not its sign.
//
//  The answer is a survival fraction, counted from this lane's own
//  completed runs and nothing else:
//
//     P = (runs that reached age + SIGNAL_DURA_BARS)
//       / (runs that reached age)
//
//  Because it is counted locally it needs no constant: a symbol whose
//  signals last longer simply reports a higher number, and the figure
//  follows the market when its behaviour changes.  Fitting a model to
//  fixed thresholds was tried and failed - the coefficients reversed
//  sign when the sample years were swapped.
//
//  Ties are counted the way a trader would: a signal that goes to NO
//  SIGNAL has ended, even if it comes back later.  Zeros are part of the
//  run history for exactly that reason.
bool SignalDurability(int ch, int age, int &pct)
{
   pct = 0;

   int cnt = g_runCount[ch];
   if(cnt < MIN_DURA_SAMPLES) return(false);

   int base    = ch * AGE_HISTORY;
   int atRisk  = 0;
   int survives= 0;
   for(int i = 0; i < cnt; i++)
   {
      int len = g_runHist[base + i];
      if(len < age) continue;              // ended before reaching this age
      atRisk++;
      if(len >= age + SIGNAL_DURA_BARS) survives++;
   }
   if(atRisk < MIN_DURA_SAMPLES) return(false);

   //  Never 0 and never 100.  With twelve runs at risk, "0%" claims a
   //  certainty the sample cannot support - the same reason the TREND
   //  percentage is clamped rather than rounded to the endpoints.
   pct = (int)MathRound(100.0 * (double)survives / (double)atRisk);
   if(pct < 1)   pct = 1;
   if(pct > 99)  pct = 99;
   return(true);
}

//  Longest completed run this channel has seen, 0 if none.
int MaxRun(int ch)
{
   int cnt = g_runCount[ch];
   if(cnt <= 0) return(0);
   int base = ch * AGE_HISTORY;
   int best = 0;
   for(int i = 0; i < cnt; i++)
      if(g_runHist[base + i] > best) best = g_runHist[base + i];
   return(best);
}

//  Bars a timeframe's bars are worth, for the tooltip.
int BarMinutes(ENUM_TIMEFRAMES tf)
{
   int secs = PeriodSeconds(tf);
   if(secs <= 0) return(0);
   int mins = secs / 60;
   return(mins < 1 ? 1 : mins);
}

string MinutesText(int bars, int minsPerBar)
{
   long total = (long)bars * (long)minsPerBar;
   if(total < 60) return(IntegerToString((int)total) + " min");
   int h = (int)(total / 60);
   int m = (int)(total % 60);
   if(m == 0) return(IntegerToString(h) + " h");
   return(IntegerToString(h) + " h " + IntegerToString(m) + " min");
}

//  One cell: "UP 6/30%L".  If it would not fit its column the bars are
//  dropped first, then the estimate, so alignment can never break.
//  The SIGNAL cell.  "SELL 22%" - 22% is the chance this signal is still
//  standing three bars from now, counted from this lane's own runs.
//  Deliberately WITHOUT the L suffix: in TREND and REGIME, %L means
//  "share of life left", and one letter cannot mean two things in one
//  row.  Reading it as a plain percent keeps that promise.
//
//  When there is no estimate the cell is just "SELL" - the same honesty
//  the TREND cell applies when its history is too thin.
string SignalCell(string label, int pct, bool ok, int maxW)
{
   if(!ok) return(label);

   string withPct = label + " " + IntegerToString(pct) + "%";
   if(StringLen(withPct) <= maxW) return(withPct);

   return(label);
}

string LeftCell(string label, int barsLeft, int pctLeft, bool ok, bool over, int maxW)
{
   if(!ok)
   {
      //  The run has outlasted every run on record: say so instead of
      //  inventing a number. "Max" needs no explanation once seen once.
      if(over)
      {
         string overTxt = label + " Max";
         if(StringLen(overTxt) <= maxW) return(overTxt);
      }
      return(label);
   }

   string withBars = label + " " + IntegerToString(barsLeft) + "/" +
                     IntegerToString(pctLeft) + "%L";
   if(StringLen(withBars) <= maxW) return(withBars);

   string pctOnly = label + " " + IntegerToString(pctLeft) + "%L";
   if(StringLen(pctOnly) <= maxW) return(pctOnly);

   return(label);
}

//  Replay the vote over closed bars that are already loaded, so the
//  median exists at attach instead of after a day.  This is not
//  look-ahead: every bar in the replay is finished, and the vote at
//  that bar uses only the bars before it - exactly the number the EA
//  would have printed had it been running.
void SeedRuns(int idx, const double &close[], const double &high[],
              const double &low[], int n, int span, double tick)
{
   int start = n - 1 - SEED_BARS;
   if(start < span) start = span;

   //  The last index is left to the live path, which tracks it next.
   for(int end = start; end < n - 1; end++)
   {
      double med = MedianAbsChange(close, end);
      if(med <= 0.0) med = tick;

      double ratio = RegressionSlope(close, end, TREND_PERIOD) / med;
      int    tv    = TrendVoteFrom(ratio);

      TrackState(idx * 3,     tv);
      TrackState(idx * 3 + 1, RegimeCodeOf(DriftZ(close, end, span)));

      //  The signal channel is seeded with the real three-vote score, not
      //  an approximation: a durability figure counted from anything other
      //  than what the panel actually shows would be a lie.
      int mv = MomentumVoteFrom(close, end + 1, med, tick);
      int sv = StructureVoteFrom(close, high, low, end + 1, med, tick);
      int sc = tv + mv + sv;
      int sg = 0;
      if(sc >=  2) sg =  1;
      if(sc <= -2) sg = -1;
      TrackState(idx * 3 + 2, sg);
   }
}

//------------------------------------------------------------------
//  Ehlers Precision Trend - comparison log ONLY, never a vote
//------------------------------------------------------------------
//  HighPass3 transcribed from Ehlers' own listing.  f is in radians,
//  which is what MathCos expects.
void EhHighPass3(const double &price[], int n, int period, double &hp[])
{
   ArrayResize(hp, n);
   ArrayInitialize(hp, 0.0);
   if(n < 3 || period < 2) return;

   double f  = 1.414 * PI_D / (double)period;
   double a1 = MathExp(-f);
   double c2 = 2.0 * a1 * MathCos(f);
   double c3 = -a1 * a1;
   double c1 = (1.0 + c2 - c3) / 4.0;

   for(int i = 2; i < n; i++)
      hp[i] = c1 * (price[i] - 2.0 * price[i - 1] + price[i - 2])
            + c2 * hp[i - 1]
            + c3 * hp[i - 2];
}

int EhTrendSign(const double &close[], int n)
{
   if(n < TREND_L1 + 2) return(0);

   double hp1[], hp2[];
   EhHighPass3(close, n, TREND_L1, hp1);
   EhHighPass3(close, n, TREND_L2, hp2);

   int k = (n < 200 ? n : 200);
   double absv[];
   ArrayResize(absv, k);
   for(int i = 0; i < k; i++)
      absv[i] = MathAbs(hp1[n - k + i] - hp2[n - k + i]);

   double band = 0.25 * MedianOfArray(absv);
   double now  = hp1[n - 1] - hp2[n - 1];
   if(now >  band) return(1);
   if(now < -band) return(-1);
   return(0);
}

//------------------------------------------------------------------
//  One lane, one closed bar
//------------------------------------------------------------------
bool UpdateLane(int idx)
{
   ENUM_TIMEFRAMES tf = g_lane[idx].tf;

   int span = RegimeBarsFor(tf);
   int need = span + 1;                      // z needs span+1 closes
   if(need < TREND_L1 * 3) need = TREND_L1 * 3;
   if(need < g_p.warmupBars) need = g_p.warmupBars;

   //  Extra bars so the AGE replay has room behind the regime span.
   int count = need + SEED_BARS;
   g_lane[idx].needBars = count;

   //  Bars() is read for the message only.  Using it as the gate would
   //  deadlock on a fresh terminal: it stays 0 until a series request is
   //  made, and the request is the CopyClose below.
   g_lane[idx].haveBars = Bars(_Symbol, tf);

   double close[], high[], low[];
   if(!LoadLane(tf, count, close, high, low)) return(false);

   int end = count - 1;                      // the most recent closed bar

   double tick = g_f.tickSize;
   if(tick <= 0.0) tick = g_f.point;
   if(tick <= 0.0) tick = 0.00001;

   double med = MedianAbsChange(close, end);
   if(med <= 0.0) med = tick;

   double ratio = RegressionSlope(close, end, TREND_PERIOD) / med;
   g_lane[idx].slopeRatio = ratio;
   g_lane[idx].trend      = TrendVoteFrom(ratio);

   g_lane[idx].vMom = MomentumVoteFrom(close, count, med, tick);
   g_lane[idx].vStr = StructureVoteFrom(close, high, low, count, med, tick);

   g_lane[idx].score  = g_lane[idx].trend + g_lane[idx].vMom + g_lane[idx].vStr;

   int sig = 0;
   if(g_lane[idx].score >=  2) sig =  1;
   if(g_lane[idx].score <= -2) sig = -1;
   g_lane[idx].signal = sig;

   g_lane[idx].zValue = DriftZ(close, end, span);
   g_lane[idx].regime = RegimeCodeOf(g_lane[idx].zValue);

   //  Only compare when BOTH have an opinion.  Counting "both flat" as
   //  agreement would flatter the bandpass by every quiet bar.
   g_lane[idx].ehSign = EhTrendSign(close, count);
   if(g_lane[idx].ehSign != 0 && g_lane[idx].trend != 0)
   {
      if(g_lane[idx].ehSign == g_lane[idx].trend) g_ehAgree++;
      else                                        g_ehDisagree++;
   }

   if(g_runPrev[idx * 3] == RUN_UNSET)
      SeedRuns(idx, close, high, low, count, span, tick);

   TrackState(idx * 3,     g_lane[idx].trend);
   TrackState(idx * 3 + 1, g_lane[idx].regime);
   TrackState(idx * 3 + 2, sig);

   g_lane[idx].trendAge  = g_runNow[idx * 3];
   g_lane[idx].regimeAge = g_runNow[idx * 3 + 1];
   g_lane[idx].signalAge = g_runNow[idx * 3 + 2];

   g_lane[idx].signalDuraOk = (g_lane[idx].signal != 0 &&
                               SignalDurability(idx * 3 + 2,
                                                g_lane[idx].signalAge,
                                                g_lane[idx].signalDuraPct));

   g_lane[idx].trendLeftOk  = RemainingRun(idx * 3,     g_lane[idx].trendAge,
                                           g_lane[idx].trendLeft,
                                           g_lane[idx].trendLeftPct,
                                           g_lane[idx].trendLo,
                                           g_lane[idx].trendHi);
   g_lane[idx].regimeLeftOk = RemainingRun(idx * 3 + 1, g_lane[idx].regimeAge,
                                           g_lane[idx].regimeLeft,
                                           g_lane[idx].regimeLeftPct,
                                           g_lane[idx].regimeLo,
                                           g_lane[idx].regimeHi);

   g_lane[idx].ready = true;

   //  One line of the diary is settled here, after the panel numbers
   //  exist for this bar.  It reads them; it can never change them.
   DiaryOnBar(idx);

   //  Then the plan for this bar.  It is built from the same three
   //  votes, and it is refused rather than invented.
   TradeOnBar(idx);
   return(true);
}

void UpdateLanes()
{
   for(int i = 0; i < LANE_COUNT; i++)
   {
      datetime t = iTime(_Symbol, g_lane[i].tf, 1);
      if(t == 0) continue;
      if(t == g_lane[i].lastBar) continue;
      //  lastBar only advances on success, so a chart still loading
      //  history retries every heartbeat instead of waiting a bar.
      if(UpdateLane(i)) g_lane[i].lastBar = t;
   }
}

//------------------------------------------------------------------
//  Text
//------------------------------------------------------------------
string TrendText(int v)
{
   if(v > 0) return("UP");
   if(v < 0) return("DOWN");
   return("FLAT");
}

color TrendColour(int v)
{
   if(v > 0) return(CLR_OK);
   if(v < 0) return(CLR_ALERT);
   return(CLR_DIM);
}

color SignalColour(int s)
{
   if(s > 0) return(CLR_OK);
   if(s < 0) return(CLR_ALERT);
   return(CLR_DIM);
}

string ScoreText(int score)
{
   int a = (score < 0 ? -score : score);
   return(IntegerToString(a) + "/3");
}

string SignalText(int s)
{
   if(s > 0) return("BUY");
   if(s < 0) return("SELL");
   return("NO SIGNAL");
}

//------------------------------------------------------------------
//  Hourly line to the Experts log, so the panel can be checked
//------------------------------------------------------------------
void LogLanes()
{
   static datetime lastPrint = 0;
   static int      lastReady = -1;

   datetime now = ServerNow();

   int ready = 0;
   for(int r = 0; r < LANE_COUNT; r++) if(g_lane[r].ready) ready++;

   //  Print hourly, and also the first time a lane comes alive - a wait
   //  message must not hide the first real reading for an hour.
   bool changed = (ready != lastReady);
   if(!changed && lastPrint != 0 && now - lastPrint < 3600) return;
   lastPrint = now;
   lastReady = ready;

   for(int i = 0; i < LANE_COUNT; i++)
   {
      if(!g_lane[i].ready)
      {
         if(g_lane[i].haveBars <= 0)
            PrintFormat("%s DATA WAIT - history not loaded yet, %d bars needed",
                        g_lane[i].name, g_lane[i].needBars);
         else
            PrintFormat("%s DATA WAIT - %d of %d closed bars",
                        g_lane[i].name, g_lane[i].haveBars, g_lane[i].needBars);
         continue;
      }
      string tLeft = (g_lane[i].trendLeftOk
                      ? StringFormat("%d bars left (%d%%), age %d",
                                     g_lane[i].trendLeft, g_lane[i].trendLeftPct,
                                     g_lane[i].trendAge)
                      : StringFormat("age %d, no estimate yet", g_lane[i].trendAge));
      string rLeft = (g_lane[i].regimeLeftOk
                      ? StringFormat("%d bars left (%d%%), age %d",
                                     g_lane[i].regimeLeft, g_lane[i].regimeLeftPct,
                                     g_lane[i].regimeAge)
                      : StringFormat("age %d, no estimate yet", g_lane[i].regimeAge));

      //  The signal's figure goes in the log too, so the number on the
      //  panel can be checked against what produced it.
      string sDura = (g_lane[i].signalDuraOk
                      ? StringFormat("%d%% chance after %d bars", 
                                     g_lane[i].signalDuraPct, g_lane[i].signalAge)
                      : StringFormat("age %d, too few runs", g_lane[i].signalAge));

      PrintFormat("%s trend %s %s | regime %s %s | z=%.2f slope %.3f | votes %d %d %d score %d %s | signal %s",
                  g_lane[i].name,
                  TrendText(g_lane[i].trend), tLeft,
                  RegimeText(g_lane[i].regime), rLeft,
                  g_lane[i].zValue, g_lane[i].slopeRatio,
                  g_lane[i].trend, g_lane[i].vMom, g_lane[i].vStr,
                  g_lane[i].score, SignalText(g_lane[i].signal), sDura);
   }

   int tot = g_ehAgree + g_ehDisagree;
   if(tot > 0)
      PrintFormat("Ehlers vs slope: %d agree, %d disagree (%.1f%% agree) over %d closed bars",
                  g_ehAgree, g_ehDisagree, 100.0 * (double)g_ehAgree / (double)tot, tot);
}

//==================================================================
//  DIARY
//==================================================================
//  The diary records what the panel claimed, and checks it later.
//  One line is written when a claim is settled.  Nothing else is
//  ever written, and nothing it stores is read back by the signal
//  engine: a witness, not a participant.
//
//  Three claim kinds:
//     SIG   a BUY or SELL was shown with a durability figure
//     TRD   a trend run was shown with a total life
//     REG   a regime run was shown with a total life
//
//  A claim starts only when the panel actually showed a number, so
//  nothing is ever graded that was never said.  Pending claims live
//  in memory only: a restart loses the claim in flight, but never a
//  line that was already written.
#define DIARY_MAX_RECENT  8     // results listed in the details panel
#define DIARY_BLK_W       15    // fixed width of one S/W/L block
#define DIARY_MIN_JUDGE   10    // results needed before a comparison shows
#define DIARY_GAP         12    // px between the two panels
#define DIARY_PREFIX      "AUTD_"
#define DIARY_KIND_SIG    "SIG"
#define DIARY_KIND_TRD    "TRD"
#define DIARY_KIND_REG    "REG"

//==================================================================
//  TRADE PLAN CONSTANTS
//==================================================================
//  All internal.  None of these is an input: a period, a band or a
//  risk percentage the owner has to tune is exactly what section 2.1
//  of autotrade.md rules out.
#define RISK_PCT          0.50   // % of equity risked per idea
#define TP_MIN_CASES      30     // analogues needed before a target is claimed
#define TP_QUANTILE       0.50   // where the measured favourable move is cut
#define REPLAY_BARS       400    // closed bars scanned for analogues
#define MAX_SPREAD_GATE   3.0    // refuse when spread exceeds this x typical
#define TP_COST_X         2.0    // target must clear this many spreads
#define SL_COST_X         3.0    // stop must be this far from entry, in spreads
#define SL_NOISE_X        1.5    // stop must be this far from entry, in med bars

#define TS_NONE           0      // nothing to do on this lane
#define TS_HOLD           1      // a direction exists but no valid plan
#define TS_WAIT           2      // a limit is at the broker
#define TS_OPEN           3      // a position is open
#define TS_PLAN           4      // a plan exists; nothing was sent

//  The live-trading gate.  False means the EA builds and shows the
//  plan but sends nothing to the broker.  It is a compile-time
//  constant, not an input: an on/off switch has to be asked for by
//  name before it becomes one.
#define TRADING_LIVE      false

struct DiaryTotals
{
   int sToday;   // signal runs checked today
   int wToday;   // trades won - no writer yet
   int lToday;   // trades lost - no writer yet
   int sAll;
   int wAll;
   int lAll;
};

struct DiaryCalib
{
   int    sigN;      // signals checked
   double sigSaid;   // what the panel said, summed
   int    sigHeld;   // how many were still standing
   int    trdN;
   double trdSaid;
   double trdDid;
   int    regN;
   double regSaid;
   double regDid;
};

struct DiaryPending
{
   bool     sigOn;
   bool     sigDone;      // this run has already been claimed once
   int      sigDir;
   int      sigPct;
   datetime sigBar;
   bool     trdOn;
   int      trdSaid;
   bool     regOn;
   int      regSaid;
};

struct DiaryResult
{
   string lane;
   string said;
   string did;
   bool   hit;
};

DiaryTotals  g_dt[LANE_COUNT];
DiaryCalib   g_dc;
DiaryPending g_dp[LANE_COUNT];
DiaryResult  g_dr[DIARY_MAX_RECENT];
int          g_drAt      = 0;      // next slot in the ring
int          g_drN       = 0;      // entries used
int          g_diary     = INVALID_HANDLE;
string       g_diaryName = "";
string       g_diaryNote = "not started";
bool         g_diaryOk   = false;
int          g_diaryRows = 0;
datetime     g_diaryDay  = 0;
int          g_panelPx   = 0;      // main panel geometry, for the side panel
int          g_panelPy   = 0;

//------------------------------------------------------------------
//  File
//------------------------------------------------------------------
string DiaryFileName()
{
   string acct = IntegerToString((long)AccountInfoInteger(ACCOUNT_LOGIN));
   string sym  = _Symbol;
   StringReplace(sym, "\\", "_");
   StringReplace(sym, "/",  "_");
   StringReplace(sym, ":",  "_");
   StringReplace(sym, "*",  "_");
   StringReplace(sym, "?",  "_");
   StringReplace(sym, "<",  "_");
   StringReplace(sym, ">",  "_");
   StringReplace(sym, "|",  "_");
   StringReplace(sym, ".",  "_");
   return("Automate_Diary_" + acct + "_" + sym + ".csv");
}

datetime DiaryDayKey(datetime t)
{
   MqlDateTime s;
   TimeToStruct(t, s);
   s.hour = 0;
   s.min  = 0;
   s.sec  = 0;
   return(StructToTime(s));
}

void DiaryReset()
{
   g_dc.sigN    = 0;
   g_dc.sigSaid = 0.0;
   g_dc.sigHeld = 0;
   g_dc.trdN    = 0;
   g_dc.trdSaid = 0.0;
   g_dc.trdDid  = 0.0;
   g_dc.regN    = 0;
   g_dc.regSaid = 0.0;
   g_dc.regDid  = 0.0;

   g_drAt      = 0;
   g_drN       = 0;
   g_diaryDay  = 0;
   g_diaryRows = 0;

   for(int i = 0; i < LANE_COUNT; i++)
   {
      g_dt[i].sToday = 0;
      g_dt[i].wToday = 0;
      g_dt[i].lToday = 0;
      g_dt[i].sAll   = 0;
      g_dt[i].wAll   = 0;
      g_dt[i].lAll   = 0;

      g_dp[i].sigOn   = false;
      g_dp[i].sigDone = false;
      g_dp[i].sigDir  = 0;
      g_dp[i].sigPct  = 0;
      g_dp[i].sigBar  = 0;
      g_dp[i].trdOn   = false;
      g_dp[i].trdSaid = 0;
      g_dp[i].regOn   = false;
      g_dp[i].regSaid = 0;
   }
   for(int i = 0; i < DIARY_MAX_RECENT; i++)
   {
      g_dr[i].lane = "";
      g_dr[i].said = "";
      g_dr[i].did  = "";
      g_dr[i].hit  = false;
   }
}

void DiaryApply(int lane, string kind, int said, int did, bool hit, datetime t)
{
   if(lane < 0 || lane >= LANE_COUNT) return;

   bool today = (g_diaryDay != 0 && DiaryDayKey(t) == g_diaryDay);

   if(kind == DIARY_KIND_SIG)
   {
      g_dt[lane].sAll++;
      g_dc.sigN++;
      g_dc.sigSaid += (double)said;
      if(hit) g_dc.sigHeld++;

      if(today) g_dt[lane].sToday++;
   }
   else if(kind == DIARY_KIND_TRD)
   {
      g_dc.trdN++;
      g_dc.trdSaid += (double)said;
      g_dc.trdDid  += (double)did;
   }
   else if(kind == DIARY_KIND_REG)
   {
      g_dc.regN++;
      g_dc.regSaid += (double)said;
      g_dc.regDid  += (double)did;
   }
}

//  Newest entry lands at g_drAt, which then moves on.  Display walks
//  the ring backwards from there.
void DiaryPushResult(string lane, string said, string did, bool hit)
{
   g_dr[g_drAt].lane = lane;
   g_dr[g_drAt].said = said;
   g_dr[g_drAt].did  = did;
   g_dr[g_drAt].hit  = hit;

   g_drAt = (g_drAt + 1) % DIARY_MAX_RECENT;
   if(g_drN < DIARY_MAX_RECENT) g_drN++;
}

void DiaryWrite(int lane, string kind, int said, int did, bool hit, datetime t)
{
   if(g_diary == INVALID_HANDLE) return;

   string row = TimeToString(t, TIME_DATE | TIME_MINUTES) + "," +
                g_lane[lane].name + "," + kind + "," +
                IntegerToString(said) + "," + IntegerToString(did) + "," +
                (hit ? "1" : "0") + "\r\n";

   uint wrote = FileWriteString(g_diary, row);
   if(wrote == 0)
   {
      g_diaryNote = "last write failed";
      PrintFormat("Diary: write failed on %s (error %d)", g_diaryName, GetLastError());
      return;
   }
   FileFlush(g_diary);
   g_diaryRows++;
}

void DiaryRecord(int lane, string kind, int said, int did, bool hit,
                 string saidTxt, string didTxt, datetime t)
{
   DiaryApply(lane, kind, said, did, hit, t);
   DiaryPushResult(g_lane[lane].name, saidTxt, didTxt, hit);
   DiaryWrite(lane, kind, said, did, hit, t);
}

//  One stored line.  A line that does not parse is skipped, never
//  repaired and never used to overwrite anything: the file is only
//  ever appended to.
bool DiaryParse(string line)
{
   string parts[];
   ushort sep = StringGetCharacter(",", 0);
   int n = StringSplit(line, sep, parts);
   if(n < 6) return(false);

   int lane = -1;
   for(int i = 0; i < LANE_COUNT; i++)
      if(parts[1] == g_lane[i].name) lane = i;
   if(lane < 0) return(false);

   if(parts[2] != DIARY_KIND_SIG &&
      parts[2] != DIARY_KIND_TRD &&
      parts[2] != DIARY_KIND_REG) return(false);

   datetime t = StringToTime(parts[0]);
   if(t == 0) return(false);

   int  said = (int)StringToInteger(parts[3]);
   int  did  = (int)StringToInteger(parts[4]);
   bool hit  = (parts[5] == "1");

   DiaryApply(lane, parts[2], said, did, hit, t);
   DiaryPushResult(g_lane[lane].name,
                   (parts[2] == DIARY_KIND_SIG ? StringFormat("signal %d%%", said)
                                               : StringFormat("%d bars", said)),
                   (parts[2] == DIARY_KIND_SIG ? (hit ? "still there" : "gone")
                                               : StringFormat("%d bars", did)),
                   hit);
   return(true);
}

bool DiaryOpen()
{
   DiaryReset();
   g_diaryName = DiaryFileName();

   uint flags = FILE_READ | FILE_WRITE | FILE_TXT;
   if(!MQLInfoInteger(MQL_TESTER)) flags |= FILE_COMMON;

   //  No share flags: the handle is exclusive for the life of the EA,
   //  so a second chart on the same symbol cannot write to the file.
   g_diary = FileOpen(g_diaryName, flags);
   if(g_diary == INVALID_HANDLE)
   {
      g_diaryOk   = false;
      g_diaryNote = "cannot open the file";
      PrintFormat("Diary: cannot open %s (error %d). Another chart may already hold it.",
                  g_diaryName, GetLastError());
      return(false);
   }

   g_diaryDay = DiaryDayKey(TimeCurrent());

   int rows = 0;
   while(!FileIsEnding(g_diary))
   {
      string line = FileReadString(g_diary);
      if(StringLen(line) == 0) continue;
      if(StringSubstr(line, 0, 1) == "#") continue;
      if(DiaryParse(line)) rows++;
   }
   g_diaryRows = rows;

   FileSeek(g_diary, 0, SEEK_END);

   if(rows == 0)
   {
      string head = "# Automate diary v1 - one line per settled claim\r\n";
      FileWriteString(g_diary, head);
      FileFlush(g_diary);
   }

   g_diaryOk   = true;
   g_diaryNote = "saved";
   PrintFormat("Diary: %s, %d results", g_diaryName, rows);
   return(true);
}

void DiaryClose()
{
   if(g_diary != INVALID_HANDLE)
   {
      FileClose(g_diary);
      g_diary = INVALID_HANDLE;
   }
}

//------------------------------------------------------------------
//  One closed bar: settle what is due, then open new claims
//------------------------------------------------------------------
void DiarySignalStep(int idx, datetime bar)
{
   int sig = g_lane[idx].signal;

   //  One claim per run, not one every SIGNAL_DURA_BARS: consecutive
   //  claims from the same run overlap and would inflate the count
   //  with the same evidence.
   if(g_lane[idx].signalAge <= 1) g_dp[idx].sigDone = false;

   if(g_dp[idx].sigOn)
   {
      long elapsed = (long)(bar - g_dp[idx].sigBar);
      long need    = (long)SIGNAL_DURA_BARS * (long)PeriodSeconds(g_lane[idx].tf);
      if(elapsed >= need)
      {
         bool held = (sig == g_dp[idx].sigDir);
         DiaryRecord(idx, DIARY_KIND_SIG, g_dp[idx].sigPct, (held ? 1 : 0), held,
                     StringFormat("%s %d%%", SignalText(g_dp[idx].sigDir), g_dp[idx].sigPct),
                     (held ? "still there" : "gone"),
                     bar);
         g_dp[idx].sigOn = false;
      }
   }

   if(!g_dp[idx].sigOn && !g_dp[idx].sigDone && sig != 0 && g_lane[idx].signalDuraOk)
   {
      g_dp[idx].sigOn   = true;
      g_dp[idx].sigDone = true;
      g_dp[idx].sigDir  = sig;
      g_dp[idx].sigPct  = g_lane[idx].signalDuraPct;
      g_dp[idx].sigBar  = bar;
   }
}

//  which: 0 = trend, 1 = regime
void DiaryRunStep(int idx, int which, datetime bar)
{
   int  ch   = idx * 3 + which;
   int  age  = (which == 0) ? g_lane[idx].trendAge     : g_lane[idx].regimeAge;
   int  left = (which == 0) ? g_lane[idx].trendLeft    : g_lane[idx].regimeLeft;
   bool ok   = (which == 0) ? g_lane[idx].trendLeftOk  : g_lane[idx].regimeLeftOk;
   bool on   = (which == 0) ? g_dp[idx].trdOn          : g_dp[idx].regOn;
   int  said = (which == 0) ? g_dp[idx].trdSaid        : g_dp[idx].regSaid;

   //  age == 1 means the previous run has just ended, and its final
   //  length is the newest entry in that channel's history.
   if(on && age == 1)
   {
      if(g_runCount[ch] > 0)
      {
         int done = g_runHist[ch * AGE_HISTORY + g_runCount[ch] - 1];
         if(done > 0)
         {
            int  tol   = (int)MathMax(2, said / 4);
            bool close = (done >= said - tol && done <= said + tol);
            DiaryRecord(idx, (which == 0 ? DIARY_KIND_TRD : DIARY_KIND_REG),
                        said, done, close,
                        StringFormat("%d bars", said),
                        StringFormat("%d bars", done), bar);
         }
      }
      if(which == 0) g_dp[idx].trdOn = false;
      else           g_dp[idx].regOn = false;
      on = false;
   }

   //  The first bar of a run at which the panel can honestly say how
   //  long it lasts.  Before that there is no number, so no claim.
   if(!on && age > 1 && ok)
   {
      if(which == 0)
      {
         g_dp[idx].trdOn   = true;
         g_dp[idx].trdSaid = age + left;
      }
      else
      {
         g_dp[idx].regOn   = true;
         g_dp[idx].regSaid = age + left;
      }
   }
}

void DiaryOnBar(int idx)
{
   if(!g_diaryOk) return;

   datetime bar = iTime(_Symbol, g_lane[idx].tf, 1);
   if(bar == 0) return;

   datetime dk = DiaryDayKey(bar);
   if(g_diaryDay == 0) g_diaryDay = dk;
   else if(dk > g_diaryDay)
   {
      g_diaryDay = dk;
      for(int i = 0; i < LANE_COUNT; i++)
      {
         g_dt[i].sToday = 0;
         g_dt[i].wToday = 0;
         g_dt[i].lToday = 0;
      }
   }

   DiarySignalStep(idx, bar);
   DiaryRunStep(idx, 0, bar);
   DiaryRunStep(idx, 1, bar);
}

//------------------------------------------------------------------
//  Panel text
//------------------------------------------------------------------
string Slash3(int a, int b, int c)
{
   return(IntegerToString(a) + "/" + IntegerToString(b) + "/" + IntegerToString(c));
}

string DiaryS(bool today)
{
   return("S" + Slash3(today ? g_dt[0].sToday : g_dt[0].sAll,
                       today ? g_dt[1].sToday : g_dt[1].sAll,
                       today ? g_dt[2].sToday : g_dt[2].sAll));
}

string DiaryW(bool today)
{
   return("W" + Slash3(today ? g_dt[0].wToday : g_dt[0].wAll,
                       today ? g_dt[1].wToday : g_dt[1].wAll,
                       today ? g_dt[2].wToday : g_dt[2].wAll));
}

string DiaryL(bool today)
{
   return("L" + Slash3(today ? g_dt[0].lToday : g_dt[0].lAll,
                       today ? g_dt[1].lToday : g_dt[1].lAll,
                       today ? g_dt[2].lToday : g_dt[2].lAll));
}

string DiaryHealthText()
{
   if(!g_diaryOk) return("off");
   return("no trades yet");
}

string TweakText()
{
   if(!InpTweakArm) return("off");
   return("on, no check yet");
}

//------------------------------------------------------------------
//  Details panel content
//------------------------------------------------------------------
void DAdd(string &lines[], color &clrs[], string text, color clr)
{
   int n = ArraySize(lines);
   ArrayResize(lines, n + 1);
   ArrayResize(clrs,  n + 1);
   lines[n] = text;
   clrs[n]  = clr;
}

void BuildDiaryDetails(string &lines[], color &clrs[])
{
   ArrayResize(lines, 0);
   ArrayResize(clrs, 0);

   DAdd(lines, clrs, " DIARY DETAILS", CLR_SECTION);
   DAdd(lines, clrs, "", CLR_TEXT);

   if(g_drN == 0)
   {
      DAdd(lines, clrs, " The diary checks what the panel said.", CLR_TEXT);
      DAdd(lines, clrs, " Nothing has been checked yet.", CLR_TEXT);
      DAdd(lines, clrs, " It writes one line when a claim is settled.", CLR_DIM);
      DAdd(lines, clrs, "", CLR_TEXT);
   }

   if(g_dc.sigN >= DIARY_MIN_JUDGE || g_dc.trdN >= DIARY_MIN_JUDGE ||
      g_dc.regN >= DIARY_MIN_JUDGE)
   {
      DAdd(lines, clrs, " WHAT WE SAID  /  WHAT HAPPENED", CLR_SECTION);

      if(g_dc.sigN >= DIARY_MIN_JUDGE)
      {
         int said = (int)MathRound(g_dc.sigSaid / (double)g_dc.sigN);
         int real = (int)MathRound(100.0 * (double)g_dc.sigHeld / (double)g_dc.sigN);
         DAdd(lines, clrs, StringFormat(" signal still there  said %d%%  real %d%%  (%d)",
                                        said, real, g_dc.sigN), CLR_TEXT);
      }
      if(g_dc.trdN >= DIARY_MIN_JUDGE)
      {
         int said = (int)MathRound(g_dc.trdSaid / (double)g_dc.trdN);
         int real = (int)MathRound(g_dc.trdDid  / (double)g_dc.trdN);
         DAdd(lines, clrs, StringFormat(" trend length       said %d bars  real %d bars  (%d)",
                                        said, real, g_dc.trdN), CLR_TEXT);
      }
      if(g_dc.regN >= DIARY_MIN_JUDGE)
      {
         int said = (int)MathRound(g_dc.regSaid / (double)g_dc.regN);
         int real = (int)MathRound(g_dc.regDid  / (double)g_dc.regN);
         DAdd(lines, clrs, StringFormat(" regime length      said %d bars  real %d bars  (%d)",
                                        said, real, g_dc.regN), CLR_TEXT);
      }
      DAdd(lines, clrs, "", CLR_TEXT);
   }

   if(g_drN > 0)
   {
      DAdd(lines, clrs, " LAST RESULTS", CLR_SECTION);

      int start = (g_drAt - g_drN + DIARY_MAX_RECENT) % DIARY_MAX_RECENT;
      for(int i = 0; i < g_drN; i++)
      {
         int k = (start + i) % DIARY_MAX_RECENT;
         string mark = g_dr[k].hit ? "yes" : "no";
         DAdd(lines, clrs, "  " + Pad(g_dr[k].lane, 5) + " " +
                            Pad(g_dr[k].said, 14) + " -> " +
                            Pad(g_dr[k].did, 12) + " " + mark,
              (g_dr[k].hit ? CLR_OK : CLR_DIM));
      }
      DAdd(lines, clrs, "", CLR_TEXT);
   }

   DAdd(lines, clrs, " COUNT OF RESULTS", CLR_SECTION);
   DAdd(lines, clrs, "  M5 " + IntegerToString(g_dt[0].sAll) +
                     "   M15 " + IntegerToString(g_dt[1].sAll) +
                     "   M30 " + IntegerToString(g_dt[2].sAll), CLR_TEXT);
   DAdd(lines, clrs, "", CLR_TEXT);

   DAdd(lines, clrs, " FILE", CLR_SECTION);
   DAdd(lines, clrs, "  " + StringSubstr(g_diaryName, 0, 46), CLR_DIM);
   DAdd(lines, clrs, "  " + IntegerToString(g_diaryRows) + " results, " + g_diaryNote,
        (g_diaryOk ? CLR_TEXT : CLR_ALERT));
}

//==================================================================
//  TRADE PLAN AND EXECUTION
//==================================================================
//  One idea per lane.  The plan is built from the lane's own bars -
//  confirmed swings for the stop, a replay of the lane's own history
//  for the target - and it is either sent or refused with a reason.
//
//  Nothing here invents a price.  If the structure needed for a stop
//  does not exist, the plan is refused and the panel says why.  A
//  refused plan never changes the signal above it.

struct LaneTrade
{
   int      state;        // TS_NONE / TS_HOLD / TS_WAIT / TS_OPEN
   int      dir;          // -1 SELL / +1 BUY
   double   entry;        // filled price, or the pending price
   double   sl;
   double   tp;
   double   lot;
   ulong    ticket;       // order ticket while waiting, position ticket while open
   datetime until;        // local clock when a waiting limit gives up
   int      atTrend;      // trend when the order was placed
   int      atSignal;     // signal when the order was placed
   string   note;         // the reason a lane is holding
};

LaneTrade g_tr[LANE_COUNT];

//------------------------------------------------------------------
//  Small helpers
//------------------------------------------------------------------
int StructureWindow(int idx)
{
   if(idx == 0) return(36);
   if(idx == 1) return(48);
   return(72);
}

int LaneHorizon(int idx)
{
   if(idx == 0) return(4);
   if(idx == 1) return(6);
   return(8);
}

ulong LaneMagic(int idx)
{
   return(20261031 + (ulong)idx);
}

string TradeStateText(int st)
{
   if(st == TS_OPEN) return("OPEN");
   if(st == TS_WAIT) return("WAIT");
   if(st == TS_PLAN) return("PLAN");
   if(st == TS_HOLD) return("HOLD");
   return("--");
}

color TradeStateColour(int st)
{
   if(st == TS_OPEN) return(CLR_OK);
   if(st == TS_WAIT) return(CLR_HOLD);
   if(st == TS_PLAN) return(CLR_SECTION);
   if(st == TS_HOLD) return(CLR_DIM);
   return(CLR_DIM);
}

//  A confirmed swing is a real three-bar turn: lower than both
//  neighbours.  The right-hand bar is already closed, so nothing here
//  looks into the future.
double SnapDown(double price, double tick)
{
   if(tick <= 0.0) return(price);
   return(NormalizeDouble(MathFloor(price / tick + 1e-9) * tick, g_f.digits));
}

double SnapUp(double price, double tick)
{
   if(tick <= 0.0) return(price);
   return(NormalizeDouble(MathCeil(price / tick - 1e-9) * tick, g_f.digits));
}

bool SwingLowOk(const MqlRates &r[], int k, int last)
{
   return(k > 0 && k < last && r[k].low < r[k - 1].low && r[k].low <= r[k + 1].low);
}

bool SwingHighOk(const MqlRates &r[], int k, int last)
{
   return(k > 0 && k < last && r[k].high > r[k - 1].high && r[k].high >= r[k + 1].high);
}

int PickFilling()
{
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_FOK) != 0) return((int)ORDER_FILLING_FOK);
   if((mode & SYMBOL_FILLING_IOC) != 0) return((int)ORDER_FILLING_IOC);
   return((int)ORDER_FILLING_RETURN);
}

//------------------------------------------------------------------
//  The target: how far this lane actually travelled, before a stop of
//  the same size, in the same direction, over the same horizon.
//------------------------------------------------------------------
double MeasureTarget(int idx, int dir, double riskPrice, double tick)
{
   if(dir == 0 || riskPrice <= 0.0) return(0.0);

   int horizon = LaneHorizon(idx);
   int window  = StructureWindow(idx);
   int need    = REPLAY_BARS + horizon + 2;

   MqlRates r[];
   int n = CopyRates(_Symbol, g_lane[idx].tf, 1, need, r);
   if(n < horizon + 120) return(0.0);

   double samples[];
   int    cnt = 0;

   for(int i = window + 2; i < n - horizon - 1; i++)
   {
      double entry = r[i].close;

      //  The same structural stop this lane would have placed then.
      double level = 0.0;
      int first = i - window + 1;
      if(first < 1) first = 1;

      for(int k = first; k < i; k++)
      {
         if(dir > 0 && SwingLowOk(r, k, i) && r[k].low < entry)
         {
            if(level == 0.0 || r[k].low > level) level = r[k].low;
         }
         if(dir < 0 && SwingHighOk(r, k, i) && r[k].high > entry)
         {
            if(level == 0.0 || r[k].high < level) level = r[k].high;
         }
      }
      if(level == 0.0) continue;

      double stop = (dir > 0) ? level - tick : level + tick;
      double risk = MathAbs(entry - stop);
      if(risk <= 0.0) continue;

      //  Replay forward.  The stop is counted first when both extremes
      //  share a bar, which is the conservative reading.
      double best = 0.0;
      for(int k = i + 1; k <= i + horizon && k < n; k++)
      {
         if(dir > 0 && r[k].low <= stop) break;
         if(dir < 0 && r[k].high >= stop) break;
         double fav = (dir > 0) ? (r[k].high - entry) : (entry - r[k].low);
         if(fav > best) best = fav;
      }

      ArrayResize(samples, cnt + 1);
      samples[cnt] = best / risk;
      cnt++;
   }

   if(cnt < TP_MIN_CASES) return(0.0);

   ArraySort(samples);
   int q = (int)MathFloor((double)(cnt - 1) * TP_QUANTILE);
   if(q < 0) q = 0;
   if(q >= cnt) q = cnt - 1;

   return(samples[q] * riskPrice);
}

//------------------------------------------------------------------
//  Size:  risk% of equity, rounded DOWN to the broker step.  If the
//  budget cannot buy the minimum lot the idea is refused, unless the
//  owner has deliberately turned Minimum lot on.
//------------------------------------------------------------------
double CalcLot(double riskPrice)
{
   if(riskPrice <= 0.0) return(0.0);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double money  = equity * RISK_PCT / 100.0;

   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return(0.0);

   double perLot = (riskPrice / tickSize) * tickValue;
   if(perLot <= 0.0) return(0.0);

   double lots = money / perLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   if(mn   <= 0.0) mn   = step;
   if(mx   <= 0.0) mx   = 100.0;

   lots = MathFloor(lots / step + 1e-8) * step;

   if(lots < mn)
   {
      if(!InpMinLot) return(0.0);
      lots = mn;
   }
   if(lots > mx) lots = MathFloor(mx / step + 1e-8) * step;

   return(NormalizeDouble(lots, 2));
}

//------------------------------------------------------------------
//  Build the plan for one lane.  Returns false with a reason.
//------------------------------------------------------------------
bool BuildPlan(int idx, int dir, bool market, int &trendNow, int &signalNow,
               double &entry, double &sl, double &tp, double &lot, string &why)
{
   entry = 0.0; sl = 0.0; tp = 0.0; lot = 0.0; why = "";

   double tick  = g_f.tickSize > 0.0 ? g_f.tickSize : g_f.point;
   double point = g_f.point > 0.0 ? g_f.point : tick;
   if(tick <= 0.0 || point <= 0.0) { why = "no price grid"; return(false); }

   double bid = g_f.bid;
   double ask = g_f.ask;
   if(bid <= 0.0 || ask <= 0.0 || ask < bid) { why = "no live quote"; return(false); }

   double spread = ask - bid;
   if(spread < 0.0) spread = 0.0;

   //  The same spread gate the market state already applies.
   if(spread > 0.0 && g_p.spreadGateX > 0.0)
   {
      double typical = 0.0;
      MqlDateTime st;
      TimeToStruct(ServerNow(), st);
      int sn = 0;
      typical = SpreadBaseline(st.hour, sn);
      if(sn >= 20 && typical > 0.0 && spread > typical * MAX_SPREAD_GATE)
      { why = "spread too wide"; return(false); }
   }

   int window = StructureWindow(idx);
   int need   = window + 4;

   MqlRates r[];
   int n = CopyRates(_Symbol, g_lane[idx].tf, 1, need, r);
   if(n < window + 2) { why = "structure needs more history"; return(false); }

   int last = n - 1;
   int first = last - window + 1;
   if(first < 1) first = 1;

   // ---- entry -----------------------------------------------------
   if(market) entry = (dir > 0) ? ask : bid;
   else
   {
      //  Nearest confirmed support below the market for a BUY, or
      //  resistance above it for a SELL.  Never a price already
      //  through the market: that would fill instantly at a worse
      //  price than the plan was sized for.
      double offset = MathMax(tick, spread);
      double level  = 0.0;
      for(int k = first; k < last; k++)
      {
         if(dir > 0 && SwingLowOk(r, k, last))
         {
            double p = r[k].low;
            if(p <= ask - offset && (level == 0.0 || p > level)) level = p;
         }
         if(dir < 0 && SwingHighOk(r, k, last))
         {
            double p = r[k].high;
            if(p >= bid + offset && (level == 0.0 || p < level)) level = p;
         }
      }
      if(level <= 0.0) { why = "no swing to rest the limit on"; return(false); }
      entry = (dir > 0) ? SnapDown(level, tick) : SnapUp(level, tick);
   }

   // ---- stop ------------------------------------------------------
   double stopLevel = 0.0;
   for(int k = first; k < last; k++)
   {
      if(dir > 0 && SwingLowOk(r, k, last))
      {
         if(r[k].low < entry - 0.5 * tick && (stopLevel == 0.0 || r[k].low > stopLevel))
            stopLevel = r[k].low;
      }
      if(dir < 0 && SwingHighOk(r, k, last))
      {
         if(r[k].high > entry + 0.5 * tick && (stopLevel == 0.0 || r[k].high < stopLevel))
            stopLevel = r[k].high;
      }
   }
   if(stopLevel <= 0.0) { why = "no swing to hide the stop behind"; return(false); }

   double buffer = MathMax(tick, spread);
   sl = (dir > 0) ? SnapDown(stopLevel - buffer, tick)
                  : SnapUp(stopLevel + buffer, tick);

   double risk = (dir > 0) ? (entry - sl) : (sl - entry);
   if(risk <= 0.0) { why = "stop on the wrong side"; return(false); }

   //  Two floors: the stop must be wider than the spread costs and
   //  wider than an ordinary bar, or it is noise rather than a plan.
   if(spread > 0.0 && risk < spread * SL_COST_X)
   { why = "stop too close to the spread"; return(false); }

   double med = g_recentMove;
   if(med > 0.0 && risk < med * SL_NOISE_X)
   { why = "stop inside one normal bar"; return(false); }

   // ---- target ----------------------------------------------------
   double dist = MeasureTarget(idx, dir, risk, tick);
   if(dist <= 0.0) { why = "not enough history for a target"; return(false); }

   tp = (dir > 0) ? SnapDown(entry + dist, tick) : SnapUp(entry - dist, tick);

   //  Cap before the nearest confirmed opposing swing.
   double cap = 0.0;
   for(int k = first; k < last; k++)
   {
      if(dir > 0 && SwingHighOk(r, k, last) && r[k].high > entry)
      {
         if(cap == 0.0 || r[k].high < cap) cap = r[k].high;
      }
      if(dir < 0 && SwingLowOk(r, k, last) && r[k].low < entry)
      {
         if(cap == 0.0 || r[k].low > cap) cap = r[k].low;
      }
   }
   if(cap > 0.0)
   {
      double capped = (dir > 0) ? SnapDown(cap - tick, tick) : SnapUp(cap + tick, tick);
      if((dir > 0 && capped > entry && capped < tp) ||
         (dir < 0 && capped < entry && capped > tp)) tp = capped;
   }

   //  The broker's own minimum distance, in points.  A level closer
   //  than this is rejected by the server, so it is refused here with
   //  a reason instead.
   if(g_f.stopsLevel > 0 && g_f.point > 0.0)
   {
      if(risk / g_f.point < (double)g_f.stopsLevel)
      { why = "stop inside the broker minimum"; return(false); }
   }

   double reward = (dir > 0) ? (tp - entry) : (entry - tp);
   if(reward <= 0.0) { why = "target on the wrong side"; return(false); }
   if(g_f.stopsLevel > 0 && g_f.point > 0.0 &&
      reward / g_f.point < (double)g_f.stopsLevel)
   { why = "target inside the broker minimum"; return(false); }
   if(spread > 0.0 && reward < spread * TP_COST_X)
   { why = "target does not clear the spread"; return(false); }

   // ---- size ------------------------------------------------------
   lot = CalcLot(risk);
   if(lot <= 0.0) { why = "risk budget below the minimum lot"; return(false); }

   double margin = 0.0;
   if(!OrderCalcMargin((dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol,
                       lot, entry, margin))
   { why = "margin cannot be calculated"; return(false); }
   if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.90)
   { why = "not enough free margin"; return(false); }

   trendNow  = g_lane[idx].trend;
   signalNow = g_lane[idx].signal;
   return(true);
}

//------------------------------------------------------------------
//  Sending
//------------------------------------------------------------------
bool TradeSend(int idx, int dir, bool market, double price, double lot,
               double sl, double tp, ulong &ticket)
{
   ticket = 0;
   MqlTradeRequest req;
   MqlTradeResult  res;

   ZeroMemory(req);
   ZeroMemory(res);

   req.symbol  = _Symbol;
   req.volume  = lot;
   req.sl      = NormalizeDouble(sl, g_f.digits);
   req.tp      = NormalizeDouble(tp, g_f.digits);
   req.magic   = LaneMagic(idx);
   req.comment = "AUT";

   if(market)
   {
      req.action       = TRADE_ACTION_DEAL;
      req.type         = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      req.price        = NormalizeDouble(price, g_f.digits);
      req.deviation    = 20;
      req.type_filling = (ENUM_ORDER_TYPE_FILLING)PickFilling();
   }
   else
   {
      req.action       = TRADE_ACTION_PENDING;
      req.type         = (dir > 0) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
      req.price        = NormalizeDouble(price, g_f.digits);
      req.type_time    = ORDER_TIME_GTC;
      req.type_filling = ORDER_FILLING_RETURN;
   }

   if(!OrderSend(req, res))
   {
      PrintFormat("%s: order not accepted (%d)", g_lane[idx].name, res.retcode);
      return(false);
   }
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED &&
      res.retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      PrintFormat("%s: rejected, retcode %d", g_lane[idx].name, res.retcode);
      return(false);
   }

   ticket = (market ? res.deal : res.order);
   return(true);
}

void TradeRemove(int idx)
{
   if(g_tr[idx].state != TS_WAIT || g_tr[idx].ticket == 0) return;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action = TRADE_ACTION_REMOVE;
   req.order  = g_tr[idx].ticket;

   if(OrderSend(req, res) &&
      (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
   {
      PrintFormat("%s: waiting order cancelled", g_lane[idx].name);
      g_tr[idx].state  = TS_NONE;
      g_tr[idx].ticket = 0;
      return;
   }

   //  Not confirmed: leave the state alone.  The next sync will find
   //  out whether it is still there, filled, or already gone.
   PrintFormat("%s: cancel not confirmed (%d)", g_lane[idx].name, res.retcode);
}

ulong FindLanePosition(int idx)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == (long)LaneMagic(idx)) return(t);
   }
   return(0);
}

//  After a market fill, or when a pending order disappears, adopt the
//  position that carries this lane's magic.  A lane never holds two.
void TradeAdopt(int idx)
{
   ulong t = FindLanePosition(idx);
   g_tr[idx].ticket = t;

   if(t == 0)
   {
      g_tr[idx].state = TS_NONE;
      return;
   }

   g_tr[idx].state = TS_OPEN;
   g_tr[idx].note  = "";
   g_tr[idx].sl    = PositionGetDouble(POSITION_SL);
   g_tr[idx].tp    = PositionGetDouble(POSITION_TP);
   g_tr[idx].lot   = PositionGetDouble(POSITION_VOLUME);
   g_tr[idx].entry = PositionGetDouble(POSITION_PRICE_OPEN);
   g_tr[idx].dir   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
}

//------------------------------------------------------------------
//  Keep the state honest against the terminal
//------------------------------------------------------------------
void TradeSync(int idx)
{
   if(g_tr[idx].state == TS_OPEN)
   {
      //  Ticket 0 means a market request was just sent and the broker
      //  has not published the position yet.  Adopt it, do not declare
      //  the lane closed - that would allow a second order.
      if(g_tr[idx].ticket == 0)
      {
         TradeAdopt(idx);
         return;
      }

      if(!PositionSelectByTicket(g_tr[idx].ticket))
      {
         //  Closed.  Keep the trend and signal it was traded on, so a
         //  signal that never changed does not buy the same idea twice.
         g_tr[idx].atTrend  = g_lane[idx].trend;
         g_tr[idx].atSignal = g_lane[idx].signal;
         g_tr[idx].state  = TS_NONE;
         g_tr[idx].ticket = 0;
         g_tr[idx].note   = "";
         return;
      }
      g_tr[idx].sl  = PositionGetDouble(POSITION_SL);
      g_tr[idx].tp  = PositionGetDouble(POSITION_TP);
      g_tr[idx].lot = PositionGetDouble(POSITION_VOLUME);
      g_tr[idx].entry = PositionGetDouble(POSITION_PRICE_OPEN);
      g_tr[idx].dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      return;
   }

   if(g_tr[idx].state == TS_WAIT)
   {
      if(OrderSelect(g_tr[idx].ticket))
      {
         g_tr[idx].entry = OrderGetDouble(ORDER_PRICE_OPEN);
         g_tr[idx].sl    = OrderGetDouble(ORDER_SL);
         g_tr[idx].tp    = OrderGetDouble(ORDER_TP);
         g_tr[idx].lot   = OrderGetDouble(ORDER_VOLUME_CURRENT);
         return;
      }

      //  The order is gone: it either filled or was removed elsewhere.
      PrintFormat("%s: waiting order %s is gone",
                  g_lane[idx].name, IntegerToString((long)g_tr[idx].ticket));
      g_tr[idx].ticket = 0;
      g_tr[idx].state  = TS_NONE;
      TradeAdopt(idx);
   }
}

//------------------------------------------------------------------
//  One closed bar on one lane
//------------------------------------------------------------------
void TradeOnBar(int idx)
{
   TradeSync(idx);

   //  No new idea while the broker is shut; an open position keeps its
   //  broker-side stop and target.
   if(g_m.code != MS_OPEN)
   {
      if(g_tr[idx].state == TS_NONE || g_tr[idx].state == TS_HOLD)
      {
         g_tr[idx].state = TS_HOLD;
         g_tr[idx].note  = "market closed";
      }
      return;
   }

   //  A waiting limit dies when the reason for it dies.
   if(g_tr[idx].state == TS_WAIT)
   {
      bool signalGone   = (g_lane[idx].signal == 0);
      bool signalFlipped = (g_lane[idx].signal != g_tr[idx].atSignal);
      bool trendChanged  = (g_lane[idx].trend  != g_tr[idx].atTrend);
      bool expired       = (g_tr[idx].until > 0 && ServerNow() > g_tr[idx].until);

      if(signalGone || signalFlipped || trendChanged || expired)
      {
         TradeRemove(idx);
         return;
      }
   }

   if(g_tr[idx].state == TS_OPEN) return;

   //  A fill can arrive a moment after the request: adopt it before
   //  deciding to send anything else for this lane.
   if(FindLanePosition(idx) != 0)
   {
      TradeAdopt(idx);
      return;
   }

   int dir = g_lane[idx].signal;
   if(dir == 0)
   {
      g_tr[idx].state = TS_NONE;
      g_tr[idx].note  = "";
      return;
   }

   //  One idea per signal, not per bar: after a trade is closed the
   //  lane waits for the signal or the trend to change.
   if(g_tr[idx].atSignal == g_lane[idx].signal &&
      g_tr[idx].atTrend  == g_lane[idx].trend) return;

   bool market = (MathAbs(g_lane[idx].score) >= 3);

   int    trNow = 0, sgNow = 0;
   double entry = 0.0, sl = 0.0, tp = 0.0, lot = 0.0;
   string why = "";

   if(!BuildPlan(idx, dir, market, trNow, sgNow, entry, sl, tp, lot, why))
   {
      g_tr[idx].state = TS_HOLD;
      g_tr[idx].dir   = dir;
      g_tr[idx].note  = why;
      g_tr[idx].entry = 0.0;
      g_tr[idx].sl    = 0.0;
      g_tr[idx].tp    = 0.0;
      g_tr[idx].lot   = 0.0;
      return;
   }

   //  The gate sits immediately before the send and nowhere else, so
   //  everything above is identical whether or not trading is live.
   if(!TRADING_LIVE)
   {
      g_tr[idx].state = TS_PLAN;
      g_tr[idx].dir   = dir;
      g_tr[idx].entry = entry;
      g_tr[idx].sl    = sl;
      g_tr[idx].tp    = tp;
      g_tr[idx].lot   = lot;
      g_tr[idx].note  = "trading is off";
      g_tr[idx].ticket = 0;
      return;
   }

   ulong ticket = 0;
   if(!TradeSend(idx, dir, market, entry, lot, sl, tp, ticket))
   {
      g_tr[idx].state = TS_HOLD;
      g_tr[idx].dir   = dir;
      g_tr[idx].note  = "the broker rejected the order";
      return;
   }

   g_tr[idx].dir      = dir;
   g_tr[idx].entry    = entry;
   g_tr[idx].sl       = sl;
   g_tr[idx].tp       = tp;
   g_tr[idx].lot      = lot;
   g_tr[idx].atTrend  = g_lane[idx].trend;
   g_tr[idx].atSignal = g_lane[idx].signal;
   g_tr[idx].note     = "";

   if(market)
   {
      //  Keep the plan on the row even if the position is not visible
      //  yet; the next bar adopts it.  Never re-send in the meantime.
      g_tr[idx].state  = TS_OPEN;
      g_tr[idx].ticket = 0;
      TradeAdopt(idx);
      if(g_tr[idx].ticket == 0)
      {
         g_tr[idx].state = TS_OPEN;   // ticket 0 = waiting for the fill
         g_tr[idx].entry = entry;
         g_tr[idx].sl    = sl;
         g_tr[idx].tp    = tp;
         g_tr[idx].lot   = lot;
         g_tr[idx].dir   = dir;
      }
   }
   else
   {
      g_tr[idx].state  = TS_WAIT;
      g_tr[idx].ticket = ticket;
      g_tr[idx].until  = ServerNow() + (int)(3 * PeriodSeconds(g_lane[idx].tf));
   }

   PrintFormat("%s: %s %s at %s, stop %s, target %s, %.2f lots",
               g_lane[idx].name, (market ? "market" : "limit"),
               SignalText(dir), DoubleToString(entry, g_f.digits),
               DoubleToString(sl, g_f.digits), DoubleToString(tp, g_f.digits), lot);
}

//------------------------------------------------------------------
//  Panel
//------------------------------------------------------------------
string TradePriceCell(double price, double from, int digits)
{
   if(price <= 0.0 || from <= 0.0) return("--");

   double point = g_f.point > 0.0 ? g_f.point : g_f.tickSize;
   if(point <= 0.0) return(DoubleToString(price, digits));

   double pts = MathAbs(price - from) / point;
   return(Pad(DoubleToString(price, digits), 8) + " (" + IntegerToString((int)MathRound(pts)) + ")");
}

void TradeRow(int idx)
{
   string tf  = g_lane[idx].name;
   string dirTxt = "--";
   string entTxt = "--";
   string slTxt  = "--";
   string tpTxt  = "--";
   string lotTxt = "--";
   string stTxt  = TradeStateText(g_tr[idx].state);
   color  stClr  = TradeStateColour(g_tr[idx].state);

   if(g_tr[idx].state == TS_HOLD)
   {
      dirTxt = (g_tr[idx].dir > 0 ? "BUY" : "SELL");
      stClr  = CLR_DIM;
   }
   else if(g_tr[idx].state != TS_NONE)
   {
      dirTxt = (g_tr[idx].dir > 0 ? "BUY" : "SELL");
      entTxt = DoubleToString(g_tr[idx].entry, g_f.digits);
      slTxt  = TradePriceCell(g_tr[idx].sl, g_tr[idx].entry, g_f.digits);
      tpTxt  = TradePriceCell(g_tr[idx].tp, g_tr[idx].entry, g_f.digits);
      lotTxt = DoubleToString(g_tr[idx].lot, 2);
   }

   string tip = "";
   if(g_tr[idx].state == TS_PLAN)      tip = "A plan is ready but trading is off, so nothing was sent to the broker.";
   else if(g_tr[idx].state == TS_HOLD) tip = "No plan: " + g_tr[idx].note + ".";
   else if(g_tr[idx].state == TS_WAIT) tip = "A limit is waiting at the broker. It is cancelled when the trend changes, the signal flips or ends, or its validity runs out.";
   else if(g_tr[idx].state == TS_OPEN) tip = "Position open. Stop and target are held at the broker.";
   else if(g_lane[idx].signal == 0)    tip = "No BUY or SELL on this lane, so nothing is planned.";
   else                                tip = "A direction exists but no plan has been built yet.";

   string segT[7];
   color  segC[7];
   string segP[7];

   segT[0] = " " + Pad(tf, 5);      segC[0] = CLR_TEXT;  segP[0] = "";
   segT[1] = Pad(dirTxt, 5);        segC[1] = SignalColour(g_tr[idx].dir); segP[1] = tip;
   segT[2] = Pad(entTxt, 9);        segC[2] = CLR_VALUE; segP[2] = tip;
   segT[3] = Pad(slTxt, 17);        segC[3] = CLR_ALERT; segP[3] = tip;
   segT[4] = Pad(tpTxt, 17);        segC[4] = CLR_OK;    segP[4] = tip;
   segT[5] = Pad(lotTxt, 6);        segC[5] = CLR_VALUE; segP[5] = tip;
   segT[6] = stTxt;                 segC[6] = stClr;     segP[6] = tip;

   AddSegLineTip(segT, segC, segP);
}

void TradeHeaderRow()
{
   string segT[7];
   color  segC[7];
   string segP[7];

   segT[0] = " " + Pad("TF", 5);     segC[0] = CLR_SECTION;
   segT[1] = Pad("DIR", 5);          segC[1] = CLR_SECTION;
   segT[2] = Pad("ENTRY", 9);        segC[2] = CLR_SECTION;
   segT[3] = Pad("SL", 17);          segC[3] = CLR_SECTION;
   segT[4] = Pad("TP", 17);          segC[4] = CLR_SECTION;
   segT[5] = Pad("LOT", 6);          segC[5] = CLR_SECTION;
   segT[6] = "STATE";                segC[6] = CLR_SECTION;

   for(int i = 0; i < 7; i++) segP[i] = "Distance in points, measured from the entry price.";

   AddSegLineTip(segT, segC, segP);
}

//==================================================================
//  PANEL
//==================================================================
//  The layout follows the interface sketch in automate.md section 7.
//  Group 1 is the lane table, group 2 is one trade row per lane and
//  group 3 is the diary.  All three groups are always drawn: a row of
//  dashes says plainly that nothing is happening on that lane, which is
//  easier to read than a panel that changes height.  The frame is the
//  same from stage to stage; only the values fill in as each stage is
//  built.
//
//  A line is either plain or made of coloured segments, so the market
//  state can be red or green while the session and spread on the same
//  line stay silver.  Every drawn label is numbered continuously,
//  which makes removing surplus objects after a redraw trivial.
//==================================================================
//  Lane table columns.  TREND and REGIME hold "LABEL 6/30%L" and are
//  sized from the widest string that format can produce.
#define LANE_TREND_W    14
#define LANE_REGIME_W   16
#define LANE_SCORE_W    7
#define LANE_SIGNAL_W   10
#define ROW_EXTRA 11            // row pitch = font size + this (as SimpleEA)

//  g_line[], g_lineClr[], g_lineSegFrom[], g_lineSegN[], g_segText[]
//  and g_segClr[] are declared once, in the GLOBAL STATE block above.

void ResetLines()
{
   ArrayResize(g_line, 0);
   ArrayResize(g_lineClr, 0);
   ArrayResize(g_lineSegFrom, 0);
   ArrayResize(g_lineSegN, 0);
   ArrayResize(g_segText, 0);
   ArrayResize(g_segClr, 0);
   ArrayResize(g_segTip, 0);
}

void AddLine(string text, color clr)
{
   int n = ArraySize(g_line);
   ArrayResize(g_line, n + 1);
   ArrayResize(g_lineClr, n + 1);
   ArrayResize(g_lineSegFrom, n + 1);
   ArrayResize(g_lineSegN, n + 1);
   g_line[n]        = text;
   g_lineClr[n]     = clr;
   g_lineSegFrom[n] = -1;
   g_lineSegN[n]    = 0;
}

//  A line of coloured pieces, each with optional hover text.
void AddSegLineTip(string &texts[], color &clrs[], string &tips[])
{
   int nseg = ArraySize(texts);
   if(nseg <= 0) { AddLine("", CLR_TEXT); return; }
   int ntip = ArraySize(tips);

   string full = "";
   for(int i = 0; i < nseg; i++) full += texts[i];

   int n = ArraySize(g_line);
   ArrayResize(g_line, n + 1);
   ArrayResize(g_lineClr, n + 1);
   ArrayResize(g_lineSegFrom, n + 1);
   ArrayResize(g_lineSegN, n + 1);
   g_line[n]        = full;
   g_lineClr[n]     = CLR_TEXT;
   g_lineSegFrom[n] = ArraySize(g_segText);
   g_lineSegN[n]    = nseg;

   for(int i = 0; i < nseg; i++)
   {
      int k = ArraySize(g_segText);
      ArrayResize(g_segText, k + 1);
      ArrayResize(g_segClr, k + 1);
      ArrayResize(g_segTip, k + 1);
      g_segText[k] = texts[i];
      g_segClr[k]  = clrs[i];
      g_segTip[k]  = (i < ntip ? tips[i] : "");
   }
}

//  A line of coloured pieces with no hover text.
void AddSegLine(string &texts[], color &clrs[])
{
   string none[];
   AddSegLineTip(texts, clrs, none);
}


//  One lane, one row, coloured by direction.  Every segment is padded
//  to its column width so the concatenation lands on the same columns
//  as the plain header:
//      TF 1 | TREND 8 | AGE 15 | REGIME 22 | SCORE 31 | SIGNAL 38
//      | TRADE STATUS 48
void LaneRow(int idx)
{
   string tfTxt     = g_lane[idx].name;
   string trendTxt  = "-";
   string regimeTxt = "-";
   string scoreTxt  = "-";
   string signalTxt = "-";

   string trendTip  = "";
   string regimeTip = "";
   string scoreTip  = "";
   string signalTip = "";

   color trendClr  = CLR_DIM;
   color signalClr = CLR_DIM;

   if(g_lane[idx].ready)
   {
      string tfName = g_lane[idx].name;
      int    mPB    = BarMinutes(g_lane[idx].tf);

      trendClr  = TrendColour(g_lane[idx].trend);
      signalClr = SignalColour(g_lane[idx].signal);

      //  Longest completed run each channel has seen. Decided once here so
      //  the cell and the tooltip can never disagree about it.
      int  seenTrend  = MaxRun(idx * 3);
      int  seenRegime = MaxRun(idx * 3 + 1);
      bool overTrend  = (seenTrend  > 0 && !g_lane[idx].trendLeftOk  &&
                         g_lane[idx].trendAge  >= seenTrend);
      bool overRegime = (seenRegime > 0 && !g_lane[idx].regimeLeftOk &&
                         g_lane[idx].regimeAge >= seenRegime);

      trendTxt  = LeftCell(TrendText(g_lane[idx].trend),
                           g_lane[idx].trendLeft, g_lane[idx].trendLeftPct,
                           g_lane[idx].trendLeftOk, overTrend, LANE_TREND_W);

      regimeTxt = LeftCell(RegimeText(g_lane[idx].regime),
                           g_lane[idx].regimeLeft, g_lane[idx].regimeLeftPct,
                           g_lane[idx].regimeLeftOk, overRegime, LANE_REGIME_W);

      scoreTxt  = ScoreText(g_lane[idx].score);
      signalTxt = SignalCell(SignalText(g_lane[idx].signal),
                             g_lane[idx].signalDuraPct,
                             g_lane[idx].signalDuraOk, LANE_SIGNAL_W);

      // ---- hover text: the only explanation on the panel -------
      if(g_lane[idx].trendLeftOk)
         trendTip = StringFormat(
            "%s trend %s. About %d more bars (%s). %d%% of its life left - "
            "a total of about %d bars, %d already used. Similar past runs "
            "went on for %d to %d more.",
            tfName, TrendText(g_lane[idx].trend),
            g_lane[idx].trendLeft, MinutesText(g_lane[idx].trendLeft, mPB),
            g_lane[idx].trendLeftPct,
            g_lane[idx].trendAge + g_lane[idx].trendLeft,
            g_lane[idx].trendAge,
            g_lane[idx].trendLo, g_lane[idx].trendHi);
      else
      {
         int done = g_lane[idx].trendAge;
         if(overTrend)
            trendTip = StringFormat(
               "%s trend %s has already run %d bars - longer than any run in its "
               "history (longest %d). Shown as Max: no honest estimate of what "
               "is left.",
               tfName, TrendText(g_lane[idx].trend), done, seenTrend);
         else
            trendTip = StringFormat(
               "%s trend %s. Too few past runs got this far to say how much "
               "longer it lasts. Age so far: %d bars.",
               tfName, TrendText(g_lane[idx].trend), done);
      }

      if(g_lane[idx].regimeLeftOk)
         regimeTip = StringFormat(
            "%s regime %s. About %d more bars (%s). %d%% of its life left - "
            "a total of about %d bars, %d already used. Similar past runs "
            "went on for %d to %d more.",
            tfName, RegimeText(g_lane[idx].regime),
            g_lane[idx].regimeLeft, MinutesText(g_lane[idx].regimeLeft, mPB),
            g_lane[idx].regimeLeftPct,
            g_lane[idx].regimeAge + g_lane[idx].regimeLeft,
            g_lane[idx].regimeAge,
            g_lane[idx].regimeLo, g_lane[idx].regimeHi);
      else
      {
         int done = g_lane[idx].regimeAge;
         if(overRegime)
            regimeTip = StringFormat(
               "%s regime %s has already run %d bars - longer than any run in its "
               "history (longest %d). Shown as Max: no honest estimate of what "
               "is left.",
               tfName, RegimeText(g_lane[idx].regime), done, seenRegime);
         else
            regimeTip = StringFormat(
               "%s regime %s. Too few past runs got this far to say how much "
               "longer it lasts. Age so far: %d bars.",
               tfName, RegimeText(g_lane[idx].regime), done);
      }

      if(g_lane[idx].signal == 0)
         signalTip = "No BUY or SELL: the three votes do not agree strongly "
                     "enough. BUY needs 2 of 3, SELL needs 2 of 3.";
      else if(g_lane[idx].signalDuraOk)
         signalTip = StringFormat(
            "%s has stood for %d bars. Of the past %s runs on this symbol "
            "that reached this age, %d%% were still standing %d bars later. "
            "Counted from this symbol's own history, not a fixed rule.",
            SignalText(g_lane[idx].signal), g_lane[idx].signalAge,
            SignalText(g_lane[idx].signal), g_lane[idx].signalDuraPct,
            SIGNAL_DURA_BARS);
      else
         signalTip = StringFormat(
            "%s has stood for %d bars. Too few past %s runs have reached "
            "this age to say how long it usually lasts.",
            SignalText(g_lane[idx].signal), g_lane[idx].signalAge,
            SignalText(g_lane[idx].signal));

      int agree = (g_lane[idx].score < 0 ? -g_lane[idx].score : g_lane[idx].score);
      scoreTip = StringFormat(
         "%d of 3 votes agree. Trend %d, momentum %d, structure %d.",
         agree, g_lane[idx].trend, g_lane[idx].vMom, g_lane[idx].vStr);

      signalTip = "BUY or SELL needs 2 of the 3 votes to agree. "
                  "Two agreeing is 2/3, all three is 3/3.";
   }

   //  The trade status lives on the plan row below, where it belongs.
   //  Keeping a second copy up here would be the same fact twice.
   string sigCell = Pad(signalTxt, LANE_SIGNAL_W);
   StringTrimRight(sigCell);

   string segT[5];
   color  segC[5];
   string segP[5];
   segT[0] = " " + Pad(tfTxt, 7);              segC[0] = CLR_TEXT;
   segT[1] = Pad(trendTxt,  LANE_TREND_W);     segC[1] = trendClr;
   segT[2] = Pad(regimeTxt, LANE_REGIME_W);    segC[2] = CLR_TEXT;
   segT[3] = Pad(scoreTxt,  LANE_SCORE_W);     segC[3] = CLR_VALUE;
   segT[4] = sigCell;                          segC[4] = signalClr;

   segP[0] = "";
   segP[1] = trendTip;
   segP[2] = regimeTip;
   segP[3] = scoreTip;
   segP[4] = signalTip;

   AddSegLineTip(segT, segC, segP);
}

//  The timeframe table header.  Drawn as six separate cells on exactly
//  the same grid as the lane rows below it, not as one long string.
//
//  Why this matters: a label's glyph advance is a little narrower than
//  the width TextWidth() assumes, so a single-string header and a
//  cell-by-cell row drift apart - by the last column the header sat
//  about 46 px left of the data.  Plus the header is the longest line
//  on the panel, so a single label was also the first thing to run out
//  of room at the right edge.  Both go away when the header walks the
//  same cell grid as everything else.
void HeaderRow()
{
   string sigHead = Pad("SIGNAL", LANE_SIGNAL_W);
   StringTrimRight(sigHead);

   string segT[5];
   color  segC[5];
   string segP[5];

   segT[0] = " " + Pad("TF", 7);              segC[0] = CLR_SECTION;
   segT[1] = Pad("TREND", LANE_TREND_W);      segC[1] = CLR_SECTION;
   segT[2] = Pad("REGIME", LANE_REGIME_W);    segC[2] = CLR_SECTION;
   segT[3] = Pad("SCORE", LANE_SCORE_W);      segC[3] = CLR_SECTION;
   segT[4] = sigHead;                         segC[4] = CLR_SECTION;

   for(int i = 0; i < 5; i++) segP[i] = "";

   AddSegLineTip(segT, segC, segP);
}

int LaneBars(ENUM_TIMEFRAMES tf)
{
   return(Bars(_Symbol, tf));
}

void BuildPanel()
{
   ResetLines();

   datetime serverNow = ServerNow();

   datetime utcNow = 0;
   string   srcNote = "";
   bool utcKnown = ResolveUtc(serverNow, utcNow, srcNote);

   // ---------------------------------------------------------------
   //  Row 1 - identity:  AUTOMATE  symbol | class | account
   //  Automate's own ON/OFF flag joins this row with the trading
   //  stage; until then the row ends at the account mode rather than
   //  leaving a separator with nothing after it.
   // ---------------------------------------------------------------
   AddLine(" AUTOMATE    " + g_f.name + "  |  " + g_p.label +
           "  |  " + AccountModeText(), CLR_TITLE);

   // ---------------------------------------------------------------
   //  Row 2 - market state | session | spread
   //  Only the state carries colour; the rest of the line stays
   //  silver so a red MARKET CLOSED does not shout the whole row.
   // ---------------------------------------------------------------
   double sprPts = (g_f.point > 0.0) ? g_f.spreadPrice / g_f.point : 0.0;

   //  The session name comes from the broker's own server clock read
   //  against real UTC; it is a statement, not an estimate.  Only the
   //  Strategy Tester, where UTC cannot be reconstructed at all, has
   //  to say "unknown".
   string sessTxt = utcKnown ? SessionLabel(utcNow) : "unknown";

   string segTxt[3];
   color  segClr[3];
   segTxt[0] = " " + g_m.headline;
   segClr[0] = g_m.clr;
   segTxt[1] = " | Session: " + sessTxt;
   segClr[1] = CLR_TEXT;
   segTxt[2] = " | Spread: " + DoubleToString(sprPts, 1) + " pts";
   segClr[2] = CLR_TEXT;
   AddSegLine(segTxt, segClr);

   //  Only when the market is not simply open: the close reason, the
   //  next open time and the broker's own restriction.  On a live
   //  symbol row 2 has already said everything.
   if(g_m.code != MS_OPEN)
      AddLine(" " + g_m.detail, (g_m.code == MS_CLOSED ? CLR_HOLD : CLR_DIM));

   if(g_m.modeNote != "")
      AddLine(L("Broker", g_m.modeNote), CLR_HOLD);

   AddLine("", CLR_TEXT);

   // ---------------------------------------------------------------
   //  Timeframe table - one row per lane, filled by the signal
   //  engine.  A lane whose history is too shallow says DATA WAIT
   //  rather than reading a regime from half a window.
   // ---------------------------------------------------------------
   HeaderRow();
   for(int i = 0; i < LANE_COUNT; i++) LaneRow(i);
   AddLine("", CLR_TEXT);

   // ---------------------------------------------------------------
   //  Group 2 - the trade plan.  One row per lane on the same grid as
   //  the table above, so no legend is needed.  Always three rows: a
   //  row of dashes is a statement that nothing is happening here.
   // ---------------------------------------------------------------
   TradeHeaderRow();
   for(int t = 0; t < LANE_COUNT; t++) TradeRow(t);
   AddLine("", CLR_TEXT);
   // ---------------------------------------------------------------
   //  Group 3 - the diary.  Two rows of counts and one health line.
   //  Order inside every block is M5 / M15 / M30, matching the table
   //  directly above, so no legend is printed.  Each block is padded
   //  to a fixed width, so the panel never widens as counts grow.
   // ---------------------------------------------------------------
   string tS = "How many signal runs the diary has checked. Each run is "
               "counted once, 3 bars after the panel first put a figure on it.";
   string tW = "Wins. Zero until filled trades are graded: the diary "
               "checks what the panel said, not trades.";
   string tL = "Losses. Zero until filled trades are graded.";

   color cS = (g_diaryOk ? CLR_VALUE : CLR_DIM);

   string sT[4];
   color  sC[4];
   string sP[4];
   sT[0] = " Diary   today   ";              sC[0] = CLR_LABEL; sP[0] = "";
   sT[1] = Pad(DiaryS(true),  DIARY_BLK_W);  sC[1] = cS;        sP[1] = tS;
   sT[2] = Pad(DiaryW(true),  DIARY_BLK_W);  sC[2] = CLR_DIM;   sP[2] = tW;
   sT[3] = DiaryL(true);                     sC[3] = CLR_DIM;   sP[3] = tL;
   AddSegLineTip(sT, sC, sP);

   string aT[4];
   color  aC[4];
   string aP[4];
   aT[0] = "         all     ";              aC[0] = CLR_LABEL; aP[0] = "";
   aT[1] = Pad(DiaryS(false), DIARY_BLK_W);  aC[1] = cS;        aP[1] = tS;
   aT[2] = Pad(DiaryW(false), DIARY_BLK_W);  aC[2] = CLR_DIM;   aP[2] = tW;
   aT[3] = DiaryL(false);                    aC[3] = CLR_DIM;   aP[3] = tL;
   AddSegLineTip(aT, aC, aP);

   string hT[4];
   color  hC[4];
   string hP[4];
   hT[0] = " Health: ";                      hC[0] = CLR_LABEL; hP[0] = "";
   hT[1] = DiaryHealthText();                hC[1] = (g_diaryOk ? CLR_TEXT : CLR_ALERT);
   hP[1] = (g_diaryOk
            ? "Advisory only. Nothing here ever gates a signal, a stop, a target or a size."
            : "The diary could not open its own file. " + g_diaryNote);
   hT[2] = " | Tweak: ";                     hC[2] = CLR_LABEL; hP[2] = "";
   hT[3] = TweakText();                      hC[3] = CLR_TEXT;
   hP[3] = "The tweak switch. On means one bounded change is armed. "
           "There is nothing to change yet, so it does nothing.";
   AddSegLineTip(hT, hC, hP);
}

//  Rendered width of one character at a font size, using the real
//  screen DPI.  Same estimate SimpleEA uses, rounded up so the panel
//  is never narrower than the glyphs it holds.
int CharW(int size)
{
   if(size < 6) size = 6;
   int dpi = (int)TerminalInfoInteger(TERMINAL_SCREEN_DPI);
   if(dpi < 72) dpi = 96;
   double em = (double)size * (double)dpi / 72.0;
   return((int)MathCeil(em * 0.55));
}

int TextWidth(string s)
{
   if(s == "") return(0);

   uint w = 0, h = 0;
   int measured = 0;
   if(TextGetSize(s, w, h) && w > 0) measured = (int)w;

   int est = StringLen(s) * CharW(FONT_SIZE);
   return(measured > est ? measured : est);
}

void EnsureRect(string name, int x, int y, int w, int h, color bg, color border)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
   }

   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
   ObjectSetInteger(0, name, OBJPROP_COLOR, border);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
}

//  A label is never given an empty string.  A freshly created chart
//  object carries its type name as the description, so an empty text
//  renders the literal word "Label" - a single space avoids that.
//  Hover text.  Written on every draw rather than compared first: an
//  OBJPROP_TOOLTIP read on a freshly created label is not always the
//  empty string, and a stale tooltip is worse than a redundant write.
void ApplyTip(string name, string tip)
{
   if(ObjectFind(0, name) < 0) return;
   ObjectSetString(0, name, OBJPROP_TOOLTIP, tip);
}

void EnsureLabel(string name, int x, int y, string text, color clr)
{
   string shown = (text == "") ? " " : text;

   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER, 10);
      ObjectSetString(0, name, OBJPROP_FONT, FONT_NAME);
   }

   //  Set on every update, not only at creation: the font then repairs
   //  itself if the object was left behind by an older build.
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FONT_SIZE);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);

   if(ObjectGetString(0, name, OBJPROP_TEXT) != shown)
      ObjectSetString(0, name, OBJPROP_TEXT, shown);
}

void DrawPanel()
{
   //  10 point font, exactly as SimpleEA renders it.
   TextSetFont(FONT_NAME, -FONT_SIZE * 10);

   int count = ArraySize(g_line);
   if(count <= 0) return;

   //  Row pitch defaults to SimpleEA's (font size + 11 px) so the two
   //  panels look the same on the same chart at the same font size.  On
   //  a chart too short for that, the pitch tightens - but never below
   //  the measured text height + 2 px, where lines would touch.
   int rowH = FONT_SIZE + ROW_EXTRA;

   uint mw = 0, mh = 0;
   int textH = (TextGetSize("Ag", mw, mh) && mh > 0) ? (int)mh : FONT_SIZE + 3;
   int floorH = textH + 2;

   int chartH = (int)ChartGetInteger(0, CHART_HEIGHT_IN_PIXELS);
   if(chartH > 200)
   {
      int avail = chartH - PANEL_Y - 8 - PANEL_PAD * 2;
      int fit   = avail / (count > 0 ? count : 1);
      if(fit < rowH) rowH = (fit > floorH ? fit : floorH);
   }

   //  Width and height come from the text actually present, so the
   //  panel is never a fixed box: it grows and shrinks by itself.
   int maxW = 0;
   for(int i = 0; i < count; i++)
   {
      int w = TextWidth(g_line[i]);
      if(w > maxW) maxW = w;
   }

   //  TextGetSize and the rendered glyph advance can disagree by a
   //  percent or two, and a line that renders a hair wide loses its
   //  last characters against the panel edge.  A small proportional
   //  margin removes that risk at no cost.
   int slack  = MathMax(12, (int)(maxW * 0.04));
   int panelW = maxW + PANEL_PAD * 2 + slack;
   int panelH = count * rowH + PANEL_PAD * 2;
   if(panelW < 300) panelW = 300;

   EnsureRect(PANEL_PREFIX + "BG", PANEL_X, PANEL_Y, panelW, panelH, CLR_BG, CLR_BORDER);

   int x0 = PANEL_X + PANEL_PAD;
   int y0 = PANEL_Y + PANEL_PAD;
   int idx = 0;

   for(int i = 0; i < count; i++)
   {
      int y = y0 + i * rowH;

      if(g_lineSegFrom[i] < 0)
      {
         string nm = PANEL_PREFIX + "T" + IntegerToString(idx);
         EnsureLabel(nm, x0, y, g_line[i], g_lineClr[i]);
         ApplyTip(nm, "");
         idx++;
         continue;
      }

      //  Several coloured pieces on one line: walk them left to right.
      int cx = x0;
      for(int s = 0; s < g_lineSegN[i]; s++)
      {
         int k = g_lineSegFrom[i] + s;
         string nm = PANEL_PREFIX + "T" + IntegerToString(idx);
         EnsureLabel(nm, cx, y, g_segText[k], g_segClr[k]);
         ApplyTip(nm, g_segTip[k]);
         idx++;
         cx += TextWidth(g_segText[k]);
      }
   }

   //  Remove labels left over from a taller or more colourful build.
   for(int i = idx; i < g_drawn; i++)
      ObjectDelete(0, PANEL_PREFIX + "T" + IntegerToString(i));

   g_drawn = idx;

   //  The side panel is placed from these, so they are kept.
   g_panelPx = panelW;
   g_panelPy = panelH;

   ChartRedraw();
}

void ClearPanel()
{
   ObjectsDeleteAll(0, PANEL_PREFIX);
   ObjectsDeleteAll(0, DIARY_PREFIX);
   g_drawn = 0;
   ChartRedraw();
}

//  The optional second panel.  Drawn only when the input is on, and
//  placed from the main panel's measured width, so the two can never
//  overlap.  If it would run past the right edge it moves below.
void DrawDiaryDetails()
{
   static bool hadDetails = false;

   if(!InpDiaryDetails)
   {
      //  Only sweep once, on the frame that actually finds it switched
      //  off.  This runs on every heartbeat.
      if(hadDetails)
      {
         ObjectsDeleteAll(0, DIARY_PREFIX);
         hadDetails = false;
      }
      return;
   }

   string lines[];
   color  clrs[];
   BuildDiaryDetails(lines, clrs);

   int count = ArraySize(lines);
   if(count <= 0)
   {
      ObjectsDeleteAll(0, DIARY_PREFIX);
      return;
   }

   TextSetFont(FONT_NAME, -FONT_SIZE * 10);

   int rowH = FONT_SIZE + ROW_EXTRA;
   int maxW = 0;
   for(int i = 0; i < count; i++)
   {
      int w = TextWidth(lines[i]);
      if(w > maxW) maxW = w;
   }

   int slack = MathMax(12, (int)(maxW * 0.04));
   int w = maxW + PANEL_PAD * 2 + slack;
   int h = count * rowH + PANEL_PAD * 2;
   if(w < 260) w = 260;

   int chartW = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   int x = PANEL_X + g_panelPx + DIARY_GAP;
   int y = PANEL_Y;

   if(chartW > 0 && x + w > chartW - 4)
   {
      x = PANEL_X;
      y = PANEL_Y + g_panelPy + DIARY_GAP;
   }

   EnsureRect(DIARY_PREFIX + "BG", x, y, w, h, CLR_BG, CLR_BORDER);

   int x0 = x + PANEL_PAD;
   int y0 = y + PANEL_PAD;

   for(int i = 0; i < count; i++)
   {
      string nm = DIARY_PREFIX + "T" + IntegerToString(i);
      EnsureLabel(nm, x0, y0 + i * rowH, lines[i], clrs[i]);
      ApplyTip(nm, "");
   }

   //  Remove labels left over from a taller build.
   for(int i = count; i < count + 64; i++)
   {
      string nm = DIARY_PREFIX + "T" + IntegerToString(i);
      if(ObjectFind(0, nm) < 0) break;
      ObjectDelete(0, nm);
   }

   hadDetails = true;
   ChartRedraw();
}

//==================================================================
//  LOG - a full dump, so discovery can be checked in Experts
//==================================================================
void DumpDiscovery()
{
   PrintFormat("Automate %s on %s %s", EA_STAGE, _Symbol,
               EnumToString((ENUM_TIMEFRAMES)Period()));
   PrintFormat("  description : %s", g_f.desc);
   PrintFormat("  path        : %s", g_f.path);
   PrintFormat("  calc mode   : %s   sector: %s   industry: %s",
               CalcModeText(g_f.calcMode), g_f.sector, g_f.industry);
   PrintFormat("  currencies  : %s / %s   account %s (%s)",
               g_f.baseCur, g_f.profitCur,
               AccountInfoString(ACCOUNT_CURRENCY), AccountModeText());
   PrintFormat("  contract    : digits %d  point %s  tick %s  tick value %.2f",
               g_f.digits, DoubleToString(g_f.point, g_f.digits),
               DoubleToString(g_f.tickSize, g_f.digits), g_f.tickValue);
   PrintFormat("  volume      : min %.2f  max %.2f  step %.2f",
               g_f.volMin, g_f.volMax, g_f.volStep);
   PrintFormat("  stops       : level %d pts  freeze %d pts",
               (int)g_f.stopsLevel, (int)g_f.freezeLevel);
   PrintFormat("  class       : %s (%s)%s", g_p.label, g_p.basis,
               g_p.unconfirmed ? "  [general profile used]" : "");
   PrintFormat("  configured  : warm-up %d bars, buffer %d ticks, spread gate %.2fx, session aware %s",
               g_p.warmupBars, g_p.bufferTicks, g_p.spreadGateX,
               g_p.sessionAware ? "yes" : "no");
   PrintFormat("  market      : %s - %s", g_m.headline, g_m.detail);

   MqlDateTime st;
   TimeToStruct(ServerNow(), st);

   datetime utcNow = 0;
   string   srcNote = "";
   bool utcKnown = ResolveUtc(ServerNow(), utcNow, srcNote);

   PrintFormat("  sessions    : %d entries in this week's table", g_sessCount);
   if(g_sessCount > 0)
   {
      PrintFormat("  today       : %s   (%d entries)", TodayWindows(st.day_of_week, 4),
                  CountSessionsForDay(st.day_of_week));
      PrintFormat("  weekdays    : %s", WeekdayList());
   }
   else
      PrintFormat("  today       : none - status falls back to quote freshness");

   string sessLine = "unknown (" + srcNote + ")";
   if(utcKnown) sessLine = SessionLabel(utcNow);
   PrintFormat("  session     : %s", sessLine);

   //  The measurements behind the self-configuration.  The panel shows
   //  the layout only, so these numbers are reported here where they
   //  can still be checked.
   int    sprN   = 0;
   double sprBase = SpreadBaseline(st.hour, sprN);
   int    m5Bars  = LaneBars(PERIOD_M5);

   PrintFormat("  warm-up     : %d bars required, M5 has %d (%s)",
               g_p.warmupBars, m5Bars, (m5Bars >= g_p.warmupBars ? "ready" : "DATA WAIT"));
   PrintFormat("  measured    : hour %d median %.1f pts (%d days), recent %.1f pts (%d bars)",
               st.hour,
               (g_f.point > 0.0 ? g_hourMove[st.hour] / g_f.point : 0.0),
               g_hourDays[st.hour],
               (g_f.point > 0.0 ? g_recentMove / g_f.point : 0.0),
               g_recentN);
   PrintFormat("  spread      : current %d pts, typical %.1f pts (%d samples), gate %.2fx",
               g_f.spreadPts, sprBase, sprN, g_p.spreadGateX);
   PrintFormat("  adjustment  : %s", g_p.note == "" ? "base profile" : g_p.note);
}

//==================================================================
//  CONFIGURATION FOR THIS HOUR
//==================================================================
void ApplyHourAdjustment()
{
   CopyProfile(g_base, g_p);           // start from what classification decided
   g_p.note = "";

   datetime now = ServerNow();
   MqlDateTime st;
   TimeToStruct(now, st);
   int hour = st.hour;
   if(hour < 0 || hour > 23) hour = 0;

   if(g_hourDays[hour] < 5 || g_hourMove[hour] <= 0.0 || g_recentMove <= 0.0)
   {
      g_p.note = (g_hourDays[hour] >= 5 ? "hour has no movement data"
                                        : "hour not learned yet - recent data only");
      return;
   }

   double ratio = g_hourMove[hour] / g_recentMove;

   if(ratio < 0.60)
   {
      //  Thin hour: price wanders less but spreads and gaps hurt more,
      //  so demand a little more room and a cleaner quote.
      g_p.bufferTicks += 2;
      g_p.spreadGateX *= 1.25;
      g_p.note = StringFormat("thin hour x%.2f -> +2 buffer ticks, gate %.2fx",
                              ratio, g_p.spreadGateX);
   }
   else if(ratio > 1.40)
   {
      //  Fast hour: movement is there, spreads widen with it.
      g_p.spreadGateX *= 1.10;
      g_p.note = StringFormat("fast hour x%.2f -> gate %.2fx", ratio, g_p.spreadGateX);
   }
   else
   {
      g_p.note = StringFormat("typical hour x%.2f -> base profile", ratio);
   }
}

//==================================================================
//  HEARTBEAT
//==================================================================
void Heartbeat()
{
   static ulong lastDraw = 0;

   datetime now = ServerNow();

   if(g_lastSessions == 0 || now - g_lastSessions >= SESSION_REFRESH_SEC)
   {
      ReadSessions();
      g_lastSessions = now;
   }

   if(g_lastProfile == 0 || now - g_lastProfile >= PROFILE_REFRESH_SEC)
   {
      BuildHourProfile();
      g_lastProfile = now;
   }

   UpdateQuote(g_f);
   SampleSpread();
   RefreshMarket();
   ApplyHourAdjustment();

   UpdateLanes();
   LogLanes();

   ulong ms = GetTickCount();
   if(lastDraw != 0 && (ms - lastDraw) < DRAW_MIN_MS) return;
   lastDraw = ms;

   BuildPanel();
   DrawPanel();
   DrawDiaryDetails();
}

//==================================================================
//  EVENT HANDLERS
//==================================================================
int OnInit()
{
   g_lastProfile  = 0;
   g_lastSessions = 0;
   g_lastSample   = 0;
   g_drawn        = 0;
   g_sessCount    = 0;

   ClearPanel();          // a re-init (symbol change) must not leave stale lines

   for(int h = 0; h < 24; h++)
   {
      g_sprN[h]     = 0;
      g_hourMove[h] = 0.0;
      g_hourDays[h] = 0;
   }

   //  Lanes and their run-length histories start empty, so the first
   //  bar of each timeframe is a clean first observation.
   g_ehAgree    = 0;
   g_ehDisagree = 0;
   ArrayInitialize(g_runHist, 0);
   for(int c = 0; c < RUN_CHANNELS; c++)
   {
      g_runCount[c] = 0;
      g_runNow[c]   = 0;
      g_runPrev[c]  = RUN_UNSET;
   }
   for(int i = 0; i < LANE_COUNT; i++)
   {
      g_tr[i].state  = TS_NONE;
      g_tr[i].dir    = 0;
      g_tr[i].entry  = 0.0;
      g_tr[i].sl     = 0.0;
      g_tr[i].tp     = 0.0;
      g_tr[i].lot    = 0.0;
      g_tr[i].ticket = 0;
      g_tr[i].until  = 0;
      g_tr[i].atTrend  = 0;
      g_tr[i].atSignal = 0;
      g_tr[i].note   = "";
   }
   for(int i = 0; i < LANE_COUNT; i++)
   {
      g_lane[i].ready      = false;
      g_lane[i].lastBar    = 0;
      g_lane[i].needBars   = 0;
      g_lane[i].haveBars   = 0;
      g_lane[i].trend      = 0;
      g_lane[i].regime     = 2;
      g_lane[i].score      = 0;
      g_lane[i].signal     = 0;
      g_lane[i].trendAge     = 0;
      g_lane[i].regimeAge    = 0;
      g_lane[i].trendLeft     = 0;
      g_lane[i].trendLeftPct  = 0;
      g_lane[i].trendLo       = 0;
      g_lane[i].trendHi       = 0;
      g_lane[i].regimeLeft    = 0;
      g_lane[i].regimeLeftPct = 0;
      g_lane[i].regimeLo      = 0;
      g_lane[i].regimeHi      = 0;
      g_lane[i].trendLeftOk  = false;
      g_lane[i].regimeLeftOk = false;
      g_lane[i].signalAge    = 0;
      g_lane[i].signalDuraPct = 0;
      g_lane[i].signalDuraOk  = false;
      g_lane[i].slopeRatio = 0.0;
      g_lane[i].zValue     = 0.0;
      g_lane[i].vMom       = 0;
      g_lane[i].vStr       = 0;
      g_lane[i].ehSign     = 0;
   }
   g_lane[0].tf = PERIOD_M5;   g_lane[0].name = "M5";
   g_lane[1].tf = PERIOD_M15;  g_lane[1].name = "M15";
   g_lane[2].tf = PERIOD_M30;  g_lane[2].name = "M30";

   DiscoverSymbol(g_f);
   ClassifySymbol(g_f, g_base);
   CopyProfile(g_base, g_p);

   ReadSessions();
   BuildHourProfile();
   RefreshMarket();
   ApplyHourAdjustment();

   //  The diary opens after the lanes are named, because its file
   //  name carries the symbol and its lines carry the lane names.
   DiaryOpen();

   UpdateLanes();
   LogLanes();

   BuildPanel();
   DrawPanel();
   DrawDiaryDetails();
   DumpDiscovery();

   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   DiaryClose();
   ClearPanel();
}

void OnTick()
{
   Heartbeat();
}

void OnTimer()
{
   Heartbeat();
}
//+------------------------------------------------------------------+
