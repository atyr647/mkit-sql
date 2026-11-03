#!/usr/bin/env python3
"""Differential test: run generated SQL through mkit-sql and SQLite, compare results.

    python3 tests/differential/diff.py [--n 3000] [--seed 1] [--show 20] [--file queries.sql]

Both engines get identical data (no NULLs are stored: Metakit cannot).  Queries that either
engine rejects are reported separately; only result mismatches count as failures.
"""
import argparse, json, math, os, random, sqlite3, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- data
def make_setup(rng):
    words = ["alpha", "Beta", "gamma", "Delta", "", "echo", "alpha", "ZULU", "x y", "foxtrot", "a%b", "under_score"]
    stmts = [
        "CREATE TABLE t1 (id INT, g INT, x DOUBLE PRECISION, s VARCHAR(30))",
        "CREATE TABLE t2 (id INT, t1id INT, v INT, tag VARCHAR(30))",
    ]
    t1, t2 = [], []
    for i in range(1, 41):
        t1.append((i, rng.randint(1, 6), rng.choice([0.5, 1.25, 2.5, 3.0, -1.5, 7.75, 10.0, 0.1, -0.5, 100.0, 6.5]), rng.choice(words)))
    for i in range(1, 61):
        t2.append((i, rng.randint(1, 45), rng.randint(-5, 20), rng.choice(words)))
    def lit(v):
        return "'" + v.replace("'", "''") + "'" if isinstance(v, str) else repr(v)
    for r in t1: stmts.append("INSERT INTO t1 VALUES (%s)" % ", ".join(lit(v) for v in r))
    for r in t2: stmts.append("INSERT INTO t2 VALUES (%s)" % ", ".join(lit(v) for v in r))
    return stmts, t1, t2

# ---------------------------------------------------------------- query generator
class Gen:
    def __init__(self, rng, kind="basic"): self.r = rng; self.kind = kind
    def pick(self, *a): return self.r.choice(a)

    def intx(self, d=0):
        r = self.r
        if d > 2 or r.random() < 0.4:
            return r.choice(["id", "g", "LENGTH(s)", str(r.randint(-3, 12))])
        k = r.randint(0, 4)
        if k <= 1: return "(%s %s %s)" % (self.intx(d + 1), r.choice("+-*"), self.intx(d + 1))
        if k == 2: return "(%s / %d)" % (self.intx(d + 1), r.choice([2, 3, -2, 5]))
        if k == 3: return "(%s %% %d)" % (self.intx(d + 1), r.choice([2, 3, 7]))
        return "ABS(%s)" % self.intx(d + 1)

    def num(self, d=0, cols=("id", "g", "x")):
        r = self.r
        if d > 2 or r.random() < 0.35:
            return r.choice(list(cols) + [str(r.randint(-3, 12)), "%.2f" % r.choice([0.5, 1.5, 2.25, 3.75])])
        k = r.randint(0, 9)
        a = self.num(d + 1, cols)
        if k <= 2: return "(%s %s %s)" % (a, r.choice("+-*"), self.num(d + 1, cols))
        if k == 3: return "ABS(%s)" % a
        if k == 4: return "(CAST(%s AS REAL) / %d)" % (a, r.choice([2, 3, 4, -2, 5]))
        if k == 5: return "(%s %% %d)" % (self.intx(d + 1), r.choice([2, 3, 7]))
        if k == 6: return "CASE WHEN %s THEN %s ELSE %s END" % (self.cond(d + 1, cols), a, self.num(d + 1, cols))
        if k == 7: return "COALESCE(NULLIF(%s, %s), %s)" % (a, self.num(d + 1, cols), self.num(d + 1, cols))
        if k == 8: return "ROUND(%s)" % a if r.random() < .5 else "ROUND(%s, %d)" % (a, r.choice([1, 2]))
        return "LENGTH(%s)" % self.text(d + 1)

    def text(self, d=0, col="s"):
        r = self.r
        if d > 2 or r.random() < 0.4:
            return r.choice([col, col, "'alpha'", "'Beta'", "''", "'%s'" % r.choice(["a", "x y"])])
        k = r.randint(0, 6)
        a = self.text(d + 1, col)
        if k == 0: return "(%s || %s)" % (a, self.text(d + 1, col))
        if k == 1: return "UPPER(%s)" % a
        if k == 2: return "LOWER(%s)" % a
        if k == 3: return "SUBSTR(%s, %d, %d)" % (a, r.randint(1, 3), r.randint(0, 4))
        if k == 4: return "TRIM(%s)" % a
        if k == 5: return "REPLACE(%s, '%s', '%s')" % (a, r.choice("al"), r.choice(["", "Q", "zz"]))
        return "(%s || CAST(%s AS TEXT))" % (a, self.intx(d + 1))

    def cond(self, d=0, cols=("id", "g", "x")):
        r = self.r
        k = r.randint(0, 11)
        if d > 2: k = r.randint(0, 5)
        if k <= 1: return "%s %s %s" % (self.num(d + 1, cols), r.choice(["=", "<>", "<", "<=", ">", ">="]), self.num(d + 1, cols))
        if k == 2: return "%s %s %s" % (self.text(d + 1), r.choice(["=", "<>", "<", ">="]), self.text(d + 1))
        if k == 3: return "%s %sLIKE '%s'" % (self.text(d + 1), r.choice(["", "NOT "]), r.choice(["a%", "%a", "%l%", "_eta", "a\\%b", "%", "x _", "%e_"]))
        if k == 4: return "%s %sIN (%s)" % (self.num(d + 1, cols), r.choice(["", "NOT "]), ", ".join(str(r.randint(-2, 8)) for _ in range(r.randint(1, 4))))
        if k == 5: return "%s %sBETWEEN %s AND %s" % (self.num(d + 1, cols), r.choice(["", "NOT "]), r.randint(-2, 3), r.randint(3, 9))
        if k == 6: return "(%s AND %s)" % (self.cond(d + 1, cols), self.cond(d + 1, cols))
        if k == 7: return "(%s OR %s)" % (self.cond(d + 1, cols), self.cond(d + 1, cols))
        if k == 8: return "NOT (%s)" % self.cond(d + 1, cols)
        if k == 9: return "%s IS %sNULL" % (self.num(d + 1, cols), r.choice(["", "NOT "]))
        if k == 10: return "EXISTS (SELECT 1 FROM t2 WHERE t2.t1id = t1.id AND t2.v %s %d)" % (r.choice([">", "<", "="]), r.randint(-2, 15))
        return "t1.id %sIN (SELECT t1id FROM t2 WHERE v %s %d)" % (r.choice(["", "NOT "]), r.choice([">", "<", ">="]), r.randint(0, 12))

    def agg(self, tbl="t1"):
        r = self.r
        c = r.choice(["x", "id", "g"]) if tbl == "t1" else r.choice(["v", "id", "t1id"])
        k = r.randint(0, 7)
        if k == 0: return "COUNT(*)"
        if k == 1: return "COUNT(%s)" % c
        if k == 2: return "COUNT(DISTINCT %s)" % c
        if k == 3: return "SUM(%s)" % c
        if k == 4: return "AVG(%s)" % c
        if k == 5: return "MIN(%s)" % c
        if k == 6: return "MAX(%s)" % c
        return "SUM(%s * 2)" % c

    def frame(self, ordcol):
        r = self.r
        mode = r.choice(["ROWS", "ROWS", "GROUPS", "RANGE"])
        def b(kind):
            if mode == "RANGE" and ordcol not in ("id", "x", "g"):
                return r.choice(["UNBOUNDED %s" % kind, "CURRENT ROW"])
            return r.choice(["UNBOUNDED %s" % kind, "CURRENT ROW", "%d %s" % (r.randint(0, 3), kind)])
        a, z = b("PRECEDING"), b("FOLLOWING")
        if a.startswith("UNBOUNDED F") or a.startswith("CURRENT") and False: a = "CURRENT ROW"
        # keep start <= end
        if z.endswith("PRECEDING"): z = "CURRENT ROW"
        if a.endswith("FOLLOWING"): a = "CURRENT ROW"
        if a == "CURRENT ROW" and z.endswith("PRECEDING"): z = "CURRENT ROW"
        return "%s BETWEEN %s AND %s" % (mode, a, z)

    def winspec(self):
        r = self.r
        part = r.choice(["", "PARTITION BY g", "PARTITION BY g % 2", "PARTITION BY s"])
        ordcol = r.choice(["id", "x", "g", "s", "id DESC", "x DESC"])
        order = "ORDER BY %s" % ordcol + ("" if ordcol == "id" or ordcol == "id DESC" else ", id")
        return part, ordcol.split()[0], order

    def window_query(self):
        r = self.r
        part, oc, order = self.winspec()
        base = (part + " " + order).strip()
        k = r.randint(0, 9)
        if k == 0:
            fn = r.choice(["ROW_NUMBER()", "RANK()", "DENSE_RANK()", "PERCENT_RANK()", "CUME_DIST()", "NTILE(%d)" % r.randint(1, 7)])
            o = "ORDER BY %s" % oc if fn != "ROW_NUMBER()" and fn[:5] != "NTILE" else order
            return "SELECT id, %s OVER (%s %s) FROM t1 ORDER BY id" % (fn, part, o)
        if k == 1:
            fn = r.choice(["LAG", "LEAD"])
            args = r.choice(["x", "id", "s", "x, 2", "id, 1, -1", "s, 2, 'none'"])
            return "SELECT id, %s(%s) OVER (%s) FROM t1 ORDER BY id" % (fn, args, base)
        if k == 2:
            fn = r.choice(["FIRST_VALUE", "LAST_VALUE"])
            fr = (" " + self.frame(oc)) if r.random() < .6 else ""
            return "SELECT id, %s(%s) OVER (%s%s) FROM t1 ORDER BY id" % (fn, r.choice(["x", "id", "s"]), base, fr)
        if k == 3:
            fr = (" " + self.frame(oc)) if r.random() < .6 else ""
            return "SELECT id, NTH_VALUE(%s, %d) OVER (%s%s) FROM t1 ORDER BY id" % (r.choice(["x", "s"]), r.randint(1, 4), base, fr)
        if k <= 6:
            agg = r.choice(["SUM(x)", "SUM(id)", "AVG(x)", "MIN(x)", "MAX(s)", "COUNT(*)", "COUNT(x)", "MIN(s)", "MAX(id)"])
            fr = (" " + self.frame(oc)) if r.random() < .7 else ""
            return "SELECT id, %s OVER (%s%s) FROM t1%s ORDER BY id" % (agg, base, fr, (" WHERE " + self.cond()) if r.random() < .3 else "")
        if k == 7:
            return "SELECT id, SUM(id) OVER w, COUNT(*) OVER (w ROWS BETWEEN 1 PRECEDING AND CURRENT ROW) FROM t1 WINDOW w AS (%s) ORDER BY id" % base
        if k == 8:
            return "SELECT g, SUM(x), RANK() OVER (ORDER BY SUM(x) DESC), SUM(SUM(x)) OVER (ORDER BY g), COUNT(*) OVER () FROM t1 GROUP BY g ORDER BY g"
        return "SELECT id, ROW_NUMBER() OVER (%s), SUM(x) OVER (PARTITION BY g), ROW_NUMBER() OVER (ORDER BY id DESC) FROM t1 WHERE x > 0 ORDER BY id" % base

    def query(self):
        r = self.r
        if self.kind == "window": return self.window_query()
        k = r.randint(0, 12)
        W = lambda: (" WHERE " + self.cond()) if r.random() < .7 else ""
        if k <= 2:
            n = r.randint(1, 3)
            items = [self.num() if r.random() < .6 else self.text() for _ in range(n)]
            ords = ", ".join(str(i + 1) for i in range(n))
            return "SELECT %s FROM t1%s ORDER BY %s%s" % (", ".join(items), W(), ords, (" LIMIT %d" % r.randint(1, 8)) if r.random() < .3 else "")
        if k == 3:
            return "SELECT DISTINCT %s FROM t1%s ORDER BY 1" % (r.choice(["g", "s", "g % 2", "LENGTH(s)", "x > 1"]), W())
        if k <= 5:
            a = [self.agg() for _ in range(r.randint(1, 3))]
            hv = (" HAVING %s %s %d" % (self.agg(), r.choice([">", "<", ">="]), r.randint(0, 5))) if r.random() < .4 else ""
            key = r.choice(["g", "s", "g % 3", "LENGTH(s)"])
            return "SELECT %s, %s FROM t1%s GROUP BY %s%s ORDER BY 1" % (key, ", ".join(a), W(), key, hv)
        if k == 6:
            return "SELECT %s FROM t1%s" % (", ".join(self.agg() for _ in range(r.randint(1, 4))), W())
        if k <= 8:
            jt = r.choice(["JOIN", "LEFT JOIN", "JOIN", "LEFT JOIN"])
            on = "t1.id = t2.t1id" + ((" AND t2.v %s %d" % (r.choice([">", "<"]), r.randint(0, 10))) if r.random() < .4 else "")
            if r.random() < .5:
                items = ["t1.id", "t2.id", r.choice(["t2.v", "t1.x", "t2.tag", "t1.s || t2.tag"])]
                return "SELECT %s FROM t1 %s t2 ON %s%s ORDER BY 1, 2" % (", ".join(items), jt, on, (" WHERE " + r.choice(["t2.v > 3", "t1.g = 2", "t2.id IS NULL", "t1.x > 1"])) if r.random() < .6 else "")
            return "SELECT t1.g, COUNT(t2.id), SUM(t2.v) FROM t1 %s t2 ON %s GROUP BY t1.g ORDER BY 1" % (jt, on)
        if k == 9:
            return "SELECT id, (SELECT COUNT(*) FROM t2 WHERE t2.t1id = t1.id), (SELECT MAX(v) FROM t2 WHERE t2.t1id = t1.id) FROM t1%s ORDER BY 1" % W()
        if k == 10:
            op = r.choice(["UNION", "UNION ALL", "INTERSECT", "EXCEPT"])
            return "SELECT g FROM t1 WHERE %s %s SELECT v FROM t2 WHERE %s ORDER BY 1" % (self.cond(), op, "v " + r.choice([">", "<"]) + " %d" % r.randint(0, 10))
        if k == 11:
            return "SELECT g, id FROM t1 WHERE x > (SELECT AVG(x) FROM t1 a WHERE a.g = t1.g) ORDER BY 1, 2"
        return "SELECT t.g, t.n FROM (SELECT g, COUNT(*) AS n FROM t1 GROUP BY g) t WHERE t.n %s %d ORDER BY 1" % (r.choice([">", "<="]), r.randint(3, 8))

# ---------------------------------------------------------------- running + comparing
def norm(v):
    if v is None: return None
    if isinstance(v, (int, float)):
        f = float(v)
        if f != f: return "nan"
        return round(f, 9) if abs(f) < 1e12 else f
    try:
        f = float(v)
        if v.strip() == v and v != "" and not v.lower() in ("nan", "inf", "-inf", "infinity"):
            return round(f, 9) if abs(f) < 1e12 else f
    except ValueError:
        pass
    return v

def normrows(rows, ordered):
    out = [tuple(norm(c) for c in r) for r in rows]
    return out if ordered else sorted(out, key=lambda t: [(c is None, str(c)) for c in t])

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=3000); ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--show", type=int, default=15); ap.add_argument("--file"); ap.add_argument("--kind", default="basic")
    ap.add_argument("--setup-only-sqlite", action="store_true")
    a = ap.parse_args()
    rng = random.Random(a.seed)
    setup, t1, t2 = make_setup(rng)
    if a.file:
        queries = [l.strip() for l in open(a.file, encoding="utf-8") if l.strip() and not l.startswith("--")]
    else:
        g = Gen(rng, a.kind); seen = set(); queries = []
        while len(queries) < a.n:
            q = g.query()
            if q not in seen: seen.add(q); queries.append(q)
    tmp = tempfile.mkdtemp()
    script = os.path.join(tmp, "script.txt"); out = os.path.join(tmp, "out.jsonl")
    with open(script, "w", encoding="utf-8") as f:
        for s in setup: f.write("S " + s + "\n")
        for q in queries: f.write("Q " + q.replace("\n", " ") + "\n")
    # MKIT_TCLSH picks the Tcl runtime (e.g. "tclkit/tclkit-8.6.3"); default is the system tclsh
    tclsh = os.environ.get("MKIT_TCLSH", "tclsh").split()
    subprocess.run(tclsh + [os.path.join(HERE, "run_tcl.tcl"), script, out], check=True)
    mine = [json.loads(l) for l in open(out, encoding="utf-8")]
    assert len(mine) == len(queries), (len(mine), len(queries))
    con = sqlite3.connect(":memory:")
    con.execute("PRAGMA case_sensitive_like=ON")
    for s in setup:
        con.execute(s.replace("DOUBLE PRECISION", "REAL").replace("VARCHAR(30)", "TEXT"))
    ok = bad = both = 0; mism = []; rej_mine = []; rej_sql = []
    for q, m in zip(queries, mine):
        try:
            sres = con.execute(q).fetchall(); serr = None
        except Exception as e:
            sres = None; serr = str(e)
        if not m["ok"] and serr is not None: both += 1; continue          # both reject
        if not m["ok"]: rej_mine.append((q, m["err"])); continue
        if serr is not None: rej_sql.append((q, serr)); continue
        ordered = "ORDER BY" in q.upper()
        x, y = normrows(m["rows"], ordered), normrows(sres, ordered)
        if x == y: ok += 1
        else: bad += 1; mism.append((q, x[:6], y[:6], len(x), len(y)))
    print("queries: %d   agree: %d (+%d rejected by both)   MISMATCH: %d   rejected only by mkit-sql: %d   rejected only by SQLite: %d" % (len(queries), ok, both, bad, len(rej_mine), len(rej_sql)))
    for q, x, y, nx, ny in mism[:a.show]:
        print("\nMISMATCH:", q); print("   mkit-sql (%d rows): %s" % (nx, x)); print("   sqlite   (%d rows): %s" % (ny, y))
    for q, e in rej_mine[:a.show]:
        print("\nREJECTED by mkit-sql:", q); print("   ", e)
    sys.exit(1 if bad else 0)

if __name__ == "__main__": main()
