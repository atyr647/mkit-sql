#!/usr/bin/env python3
"""Features SQLite cannot be the oracle for (or only partly): checked against SQLite where it has an equivalent
formulation, and otherwise against a small independent model written in Python.

    python3 tests/differential/features.py [--seed 1] [--n 150] [--only cte,lateral,merge,alter,subview,schema]

  cte      WITH RECURSIVE (counting, string building, Fibonacci, graph reachability / depth with UNION and UNION ALL,
           aggregates over a recursive table)                                     vs SQLite
  lateral  CROSS / LEFT JOIN LATERAL (top-k per parent, aggregate per parent)     vs SQLite (window / scalar subquery rewrite)
  merge    MERGE with WHEN [NOT] MATCHED [AND ..] UPDATE / DELETE / INSERT, double-match error      vs a Python model
  alter    ADD / DROP / RENAME COLUMN, ALTER COLUMN TYPE, RENAME TO (Metakit semantics: new columns hold 0 / '',
           renamed or retyped columns move to the end)                            vs a Python model
  subview  nested tables: INSERT / UPDATE / DELETE through t[i].sub, unnesting joins, parent deletes     vs a Python model
  schema   information_schema.tables / columns                                    vs a Python model
"""
import argparse, json, os, random, sqlite3, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diff import norm, HERE

def lit(v): return "'" + v.replace("'", "''") + "'" if isinstance(v, str) else repr(v)

class Run:
    """one mkit-sql process for a whole batch of statements; each statement answers {ok, rows|err, affected}"""
    def __init__(self): self.lines = []
    def add(self, sql, kind="Q"): self.lines.append((kind, sql)); return len(self.lines) - 1
    def go(self):
        tmp = tempfile.mkdtemp(); script = os.path.join(tmp, "s.txt"); out = os.path.join(tmp, "o.jsonl")
        with open(script, "w", encoding="utf-8") as f:
            for k, s in self.lines: f.write(k + " " + s.replace("\n", " ") + "\n")
        subprocess.run(os.environ.get("MKIT_TCLSH", "tclsh").split() + [os.path.join(HERE, "run_tcl.tcl"), script, out], check=True)
        res = [json.loads(l) for l in open(out, encoding="utf-8")]
        qs = [i for i, (k, _) in enumerate(self.lines) if k == "Q"]
        return {i: r for i, r in zip(qs, res)}

def rows_of(r): return [tuple(norm(c) for c in row) for row in r["rows"]] if r["ok"] else None

class Report:
    def __init__(self): self.ok = 0; self.bad = []; self.both = 0
    def cmp(self, label, got, want):
        if got == want: self.ok += 1
        else: self.bad.append((label, got, want))

# ------------------------------------------------------------------------------------------------ recursive CTEs
def feat_cte(rng, n, rep):
    r = Run(); edges = sorted({(rng.randint(1, 12), rng.randint(1, 12)) for _ in range(30)})
    setup = ["CREATE TABLE edges (a INT, b INT)"] + ["INSERT INTO edges VALUES (%d, %d)" % e for e in edges]
    for s in setup: r.add(s, "S")
    qs = []
    for _ in range(n):
        k = rng.randint(0, 6)
        if k == 0:
            a, b, st = rng.randint(-5, 10), rng.randint(0, 40), rng.randint(1, 5)
            qs.append("WITH RECURSIVE c(n) AS (SELECT %d UNION ALL SELECT n + %d FROM c WHERE n < %d) SELECT n, n * n FROM c ORDER BY n" % (a, st, b))
        elif k == 1:
            qs.append("WITH RECURSIVE r(n, s) AS (SELECT 1, 'a' UNION ALL SELECT n + 1, s || 'b' FROM r WHERE n < %d) SELECT n, s, LENGTH(s) FROM r ORDER BY n" % rng.randint(1, 25))
        elif k == 2:
            qs.append("WITH RECURSIVE f(a, b, i) AS (SELECT 0, 1, 0 UNION ALL SELECT b, a + b, i + 1 FROM f WHERE i < %d) SELECT i, a FROM f ORDER BY i" % rng.randint(1, 40))
        elif k == 3:
            s = rng.randint(1, 12)
            qs.append("WITH RECURSIVE reach(x) AS (SELECT %d UNION SELECT e.b FROM edges e JOIN reach r ON e.a = r.x) SELECT x FROM reach ORDER BY x" % s)
        elif k == 4:
            s = rng.randint(1, 12)
            qs.append("WITH RECURSIVE p(x, d) AS (SELECT %d, 0 UNION ALL SELECT e.b, d + 1 FROM edges e JOIN p ON e.a = p.x WHERE d < %d) SELECT x, d FROM p ORDER BY d, x" % (s, rng.randint(1, 4)))
        elif k == 5:
            qs.append("WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM c WHERE n < %d) SELECT COUNT(*), SUM(n), MAX(n * n), MIN(n) FROM c WHERE n %% %d = %d" % (rng.randint(1, 60), rng.randint(2, 5), rng.randint(0, 1)))
        else:
            s = rng.randint(1, 12)
            qs.append("WITH RECURSIVE reach(x, d) AS (SELECT %d, 0 UNION SELECT e.b, d + 1 FROM edges e JOIN reach r ON e.a = r.x WHERE d < 3) SELECT x, MIN(d) FROM reach GROUP BY x ORDER BY x" % s)
    ids = [r.add(q) for q in qs]
    res = r.go()
    con = sqlite3.connect(":memory:")
    for s in setup: con.execute(s)
    for i, q in zip(ids, qs):
        try: want = [tuple(norm(c) for c in row) for row in con.execute(q).fetchall()]
        except Exception as e: want = None
        got = rows_of(res[i])
        if want is None and got is None: rep.both += 1
        else: rep.cmp(q, got, want)

# ------------------------------------------------------------------------------------------------ LATERAL
def feat_lateral(rng, n, rep):
    r = Run()
    parents = [(i, rng.randint(1, 4)) for i in range(1, 15)]
    children = [(i, rng.randint(1, 18), rng.randint(-5, 20)) for i in range(1, 70)]
    setup = ["CREATE TABLE parent (id INT, g INT)", "CREATE TABLE child (id INT, pid INT, v INT)"] \
        + ["INSERT INTO parent VALUES (%d, %d)" % p for p in parents] + ["INSERT INTO child VALUES (%d, %d, %d)" % c for c in children]
    for s in setup: r.add(s, "S")
    pairs = []
    for _ in range(n):
        k = rng.randint(0, 3); kk = rng.randint(1, 4); thr = rng.randint(-3, 15); g = rng.randint(1, 4)
        rank = "(SELECT pid, id, v, ROW_NUMBER() OVER (PARTITION BY pid ORDER BY v DESC, id) AS rn FROM child WHERE v > %d)" % thr
        if k == 0:
            m = "SELECT p.id, l.id, l.v FROM parent p CROSS JOIN LATERAL (SELECT c.id, c.v FROM child c WHERE c.pid = p.id AND c.v > %d ORDER BY c.v DESC, c.id LIMIT %d) l ORDER BY p.id, l.id" % (thr, kk)
            s = "SELECT p.id, x.id, x.v FROM parent p JOIN %s x ON x.pid = p.id AND x.rn <= %d ORDER BY p.id, x.id" % (rank, kk)
        elif k == 1:
            m = "SELECT p.id, l.id, l.v FROM parent p LEFT JOIN LATERAL (SELECT c.id, c.v FROM child c WHERE c.pid = p.id AND c.v > %d ORDER BY c.v DESC, c.id LIMIT %d) l ON TRUE WHERE p.g = %d ORDER BY p.id, l.id" % (thr, kk, g)
            s = "SELECT p.id, x.id, x.v FROM parent p LEFT JOIN %s x ON x.pid = p.id AND x.rn <= %d WHERE p.g = %d ORDER BY p.id, x.id" % (rank, kk, g)
        elif k == 2:
            m = "SELECT p.id, l.n, l.m, l.s FROM parent p LEFT JOIN LATERAL (SELECT COUNT(*) AS n, MAX(c.v) AS m, SUM(c.v) AS s FROM child c WHERE c.pid = p.id AND c.v > %d) l ON TRUE ORDER BY p.id" % thr
            s = "SELECT p.id, (SELECT COUNT(*) FROM child c WHERE c.pid = p.id AND c.v > %d), (SELECT MAX(c.v) FROM child c WHERE c.pid = p.id AND c.v > %d), (SELECT SUM(c.v) FROM child c WHERE c.pid = p.id AND c.v > %d) FROM parent p ORDER BY p.id" % (thr, thr, thr)
        else:
            m = "SELECT p.id, l.v FROM parent p CROSS JOIN LATERAL (SELECT c.v + p.g AS v FROM child c WHERE c.pid = p.id ORDER BY c.id LIMIT %d) l WHERE l.v > %d ORDER BY p.id, l.v" % (kk, thr)
            s = "SELECT p.id, x.v + p.g FROM parent p JOIN (SELECT pid, v, ROW_NUMBER() OVER (PARTITION BY pid ORDER BY id) AS rn FROM child) x ON x.pid = p.id AND x.rn <= %d WHERE x.v + p.g > %d ORDER BY p.id, x.v + p.g" % (kk, thr)
        pairs.append((r.add(m), m, s))
    res = r.go()
    con = sqlite3.connect(":memory:")
    for s in setup: con.execute(s)
    for i, m, s in pairs:
        want = [tuple(norm(c) for c in row) for row in con.execute(s).fetchall()]
        rep.cmp(m, rows_of(res[i]), want)

# ------------------------------------------------------------------------------------------------ MERGE
def feat_merge(rng, n, rep):
    for round_ in range(n):
        r = Run()
        tgt = {}
        for i in rng.sample(range(1, 25), rng.randint(3, 12)): tgt[i] = [rng.randint(-5, 20), rng.choice(["a", "b", "c"])]
        src = [(rng.randint(1, 30), rng.randint(-5, 20)) for _ in range(rng.randint(1, 10))]
        if rng.random() < 0.6:       # mostly unique source ids, so the statement usually succeeds
            seen = set(); src = [s for s in src if not (s[0] in seen or seen.add(s[0]))]
        r.add("CREATE TABLE mt (id INT, v INT, s TEXT)", "S"); r.add("CREATE TABLE ms (id INT, v INT)", "S")
        for k, (v, s) in tgt.items(): r.add("INSERT INTO mt VALUES (%d, %d, %s)" % (k, v, lit(s)), "S")
        for k, v in src: r.add("INSERT INTO ms VALUES (%d, %d)" % (k, v), "S")
        r.add("COMMIT", "S")
        clauses = []
        conds = [(None, lambda t, s: True, ""), (" AND s.v > %d" % rng.randint(0, 10), None, ""), (" AND t.v %% 2 = 0", None, "")]
        c1 = rng.choice([("", lambda t, s: True), (" AND s.v > 5", lambda t, s: s[1] > 5), (" AND t.v % 2 = 0", lambda t, s: t[0] % 2 == 0), (" AND s.v < t.v", lambda t, s: s[1] < t[0])])
        a1 = rng.choice(["DELETE", "UPDATE SET v = t.v + s.v", "UPDATE SET v = s.v, s = 'u'"])
        c2 = rng.choice([("", lambda t, s: True), (" AND s.v > 8", lambda t, s: s[1] > 8)])
        a2 = rng.choice([None, "DELETE", "UPDATE SET v = t.v - 1"])
        c3 = rng.choice([("", lambda t, s: True), (" AND s.v > 3", lambda t, s: s[1] > 3)])
        a3 = rng.choice([None, "INSERT (id, v, s) VALUES (s.id, s.v, 'new')", "INSERT (id, v, s) VALUES (s.id, s.v * 2, 'x')"])
        sql = "MERGE INTO mt t USING ms s ON t.id = s.id WHEN MATCHED%s THEN %s" % (c1[0], a1)
        if a2: sql += " WHEN MATCHED%s THEN %s" % (c2[0], a2)
        if a3: sql += " WHEN NOT MATCHED%s THEN %s" % (c3[0], a3)
        mi = r.add(sql); di = r.add("SELECT id, v, s FROM mt ORDER BY id, v, s")
        res = r.go()
        # the model
        def act(a, t, s):
            if a == "DELETE": return ("del",)
            if a.startswith("UPDATE SET v = t.v + s.v"): return ("upd", [t[0] + s[1], t[1]])
            if a.startswith("UPDATE SET v = s.v"): return ("upd", [s[1], "u"])
            if a == "UPDATE SET v = t.v - 1": return ("upd", [t[0] - 1, t[1]])
        newt = {k: list(v) for k, v in tgt.items()} ; touched = {} ; inserts = [] ; err = False ; dels = set()
        for sid, sv in src:
            if sid in tgt:
                t = tgt[sid]
                cl = [(c1[1], a1)] + ([(c2[1], a2)] if a2 else [])
                for cond, a in cl:
                    if cond(t, (sid, sv)):
                        if sid in touched: err = True
                        touched[sid] = 1
                        r_ = act(a, t, (sid, sv))
                        if r_[0] == "del": dels.add(sid)
                        else: newt[sid] = r_[1]
                        break
            elif a3 and c3[1](None, (sid, sv)):
                inserts.append((sid, [sv if "* 2" not in a3 else sv * 2, "new" if "'new'" in a3 else "x"]))
        if err:
            rep.cmp("merge double match must fail: " + sql, (res[mi]["ok"], rows_of(res[di])), (False, sorted([(k, v[0], v[1]) for k, v in tgt.items()])))
            continue
        final = {k: v for k, v in newt.items() if k not in dels}
        rowsm = sorted([(k, v[0], v[1]) for k, v in final.items()] + [(k, v[0], v[1]) for k, v in inserts])
        rep.cmp("merge: " + sql + " | tgt=%s src=%s" % (tgt, src), (res[mi]["ok"], rows_of(res[di])), (True, rowsm))

# ------------------------------------------------------------------------------------------------ ALTER
def feat_alter(rng, n, rep):
    for round_ in range(n):
        r = Run()
        cols = [("id", "INT"), ("name", "TEXT"), ("qty", "INT")]
        data = [[i, "n%d" % i, rng.randint(0, 50)] for i in range(1, rng.randint(3, 9))]
        r.add("CREATE TABLE at1 (id INT, name TEXT, qty INT)", "S")
        for d in data: r.add("INSERT INTO at1 VALUES (%d, %s, %d)" % (d[0], lit(d[1]), d[2]), "S")
        r.add("COMMIT", "S")
        steps = []
        spare = ["c%d" % i for i in range(1, 9)]
        tname = "at1"
        expect = []     # per step: (dump query index, schema query index, model state snapshot)
        for _ in range(rng.randint(2, 6)):
            op = rng.choice(["add", "add", "drop", "rename", "rename", "table"])
            names = [c[0] for c in cols]
            if op == "add" and spare:
                nm = spare.pop(0); ty = rng.choice(["INT", "TEXT"])
                sql = "ALTER TABLE %s ADD COLUMN %s %s" % (tname, nm, ty)
                cols.append((nm, ty)) ; [d.append(0 if ty == "INT" else "") for d in data]
            elif op == "drop" and len(cols) > 1:
                i = rng.randrange(len(cols)); sql = "ALTER TABLE %s DROP COLUMN %s" % (tname, cols[i][0])
                del cols[i] ; [d.pop(i) for d in data]
            elif op == "rename" and spare:
                i = rng.randrange(len(cols)); nm = spare.pop(0)
                sql = "ALTER TABLE %s RENAME COLUMN %s TO %s" % (tname, cols[i][0], nm)
                c = cols.pop(i); cols.append((nm, c[1])); [d.append(d.pop(i)) for d in data]
            elif op == "retype":
                i = rng.randrange(len(cols)); nt = "TEXT" if cols[i][1] == "INT" else "INT"
                if nt == "INT":
                    if not all(isinstance(d[i], int) or (isinstance(d[i], str) and d[i].lstrip("-").isdigit()) for d in data): continue
                    conv = lambda v: int(v)
                else: conv = lambda v: str(v)
                sql = "ALTER TABLE %s ALTER COLUMN %s TYPE %s" % (tname, cols[i][0], nt)
                c = cols.pop(i); cols.append((c[0], nt)); [d.append(conv(d.pop(i))) for d in data]
            elif op == "table":
                nn = tname + "x" ; sql = "ALTER TABLE %s RENAME TO %s" % (tname, nn) ; tname = nn
            else: continue
            ai = r.add(sql)
            dq = r.add("SELECT %s FROM %s ORDER BY %s" % (", ".join(c[0] for c in cols), tname, ", ".join(c[0] for c in cols)))
            sq = r.add("SELECT column_name FROM information_schema.columns WHERE table_name = '%s' ORDER BY ordinal_position" % tname)
            expect.append((sql, dq, sq, ai, [c[0] for c in cols], sorted([tuple(d) for d in data], key=lambda t: [(isinstance(x, str), x) for x in t])))
        res = r.go()
        for sql, dq, sq, ai, cn, dd in expect:
            rep.cmp("alter statement accepted: " + sql + " -> " + str(res[ai].get("err", ""))[:150] + "   [steps so far: " + "; ".join(e[0] for e in expect[:expect.index((sql, dq, sq, ai, cn, dd)) + 1]) + "]", res[ai]["ok"], True)
            got = rows_of(res[dq]); schema = rows_of(res[sq])
            rep.cmp("alter schema after: " + sql, schema, [(c,) for c in cn])
            want = [tuple(norm(x) for x in row) for row in dd]
            kf = lambda t: [str(x) for x in t]
            rep.cmp("alter data after: " + sql, sorted(got, key=kf) if got is not None else None, sorted(want, key=kf))

# ------------------------------------------------------------------------------------------------ nested tables
def feat_subview(rng, n, rep):
    for round_ in range(n):
        r = Run()
        parents = []     # each: {"id": n, "kids": [(k, w)]}
        r.add("CREATE TABLE sp (id INT, kids TABLE (k TEXT, w INT))", "S")
        nid = 0 ; qidx = []
        def check(label):
            q1 = r.add("SELECT p.id, x.k, x.w FROM sp p JOIN p.kids x ON TRUE ORDER BY p.id, x.k, x.w")
            q2 = r.add("SELECT id, kids + 0 FROM sp ORDER BY id")
            q3 = r.add("SELECT p.id, x.k FROM sp p LEFT JOIN p.kids x ON x.w > 5 ORDER BY p.id, x.k")
            q4 = r.add("SELECT id FROM sp WHERE kids > 1 ORDER BY id")
            m1 = sorted([(p["id"], k, w) for p in parents for k, w in p["kids"]], key=lambda t: (t[0], t[1], t[2]))
            m2 = sorted([(p["id"], len(p["kids"])) for p in parents])
            m3 = []
            for p in parents:
                hit = [k for k, w in p["kids"] if w > 5]
                m3 += [(p["id"], k) for k in sorted(hit)] if hit else [(p["id"], None)]
            m3.sort(key=lambda t: (t[0], t[1] is not None, t[1] or ""))
            m4 = sorted([(p["id"],) for p in parents if len(p["kids"]) > 1])
            qidx.append((label, q1, q2, q3, q4, m1, m2, m3, m4))
        for _ in range(rng.randint(6, 16)):
            op = rng.choice(["addp", "addp", "addk", "addk", "addk", "updk", "delk", "delp"])
            if op == "addp" or not parents:
                nid += 1 ; parents.append({"id": nid, "kids": []}) ; sql = "INSERT INTO sp (id) VALUES (%d)" % nid
            else:
                i = rng.randrange(len(parents)); p = parents[i]
                if op == "addk":
                    k = rng.choice(["a", "b", "c", "d"]); w = rng.randint(0, 10)
                    p["kids"].append((k, w)) ; sql = "INSERT INTO sp[%d].kids (k, w) VALUES (%s, %d)" % (i, lit(k), w)
                elif op == "updk":
                    x = rng.randint(0, 8) ; d = rng.randint(1, 4)
                    p["kids"] = [(k, w + d if w > x else w) for k, w in p["kids"]] ; sql = "UPDATE sp[%d].kids SET w = w + %d WHERE w > %d" % (i, d, x)
                elif op == "delk":
                    x = rng.randint(0, 10)
                    p["kids"] = [(k, w) for k, w in p["kids"] if not w < x] ; sql = "DELETE FROM sp[%d].kids WHERE w < %d" % (i, x)
                else:
                    parents.pop(i) ; sql = "DELETE FROM sp WHERE id = %d" % p["id"]
            r.add(sql, "Q") ; check(sql)
        res = r.go()
        for label, q1, q2, q3, q4, m1, m2, m3, m4 in qidx:
            rep.cmp("subview unnest after: " + label, rows_of(res[q1]), [tuple(norm(c) for c in t) for t in m1])
            rep.cmp("subview counts after: " + label, rows_of(res[q2]), [tuple(norm(c) for c in t) for t in m2])
            rep.cmp("subview left join after: " + label, rows_of(res[q3]), [tuple(norm(c) for c in t) for t in m3])
            rep.cmp("subview count filter after: " + label, rows_of(res[q4]), [tuple(norm(c) for c in t) for t in m4])

# ------------------------------------------------------------------------------------------------ information_schema
def feat_schema(rng, n, rep):
    types = {"INT": "INTEGER", "BIGINT": "BIGINT", "TEXT": "VARCHAR", "DOUBLE PRECISION": "DOUBLE PRECISION", "BLOB": "BLOB"}
    for round_ in range(n):
        r = Run(); model = {}
        for t in range(rng.randint(1, 4)):
            name = "sc%d_%d" % (round_, t)
            cols = [("c%d" % i, rng.choice(list(types))) for i in range(rng.randint(1, 5))]
            sub = rng.random() < 0.4
            ddl = ", ".join("%s %s" % c for c in cols) + (", sub TABLE (a INT, b TEXT)" if sub else "")
            r.add("CREATE TABLE %s (%s)" % (name, ddl), "S")
            nrows = rng.randint(0, 6)
            for i in range(nrows):
                vals = []
                for c, ty in cols: vals.append(lit("x") if ty == "TEXT" else ("X'AB'" if ty == "BLOB" else "1"))
                r.add("INSERT INTO %s (%s) VALUES (%s)" % (name, ", ".join(c for c, _ in cols), ", ".join(vals)), "S")
            model[name] = (cols + ([("sub", "TABLE")] if sub else []), nrows)
        r.add("COMMIT", "S")
        qt = r.add("SELECT table_name, table_type, row_count FROM information_schema.tables WHERE table_name LIKE 'sc%d\\_%%' ESCAPE '\\' ORDER BY table_name" % round_)
        qc = r.add("SELECT table_name, column_name, ordinal_position, data_type FROM information_schema.columns WHERE table_name LIKE 'sc%d\\_%%' ESCAPE '\\' ORDER BY table_name, ordinal_position" % round_)
        res = r.go()
        rep.cmp("schema tables", rows_of(res[qt]), [(n_, "BASE TABLE", float(m[1])) for n_, m in sorted(model.items())] and [tuple(norm(x) for x in (n_, "BASE TABLE", m[1])) for n_, m in sorted(model.items())])
        want = []
        for n_, (cols, _) in sorted(model.items()):
            for i, (c, ty) in enumerate(cols, 1): want.append(tuple(norm(x) for x in (n_, c, i, types.get(ty, ty))))
        rep.cmp("schema columns", rows_of(res[qc]), want)

FEATS = {"cte": feat_cte, "lateral": feat_lateral, "merge": feat_merge, "alter": feat_alter, "subview": feat_subview, "schema": feat_schema}
def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--seed", type=int, default=1); ap.add_argument("--n", type=int, default=150)
    ap.add_argument("--only", default=",".join(FEATS)); ap.add_argument("--show", type=int, default=8); a = ap.parse_args()
    rng = random.Random(a.seed); total_bad = 0
    for name in a.only.split(","):
        rep = Report()
        n = a.n if name in ("cte", "lateral") else max(10, a.n // 3)
        FEATS[name](rng, n, rep)
        print("%-8s checks: %4d   agree: %4d   both rejected: %d   MISMATCH: %d" % (name, rep.ok + len(rep.bad) + rep.both, rep.ok, rep.both, len(rep.bad)))
        for label, got, want in rep.bad[:a.show]:
            print("\n   ", label[:240]); print("      mkit-sql:", str(got)[:240]); print("      oracle:  ", str(want)[:240])
        total_bad += len(rep.bad)
    sys.exit(1 if total_bad else 0)
if __name__ == "__main__": main()
