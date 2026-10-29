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
TYPE = r'(?:string|int|double|long|ulong|bool|color|datetime|uint|float|char|short|uchar|ushort|SymbolFacts|AssetProfile|MarketState|SessionRec)'
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
TextSetFont TextGetSize""".split())
calls = set(re.findall(r'(\w+)\s*\(', s))
unknown = sorted(c for c in calls if c not in set(fnames) and c not in kw and c not in b)
chk("every call resolves", not unknown, str(unknown))

# struct field access
structs = {}
for m in re.finditer(r'struct\s+(\w+)\s*\{(.*?)\};', s, re.S):
    structs[m.group(1)] = set(re.findall(r'^\s*(?:const\s+)?(?:string|int|double|long|ulong|bool|color|datetime|ENUM_\w+)\s+(\w+)', m.group(2), re.M))
vs = {}
for m in re.finditer(r'\b(SymbolFacts|AssetProfile|MarketState|SessionRec|MqlTick|MqlDateTime)\s+(\w+)', s):
    vs.setdefault(m.group(2), m.group(1))
bad = [(v, f.group(1)) for v, t in vs.items() if t in structs
       for f in re.finditer(r'\b' + re.escape(v) + r'\.(\w+)', s) if f.group(1) not in structs[t]]
chk("struct fields valid", not bad, str(sorted(set(bad))))

chk("no input declarations", not re.search(r'^\s*input\s', s, re.M))

# dead code: a function defined but never called
dead = [f for f in set(fnames) if f not in ('OnInit','OnDeinit','OnTick','OnTimer')
        and len(re.findall(r'\b' + re.escape(f) + r'\s*\(', s)) <= 1]
chk("no unused functions", not dead, str(sorted(dead)))
chk("ascii only", all(ord(c) < 128 for c in src))

print(f"\nlines: {src.count(chr(10))+1} | functions: {len(fnames)} | file-scope vars: {len(decls)}")
print("RESULT:", "ALL PASSED" if not fails else f"{len(fails)} FAILURE(S): {fails}")
sys.exit(0 if not fails else 1)
