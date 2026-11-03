#!/usr/bin/env python3
"""Benchmark mkit-sql (real Metakit, pure Tcl) against SQLite (C, on disk) on the same data and queries.

    python3 tests/bench/bench.py [rows]        env: MKIT_TCLSH=tclkit/tclkit-8.6.3  MKIT_MK4TCL=builtin

Not a claim that mkit-sql is fast: it is a pure-Tcl engine over a file format with no indexes.  The numbers say where.
SQLite runs with NO indexes either (apart from what the queries create implicitly), to compare like with like;
a second column shows SQLite with the obvious index on a.id and a.name.
"""
import json, os, sqlite3, subprocess, sys, tempfile, time
N = int(sys.argv[1]) if len(sys.argv) > 1 else 200000
HERE = os.path.dirname(os.path.abspath(__file__))
tmp = tempfile.mkdtemp(); out = os.path.join(tmp, "m.json")
tcl = os.environ.get("MKIT_TCLSH", "tclsh").split()
subprocess.run(tcl + [os.path.join(HERE, "bench.tcl"), str(N), out], check=True, stdout=subprocess.DEVNULL)
mk = json.load(open(out))

def run_sqlite(indexed):
    path = os.path.join(tmp, "s%d.db" % indexed)
    con = sqlite3.connect(path); con.execute("PRAGMA journal_mode=OFF"); con.execute("PRAGMA synchronous=OFF")
    con.execute("CREATE TABLE a (id INT, grp INT, val REAL, name TEXT, tag TEXT)"); con.execute("CREATE TABLE b (id INT, aid INT, w INT)")
    res = {}
    t0 = time.perf_counter()
    con.executemany("INSERT INTO a VALUES (?,?,?,?,?)", ((i, i % 1000, (i * 37 % 10007) / 4.0, "name%d" % (i * 7919 % N), "t%d" % (i % 50)) for i in range(N)))
    con.commit(); res["load_a"] = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter()
    con.executemany("INSERT INTO b VALUES (?,?,?)", ((i, (i * 13) % N, i % 100) for i in range(N // 4)))
    con.commit(); res["load_b"] = (time.perf_counter() - t0) * 1000
    if indexed:
        con.execute("CREATE INDEX ia ON a(id)"); con.execute("CREATE INDEX iname ON a(name)"); con.execute("CREATE INDEX ibaid ON b(aid)"); con.commit()
    target = N * 7 // 10
    queries = {
     "point_lookup_int": "SELECT * FROM a WHERE id = %d" % target, "point_lookup_text": "SELECT * FROM a WHERE name = 'name%d'" % target,
     "range_10_rows": "SELECT * FROM a WHERE id BETWEEN %d AND %d" % (target, target + 9), "count_all": "SELECT COUNT(*) FROM a",
     "count_filtered": "SELECT COUNT(*) FROM a WHERE grp = 7", "sum_avg": "SELECT SUM(val), AVG(val), MIN(id), MAX(id) FROM a",
     "group_by_1000": "SELECT grp, COUNT(*), SUM(val) FROM a GROUP BY grp", "distinct_tag": "SELECT DISTINCT tag FROM a",
     "order_by_limit_10": "SELECT id FROM a ORDER BY val DESC, id LIMIT 10", "order_by_full": "SELECT id, name FROM a ORDER BY name",
     "join_hash": "SELECT COUNT(*) FROM a JOIN b ON a.id = b.aid WHERE b.w < 50", "like_prefix": "SELECT COUNT(*) FROM a WHERE name LIKE 'name12%'",
     "window_row_number": "SELECT COUNT(*) FROM (SELECT ROW_NUMBER() OVER (PARTITION BY grp ORDER BY val) AS rn FROM a) x WHERE rn = 1",
     "correlated_subquery": "SELECT COUNT(*) FROM b WHERE w > (SELECT AVG(w) FROM b b2 WHERE b2.aid % 10 = b.aid % 10)"}
    for name, sql in queries.items():
        best = 1e18
        for _ in range(3):
            t0 = time.perf_counter(); con.execute(sql).fetchall(); best = min(best, (time.perf_counter() - t0) * 1000)
        res[name] = best
    t0 = time.perf_counter(); con.execute("INSERT INTO a VALUES " + ",".join("(%d,1,1.5,'x','t1')" % (N + i) for i in range(10000))); con.commit(); res["insert_10k_rows"] = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter(); con.execute("UPDATE a SET val = val + 1 WHERE grp < 100"); con.commit(); res["update_10pct"] = (time.perf_counter() - t0) * 1000
    t0 = time.perf_counter(); con.execute("DELETE FROM a WHERE grp >= 900"); con.commit(); res["delete_10pct"] = (time.perf_counter() - t0) * 1000
    return res
plain = run_sqlite(0); idx = run_sqlite(1)
print("rows in a: %d, in b: %d     (ms; best of 3 for queries)" % (N, N // 4))
print("%-22s %12s %12s %12s %10s" % ("", "mkit-sql", "SQLite", "SQLite+idx", "mkit/SQLite"))
for k in mk:
    print("%-22s %12.1f %12.1f %12.1f %9.0fx" % (k, mk[k], plain[k], idx[k], mk[k] / max(plain[k], 0.01)))
