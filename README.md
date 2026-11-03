# mkit-sql

Standard SQL for [Metakit](https://www.equi4.com/metakit/) database files, in pure Tcl. It is the query engine for
[MK Studio](https://github.com/atyr647/mkstudio) and also works on its own in any Tcl program that has Mk4tcl.

```tcl
lappend auto_path /path/to/mkit-sql                      ;# the directory that contains mkitsql/
package require mkitsql                                  ;# needs MK Studio's ::store layer (store.tcl)

set db [::store::openFile game.mk -create]
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

Deliberately **not** supported (Metakit has no equivalent): `PRIMARY KEY` / `UNIQUE` / `FOREIGN KEY` / `CHECK` /
`NOT NULL` / `DEFAULT`, indexes, SQL views, triggers, permissions, savepoints, upsert (use `MERGE`). Also not built
yet: `ROLLUP/CUBE/GROUPING SETS`, `COLLATE`, `SIMILAR TO`. See [Not supported](docs/SQL.md#not-supported).

Things that differ from what you may be used to: Metakit has **no NULL** (NULLs exist only while a query runs;
storing one writes `0` / empty text), `DECIMAL` is a double (not exact), integer `/` truncates (`7 / 2` is `3`),
`LIKE` is case-sensitive, and a column rename moves the column to the end (a Metakit limitation).

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
rows). `mkitsql/engine_studio.tcl` is the adapter. On a patched fresh clone, MK Studio's own lint, its 38-check
engine contract and its 41 UI-logic checks all pass.

## Verification

Everything below was run on **both of MK Studio's runtimes**, tclkit 8.6.3 and tclkit 8.5.17 (each with its own
built-in Mk4tcl 2.4.9.7), and also on a Mk4tcl built from source and on the pure-Tcl stand-in.

| | result |
| --- | --- |
| Engine suite, 526 checks | pass on both kits against **real Metakit**, and on the stand-in |
| Metakit-only checks (`tests/real_metakit.tcl`, 22) | pass: persistence across close/reopen, 64-bit values, binary, Unicode, nested subviews, every `ALTER`, drop/recreate |
| **Differential test against SQLite** (`tests/differential`) | more than 60,000 generated queries (about 10,000 of them window queries), 0 mismatches; recursive CTEs and row values checked too. Differences are deliberate (below) |
| **Code injection** (`tests/injection.tcl`, 1,218 checks) | hostile strings (`[exit 7]`, `}[set x 1]{`, backslashes, braces, NULs...) used as literals, parameters, aliases and stored data never run as code and always round-trip exactly |
| **Fuzzer** (`tests/fuzz.tcl`) | more than 300,000 mutated statements: every failure is a clean engine error, none is a raw Tcl error |
| **A Metakit file we did not create** (`tests/realworld.tcl`) | a tclkit's own boot database: nested tables, binary columns, joins, windows, subqueries - all work |
| MK Studio's engine contract (38) and UI tests (16 + 41) | pass on both kits, real Metakit |
| 200,000 rows on real Metakit (`tests/scale.tcl`) | most queries 0.2-1.5 s, heaviest 3.4 s, 185-229 MB peak |
| Lint: ASCII, no shadowed commands, nothing newer than the target runtimes | clean |
| **Not tested** | Windows and macOS; files far larger than memory allows (see below); the GitHub Actions workflow itself (never run, YAML validated only) |

The engine is **in-memory per query**: scans, sorts and joins hold their rows in Tcl lists, so a query's working set
must fit in RAM (about 1 KB per row at 5 columns; 200,000 rows peaked at 229 MB). Plain `LIMIT` queries and
equality lookups stop early, but a full `ORDER BY` over millions of rows will not fit.

Deliberate differences from SQLite (found by the differential test): `ROUND` rounds the decimal value (so
`ROUND(2.675, 2)` is `2.68`, as in PostgreSQL), `%` is for integers, typing is static (`COALESCE(int, real)` is
real), and `LIKE` is case-sensitive.

Two bugs in MK Studio's `store.tcl` showed up only on real Metakit. One is fixed in current MK Studio (a dropped
view stays listed until commit); the other is not, so [`mkitsql/storefix.tcl`](mkitsql/storefix.tcl) and the
mkstudio patch fix it: `mk::view delete` leaves the rows behind, so a table re-created under the same name came back
**with its old rows**.

## Tests

```sh
tclsh tests/run.tcl                       # 526 engine checks on the pure-Tcl stand-in   (glob to filter: 'join_*')
tclsh tests/lint.tcl                      # static checks
tclsh tests/doc_examples.tcl              # the examples in docs/SQL.md
python3 tests/differential/diff.py [--n 3000] [--seed 1] [--kind window]      # compare with SQLite
python3 tests/differential/diff.py --file tests/differential/recursive.sql
tclsh tests/injection.tcl                 # hostile strings must stay inert
tclsh tests/fuzz.tcl 40000 1              # mutated SQL must fail cleanly
MKIT_MK4TCL=builtin tclkit/tclkit-8.6.3 tests/realworld.tcl tclkit/tclkit-8.5.17    # a Metakit file we did not create

tests/build_mk4tcl.sh /tmp/mk4build       # build the real Metakit + Mk4tcl (git, cmake, g++, tcl8.6-dev)
export LD_LIBRARY_PATH=/tmp/mk4build/build/src MKIT_MK4TCL=/tmp/mk4build/build/tcl/libMk4tcl.so
tclsh tests/run.tcl                       # the same suite on real Metakit
tclsh tests/real_metakit.tcl              # checks that only mean something on real Metakit
tclsh tests/scale.tcl 200000              # timings and memory

MKSTUDIO_DIR=/path/to/mkstudio tclsh tests/studio_contract.tcl                  # mkstudio's own engine contract
MKSTUDIO_DIR=/path/to/mkstudio xvfb-run wish tests/studio_integration.tcl       # the real UI, mkit-sql behind it
```

`MKIT_MK4TCL` selects the Mk4tcl used by every script: unset = stand-in, `builtin` = the running tclkit's, or a path
to a shared library. `.github/workflows/test.yml` runs all of the above.
`tests/vendor/` holds copies of MK Studio's `store.tcl` and the Mk4tcl stand-in.

## Layout

```
mkitsql/mkitsql.tcl       entry point (run, query); mkitsql/pkgIndex.tcl for package require
mkitsql/parser.tcl        lexer + parser -> AST (errors carry {MKQL SYNTAX pos len})
mkitsql/bind.tcl          name resolution, * expansion, subqueries, CTEs, windows, type checks, column pruning
mkitsql/expr.tcl          expression compiler (SQL expression -> small Tcl proc) and runtime functions
mkitsql/datetime.tcl      DATE / TIME / TIMESTAMP / INTERVAL
mkitsql/plan.tcl          planner + executor: scans, hash joins, filter pushdown, aggregation, sorting, set ops, recursion
mkitsql/window.tcl        window-function runtime
mkitsql/stmt.tcl          result shaping, INSERT/UPDATE/DELETE/MERGE, DDL, transactions
mkitsql/engine_studio.tcl adapter for MK Studio's ::engine seam
mkitsql/storefix.tcl      workaround for Metakit's drop behaviour
integration/              install-into-mkstudio.sh + mkstudio.patch
docs/SQL.md               the SQL reference
```

The only file that talks to Mk4tcl is MK Studio's `store.tcl`; mkit-sql calls just `::store::` `tags views layout size
rows subSize appendRow setCell deleteRows createView dropView restructure rebuildColumn commit rollback dirty
readonly`.
