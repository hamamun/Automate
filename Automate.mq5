//+------------------------------------------------------------------+
//|  Automate.mq5                                                    |
//|                                                                  |
//|  STAGE 1 - self-discovery and market status only.                |
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
//|      established honestly.                                       |
//|                                                                  |
//|  What this build deliberately does NOT do yet:                   |
//|    * no signals, no orders, no positions, no diary.              |
//|      That is the next stage and is not in this file.             |
//|                                                                  |
//|  There are NO user inputs. Everything above is discovered or     |
//|  measured; nothing needs to be typed in.                         |
//+------------------------------------------------------------------+
#property copyright "Automate"
#property version   "1.00"
#property description "Automate stage 1: self-discovery, automatic configuration, market and session status."
#property description "No inputs. Sends no orders. Attach to any chart and timeframe."

//==================================================================
//  INTERNAL CONSTANTS  (deliberately not inputs)
//==================================================================
#define EA_STAGE            "stage 1 - discovery only"
#define PANEL_PREFIX        "AUT_"
#define PANEL_X             10
#define PANEL_Y             20
#define PANEL_PAD           10
#define FONT_NAME           "Consolas"
#define FONT_SIZE           10
#define LINE_EXTRA          4
#define LABEL_W             13
#define MAX_SESSIONS        64
#define SPREAD_SAMPLES      240
#define HOUR_MAX_VALUES     256

#define PROFILE_REFRESH_SEC 600     // rebuild the hour profile every 10 min
#define SESSION_REFRESH_SEC 300     // re-read the broker session table
#define SPREAD_SAMPLE_SEC   5       // spread sampling interval
#define STALE_MINUTES       5.0     // a quote older than this is stale
#define DRAW_MIN_MS         250     // never repaint faster than this

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

//==================================================================
//  GLOBAL STATE
//==================================================================
SymbolFacts  g_f;
AssetProfile g_base;   // what classification decided, untouched
AssetProfile g_p;      // g_base plus this hour's adjustment
MarketState  g_m;

string g_line[];       // panel text, one entry per drawn line
color  g_lineClr[];    // colour per drawn line
int    g_drawn = 0;    // lines currently on the chart

SessionRec g_sess[MAX_SESSIONS];
int        g_sessCount = 0;

double g_hourMove[24];   // median |close-to-close| per server hour
int    g_hourDays[24];   // distinct days observed for that hour
double g_recentMove = 0; // median |close-to-close| of recent bars
int    g_recentN    = 0;

double g_spr[24][SPREAD_SAMPLES];  // running spread samples per hour
int    g_sprN[24];

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
      ev[A_FOREX] += "currencies;";
   }
   if(EqualsAny(bas, METAL_CODE))  { sc[A_METAL]  += 4; ev[A_METAL]  += "base ccy, "; }
   if(EqualsAny(bas, CRYPTO_CODE)) { sc[A_CRYPTO] += 4; ev[A_CRYPTO] += "base ccy, "; }

   // ---- calculation mode ----
   if(f.calcMode == (int)SYMBOL_CALC_MODE_FOREX ||
      f.calcMode == (int)SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)
   {
      sc[A_FOREX] += 2;
      ev[A_FOREX] += "calc mode;";
      sc[A_METAL] += 1;                       // metals are usually Forex-calculated
   }
   if(f.calcMode == (int)SYMBOL_CALC_MODE_CFDINDEX)
   {
      sc[A_INDEX] += 3;
      ev[A_INDEX] += "calc mode, ";
   }
   if(f.calcMode == (int)SYMBOL_CALC_MODE_EXCH_STOCKS)
   {
      sc[A_STOCK] += 3;
      ev[A_STOCK] += "calc mode, ";
   }
   if(f.calcMode == (int)SYMBOL_CALC_MODE_FUTURES)
   {
      sc[A_ENERGY] += 1;
   }

   // ---- description and exchange metadata ----
   if(HasToken(dsc, "GOLD|SILVER|PLATINUM|PALLADIUM"))  { sc[A_METAL]  += 3; ev[A_METAL]  += "description, "; }
   if(HasToken(dsc, "BITCOIN|ETHEREUM|CRYPTO|DOGECOIN")){ sc[A_CRYPTO] += 3; ev[A_CRYPTO] += "description, "; }
   if(HasToken(dsc, "CRUDE|BRENT|NATURAL GAS|WTI|OIL")) { sc[A_ENERGY] += 3; ev[A_ENERGY] += "description, "; }
   if(HasToken(dsc, "INDEX|INDICES"))                   { sc[A_INDEX]  += 2; ev[A_INDEX]  += "description, "; }
   if(HasToken(dsc, " VS "))                            { sc[A_FOREX]  += 1; ev[A_FOREX]  += "description, "; }
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
string TodayWindows(int dow, int maxShown)
{
   string s = "";
   int shown = 0;

   for(int i = 0; i < g_sessCount; i++)
   {
      if(g_sess[i].dow != dow) continue;
      if(shown >= maxShown) { s += ", ..."; break; }

      long e = (long)g_sess[i].startSec + (long)g_sess[i].durSec;
      s += (shown > 0 ? ", " : "");
      s += Hhmm(g_sess[i].startSec) + "-" + Hhmm(e);
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

   if(off == 0)     srcNote = "server UTC+0 (est.)";
   else if(off < 0) srcNote = StringFormat("server UTC-%d:%02d (est.)", (int)oh, (int)om);
   else             srcNote = StringFormat("server UTC+%d:%02d (est.)", (int)oh, (int)om);

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

string SessionClockLine(datetime utcNow)
{
   int lonOff = EuSummerTime(utcNow) ? 3600 : 0;
   int nyOff  = UsSummerTime(utcNow) ? -4 * 3600 : -5 * 3600;

   long tokyoSec = ((long)utcNow + 9 * 3600) % 86400;
   long lonSec   = ((long)utcNow + lonOff) % 86400;
   long nySec    = ((long)utcNow + nyOff) % 86400;

   return("Tokyo " + Hhmm(tokyoSec) + "  London " + Hhmm(lonSec) + "  NY " + Hhmm(nySec));
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
//  PANEL - built from lines, sized to fit them
//==================================================================
void ResetLines()
{
   ArrayResize(g_line, 0);
   ArrayResize(g_lineClr, 0);
}

void AddLine(string text, color clr)
{
   int n = ArraySize(g_line);
   ArrayResize(g_line, n + 1);
   ArrayResize(g_lineClr, n + 1);
   g_line[n]    = text;
   g_lineClr[n] = clr;
}

void SectionTitle(string text)
{
   string t = " " + text + " ";
   int want = 40;
   if(StringLen(t) < want) t += Spaces(want - StringLen(t));
   AddLine(t, CLR_SECTION);
}

int LaneBars(ENUM_TIMEFRAMES tf)
{
   return(Bars(_Symbol, tf));
}

void BuildPanel()
{
   ResetLines();

   datetime serverNow = ServerNow();
   MqlDateTime st;
   TimeToStruct(serverNow, st);

   int hour = st.hour;
   if(hour < 0 || hour > 23) hour = 0;

   // ---------------- header ----------------
   AddLine(" AUTOMATE   " + EA_STAGE + "   -   no orders", CLR_TITLE);
   AddLine("", CLR_TEXT);

   string head = " " + Pad(g_f.name, 14) + " " + Pad(g_p.label, 20) +
                 Pad(AccountModeText(), 10) +
                 StringFormat("spread %.1f pts",
                              (g_f.point > 0.0 ? g_f.spreadPrice / g_f.point : 0.0));
   AddLine(head, CLR_VALUE);
   AddLine("", CLR_TEXT);

   // ---------------- market ----------------
   AddLine(" " + g_m.headline, g_m.clr);
   AddLine(" " + g_m.detail, CLR_TEXT);

   if(g_m.code == MS_CLOSED)
      AddLine(" Nothing to do while the market is closed.", CLR_DIM);
   if(g_m.modeNote != "")
      AddLine(L("Broker", g_m.modeNote), CLR_HOLD);

   datetime utcNow = 0;
   string   srcNote = "";
   bool utcKnown = ResolveUtc(serverNow, utcNow, srcNote);

   if(utcKnown)
   {
      AddLine(L("Session", SessionLabel(utcNow) + "   (est.)"), CLR_TEXT);
      AddLine(L("Cities", SessionClockLine(utcNow)), CLR_DIM);
   }
   else
   {
      AddLine(L("Session", "unknown - " + srcNote), CLR_DIM);
   }

   AddLine(L("Server", TimeToString(serverNow, TIME_DATE | TIME_MINUTES) + "  " +
                      WeekdayShort(serverNow) +
                      (utcKnown ? ("   |   UTC " + TimeToString(utcNow, TIME_MINUTES)) : "")),
           CLR_DIM);
   AddLine("", CLR_TEXT);

   // ---------------- discovery ----------------
   SectionTitle("DISCOVERED");

   AddLine(L("Description", g_f.desc == "" ? "-" : g_f.desc), CLR_TEXT);
   AddLine(L("Path", g_f.path == "" ? "-" : g_f.path), CLR_TEXT);
   AddLine(L("Calc mode", CalcModeText(g_f.calcMode) +
                          "   |   sector: " + (g_f.sector == "" ? "-" : g_f.sector)), CLR_TEXT);

   AddLine(L("Currencies", (g_f.baseCur == "" ? "-" : g_f.baseCur) + " / " +
                           (g_f.profitCur == "" ? "-" : g_f.profitCur) +
                           "   account " + AccountInfoString(ACCOUNT_CURRENCY)), CLR_TEXT);

   AddLine(L("Price", DoubleToString(g_f.bid, g_f.digits) + " / " +
                      DoubleToString(g_f.ask, g_f.digits) +
                      "   digits " + IntegerToString(g_f.digits)), CLR_TEXT);

   AddLine(L("Tick", DoubleToString(g_f.tickSize, g_f.digits) +
                      "   value " + DoubleToString(g_f.tickValue, 2) + " " +
                      AccountInfoString(ACCOUNT_CURRENCY)), CLR_TEXT);

   AddLine(L("Volume", DoubleToString(g_f.volMin, 2) + " - " +
                      DoubleToString(g_f.volMax, 2) +
                      "   step " + DoubleToString(g_f.volStep, 2) +
                      "   stops " + IntegerToString(g_f.stopsLevel) + " pts"), CLR_TEXT);

   AddLine(L("Data", (g_f.synced ? "synced" : "NOT synced") +
                      StringFormat("   M5 %d  M15 %d  M30 %d bars",
                                   LaneBars(PERIOD_M5),
                                   LaneBars(PERIOD_M15),
                                   LaneBars(PERIOD_M30))),
           (g_f.synced ? CLR_TEXT : CLR_HOLD));
   AddLine("", CLR_TEXT);

   // ---------------- self-configuration ----------------
   SectionTitle("AUTO CONFIG");

   AddLine(L("Class", g_p.label + "   (" + g_p.basis + ")"),
           (g_p.unconfirmed ? CLR_HOLD : CLR_VALUE));

   int m5 = LaneBars(PERIOD_M5);
   bool warmOk = (m5 >= g_p.warmupBars);
   AddLine(L("Warm-up", IntegerToString(g_p.warmupBars) + " bars   " +
                        (warmOk ? "ready" : "DATA WAIT")),
           (warmOk ? CLR_TEXT : CLR_HOLD));

   AddLine(L("Stop buffer", IntegerToString(g_p.bufferTicks) + " ticks beyond a swing"), CLR_TEXT);

   int sprN = 0;
   double spreadBase = SpreadBaseline(hour, sprN);
   string gate = StringFormat("%.1f x typical", g_p.spreadGateX);
   if(spreadBase > 0.0)
      gate += StringFormat("   typical %.1f pts (%d samples)", spreadBase, sprN);
   else
      gate += "   typical: sampling...";
   AddLine(L("Spread gate", gate), CLR_TEXT);

   string hourTxt;
   if(g_hourDays[hour] > 0 && g_hourMove[hour] > 0.0 && g_f.point > 0.0)
      hourTxt = StringFormat("%.1f pts (%d days)", g_hourMove[hour] / g_f.point, g_hourDays[hour]);
   else
      hourTxt = "not measured yet";

   string recentTxt = "n/a";
   if(g_recentMove > 0.0 && g_f.point > 0.0)
      recentTxt = StringFormat("%.1f pts (%d bars)", g_recentMove / g_f.point, g_recentN);

   AddLine(L("Hour " + IntegerToString(hour), hourTxt + "   recent " + recentTxt), CLR_TEXT);
   AddLine(L("Adjust", g_p.note == "" ? "base profile" : g_p.note), CLR_DIM);
   AddLine("", CLR_TEXT);

   // ---------------- broker sessions ----------------
   SectionTitle("BROKER SESSIONS");

   AddLine(L("Published", (g_sessCount > 0
                           ? IntegerToString(g_sessCount) + " entries / week, " +
                             IntegerToString(CountSessionsForDay(st.day_of_week)) + " today"
                           : "none - status falls back to quotes")), CLR_TEXT);

   if(g_sessCount > 0)
   {
      AddLine(L("Today", TodayWindows(st.day_of_week, 2)), CLR_TEXT);
      AddLine(L("Days", WeekdayList()), CLR_DIM);
   }

   AddLine("", CLR_TEXT);
   AddLine(" No signals, no orders, no positions in this build.", CLR_DIM);
   AddLine(" Algo trading permission is irrelevant here.", CLR_DIM);
}

int MeasureWidth(string s)
{
   uint w = 0, h = 0;
   int measured = 0;

   if(TextGetSize(s, w, h) && w > 0) measured = (int)w;

   //  Monospace estimate as a safety floor so text is never clipped on
   //  a scaled (high-DPI) chart where measurement can come back small.
   int est = (int)(StringLen(s) * FONT_SIZE * 0.80);

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

void EnsureLabel(string name, int x, int y, string text, color clr)
{
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
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, FONT_SIZE);
   }

   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);

   if(ObjectGetString(0, name, OBJPROP_TEXT) != text)
      ObjectSetString(0, name, OBJPROP_TEXT, text);
}

void DrawPanel()
{
   TextSetFont(FONT_NAME, -FONT_SIZE * 10);

   int count = ArraySize(g_line);
   if(count <= 0) return;

   //  Width and height come from the text actually present, so the
   //  panel is never a fixed box: it grows and shrinks by itself.
   int maxW = 0;
   for(int i = 0; i < count; i++)
   {
      int w = MeasureWidth(g_line[i]);
      if(w > maxW) maxW = w;
   }

   uint tw = 0, th = 0;
   int lineH = FONT_SIZE * 2 + LINE_EXTRA;
   if(TextGetSize("Ag", tw, th) && th > 0) lineH = (int)th + LINE_EXTRA;

   int panelW = maxW + PANEL_PAD * 2;
   int panelH = count * lineH + PANEL_PAD * 2;
   if(panelW < 300) panelW = 300;

   EnsureRect(PANEL_PREFIX + "BG", PANEL_X, PANEL_Y, panelW, panelH, CLR_BG, CLR_BORDER);

   int x = PANEL_X + PANEL_PAD;
   int y = PANEL_Y + PANEL_PAD;

   for(int i = 0; i < count; i++)
   {
      string name = PANEL_PREFIX + "L" + IntegerToString(i);
      EnsureLabel(name, x, y + i * lineH, g_line[i], g_lineClr[i]);
   }

   //  Remove labels left over from a taller previous build.
   for(int i = count; i < g_drawn; i++)
      ObjectDelete(0, PANEL_PREFIX + "L" + IntegerToString(i));

   g_drawn = count;
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
   PrintFormat("  sessions    : %d entries in this week's table", g_sessCount);
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

   DiscoverSymbol(g_f);
   ClassifySymbol(g_f, g_base);
   CopyProfile(g_base, g_p);

   ReadSessions();
   BuildHourProfile();
   RefreshMarket();
   ApplyHourAdjustment();

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
