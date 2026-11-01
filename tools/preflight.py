#!/usr/bin/env python3
"""Preflight checks for Automate.mq5 - catches the classes of error that
MQL5 reports at compile time but a plain brace count does not."""
import re, sys, collections

path = sys.argv[1] if len(sys.argv) > 1 else 'Automate.mq5'
src = open(path, encoding='utf-8').read()

def strip(c):
    c = re.sub(r'/\*.*?\*/', '', c, flags=re.S)
    c = re.sub(r'//[^\n]*', '', c)
    c = re.sub(r'"(\\.|[^"\\])*"', '""', c)
    c = re.sub(r"'(\\.|[^'\\])*'", "''", c)
    return c

s = strip(src)
fails = []
def chk(label, cond, extra=""):
    if not cond: fails.append(label)
    print(("PASS  " if cond else "FAIL  ") + label + (("   " + extra) if extra else ""))

for o, c in [('{','}'), ('(',')'), ('[',']')]:
    chk(f"balanced {o}{c}", s.count(o) == s.count(c), f"{s.count(o)}/{s.count(c)}")

# duplicate file-scope declarations
TYPE = r'(?:string|int|double|long|ulong|bool|color|datetime|uint|float|char|short|uchar|ushort|SymbolFacts|AssetProfile|MarketState|SessionRec|LaneState)'
depth, decls = 0, collections.defaultdict(list)
for ln, raw in enumerate(s.split('\n'), start=1):
    st = raw.strip()
    if depth == 0 and st and not st.startswith('#'):
        m = re.match(r'^' + TYPE + r'\s+(\w+)\s*(\[.*?\])?\s*(=|;)', st)
        if m: decls[m.group(1)].append(ln)
    depth += raw.count('{') - raw.count('}')
dups = {k: v for k, v in decls.items() if len(v) > 1}
chk("no duplicate file-scope declarations", not dups,
    "; ".join(f"{k} at {v}" for k, v in dups.items()))

# duplicate functions
defs = re.findall(r'^\s*(?:static\s+)?(?:void|int|bool|double|string|long|ulong|datetime|color|uint|float)\s+(\w+)\s*\(([^)]*)\)', s, re.M)
fnames = [d[0] for d in defs]
chk("no duplicate functions", len(fnames) == len(set(fnames)),
    str({n for n in fnames if fnames.count(n) > 1}))

# every call resolves
kw = {'if','for','while','switch','return','sizeof','else','case','do'}
b = set("""Print PrintFormat StringFormat StringLen StringFind StringSplit StringSubstr StringToUpper
IntegerToString DoubleToString TimeToString TimeToStruct StructToTime TimeCurrent TimeTradeServer TimeGMT
MathAbs MathRound MathCeil MathMin MathMax MathIsValidNumber ArrayResize ArraySize ArrayCopy ArraySort
ArraySetAsSeries CopyRates Bars SymbolInfoString SymbolInfoInteger SymbolInfoDouble SymbolInfoTick
SymbolInfoSessionTrade SymbolIsSynchronized ObjectsDeleteAll ObjectCreate ObjectDelete ObjectFind
ObjectGetString ObjectSetString ObjectSetInteger ChartRedraw ChartGetInteger EventSetTimer EventKillTimer
GetTickCount AccountInfoInteger AccountInfoString TerminalInfoInteger MQLInfoInteger Period EnumToString
TextSetFont TextGetSize MathSqrt MathCos MathExp MathFloor MathPow
ArrayInitialize PeriodSeconds iTime CopyClose CopyHigh CopyLow ArrayCopy
FileOpen FileClose FileReadString FileWriteString FileFlush FileIsEnding FileSeek
FileDelete GetLastError StringReplace StringGetCharacter StringToInteger StringToDouble
StringToTime StringTrimRight
OrderSend OrderSelect OrderGetTicket OrdersTotal OrderGetDouble OrderGetInteger OrderCalcMargin
HistorySelectByPosition HistoryDealsTotal HistoryDealGetTicket HistoryDealGetDouble
PositionSelectByTicket PositionGetString OrderGetString AccountInfoDouble
PositionGetDouble PositionGetInteger PositionGetTicket PositionsTotal ZeroMemory NormalizeDouble
CopyRates""".split())
calls = set(re.findall(r'(\w+)\s*\(', s))
unknown = sorted(c for c in calls if c not in set(fnames) and c not in kw and c not in b)
chk("every call resolves", not unknown, str(unknown))

# struct field access
structs = {}
for m in re.finditer(r'struct\s+(\w+)\s*\{(.*?)\};', s, re.S):
    structs[m.group(1)] = set(re.findall(r'^\s*(?:const\s+)?(?:string|int|double|long|ulong|bool|color|datetime|ENUM_\w+)\s+(\w+)', m.group(2), re.M))
vs = {}
for m in re.finditer(r'\b(SymbolFacts|AssetProfile|MarketState|SessionRec|LaneState|MqlTick|MqlDateTime'
                     r'|DiaryTotals|DiaryCalib|DiaryPending|DiaryResult)\s+(\w+)', s):
    vs.setdefault(m.group(2), m.group(1))
bad = [(v, f.group(1)) for v, t in vs.items() if t in structs
       for f in re.finditer(r'\b' + re.escape(v) + r'\.(\w+)', s) if f.group(1) not in structs[t]]
chk("struct fields valid", not bad, str(sorted(set(bad))))

# inputs: the rule is no PER-ITEM inputs (autotrade.md 2.1).  Only the
# switches the owner asked for by name may exist.  The autotrading block
# was asked for with defaults of true; the three older switches default
# to false so that leaving them alone is never wrong.
want_inputs = ["bool InpAutoTrade = true", "bool InpAllowM5 = true",
               "bool InpAllowM15 = true", "bool InpAllowM30 = true",
               "bool InpTrailStop = true",
               "bool InpDiaryDetails = false", "bool InpTweakArm = false",
               "bool InpMinLot = false"]
have_inputs = [re.sub(r'\s+', ' ', m.group(1)).strip()
               for m in re.finditer(r'^\s*input\s+([^;]+);', s, re.M)]
chk("only the sanctioned inputs", have_inputs == want_inputs, str(have_inputs))

# every #define must actually be used, or it is dead weight in a file
# that claims each constant has a job
defined = re.findall(r'^#define\s+(\w+)', src, re.M)
# the #define line itself is one occurrence, so a live constant scores >= 2
unused = sorted(d for d in defined if len(re.findall(r'\b' + d + r'\b', s)) < 2)
chk("no unused #defines", not unused, str(unused))

# dead code: a function defined but never called
dead = [f for f in set(fnames) if f not in ('OnInit','OnDeinit','OnTick','OnTimer')
        and len(re.findall(r'\b' + re.escape(f) + r'\s*\(', s)) <= 1]
chk("no unused functions", not dead, str(sorted(dead)))
chk("ascii only", all(ord(c) < 128 for c in src))

# Cross-chart guard.  PositionsTotal() and OrdersTotal() return the whole
# terminal; the magic number is the same on every chart.  A scan of either
# list that does not also compare the symbol will adopt another chart's
# trade.  Every such loop has to filter, and every request that acts on a
# ticket has to check the symbol first.
raw_lines = src.split('\n')
bad_scans = []
for ln, line in enumerate(raw_lines):
    if 'PositionsTotal()' in line and 'for(' in line.replace(' ', ''):
        window = '\n'.join(raw_lines[ln:ln + 8])
        if 'POSITION_SYMBOL' not in window:
            bad_scans.append(f"position scan at line {ln + 1} has no symbol filter")
    if 'OrdersTotal()' in line and 'for(' in line.replace(' ', ''):
        window = '\n'.join(raw_lines[ln:ln + 8])
        if 'ORDER_SYMBOL' not in window:
            bad_scans.append(f"order scan at line {ln + 1} has no symbol filter")
chk("terminal scans filter by symbol", not bad_scans, str(bad_scans))

# The once-a-second path manages a resting limit and nothing else: it may
# cancel, but it must never send or reprice, and it must never look at an
# open position.  This is the promise the panel and the docs make.
def body(fn):
    i = src.find(fn + '(')
    if i < 0:
        return ''
    j = src.find('{', i)
    if j < 0:
        return ''
    depth, k = 0, j
    while k < len(src):
        if src[k] == '{':
            depth += 1
        elif src[k] == '}':
            depth -= 1
            if depth == 0:
                return src[j:k + 1]
        k += 1
    return ''

sec = body('void ManageRestingLimit')
bad_sec = [w for w in ('TradeSend', 'TradeModify', 'TS_OPEN') if w in sec]
chk("the once-a-second path only cancels limits", not bad_sec,
    "found: " + str(bad_sec) if bad_sec else "")

# MQL5 has no hoisting for variables: a global read above its declaration
# is a compile error, and the message points at the use, not the cause.
# Only names starting with g_ and every #define are checked - those are the
# ones a function can be moved above by accident.
lines_no_comment = []
for raw in src.split('\n'):
    ln = raw.split('//')[0]
    ln = re.sub(r'"(\\.|[^"\\])*"', '""', ln)
    lines_no_comment.append(ln)

def first_use_line(name):
    pat = re.compile(r'\b' + re.escape(name) + r'\b')
    for i, ln in enumerate(lines_no_comment, start=1):
        if pat.search(ln):
            return i
    return 0

early = []
for i, ln in enumerate(lines_no_comment, start=1):
    st = ln.strip()
    if st.startswith('#'):
        continue
    m = re.match(r'^(?:' + TYPE + r'|\w+)\s+(g_\w+)\s*(?:\[.*?\])?\s*(?:=|;)', st)
    if not m:
        continue
    use = first_use_line(m.group(1))
    if use and use < i:
        early.append(f"{m.group(1)} used at line {use}, declared at {i}")
for i, ln in enumerate(lines_no_comment, start=1):
    m = re.match(r'^\s*#define\s+(\w+)', ln)
    if not m:
        continue
    use = first_use_line(m.group(1))
    if use and use < i:
        early.append(f"{m.group(1)} used at line {use}, defined at {i}")
chk("no global used before it is declared", not early, str(early))

print(f"\nlines: {src.count(chr(10))+1} | functions: {len(fnames)} | file-scope vars: {len(decls)}")
print("RESULT:", "ALL PASSED" if not fails else f"{len(fails)} FAILURE(S): {fails}")
sys.exit(0 if not fails else 1)
