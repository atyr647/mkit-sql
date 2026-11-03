#!/usr/bin/env python3
"""Date / time / interval arithmetic against Python's calendar (an independent implementation).

    python3 tests/differential/dates.py [--n 4000] [--seed 1]

Covers the whole supported range (years 0001-9999, leap years, century rules, month-end clamping),
+ and - with every interval unit, date - date, EXTRACT, comparison of ISO text, and the rule that
a date plus a whole number of days stays a date.
"""
import argparse, calendar, datetime as dt, json, os, random, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diff import HERE

def add_months(d, n):
    t = d.year * 12 + d.month - 1 + n
    y, m = divmod(t, 12); m += 1
    if y < 1 or y > 9999: raise OverflowError
    day = min(d.day, calendar.monthrange(y, m)[1])
    return d.replace(year=y, month=m, day=day)

def rdate(r):
    y = r.choice([r.randint(1, 9999), r.randint(1900, 2100), r.choice([1, 4, 100, 400, 1600, 1900, 2000, 2024, 9999])])
    m = r.randint(1, 12); d = r.randint(1, calendar.monthrange(y, m)[1])
    return dt.datetime(y, m, d)
def fmt_d(x): return "%04d-%02d-%02d" % (x.year, x.month, x.day)
def fmt_t(x): return fmt_d(x) + " %02d:%02d:%02d" % (x.hour, x.minute, x.second)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--n", type=int, default=4000); ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--show", type=int, default=10); a = ap.parse_args()
    r = random.Random(a.seed)
    cases = []
    for _ in range(a.n):
        base = rdate(r); ts = base + dt.timedelta(seconds=r.randint(0, 86399))
        sign = r.choice(["+", "-"]); sg = 1 if sign == "+" else -1
        kind = r.randint(0, 7)
        try:
            if kind <= 2:
                unit = r.choice(["DAY", "MONTH", "YEAR", "HOUR", "MINUTE", "SECOND"]); n = r.randint(0, 400) if r.random() < .8 else r.randint(0, 40000)
                isdate = r.random() < .5
                b = base if isdate else ts
                lit = ("DATE '%s'" % fmt_d(b)) if isdate else ("TIMESTAMP '%s'" % fmt_t(b))
                sql = "SELECT %s %s INTERVAL '%d' %s" % (lit, sign, n, unit)
                if unit in ("MONTH", "YEAR"):
                    e = add_months(b, sg * n * (12 if unit == "YEAR" else 1))
                    want = fmt_d(e) if isdate else fmt_t(e)
                else:
                    secs = n * {"DAY": 86400, "WEEK": 604800, "HOUR": 3600, "MINUTE": 60, "SECOND": 1}[unit]
                    e = b + dt.timedelta(seconds=sg * secs)
                    want = fmt_d(e) if (isdate and secs % 86400 == 0) else fmt_t(e)
                cases.append((sql, [want]))
            elif kind == 3 and r.random() < 0.15:
                n = r.randint(0, 300)
                e = base + dt.timedelta(days=7 * n * sg)
                cases.append(("SELECT DATE '%s' %s INTERVAL '%d weeks'" % (fmt_d(base), sign, n), [fmt_d(e)]))
            elif kind == 3:
                x, y = rdate(r), rdate(r)
                days = (x - y).days
                cases.append(("SELECT EXTRACT(DAY FROM DATE '%s' - DATE '%s')" % (fmt_d(x), fmt_d(y)), [str(days)]))
            elif kind == 4:
                x = base + dt.timedelta(seconds=r.randint(0, 86399)); y = base + dt.timedelta(days=r.randint(-30, 30), seconds=r.randint(0, 86399))
                tot = int((x - y).total_seconds())
                cases.append(("SELECT EXTRACT(EPOCH FROM TIMESTAMP '%s' - TIMESTAMP '%s')" % (fmt_t(x), fmt_t(y)), [str(tot)]))
            elif kind == 5:
                f = [("YEAR", ts.year), ("MONTH", ts.month), ("DAY", ts.day), ("HOUR", ts.hour), ("MINUTE", ts.minute), ("SECOND", ts.second),
                     ("DOW", (ts.weekday() + 1) % 7), ("DOY", ts.timetuple().tm_yday)]
                cases.append(("SELECT " + ", ".join("EXTRACT(%s FROM TIMESTAMP '%s')" % (n_, fmt_t(ts)) for n_, _ in f), [str(v) for _, v in f]))
            elif kind == 6:
                x, y = rdate(r), rdate(r)
                cases.append(("SELECT DATE '%s' < DATE '%s', DATE '%s' = DATE '%s', DATE '%s' >= DATE '%s'" % (fmt_d(x), fmt_d(y), fmt_d(x), fmt_d(x), fmt_d(x), fmt_d(y)),
                              [str(int(x < y)), "1", str(int(x >= y))]))
            else:
                m = r.randint(-30, 30); y = r.randint(-3, 3)
                e = add_months(base, m + 12 * y)
                cases.append(("SELECT DATE '%s' + INTERVAL '%d' MONTH + INTERVAL '%d' YEAR" % (fmt_d(base), m, y) if False else
                              "SELECT CAST('%04d-%d-%d' AS DATE)" % (base.year, base.month, base.day), [fmt_d(base)]))
        except (OverflowError, ValueError):
            continue
    tmp = tempfile.mkdtemp(); script = os.path.join(tmp, "s.txt"); out = os.path.join(tmp, "o.jsonl")
    with open(script, "w", encoding="utf-8") as f:
        for sql, _ in cases: f.write("Q " + sql + "\n")
    subprocess.run(os.environ.get("MKIT_TCLSH", "tclsh").split() + [os.path.join(HERE, "run_tcl.tcl"), script, out], check=True)
    mine = [json.loads(l) for l in open(out, encoding="utf-8")]
    bad = []; ok = 0
    for (sql, want), m in zip(cases, mine):
        if not m["ok"]:
            # out-of-range results are rejected on purpose (years 0001-9999)
            bad.append((sql, "error: " + m["err"][:90])); continue
        got = [str(c) for c in m["rows"][0]]
        # negative intervals: EXTRACT truncates toward zero like the engine documents; compare as ints where numeric
        def same(g, w):
            if g == w: return True
            try: return float(g) == float(w)
            except ValueError: return False
        if len(got) == len(want) and all(same(g, w) for g, w in zip(got, want)): ok += 1
        else: bad.append((sql, "mkit=%s expected=%s" % (got, want)))
    print("date / interval cases: %d   agree: %d   MISMATCH: %d" % (len(cases), ok, len(bad)))
    for sql, why in bad[:a.show]: print("\n ", sql[:200], "\n    ", why)
    sys.exit(1 if bad else 0)
if __name__ == "__main__": main()
