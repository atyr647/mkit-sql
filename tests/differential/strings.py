#!/usr/bin/env python3
"""String functions and LIKE against independent oracles.

    python3 tests/differential/strings.py [--n 3000] [--seed 1]

LIKE / NOT LIKE / ESCAPE are compared with SQLite (case-sensitive mode); the string functions with a Python
model of the standard / PostgreSQL behaviour.  Strings contain regex metacharacters, quotes, backslashes,
braces, blanks, digits and non-ASCII letters, because the engine turns patterns into regular expressions.
"""
import argparse, json, os, random, re, sqlite3, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diff import HERE

ALPHA = list("abAB12 _%.*+?()[]{}|^$\\'\"-,;:!#é€")
def rs(r, maxlen=6): return "".join(r.choice(ALPHA) for _ in range(r.randint(0, maxlen)))
def q(s): return "'" + s.replace("'", "''") + "'"

def initcap(s):
    out = []; up = True
    for c in s:
        if c.isalnum(): out.append(c.upper() if up else c.lower()); up = False
        else: out.append(c); up = True
    return "".join(out)
def substr(s, a, b=None):
    to = len(s) if b is None else a + b - 1
    frm = max(a, 1); to = min(to, len(s))
    return "" if to < frm else s[frm - 1:to]
def pad(s, n, fill, left):
    if n <= len(s): return s[:max(n, 0)]
    if fill == "": return s
    p = (fill * ((n - len(s)) // len(fill) + 1))[:n - len(s)]
    return p + s if left else s + p
def left(s, n): return s[:n] if n >= 0 else s[:len(s) + n] if len(s) + n > 0 else ""
def right(s, n): return s[len(s) - n:] if n > 0 and n <= len(s) else (s if n > len(s) else (s[-n:] if n < 0 else ""))
def trim(s, chars, mode):
    cs = set(chars)
    i, j = 0, len(s)
    if mode in ("both", "leading"):
        while i < j and s[i] in cs: i += 1
    if mode in ("both", "trailing"):
        while j > i and s[j - 1] in cs: j -= 1
    return s[i:j]

def like_re(pat, esc):
    out = ["^"]; i = 0
    while i < len(pat):
        c = pat[i]
        if esc and c == esc and i + 1 < len(pat): i += 1; out.append(re.escape(pat[i]))
        elif c == "%": out.append(".*")
        elif c == "_": out.append(".")
        else: out.append(re.escape(c))
        i += 1
    out.append("$"); return re.compile("".join(out), re.S)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--n", type=int, default=3000); ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--show", type=int, default=10); a = ap.parse_args()
    r = random.Random(a.seed)
    cases = []          # (sql, expected-python-value or None for sqlite-compared, kind)
    sq = []             # LIKE cases compared with sqlite
    for _ in range(a.n):
        s = rs(r, 8); t = rs(r, 3); u = rs(r, 3)
        k = r.randint(0, 19)
        if k == 0: cases.append(("SELECT LENGTH(%s)" % q(s), str(len(s))))
        elif k == 1: cases.append(("SELECT UPPER(%s), LOWER(%s)" % (q(s), q(s)), (s.upper(), s.lower())))
        elif k == 2:
            a1 = r.randint(-2, 9); b1 = r.randint(0, 9)
            cases.append(("SELECT SUBSTR(%s, %d, %d), SUBSTR(%s, %d)" % (q(s), a1, b1, q(s), a1), (substr(s, a1, b1), substr(s, a1))))
        elif k == 3:
            n = r.randint(-9, 12); cases.append(("SELECT LEFT(%s, %d), RIGHT(%s, %d)" % (q(s), n, q(s), n), (left(s, n), right(s, n))))
        elif k == 4: cases.append(("SELECT REVERSE(%s)" % q(s), s[::-1]))
        elif k == 5:
            n = r.randint(-2, 5); cases.append(("SELECT REPEAT(%s, %d)" % (q(t), n), t * max(n, 0)))
        elif k == 6:
            n = r.randint(-2, 14); cases.append(("SELECT LPAD(%s, %d, %s), RPAD(%s, %d, %s)" % (q(s), n, q(t), q(s), n, q(t)), (pad(s, n, t, True), pad(s, n, t, False))))
        elif k == 7:
            n = r.randint(0, 12); cases.append(("SELECT LPAD(%s, %d), RPAD(%s, %d)" % (q(s), n, q(s), n), (pad(s, n, " ", True), pad(s, n, " ", False))))
        elif k == 8: cases.append(("SELECT TRIM(%s), LTRIM(%s), RTRIM(%s)" % (q(s), q(s), q(s)), (trim(s, " ", "both"), trim(s, " ", "leading"), trim(s, " ", "trailing"))))
        elif k == 9: cases.append(("SELECT TRIM(%s, %s), LTRIM(%s, %s), RTRIM(%s, %s)" % (q(s), q(t), q(s), q(t), q(s), q(t)), (trim(s, t, "both"), trim(s, t, "leading"), trim(s, t, "trailing"))))
        elif k == 10:
            if t == "": continue
            cases.append(("SELECT REPLACE(%s, %s, %s)" % (q(s), q(t), q(u)), s.replace(t, u)))
        elif k == 11: cases.append(("SELECT POSITION(%s IN %s), INSTR(%s, %s)" % (q(t), q(s), q(s), q(t)), (s.find(t) + 1, s.find(t) + 1)))
        elif k == 12: cases.append(("SELECT INITCAP(%s)" % q(s), initcap(s)))
        elif k == 13: cases.append(("SELECT %s || %s || %s, CONCAT(%s, %s, %s)" % (q(s), q(t), q(u), q(s), q(t), q(u)), (s + t + u, s + t + u)))
        elif k == 14: cases.append(("SELECT CONCAT_WS(%s, %s, %s, %s)" % (q(t), q(s), q(u), q(s)), t.join([s, u, s])))
        elif k == 15:
            if s == "": continue
            cases.append(("SELECT ASCII(%s), CHR(%d)" % (q(s), ord(s[0])), (ord(s[0]), s[0])))
        elif k == 16: cases.append(("SELECT %s = %s, %s < %s, %s <> %s" % (q(s), q(t), q(s), q(t), q(s), q(t)), (int(s == t), int(s < t), int(s != t))))
        else:
            pat = "".join(r.choice(list("ab%_.*[]\\!1 ")) for _ in range(r.randint(0, 6)))
            esc = r.choice(["", "!", "\\"])
            sq.append((s, pat, esc))
    # data for LIKE: a table so patterns and values come from columns too
    setup = ["CREATE TABLE l (id INT, s VARCHAR(30), p VARCHAR(30))"]
    for i, (s, p, e) in enumerate(sq): setup.append("INSERT INTO l VALUES (%d, %s, %s)" % (i, q(s), q(p)))
    queries = [c[0] for c in cases]
    for i, (s, p, e) in enumerate(sq):
        queries.append("SELECT %s LIKE %s%s, %s NOT LIKE %s%s" % (q(s), q(p), (" ESCAPE " + q(e)) if e else "", q(s), q(p), (" ESCAPE " + q(e)) if e else ""))
    queries.append("SELECT id FROM l WHERE s LIKE p ORDER BY id")
    queries.append("SELECT id FROM l WHERE s LIKE '%a%' AND s NOT LIKE '_b%' ORDER BY id")
    tmp = tempfile.mkdtemp(); script = os.path.join(tmp, "s.txt"); out = os.path.join(tmp, "o.jsonl")
    with open(script, "w", encoding="utf-8") as f:
        for s in setup: f.write("S " + s.replace("\n", " ") + "\n")
        for x in queries: f.write("Q " + x.replace("\n", " ") + "\n")
    subprocess.run(os.environ.get("MKIT_TCLSH", "tclsh").split() + [os.path.join(HERE, "run_tcl.tcl"), script, out], check=True)
    mine = [json.loads(l) for l in open(out, encoding="utf-8")]
    assert len(mine) == len(queries)
    bad = []; ok = 0
    def cell(v):
        return v
    for (sql, want), m in zip(cases, mine):
        if not m["ok"]: bad.append((sql, "error: " + m["err"][:100])); continue
        got = m["rows"][0]
        w = list(want) if isinstance(want, tuple) else [want]
        w = [str(x) if not isinstance(x, str) else x for x in w]
        g = [str(x) for x in got]
        if g != w: bad.append((sql, "mkit=%r expected=%r" % (g, w)))
        else: ok += 1
    con = sqlite3.connect(":memory:"); con.execute("PRAGMA case_sensitive_like=ON")
    for s in setup: con.execute(s.replace("VARCHAR(30)", "TEXT"))
    n_c = len(cases)
    for i, (s, p, e) in enumerate(sq):
        sql = queries[n_c + i]; m = mine[n_c + i]
        try: want = con.execute(sql).fetchall()
        except Exception as ex: want = None
        if want is None:
            if m["ok"]: bad.append((sql, "sqlite rejected, mkit accepted: %s" % m["rows"]))
            else: ok += 1
            continue
        if not m["ok"]: bad.append((sql, "mkit error: " + m["err"][:100])); continue
        g = [[str(c) if c != "NULL" else None for c in row] for row in m["rows"]]
        w = [[None if c is None else str(c) for c in row] for row in want]
        if g != w: bad.append((sql, "mkit=%s sqlite=%s" % (g, w)))
        else: ok += 1
    for j in (1, 2):
        sql = queries[-3 + j]; m = mine[-3 + j]
        try: want = sorted(r_[0] for r_ in con.execute(sql).fetchall())
        except Exception as ex: want = None
        got = sorted(int(float(row[0])) for row in m["rows"]) if m["ok"] else None
        if want != got: bad.append((sql, "mkit=%s sqlite=%s" % (got, want)))
        else: ok += 1
    print("string / LIKE cases: %d   agree: %d   MISMATCH: %d" % (len(queries) - 1 + 1 - 1 + 1 - 1 + 0 + 3 - 3 + len(queries) - len(queries) + 0, ok, len(bad)) if False else "string / LIKE cases: %d   agree: %d   MISMATCH: %d" % (ok + len(bad), ok, len(bad)))
    for sql, why in bad[:a.show]: print("\n ", sql[:200], "\n    ", why)
    sys.exit(1 if bad else 0)
if __name__ == "__main__": main()
