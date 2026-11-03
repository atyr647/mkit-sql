#!/usr/bin/env python3
"""Numeric edge cases against SQLite: 32/64-bit boundaries, huge and tiny doubles, negative zero, mixed
INT/REAL comparison, sorting and grouping of large values, with and without spilling.

    python3 tests/differential/numeric.py [--show 10]        (MKIT_MEMBYTES / MKIT_CHUNK / MKIT_TCLSH as for diff.py)
"""
import argparse, json, os, sqlite3, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diff import norm, normrows, HERE

INTS = [0, 1, -1, 2, 7, -7, 255, 65535, 2147483647, -2147483648, 1000000, -1000000]
BIGS = [0, 1, -1, 4294967296, -4294967296, 1099511627776, 4611686018427387904, -4611686018427387904, 9007199254740993, 123456789012, -987654321098, 2147483648]
DBLS = [0.0, -0.0, 0.5, -0.5, 1.0, 1.5, 2.5, 1e-300, -1e-300, 1e300, -1e300, 123456.789, 0.1, 3.14159265358979, 1e15, 1e16, 4503599627370496.0, 2.0]
def build():
    stmts = ["CREATE TABLE n (id INT, i INT, l BIGINT, d DOUBLE PRECISION)",
             "CREATE TABLE m (id INT, i INT, d DOUBLE PRECISION)"]
    rows = []
    for k in range(60):
        rows.append((k, INTS[k % len(INTS)], BIGS[(k * 5) % len(BIGS)], DBLS[(k * 7) % len(DBLS)]))
    for r in rows: stmts.append("INSERT INTO n VALUES (%d, %d, %d, %s)" % (r[0], r[1], r[2], repr(r[3])))
    for k in range(25):
        stmts.append("INSERT INTO m VALUES (%d, %d, %s)" % (k, INTS[(k * 3) % len(INTS)], repr(float(INTS[(k * 5) % len(INTS)]))))
    return stmts
Q = []
for col in ("i", "l", "d"):
    Q += ["SELECT id, %s FROM n ORDER BY %s, id" % (col, col), "SELECT id, %s FROM n ORDER BY %s DESC, id" % (col, col),
          "SELECT DISTINCT %s FROM n ORDER BY 1" % col, "SELECT %s, COUNT(*) FROM n GROUP BY %s ORDER BY 1" % (col, col),
          "SELECT MIN(%s), MAX(%s), COUNT(DISTINCT %s) FROM n" % (col, col, col),
          "SELECT id FROM n WHERE %s > 0 ORDER BY id" % col, "SELECT id FROM n WHERE %s BETWEEN -1 AND 1 ORDER BY id" % col,
          "SELECT id, RANK() OVER (ORDER BY %s), DENSE_RANK() OVER (ORDER BY %s DESC) FROM n ORDER BY id" % (col, col),
          "SELECT id, ROW_NUMBER() OVER (PARTITION BY id %% 4 ORDER BY %s DESC, id) FROM n ORDER BY id" % col,
          "SELECT id, LAG(%s) OVER (ORDER BY id), LEAD(%s, 3) OVER (ORDER BY id) FROM n ORDER BY id" % (col, col)]
Q += [
    "SELECT SUM(i), AVG(i), SUM(d) / 1e290, SUM(DISTINCT i), AVG(DISTINCT i) FROM n",
    "SELECT SUM(l / 1000000), MIN(l), MAX(l) FROM n",
    "SELECT i % 7, l % 1000, id % 3 FROM n ORDER BY id", "SELECT -i, ABS(i), ABS(d) FROM n ORDER BY id",
    "SELECT i / 2, i / 3, i / -2, l / 7 FROM n ORDER BY id",
    "SELECT CAST(d AS INT) FROM n WHERE d >= 0 AND d < 1e9 AND d - FLOOR(d) < 0.5 ORDER BY id",
    "SELECT id, ROUND(d, 1), ROUND(d), FLOOR(d), CEIL(d) FROM n WHERE ABS(d) < 1e9 ORDER BY id",
    "SELECT a.id, b.id FROM n a JOIN m b ON a.i = b.d ORDER BY a.id, b.id",
    "SELECT a.id, b.id FROM n a JOIN m b ON a.d = b.i ORDER BY a.id, b.id",
    "SELECT a.id, b.id FROM n a JOIN m b ON a.i = b.i ORDER BY a.id, b.id",
    "SELECT a.id, b.id FROM n a JOIN n b ON a.l = b.l AND a.id < b.id ORDER BY a.id, b.id",
    "SELECT a.id, b.id FROM n a LEFT JOIN m b ON a.i < b.i AND b.id < 3 ORDER BY a.id, b.id",
    "SELECT id FROM n WHERE i IN (0, 1, 2147483647, -2147483648) ORDER BY id",
    "SELECT id FROM n WHERE l IN (SELECT l FROM n WHERE id < 10) ORDER BY id",
    "SELECT id FROM n WHERE d IN (SELECT d FROM m) ORDER BY id",
    "SELECT i FROM n UNION SELECT i FROM m ORDER BY 1", "SELECT d FROM n INTERSECT SELECT d FROM m ORDER BY 1",
    "SELECT i FROM n EXCEPT SELECT i FROM m ORDER BY 1",
    "SELECT i, d, i = d, i < d, i <= d FROM n WHERE ABS(d) < 1e9 ORDER BY id",
    "SELECT id, i + d, i * d FROM n WHERE ABS(d) < 1e9 ORDER BY id",
    "SELECT id FROM n ORDER BY CASE WHEN i > 0 THEN l ELSE -l END, id",
    "SELECT i, COUNT(*), SUM(l / 100000000), MAX(d) FROM n GROUP BY i HAVING COUNT(*) > 4 ORDER BY i",
    "SELECT COUNT(DISTINCT l), COUNT(DISTINCT d), SUM(DISTINCT id % 5) FROM n",
    "SELECT i, COUNT(DISTINCT l), MIN(d), MAX(d) FROM n GROUP BY i ORDER BY i",
    "SELECT COALESCE(NULLIF(i, 0), 99), CASE WHEN i > 5 THEN i ELSE 5 END FROM n ORDER BY id",
    "SELECT id FROM n ORDER BY d DESC, l, id LIMIT 7 OFFSET 5",
]
def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--show", type=int, default=10); a = ap.parse_args()
    setup = build()
    tmp = tempfile.mkdtemp(); script = os.path.join(tmp, "s.txt"); out = os.path.join(tmp, "o.jsonl")
    with open(script, "w", encoding="utf-8") as f:
        for s in setup: f.write("S " + s + "\n")
        for q in Q: f.write("Q " + q + "\n")
    subprocess.run(os.environ.get("MKIT_TCLSH", "tclsh").split() + [os.path.join(HERE, "run_tcl.tcl"), script, out], check=True)
    mine = [json.loads(l) for l in open(out, encoding="utf-8")]
    con = sqlite3.connect(":memory:")
    for s in setup: con.execute(s.replace("DOUBLE PRECISION", "REAL").replace("BIGINT", "INTEGER"))
    ok = bad = both = 0; shown = []
    for q, m in zip(Q, mine):
        try: sres = con.execute(q).fetchall(); serr = None
        except Exception as e: sres = None; serr = str(e)
        if not m["ok"] and serr is not None: both += 1; continue
        if not m["ok"] or serr is not None:
            bad += 1; shown.append((q, "rejected: mkit=%s sqlite=%s" % (m.get("err"), serr))); continue
        ordered = "ORDER BY" in q.upper()
        x, y = normrows(m["rows"], ordered), normrows(sres, ordered)
        if x == y: ok += 1
        else:
            bad += 1
            i = next((i for i in range(min(len(x), len(y))) if x[i] != y[i]), min(len(x), len(y)))
            shown.append((q, "row %d: mkit=%s sqlite=%s (%d vs %d rows)" % (i, x[i:i+2], y[i:i+2], len(x), len(y))))
    print("numeric edge queries: %d   agree: %d   both rejected: %d   MISMATCH: %d" % (len(Q), ok, both, bad))
    for q, why in shown[:a.show]: print("\n ", q, "\n    ", why)
    sys.exit(1 if bad else 0)
if __name__ == "__main__": main()
