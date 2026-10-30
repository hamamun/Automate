//+------------------------------------------------------------------+
//|  Automate.mq5                                                    |
//|                                                                  |
//|  STAGE 2 - self-discovery, market status and the signal engine.  |
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
//|      reports TREND, the age of that trend, REGIME, a three-vote  |
//|      SCORE and a SIGNAL.                                         |
//|                                                                  |
//|  What this build deliberately does NOT do yet:                   |
//|    * no entries, stops, targets, lot size, orders, no diary.     |
//|      The panel says SIGNAL ONLY so this can never be mistaken    |
//|      for a trading build. That is stage 3 and later.             |
//|                                                                  |
//|  There are NO user inputs. Everything above is discovered or     |
//|  measured; nothing needs to be typed in.                         |
//+------------------------------------------------------------------+
#property copyright "Automate"
#property version   "1.10"
#property description "Automate stage 2: self-discovery, automatic configuration, market and session status, trend / regime / score / signal per timeframe."
#property description "No inputs. Sends no orders. Attach to any chart and timeframe."

//==================================================================
//  INTERNAL CONSTANTS  (deliberately not inputs)
//==================================================================
#define EA_STAGE            "stage 2 - signal engine"
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
#define REGIME_HOURS        128     // equalised drift span, in hours
#define Z_STEADY            2.0     // regime boundary, standard deviations
#define Z_MIXED             1.0     // regime boundary, standard deviations
#define TREND_BAND_X        0.20    // trend deadband, in units of a typical bar
#define MOVE_BAND_X         0.50    // move deadband = X * med * sqrt(horizon)
#define MOVE_BAND_TICKS     1.00    // floor of the move deadband, in ticks
#define AGE_HISTORY         200     // completed runs kept per state
#define SEED_BARS           400     // closed bars replayed at attach so AGE
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
   int      trendMed;
   int      regimeAge;
   int      regimeMed;
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

int g_runHist[LANE_COUNT * 2 * AGE_HISTORY];
int g_runCount[LANE_COUNT * 2];
int g_runNow[LANE_COUNT * 2];
int g_runPrev[LANE_COUNT * 2];
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

int RunMedian(int ch)
{
   int cnt = g_runCount[ch];
   if(cnt <= 0) return(0);
   int base = ch * AGE_HISTORY;
   int tmp[];
   ArrayResize(tmp, cnt);
   for(int i = 0; i < cnt; i++) tmp[i] = g_runHist[base + i];
   ArraySort(tmp);
   return(tmp[cnt / 2]);
}

//  Replay the vote over closed bars that are already loaded, so the
//  median exists at attach instead of after a day.  This is not
//  look-ahead: every bar in the replay is finished, and the vote at
//  that bar uses only the bars before it - exactly the number the EA
//  would have printed had it been running.
void SeedRuns(int idx, const double &close[], int n, int span, double tick)
{
   int start = n - 1 - SEED_BARS;
   if(start < span) start = span;

   //  The last index is left to the live path, which tracks it next.
   for(int end = start; end < n - 1; end++)
   {
      double med = MedianAbsChange(close, end);
      if(med <= 0.0) med = tick;

      double ratio = RegressionSlope(close, end, TREND_PERIOD) / med;
      TrackState(idx * 2, TrendVoteFrom(ratio));
      TrackState(idx * 2 + 1, RegimeCodeOf(DriftZ(close, end, span)));
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

   if(g_runPrev[idx * 2] == RUN_UNSET)
      SeedRuns(idx, close, count, span, tick);

   TrackState(idx * 2,     g_lane[idx].trend);
   TrackState(idx * 2 + 1, g_lane[idx].regime);

   g_lane[idx].trendAge  = g_runNow[idx * 2];
   g_lane[idx].trendMed  = RunMedian(idx * 2);
   g_lane[idx].regimeAge = g_runNow[idx * 2 + 1];
   g_lane[idx].regimeMed = RunMedian(idx * 2 + 1);

   g_lane[idx].ready = true;
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

//  The AGE column is 7 characters wide.  "age/median" is shown when it
//  fits; on a very long run the median is dropped rather than letting
//  the text run into REGIME.
string AgeText(int age, int med)
{
   if(age < 0) age = 0;
   string a = IntegerToString(age);
   string m = (med <= 0 ? "-" : IntegerToString(med));

   if(StringLen(a) + 1 + StringLen(m) <= 7)
      return(a + "/" + m);

   //  Too wide: the age is the number that matters.
   if(StringLen(a) <= 7) return(a);
   return("LONG");
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
      PrintFormat("%s trend %s %d/%d, regime %s %d/%d, z=%.2f, slope ratio %.3f, votes %d %d %d, score %d, %s",
                  g_lane[i].name,
                  TrendText(g_lane[i].trend), g_lane[i].trendAge, g_lane[i].trendMed,
                  RegimeText(g_lane[i].regime), g_lane[i].regimeAge, g_lane[i].regimeMed,
                  g_lane[i].zValue, g_lane[i].slopeRatio,
                  g_lane[i].trend, g_lane[i].vMom, g_lane[i].vStr,
                  g_lane[i].score, SignalText(g_lane[i].signal));
   }

   int tot = g_ehAgree + g_ehDisagree;
   if(tot > 0)
      PrintFormat("Ehlers vs slope: %d agree, %d disagree (%.1f%% agree) over %d closed bars",
                  g_ehAgree, g_ehDisagree, 100.0 * (double)g_ehAgree / (double)tot, tot);
}

//==================================================================
//  PANEL
//==================================================================
//  The layout follows the interface sketch in automate.md section 7.
//  Fields whose data does not exist yet - trend, regime, score, signal,
//  trade status, the selected plan, exposure and the diary - are drawn
//  as labels with blank values.  The frame is the same from stage to
//  stage; only the values fill in as each stage is built.
//
//  A line is either plain or made of coloured segments, so the market
//  state can be red or green while the session and spread on the same
//  line stay silver.  Every drawn label is numbered continuously,
//  which makes removing surplus objects after a redraw trivial.
//==================================================================
#define COL_RIGHT 30            // where the right-hand column starts
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

void AddSegLine(string &texts[], color &clrs[])
{
   int nseg = ArraySize(texts);
   if(nseg <= 0) { AddLine("", CLR_TEXT); return; }

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
      g_segText[k] = texts[i];
      g_segClr[k]  = clrs[i];
   }
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
   string ageTxt    = "-";
   string regimeTxt = "-";
   string scoreTxt  = "-";
   string signalTxt = "-";
   string statusTxt = "DATA WAIT";

   color trendClr  = CLR_DIM;
   color signalClr = CLR_DIM;

   if(g_lane[idx].ready)
   {
      trendTxt  = TrendText(g_lane[idx].trend);
      ageTxt    = AgeText(g_lane[idx].trendAge, g_lane[idx].trendMed);
      regimeTxt = RegimeText(g_lane[idx].regime);
      scoreTxt  = ScoreText(g_lane[idx].score);
      signalTxt = SignalText(g_lane[idx].signal);
      statusTxt = "SIGNAL ONLY";
      trendClr  = TrendColour(g_lane[idx].trend);
      signalClr = SignalColour(g_lane[idx].signal);
   }

   string segT[7];
   color  segC[7];
   segT[0] = " " + Pad(tfTxt, 7);   segC[0] = CLR_TEXT;
   segT[1] = Pad(trendTxt, 7);      segC[1] = trendClr;
   segT[2] = Pad(ageTxt, 7);        segC[2] = CLR_DIM;
   segT[3] = Pad(regimeTxt, 9);     segC[3] = CLR_TEXT;
   segT[4] = Pad(scoreTxt, 7);      segC[4] = CLR_VALUE;
   segT[5] = Pad(signalTxt, 10);    segC[5] = signalClr;
   segT[6] = statusTxt;             segC[6] = CLR_DIM;
   AddSegLine(segT, segC);
}

//  Two columns at the exact positions used by the automate.md sketch:
//  left text at column 1, right text at column COL_RIGHT.
string TwoCol(string left, string right)
{
   return(" " + Pad(left, COL_RIGHT - 1) + right);
}

//  The timeframe table header: TF, TREND, AGE, REGIME, SCORE, SIGNAL,
//  TRADE STATUS at columns 1, 8, 15, 22, 31, 38 and 48.  SIGNAL is 10
//  wide because NO SIGNAL is 9 characters and needs one separating
//  space before TRADE STATUS.
string TableRow(string tf, string trend, string age, string regime,
                string score, string signal, string status)
{
   return(" " + Pad(tf, 7) + Pad(trend, 7) + Pad(age, 7) + Pad(regime, 9) +
          Pad(score, 7) + Pad(signal, 10) + status);
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
   AddLine(TableRow("TF", "TREND", "AGE", "REGIME", "SCORE", "SIGNAL",
                    "TRADE STATUS"), CLR_SECTION);
   for(int i = 0; i < LANE_COUNT; i++) LaneRow(i);
   AddLine("", CLR_TEXT);

   // ---------------------------------------------------------------
   //  Selected lane.  Blank until the plan stage exists.
   // ---------------------------------------------------------------
   AddLine(TwoCol("Selected:", "Entry:"), CLR_DIM);
   AddLine(TwoCol("SL:", "TP:"), CLR_DIM);
   AddLine(TwoCol("Entry timing:", "TP estimate:"), CLR_DIM);
   AddLine(TwoCol("Size:", "Planned risk:"), CLR_DIM);
   AddLine(TwoCol("Combined exposure:", ""), CLR_DIM);
   AddLine(TwoCol("Diary:", "Unknown future costs:"), CLR_DIM);
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
         EnsureLabel(PANEL_PREFIX + "T" + IntegerToString(idx), x0, y, g_line[i], g_lineClr[i]);
         idx++;
         continue;
      }

      //  Several coloured pieces on one line: walk them left to right.
      int cx = x0;
      for(int s = 0; s < g_lineSegN[i]; s++)
      {
         int k = g_lineSegFrom[i] + s;
         EnsureLabel(PANEL_PREFIX + "T" + IntegerToString(idx), cx, y, g_segText[k], g_segClr[k]);
         idx++;
         cx += TextWidth(g_segText[k]);
      }
   }

   //  Remove labels left over from a taller or more colourful build.
   for(int i = idx; i < g_drawn; i++)
      ObjectDelete(0, PANEL_PREFIX + "T" + IntegerToString(i));

   g_drawn = idx;
   ChartRedraw();
}

void ClearPanel()
{
   ObjectsDeleteAll(0, PANEL_PREFIX);
   g_drawn = 0;
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
   for(int c = 0; c < LANE_COUNT * 2; c++)
   {
      g_runCount[c] = 0;
      g_runNow[c]   = 0;
      g_runPrev[c]  = RUN_UNSET;
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
      g_lane[i].trendAge   = 0;
      g_lane[i].trendMed   = 0;
      g_lane[i].regimeAge  = 0;
      g_lane[i].regimeMed  = 0;
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

   UpdateLanes();
   LogLanes();

   BuildPanel();
   DrawPanel();
   DumpDiscovery();

   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
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
