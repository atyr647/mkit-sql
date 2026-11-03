# mkit-sql

A large, heavily tested subset of standard SQL for [Metakit](https://www.equi4.com/metakit/) database files, in
pure Tcl. It is the query engine for [MK Studio](https://github.com/atyr647/mkstudio) and also works on its own in
any Tcl program that has Mk4tcl. **It is not "fully SQL-standard compliant"**: Metakit stores no constraints,
indexes, exact decimals or NULLs, so those parts of SQL cannot be honoured (see [What it does not
have](#what-it-does-not-have)).

```tcl
lappend auto_path /path/to/mkit-sql                      ;# the directory that contains mkitsql/
package require mkitsql                                  ;# standalone: nothing from MK Studio is needed

set db [::mkitsql::db::openFile game.mk -create]
::mkitsql::run {CREATE TABLE players (id INT, name VARCHAR(20), score DOUBLE PRECISION,
                                      items TABLE (item TEXT, qty INT))} $db
::mkitsql::run {INSERT INTO players (id, name, score) VALUES (1, 'Ada', 9.5), (2, 'Bob', 7)} $db
::mkitsql::run {COMMIT} $db

set r [::mkitsql::query {SELECT name, score FROM players WHERE score > ? ORDER BY score DESC} $db {8}]
# -> cols {name score}  rows {{Ada 9.5}}
```

**[Full SQL reference: docs/SQL.md](docs/SQL.md)** (every example in it is executed by `tests/doc_examples.tcl`).

## What it covers

Queries with every join type (hash joins, filter pushdown, `LATERAL`), subqueries (scalar, `IN`, `EXISTS`,
`ANY/ALL`, correlated, row values), `UNION/INTERSECT/EXCEPT`, `WITH` and **`WITH RECURSIVE`**, aggregates
(`DISTINCT`, `FILTER`), **window functions** (ranking, `LAG/LEAD`, running totals, `ROWS/RANGE/GROUPS` frames,
named windows), ~60 functions, **dates and intervals**, `INSERT/UPDATE/DELETE`, **`MERGE`**, `CREATE/DROP/ALTER
TABLE` (also `AS SELECT`), transactions, `information_schema`, parameters, and Metakit's nested tables
(*subviews*) as first-class citizens. Writes are all-or-nothing and range-checked. Syntax errors carry a character
position for editor underlining; a UI can cancel any long query.

## What it does not have

These are gaps, not bugs; each is rejected with a clear message rather than silently ignored.

| Missing | Why / what happens instead |
| --- | --- |
| **Persistent constraints**: `PRIMARY KEY`, `UNIQUE`, `FOREIGN KEY`, `CHECK`, `NOT NULL`, `DEFAULT` | Metakit stores none. The statement is refused (opt in to `::mkitsql::ignoreConstraints 1` to have them parsed and silently dropped, e.g. to run a schema written for another database). Nothing enforces integrity, so applications that expect the database to reject bad rows must check themselves. |
| **Indexes** | Metakit has no secondary indexes. Equality joins and correlated lookups use hash tables built per query; a point lookup is still a scan. |
| **Exact decimal arithmetic** | `DECIMAL`/`NUMERIC` are 64-bit floats. Do not use them for money. |
| **Persistent NULL** | Metakit has no NULL. NULLs exist while a query runs (`LEFT JOIN`, `SELECT NULL`, empty aggregates...) and obey three-valued logic; storing one writes `0` / empty text, so `WHERE col IS NULL` never matches stored rows. |
| SQL views, triggers, stored procedures, permissions, savepoints, upsert (`ON CONFLICT`; use `MERGE`) | no Metakit equivalent |
| `ROLLUP/CUBE/GROUPING SETS`, `COLLATE`, `SIMILAR TO`, window `EXCLUDE`, `IGNORE NULLS` | not built yet |

Other things that differ from what you may be used to: integer `/` truncates (`7 / 2` is `3`), `LIKE` is
case-sensitive (`ILIKE` is not), and a column rename moves the column to the end (a Metakit limitation).

## Runtimes

mkit-sql targets the **same Tcl runtimes as MK Studio**: **tclkit 8.6.3** (what MK Studio is built and tested on, with
Mk4tcl 2.4.9.7 inside) as the primary, and **tclkit 8.5.17** for classic tclkits. The code is written in Tcl 8.5
syntax and `package require Tcl 8.5` is enforced; `tests/lint.tcl` rejects anything newer than those runtimes
(`lmap`, `try`, `string cat`, `lsort -stride`, `dict getdef`, ...). Dates are computed with plain integer arithmetic,
not `[clock]`, so results cannot differ between Tcl versions. `tests/fetch-tclkit.sh` downloads exactly those two
kits (verified against the SHA1s MK Studio publishes), and CI runs every suite on both:

```sh
tests/fetch-tclkit.sh
MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3  tests/run.tcl      # primary
MKIT_MK4TCL=builtin tclkit/tclkit-8.5.17 tests/run.tcl      # compatibility
```

## Using it in MK Studio

MK Studio talks to its query language through one seam (`::engine`). One command installs mkit-sql behind it:

```sh
integration/install-into-mkstudio.sh /path/to/mkstudio
```

It copies the engine into `mkstudio.vfs/lib/mkitsql/` and applies [`integration/mkstudio.patch`](integration/mkstudio.patch)
(loader, a standard-SQL sample script, explorer refresh after `MERGE`, and a fix so dropping a view discards its
rows and a failure to do so aborts the drop). `mkitsql/engine_studio.tcl` is the adapter. On a patched fresh clone, MK Studio's own lint, its 38-check
engine contract and its 41 UI-logic checks all pass.

## Storage layer

The engine reaches Metakit through one interface, `::mkitsql::db` (`openFile closeFile tags views layout size rows
subSize appendRow setCell deleteRows createView dropView restructure rebuildColumn commit rollback dirty readonly`).
`mkitsql/db.tcl` implements it directly on Mk4tcl and is the default, so **mkit-sql needs no file from MK Studio**.
Inside MK Studio, `mkitsql/db_studio.tcl` forwards the same interface to MK Studio's `::store`, so both share one set
of open files (chosen automatically when `::store` is loaded; force one with `MKIT_BACKEND=standalone|studio`).
Metakit's `mk::view delete` leaves a view's rows behind, so `dropView` empties the view first and **abandons the drop
with the original error if that fails**: nothing is swallowed, and a table can never be dropped while its old rows
could come back.

## Large tables and memory

A query does not have to fit in RAM. Scans are read in chunks; every operator that must hold rows (sort and top-N,
`GROUP BY`, `DISTINCT` and `COUNT(DISTINCT ...)`, hash/sort-merge/nested-loop joins, `UNION/INTERSECT/EXCEPT`,
windows over big inputs, recursion, and the row sets built by `INSERT ... SELECT`, `UPDATE`, `MERGE`, `CREATE TABLE
AS`) is limited by `::mkitsql::memBytes` (default 32 MB per operator) and spills to temporary files beyond that (an
external merge sort, hash tables that dump partial results, a sort-merge join when the build side does not fit).
`::mkitsql::stream` hands a result to a callback chunk by chunk without ever holding it.

Measured on real Metakit with `tests/scale_memory.tcl` (24 statements, 4 MB budget; "baseline" is what the process
holds right after loading, mostly Metakit's view of the file):

| rows | baseline | peak of the 17 read-only queries | slowest query | each operator adds | `DELETE` of half (peak above baseline, alone) |
| --- | --- | --- | --- | --- | --- |
| 200,000 | 14 MB | 50 MB | 9 s (self join) | 0 to +11 MB | +20 MB, 2.3 s |
| 500,000 | 25 MB | 71 MB | 27 s | 0 to +13 MB | +49 MB, 5.6 s |
| 1,000,000 | 43 MB | 105 MB | 65 s | 0 to +17 MB | +89 MB, 11 s |

The old in-memory engine peaked at 185-229 MB *per query* at 200,000 rows and ran out of room at about 1M. Now the
extra memory of an operator does not depend on the table size (external sort, grouping by a unique key, a join of the
table with itself, `UNION/INTERSECT/EXCEPT`, windows, `COUNT(DISTINCT id)`, `INSERT ... SELECT`, `CREATE TABLE AS` all
stay in the single digits to teens of MB); the peak creeps up only with the baseline. The biggest steps are Metakit's
own: it keeps uncommitted changes in RAM, so rewriting half of a 1M-row table briefly holds the rebuilt copy
(`COMMIT` writes it out). Honest limits: one *partition* of a window function must fit in memory; the value set of an
`IN (SELECT ...)` is capped at 5,000,000 values (clear error beyond that); `DELETE` keeps one integer per deleted
row; `query`/`run` return the whole (capped) result. Metakit is quadratic for scattered deletes and for changing
the length of many strings in place (every later row or string is shifted each time), so a `DELETE` or a string
`UPDATE` that touches 20,000 or more rows rebuilds the table through a scratch view instead (linear;
`tests/bulkwrite.tcl` checks that both strategies give identical files): on 200,000 rows a scattered `DELETE` of half
went from 65 s to 2.3 s and a string `UPDATE` of every row from 56 s to 8 s.

## Safety: NULL, intervals and generated code

* **NULL cannot be forged.** Inside the engine NULL is a tagged value starting with U+FDD0, a Unicode
  *noncharacter*, and the engine keeps one invariant: no value ever contains that character. SQL text and
  parameters containing it are rejected, `CHR(64976)` refuses to create it, blobs are bytes, text read from a file has
  it replaced by U+FFFD (and a statement that read such a value refuses to write, so the replacement is never saved
  back), and string operations only rearrange characters they were given. Parameters are never interpreted: NULL is
  passed out of band (`nulls` argument), not as a magic string. `INTERVAL` values use the same prefix, so text like
  `'ivl:5'` is just text (`tests/nullforge.tcl`, 57 checks, including a randomised attempt to build the sentinel).
* **SQL is compiled to small Tcl procs, so every string-to-code boundary is guarded three ways.** Values enter the
  generated code only through `[list]` (one word, whatever it contains); `mkitsql/verify.tcl` then parses every
  generated proc and refuses to install it unless it consists only of the commands the compiler emits (checked by a
  mutation test: ~70,000 code injections, 17,000 of which would really run, none accepted); and `tests/lint.tcl`
  keeps an **inventory of every place that can turn a string into code or reach outside the process** (`eval`,
  `uplevel`, dynamic `proc` names, `open`, `source`...) with exact counts, so adding one fails CI until it is
  reviewed. Auditing this found and fixed two real bugs (a `LIKE` cache whose key could collide, and text beginning
  `ivl:` being taken for an interval).

## Verification

Run on **both of MK Studio's runtimes**, tclkit 8.6.3 and tclkit 8.5.17 (each with its own built-in Mk4tcl 2.4.9.7),
against **both storage layers**, and also on a Mk4tcl built from source and on the pure-Tcl stand-in.

| | result |
| --- | --- |
| Engine suite (`tests/run.tcl`), 566 checks | pass on both kits, both storage layers, real Metakit; also on the stand-in; also with `MKIT_BULKMIN=1` (every big delete/update rebuilds the table) |
| Same suite with tiny memory budgets (`MKIT_MEMBYTES=1..2000 MKIT_CHUNK=1..11`) | pass: every sort, group, join, distinct and DML spills, thousands of spill files, none left behind |
| Metakit-only checks (`tests/real_metakit.tcl`, 22) | pass: persistence across close/reopen, 64-bit values, binary, Unicode, nested subviews, every `ALTER`, drop/recreate |
| **Differential test against SQLite** (`tests/differential`) | more than 60,000 generated queries (about 10,000 window queries), 0 mismatches; repeated with a 50-byte memory budget |
| Code injection (`tests/injection.tcl`, 1,218 checks) and code-generation audit (`tests/codegen_audit.tcl`, 44 checks + mutation test) | hostile strings never run as code and round-trip exactly |
| `DROP TABLE` failure modes (`tests/dropview.tcl`, 34) | every way the row-clearing can fail (raises, silently does nothing, size unreadable, final delete fails) is injected on real Metakit: the drop is abandoned, the table keeps its rows, nothing is swallowed, and a re-created table is always empty (also after commit and reopen, with subviews) |
| Spilling exactness (`tests/spillroundtrip.tcl`, 265) | newlines, carriage returns, backslashes, braces, quotes, NUL-bearing blobs, emoji, 5,000-character values: 34 query shapes and 5 data-changing statements give identical results in memory and with 6 different tiny budgets |
| Robustness (`tests/robustness.tcl`, 569) | an error or a cancel in the middle of a sort, group, join, window, update, delete, insert, CTAS or merge leaves no temp file, no state and no scratch table, and changes nothing; a rebuild that fails half way is cleaned up; statements cannot nest; bad temp folder; read-only files; several databases; empty and one-row tables through 19 operator shapes; persistence after a rebuild |
| Stateful DML differential (`tests/differential/dml.py`) | thousands of random INSERT / INSERT..SELECT / UPDATE / DELETE / CREATE TABLE AS / DROP / COMMIT / ROLLBACK statements, affected-row count and full table contents compared with SQLite after every statement; also with every big write forced through the rebuild path and with everything spilling |
| Numeric edges, strings and `LIKE`, dates (`tests/differential/{numeric,strings,dates}.py`) | 32/64-bit boundaries, 1e300, negative zero; ~9,000 string-function and `LIKE ... ESCAPE` cases with regex metacharacters; ~11,000 date and interval calculations over years 0001-9999 checked against Python's calendar |
| NULL/interval forgery (`tests/nullforge.tcl`, 57) | no SQL text, parameter, stored value or function can produce NULL or an interval |
| Fuzzer (`tests/fuzz.tcl`) | more than 300,000 mutated statements: every failure is a clean engine error |
| A Metakit file we did not create (`tests/realworld.tcl`) | a tclkit's own boot database: nested tables, binary columns, joins, windows, subqueries |
| MK Studio's engine contract (38) and UI tests (16 + 41) | pass on both kits, real Metakit, on a freshly patched checkout |
| Memory (`tests/scale_memory.tcl`) | flat; see above |
| Lint: ASCII, no shadowed commands, nothing newer than the target runtimes, code-boundary inventory | clean |
| **Not tested** | Windows and macOS; tables of tens of millions of rows; the GitHub Actions workflow itself (never run, YAML validated only) |

Deliberate differences from SQLite (found by the differential test): `ROUND` rounds the decimal value (so
`ROUND(2.675, 2)` is `2.68`, as in PostgreSQL), `%` is for integers, typing is static (`COALESCE(int, real)` is
real), `LIKE` is case-sensitive, and `UPPER`/`LOWER` handle all of Unicode (SQLite only changes ASCII letters), casting a real to an integer rounds (SQLite truncates), and there is no negative zero (`-0.0` is `0.0`).

Two bugs in MK Studio's `store.tcl` showed up only on real Metakit: a dropped view stays listed until commit, and
`mk::view delete` leaves the rows behind (a table re-created under the same name came back **with its old rows**).
Both are handled in the storage layer and in [`integration/mkstudio.patch`](integration/mkstudio.patch).

## Tests

```sh
tclsh tests/run.tcl                       # 566 engine checks on the pure-Tcl stand-in   (glob to filter: 'join_*')
MKIT_BACKEND=standalone tclsh tests/run.tcl   # ... on the standalone storage layer (default: MK Studio's ::store)
MKIT_MEMBYTES=50 MKIT_CHUNK=3 tclsh tests/run.tcl   # tiny memory budget: everything spills
tclsh tests/lint.tcl                      # static checks + inventory of code boundaries
tclsh tests/doc_examples.tcl              # the examples in docs/SQL.md
python3 tests/differential/diff.py [--n 3000] [--seed 1] [--kind window]      # compare with SQLite
python3 tests/differential/diff.py --file tests/differential/recursive.sql
tclsh tests/injection.tcl                 # hostile strings must stay inert
tclsh tests/nullforge.tcl                 # NULL / interval cannot be forged
tclsh tests/codegen_audit.tcl             # generated code verifier + mutation test
tclsh tests/bulkwrite.tcl                 # big deletes/updates: rebuild strategy == row-by-row
tclsh tests/dropview.tcl                  # DROP TABLE failure injection
tclsh tests/spillroundtrip.tcl            # spilled results are exact
tclsh tests/robustness.tcl                # errors, cancels, atomicity, odd corners
python3 tests/differential/dml.py         # random DML sequences vs SQLite
python3 tests/differential/numeric.py     # numeric edge cases vs SQLite
python3 tests/differential/strings.py     # string functions / LIKE
python3 tests/differential/dates.py       # dates and intervals vs Python's calendar
tclsh tests/fuzz.tcl 40000 1              # mutated SQL must fail cleanly
MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/realworld.tcl tclkit/tclkit-8.5.17    # a Metakit file we did not create

tests/build_mk4tcl.sh /tmp/mk4build       # build the real Metakit + Mk4tcl (git, cmake, g++, tcl8.6-dev)
export LD_LIBRARY_PATH=/tmp/mk4build/build/src MKIT_MK4TCL=/tmp/mk4build/build/tcl/libMk4tcl.so
tclsh tests/run.tcl                       # the same suite on real Metakit
tclsh tests/real_metakit.tcl              # checks that only mean something on real Metakit
tclsh tests/scale.tcl 200000              # timings and memory
tclkit/tclkit-8.6.3 tests/scale_memory.tcl 200000 4194304   # bounded memory (MKIT_MK4TCL=builtin)

MKSTUDIO_DIR=/path/to/mkstudio tclsh tests/studio_contract.tcl                  # mkstudio's own engine contract
MKSTUDIO_DIR=/path/to/mkstudio xvfb-run wish tests/studio_integration.tcl       # the real UI, mkit-sql behind it
```

`MKIT_MK4TCL` selects the Mk4tcl used by every script: unset = stand-in, `builtin` = the running tclkit's, or a path
to a shared library. `.github/workflows/test.yml` runs all of the above.
`tests/vendor/` holds copies of MK Studio's `store.tcl` and the Mk4tcl stand-in (used only by tests).

## Layout

```
mkitsql/mkitsql.tcl       entry point (run, query, stream); mkitsql/pkgIndex.tcl for package require
mkitsql/parser.tcl        lexer + parser -> AST (errors carry {MKQL SYNTAX pos len})
mkitsql/bind.tcl          name resolution, * expansion, subqueries, CTEs, windows, type checks, column pruning
mkitsql/expr.tcl          expression compiler (SQL expression -> small Tcl proc), runtime functions, NULL marker
mkitsql/verify.tcl        checks every generated proc before it is installed
mkitsql/datetime.tcl      DATE / TIME / TIMESTAMP / INTERVAL
mkitsql/plan.tcl          planner: join planning, filter pushdown, lookup/scan caches, subquery runtime
mkitsql/exec.tcl          streaming executor: scans, joins, aggregation, DISTINCT, sort, windows, set ops, recursion
mkitsql/spill.tcl         memory budget, temp files, spools, external merge sort
mkitsql/window.tcl        window-function runtime
mkitsql/stmt.tcl          result shaping, INSERT/UPDATE/DELETE/MERGE, DDL, transactions
mkitsql/db.tcl            storage layer on Mk4tcl (standalone, default)
mkitsql/db_studio.tcl     the same interface forwarded to MK Studio's ::store
mkitsql/engine_studio.tcl adapter for MK Studio's ::engine seam
integration/              install-into-mkstudio.sh + mkstudio.patch
docs/SQL.md               the SQL reference
```

Only `db.tcl` and `db_studio.tcl` talk to Mk4tcl / `::store`.
