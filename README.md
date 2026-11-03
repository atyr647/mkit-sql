# mkit-sql

Standard SQL for [Metakit](https://www.equi4.com/metakit/) database files, written in pure Tcl.
It is the query engine for [MK Studio](https://github.com/atyr647/mkstudio) (it replaces the built-in
stand-in dialect), but it works on its own in any Tcl program that has Mk4tcl.

```tcl
source mkitsql/mkitsql.tcl      ;# needs MK Studio's ::store layer (store.tcl) to be loaded

set db [::store::openFile game.mk -create]
::mkitsql::run {CREATE TABLE players (id INT, name VARCHAR(20), score DOUBLE PRECISION,
                                      items TABLE (item TEXT, qty INT))} $db
::mkitsql::run {INSERT INTO players (id, name, score) VALUES (1, 'Ada', 9.5), (2, 'Bob', 7)} $db
::mkitsql::run {COMMIT} $db

set r [::mkitsql::query {SELECT name, score FROM players WHERE score > ? ORDER BY score DESC} $db {8}]
# -> cols {name score}  rows {{Ada 9.5}}
```

## Status

* **Tested against real Metakit** (Metakit 2.4.9.7 + Mk4tcl built from `tcltk/metakit`, Tcl 8.6): all 311
  engine checks, 22 Metakit-specific checks (persistence across close/reopen, 64-bit values, binary
  data, Unicode, nested subviews, every `ALTER`, drop/recreate) and the 16 MK Studio UI checks pass.
  The same engine checks also pass on the pure-Tcl stand-in. 20,000-row scans, grouping, sorting and
  joins take 45-80 ms.
* Real Metakit showed two bugs in MK Studio's `store.tcl` that its stand-in hid. `mkitsql/storefix.tcl`
  works around both (and should be folded into `store.tcl`):
  1. after a drop, `store::views` / `store::hasView` keep listing the dropped table until the next commit,
     so `DROP TABLE t; CREATE TABLE t ...` failed with "already exists";
  2. `store::dropView` leaves the rows behind, so a table re-created under the same name came back
     **with its old rows**.
* Written in Tcl 8.5 syntax (no `lmap`, `try`, ...) so it can run on classic tclkits, but only executed
  on Tcl 8.6. Your own tclkit's Mk4tcl is the one that matters: run the suites on it (below).

## What is supported

| Area | Supported |
| --- | --- |
| Queries | `SELECT [DISTINCT]`, `FROM` with aliases, `WHERE`, `GROUP BY` (expressions, ordinals, aliases), `HAVING`, `ORDER BY` (expressions, aliases, ordinals, `ASC/DESC`, `NULLS FIRST/LAST`), `LIMIT/OFFSET` and `OFFSET .. FETCH FIRST .. ROWS ONLY` |
| Joins | `INNER`, `LEFT`, `RIGHT`, `FULL`, `CROSS`, comma joins, `ON`, `USING`, `NATURAL`, self-joins. Equality conditions run as hash joins; `WHERE` filters are pushed down to the table scans |
| Subqueries | scalar, `IN`, `EXISTS`, correlated (equality correlations are hash-indexed), in `FROM` (derived tables) |
| Set operations | `UNION [ALL]`, `INTERSECT [ALL]`, `EXCEPT [ALL]`, `VALUES` lists, parenthesised queries |
| CTEs | `WITH name [(cols)] AS (...)`, multiple, non-recursive |
| Expressions | arithmetic, `\|\|`, comparisons, `AND/OR/NOT` with proper NULL logic, `IS [NOT] NULL/TRUE/FALSE`, `IS [NOT] DISTINCT FROM`, `BETWEEN`, `IN`, `LIKE/ILIKE ... ESCAPE`, `CASE` (both forms), `CAST`, `COALESCE`, `NULLIF`, `GREATEST/LEAST`, blob literals `X'CAFE'`, parameters `?` and `:name` |
| Aggregates | `COUNT(*)`, `COUNT/SUM/AVG/MIN/MAX([DISTINCT] x)`, `STRING_AGG(x, sep)` |
| Functions | ~60: math (`ABS ROUND FLOOR CEIL POWER SQRT MOD LN EXP SIN..`), text (`UPPER LOWER LENGTH SUBSTRING TRIM POSITION REPLACE LEFT RIGHT LPAD REPEAT CONCAT..`), date (`CURRENT_DATE/TIME/TIMESTAMP`, `EXTRACT`) - `::mkitsql::functions` lists them |
| Data changes | `INSERT` (`VALUES`, `SELECT`, `DEFAULT VALUES`), `UPDATE`, `DELETE`, `TRUNCATE` |
| Schema | `CREATE TABLE [IF NOT EXISTS]` (also `AS SELECT`), `DROP TABLE [IF EXISTS]`, `ALTER TABLE` add / drop / rename column, change type, rename table |
| Transactions | `BEGIN`, `COMMIT`, `ROLLBACK` (see below) |
| Introspection | `information_schema.tables`, `information_schema.columns` |
| MK Studio extras | `USE db`, `SHOW TABLES`, `SHOW DATABASES`, `DESCRIBE table` |

Every write statement is all-or-nothing: all values are validated and converted before anything is
written, so a bad value in row 500 does not leave 499 rows half-applied.

## Deliberately left out - and why

These are parts of SQL that either have nothing to map to in Metakit or are not worth their cost yet.
Each one gives a clear error rather than being silently ignored.

| Left out | Reason |
| --- | --- |
| `PRIMARY KEY`, `UNIQUE`, `FOREIGN KEY`, `CHECK`, `NOT NULL`, `DEFAULT`, `AUTOINCREMENT` | Metakit stores no constraints or defaults, and there is nowhere to persist them. `NOT NULL` would be a lie because rows can never hold NULL. (`::mkitsql::ignoreConstraints 1` parses and drops them so existing scripts still run.) |
| `CREATE INDEX` / `DROP INDEX` | Metakit has no secondary indexes. |
| SQL `VIEW`s | In Metakit "view" means *table*. Use `CREATE TABLE ... AS SELECT` for a snapshot. |
| Triggers, stored procedures, `GRANT/REVOKE`, users, roles, locking, isolation levels, cursors | Metakit is a single-process embedded file; none of this exists. |
| `UPSERT` / `ON CONFLICT` / `MERGE` | Needs keys, which Metakit does not have. |
| `SELECT TOP n` | T-SQL only. Use `LIMIT n` or `FETCH FIRST n ROWS ONLY`. |
| Row-value constructors `(a, b) IN ...` | Rarely used. |

**Not done yet** (useful, just not built): window functions (`OVER`), `WITH RECURSIVE`, `FILTER (WHERE ..)` on
aggregates, `ANY/ALL/SOME` quantified comparisons, `INSERT ... RETURNING`, `UPDATE ... FROM`, date
arithmetic and `INTERVAL`, `COLLATE`, savepoints.

## How SQL maps onto Metakit

* **Tables** are Metakit views. **Subviews** (a column that is itself a table) are first-class:
  * `SELECT * FROM employees` shows a subview column as a count (`> 2 rows`) you can drill into;
    `WHERE skills >= 3` compares that count.
  * Unnest with a lateral join: `FROM employees e JOIN e.skills s ON s.level > 3` (also `LEFT JOIN`).
  * Address one row's subview directly: `FROM employees[3].skills` (also for `INSERT/UPDATE/DELETE`).
  * Create one: `CREATE TABLE t (id INT, kids TABLE (name TEXT, age INT))`.
* **Types**: `INT/SMALLINT` -> 32-bit integer, `BIGINT` -> 64-bit integer, `REAL` -> 32-bit float,
  `DOUBLE/FLOAT/DECIMAL/NUMERIC` -> 64-bit float (`DECIMAL` is *not* exact), `VARCHAR/CHAR/TEXT` -> string,
  `BLOB/BINARY` -> bytes, `BOOLEAN` -> integer 0/1, `DATE/TIME/TIMESTAMP` -> ISO-8601 text. Values are
  range-checked on write (an `INT` column rejects 3000000000 and tells you to use `BIGINT`).
* **NULL**: Metakit has no NULL. NULLs exist while a query runs (`LEFT JOIN`, `SELECT NULL`, `SUM` of nothing)
  and follow standard three-valued logic. Writing a NULL stores the column default (`0` or empty text), so
  `WHERE col IS NULL` never matches stored data. Result grids show NULL as `NULL`
  (`::mkitsql::nullText`).
* **Typing is standard**: `7 / 2` is `3` (integer division), `'2' < '10'` is false (text comparison),
  `LIKE` is case-sensitive (use `ILIKE`), text sorts in binary order.
* **Transactions**: files are opened `-nocommit`, so changes stay in memory until `COMMIT`; `ROLLBACK` discards
  them. `BEGIN` is accepted but is not needed. `COMMIT`/`ROLLBACK` without a name apply to every open
  database with pending changes; `COMMIT db` targets one. Set `::mkitsql::autocommit 1` to commit after each
  successful write statement.
* **Names** are case-insensitive. Because Metakit keeps names in layout strings, table and column names
  may only contain letters, digits and underscores. Quoted names may still be reserved words
  (`"select"`).
* Renaming or retyping a column moves it to the end of the table (a Metakit limitation, same as in MK Studio).

## Using it in MK Studio

MK Studio's query window calls only `parseScript` and `execStatement`, so the swap is two lines. In
`mkstudio.vfs/lib/app-mkstudio/loader.tcl`, load `store` first, then:

```tcl
source /path/to/mkit-sql/mkitsql/mkitsql.tcl
source /path/to/mkit-sql/mkitsql/mkql_compat.tcl     ;# maps ::mkql::* (cancel, maxRows, keywords, ...) onto mkit-sql
```

and drop `mkql` from the list of files. `tests/studio_integration.tcl` does exactly this to a scratch copy and
drives the real UI headlessly (result grids, multiple result tabs, subview drill-down, dirty tracking,
rollback, error underlining, row cap).

Things in MK Studio that still refer to the old dialect and should be updated: the sample script in
`app.tcl` uses `SELECT TOP 10` (use `LIMIT 10`), and the in-app help text in `docs.tcl`.

## Tests

```sh
tclsh tests/run.tcl                       # 311 engine checks on the pure-Tcl Mk4tcl stand-in
                                          #   (add a glob to run some: tclsh tests/run.tcl 'join_*')

tests/build_mk4tcl.sh /tmp/mk4build       # builds the real Metakit + Mk4tcl (git, cmake, g++, tcl8.6-dev)
export LD_LIBRARY_PATH=/tmp/mk4build/build/src MKIT_MK4TCL=/tmp/mk4build/build/tcl/libMk4tcl.so
tclsh tests/run.tcl                       # the same 311 checks on real Metakit
tclsh tests/real_metakit.tcl              # 22 checks that only mean something on real Metakit
MKSTUDIO_DIR=/path/to/mkstudio xvfb-run wish tests/studio_integration.tcl     # 16 checks driving the real MK Studio UI
```

`tests/vendor/` holds copies of MK Studio's `store.tcl` and the Mk4tcl stand-in (from mkstudio commit
`abad5c9`).

## Layout

```
mkitsql/mkitsql.tcl      entry point: run, query
mkitsql/parser.tcl       lexer + parser -> AST (errors carry {MKQL SYNTAX pos len} for editor underlining)
mkitsql/bind.tcl         name resolution, * expansion, type checks, column pruning
mkitsql/expr.tcl         expression compiler (SQL expression -> small Tcl proc) and runtime functions
mkitsql/plan.tcl         planner + executor: scans, hash joins, filter pushdown, aggregation, sorting, set ops
mkitsql/stmt.tcl         result shaping, INSERT/UPDATE/DELETE, DDL, transactions
mkitsql/mkql_compat.tcl  drop-in layer for MK Studio
mkitsql/storefix.tcl     workarounds for two store.tcl bugs found on real Metakit
```

The only file that talks to Mk4tcl is MK Studio's `store.tcl`; mkit-sql calls just `::store::` `tags views
layout size rows subSize appendRow setCell deleteRows createView dropView restructure rebuildColumn commit
rollback dirty readonly`.
