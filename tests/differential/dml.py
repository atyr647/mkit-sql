#!/usr/bin/env python3
"""Stateful differential test for data-changing statements.

    python3 tests/differential/dml.py [--seqs 40] [--steps 40] [--seed 1] [--show 10]

Each sequence creates two tables, then applies random INSERT / INSERT..SELECT / UPDATE / DELETE /
CREATE TABLE AS / DROP TABLE / COMMIT / ROLLBACK statements to mkit-sql and to SQLite.  After EVERY statement
the affected-row count and the full contents of every table must agree (the two engines get identical data;
no NULLs are stored because Metakit cannot, so scalar subqueries are wrapped in COALESCE).
Run with MKIT_BULKMIN=1 to push every big delete/update through the table-rebuild path, and with
MKIT_MEMBYTES/MKIT_CHUNK to force spilling.
"""
import argparse, json, os, random, sqlite3, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diff import norm, HERE

WORDS = ["alpha", "Beta", "gamma", "Delta", "", "echo", "ZULU", "x y", "foxtrot", "a%b", "under_score", "it's", "tab\there"]

def lit(v):
    return "'" + v.replace("'", "''") + "'" if isinstance(v, str) else repr(v)

class Seq:
    def __init__(self, rng, k):
        self.r = rng; self.k = k
        self.a = "a%d" % k; self.b = "b%d" % k
        self.extra = []          # extra tables (CTAS)
        self.nid = 1000
    def cond(self, alias=""):
        r = self.r; p = alias + "." if alias else ""
        c = r.randint(0, 9)
        if c == 0: return "%sid %% %d = %d" % (p, r.choice([2, 3, 5, 7]), r.randint(0, 1))
        if c == 1: return "%sg > %d" % (p, r.randint(0, 5))
        if c == 2: return "%sg <= %d" % (p, r.randint(1, 6))
        if c == 3: return "%ss LIKE '%s%%'" % (p, r.choice("abgeZxfu"))
        if c == 4: return "%sx BETWEEN %s AND %s" % (p, r.choice([-2, 0, 1]), r.choice([3, 6, 50]))
        if c == 5: return "%sid IN (SELECT aid FROM %s WHERE v > %d)" % (p, self.b, r.randint(-2, 12))
        if c == 6: return "EXISTS (SELECT 1 FROM %s WHERE %s.aid = %sid AND v %% 2 = %d)" % (self.b, self.b, p, r.randint(0, 1))
        if c == 7: return "(%sg + %sid) %% %d = %d" % (p, p, r.choice([3, 4]), r.randint(0, 2))
        if c == 8: return "%ss = %s" % (p, lit(r.choice(WORDS)))
        return "NOT (%sg = %d OR %sid < %d)" % (p, r.randint(1, 6), p, r.randint(3, 20))
    def stmt(self):
        r = self.r; a, b = self.a, self.b
        k = r.randint(0, 17)
        if k <= 1:
            rows = []
            for _ in range(r.randint(1, 6)):
                self.nid += 1
                rows.append("(%d, %d, %s, %s)" % (self.nid, r.randint(1, 6), r.choice([0.5, 1.25, 2.5, -1.5, 7.75, 100.0]), lit(r.choice(WORDS))))
            return "INSERT INTO %s VALUES %s" % (a, ", ".join(rows))
        if k == 2:
            return "INSERT INTO %s (id, aid, v, tag) VALUES (%d, %d, %d, %s)" % (b, r.randint(2000, 3000), r.randint(1, 40), r.randint(-5, 20), lit(r.choice(WORDS)))
        if k == 3:
            return "INSERT INTO %s (id, g, x, s) SELECT id + 5000, g, x * 2, s || '!' FROM %s WHERE %s" % (a, a, self.cond())
        if k == 4:
            return "INSERT INTO %s SELECT id + 7000, aid, v + 1, tag FROM %s WHERE v > %d" % (b, b, r.randint(-3, 15))
        if k == 5: return "UPDATE %s SET g = (g + %d) %% 7 WHERE %s" % (a, r.randint(1, 5), self.cond())
        if k == 6: return "UPDATE %s SET x = x * %s + %d, s = s || %s WHERE %s" % (a, r.choice([2, 0.5, 3]), r.randint(-2, 2), lit(r.choice(["", "_", "e", "z"])), self.cond())
        if k == 7: return "UPDATE %s SET s = UPPER(s) WHERE %s" % (a, self.cond())
        if k == 8: return "UPDATE %s SET g = COALESCE((SELECT MAX(v) FROM %s WHERE %s.aid = %s.id), 0) %% 7 WHERE %s" % (a, b, b, a, self.cond())
        if k == 9: return "UPDATE %s SET v = v + %d WHERE aid IN (SELECT id FROM %s WHERE %s)" % (b, r.randint(-2, 3), a, self.cond())
        if k == 10: return "UPDATE %s SET tag = %s || tag, v = v * 2 %% 50 WHERE v %% %d = %d" % (b, lit(r.choice(["p", "q-", ""])), r.choice([2, 3]), r.randint(0, 1))
        if k == 11: return "DELETE FROM %s WHERE %s" % (a, self.cond())
        if k == 12: return "DELETE FROM %s WHERE aid IN (SELECT id FROM %s WHERE %s)" % (b, a, self.cond())
        if k == 13: return "DELETE FROM %s WHERE v < %d OR tag = %s" % (b, r.randint(-5, 6), lit(r.choice(WORDS)))
        if k == 14:
            if len(self.extra) < 2:
                name = "c%d_%d" % (self.k, len(self.extra) + r.randint(0, 99))
                if name in self.extra: return "COMMIT"
                self.extra.append(name)
                return "CREATE TABLE %s AS SELECT id, g, x, s FROM %s WHERE %s" % (name, a, self.cond())
            name = self.extra.pop(r.randrange(len(self.extra)))
            return "DROP TABLE %s" % name
        if k == 15: return "COMMIT"
        if k == 16: return "ROLLBACK"
        return "UPDATE %s SET g = g + 1 WHERE g < 6 AND %s" % (a, self.cond())

def setup(rng, s):
    st = ["CREATE TABLE %s (id INT, g INT, x DOUBLE PRECISION, s VARCHAR(30))" % s.a,
          "CREATE TABLE %s (id INT, aid INT, v INT, tag VARCHAR(30))" % s.b]
    for i in range(1, 41):
        st.append("INSERT INTO %s VALUES (%d, %d, %s, %s)" % (s.a, i, rng.randint(1, 6), rng.choice([0.5, 1.25, 2.5, 3.0, -1.5, 7.75, 10.0]), lit(rng.choice(WORDS))))
    for i in range(1, 61):
        st.append("INSERT INTO %s VALUES (%d, %d, %d, %s)" % (s.b, i, rng.randint(1, 45), rng.randint(-5, 20), lit(rng.choice(WORDS))))
    st.append("COMMIT")
    return st

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seqs", type=int, default=40); ap.add_argument("--steps", type=int, default=40)
    ap.add_argument("--seed", type=int, default=1); ap.add_argument("--show", type=int, default=10)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    seqs = [Seq(rng, k) for k in range(a.seqs)]
    plan = []                      # (kind, sql) in order: kind S setup, D dml, T dump
    live = {}                      # per sequence: tables that exist right now (committed or not): tracked via sqlite
    for s in seqs:
        for st in setup(rng, s): plan.append(("S", st))
        for _ in range(a.steps):
            plan.append(("D", s.stmt(), s))
    tmp = tempfile.mkdtemp()
    script = os.path.join(tmp, "script.txt"); out = os.path.join(tmp, "out.jsonl")
    con = sqlite3.connect(":memory:", isolation_level=None)
    con.execute("PRAGMA case_sensitive_like=ON")
    lines = []; expect = []        # expect: per Q line, a callable describing the sqlite answer
    def sq(sql):
        try:
            cur = con.execute(sql); rows = cur.fetchall()
            return (True, rows, cur.rowcount)
        except Exception as e:
            return (False, str(e), -1)
    # replay on sqlite while building the mkit script so both see the same statements
    for ent in plan:
        kind, sql = ent[0], ent[1]
        if kind == "S":
            if sql == "COMMIT":
                con.execute("COMMIT") if con.in_transaction else None
                con.execute("BEGIN")
                lines.append("S COMMIT")
            else:
                if not con.in_transaction: con.execute("BEGIN")
                con.execute(sql.replace("DOUBLE PRECISION", "REAL").replace("VARCHAR(30)", "TEXT"))
                lines.append("S " + sql)
            continue
        s = ent[2]
        if sql in ("COMMIT", "ROLLBACK"):
            if con.in_transaction: con.execute(sql)
            con.execute("BEGIN")
            lines.append("Q " + sql); expect.append(("ctl", sql, None))
            # a rolled-back CTAS/DROP changes which extra tables exist: resync from sqlite
            names = [r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'c%d\\_%%' ESCAPE '\\'" % s.k)]
            s.extra = names
        else:
            res = sq(sql)
            lines.append("Q " + sql.replace("\n", " "))
            expect.append(("dml", sql, res))
            if not res[0]: pass
        # dump every table of this sequence
        for t in [s.a, s.b] + list(s.extra):
            q = "SELECT * FROM %s ORDER BY 1, 2, 3, 4" % t
            lines.append("Q " + q)
            expect.append(("dump", q, sq(q)))
    with open(script, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    tclsh = os.environ.get("MKIT_TCLSH", "tclsh").split()
    subprocess.run(tclsh + [os.path.join(HERE, "run_tcl.tcl"), script, out], check=True)
    mine = [json.loads(l) for l in open(out, encoding="utf-8")]
    assert len(mine) == len(expect), (len(mine), len(expect))
    bad = []; ok = 0; both_err = 0; steps = 0
    dead = set(); rejected = []
    cur = None
    for (kind, sql, res), m in zip(expect, mine):
        steps += 1
        if kind == "ctl":
            if not m["ok"]: bad.append((sql, "mkit-sql rejected: " + m["err"]))
            else: ok += 1
            continue
        if kind == "dml":
            if not res[0] and not m["ok"]: both_err += 1; rejected.append((sql, res[1], m["err"])); continue
            if res[0] != m["ok"]:
                bad.append((sql, "ok mismatch: sqlite=%s mkit=%s" % (res[0] and "ok" or res[1], m["ok"] and "ok" or m.get("err"))))
                continue
            if m["ok"] and res[2] >= 0 and m.get("affected", -1) >= 0 and m["affected"] != res[2]:
                bad.append((sql, "affected: mkit=%s sqlite=%s" % (m["affected"], res[2]))); continue
            ok += 1; continue
        # dump
        if not res[0] and not m["ok"]: continue
        if res[0] != m["ok"]:
            bad.append((sql, "dump ok mismatch: sqlite=%s mkit=%s" % (res[0] and "ok" or res[1], m["ok"] and "ok" or m.get("err")))); continue
        x = [tuple(norm(c) for c in r) for r in m["rows"]]
        y = [tuple(norm(c) for c in r) for r in res[1]]
        # NULL-free by construction; text '' is stored as '' by both
        if x != y:
            i = next((i for i in range(min(len(x), len(y))) if x[i] != y[i]), min(len(x), len(y)))
            bad.append((sql, "contents differ (mkit %d rows, sqlite %d rows) first diff at %d: mkit=%s sqlite=%s" % (len(x), len(y), i, x[i:i+2], y[i:i+2])))
        else: ok += 1
    print("sequences: %d x %d steps   checks: %d   agree: %d   both rejected: %d   MISMATCH: %d" % (a.seqs, a.steps, steps, ok, both_err, len(bad)))
    # show the statement that preceded each failure
    for sql, why in bad[:a.show]:
        print("\n  after/at:", sql[:160]); print("   ", why)
    for sql, e1, e2 in rejected[:a.show]: print("\n  rejected by both:", sql[:100], "\n     sqlite:", e1[:70], "\n     mkit:  ", e2[:90])
    sys.exit(1 if bad else 0)

if __name__ == "__main__": main()
