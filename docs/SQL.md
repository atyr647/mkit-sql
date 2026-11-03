# mkit-sql reference

Standard SQL for Metakit. Everything below is implemented and covered by tests; where behaviour follows
PostgreSQL rather than SQLite or MySQL, it says so. Examples use the sample database that MK Studio creates
(`employees`, `departments`, `orders`, `products`).

* [Types and NULL](#types-and-null)
* [Queries](#queries)
* [Joins](#joins) - [Subqueries](#subqueries) - [Set operations and CTEs](#set-operations-and-ctes)
* [Aggregates and window functions](#aggregates-and-window-functions)
* [Expressions and functions](#expressions-and-functions)
* [Dates and intervals](#dates-and-intervals)
* [Changing data](#changing-data): INSERT, UPDATE, DELETE, MERGE
* [Changing structure](#changing-structure): CREATE, DROP, ALTER
* [Transactions](#transactions) - [Subviews](#subviews-nested-tables) - [Introspection](#introspection)
* [Parameters](#parameters) - [Errors](#errors) - [Not supported](#not-supported)

## Types and NULL

| SQL type | Metakit column | Notes |
| --- | --- | --- |
| `INT`, `INTEGER`, `SMALLINT`, `TINYINT` | `I` (32-bit) | writing a bigger value is an error that suggests `BIGINT` |
| `BIGINT` | `L` (64-bit) | |
| `REAL` | `F` (32-bit float) | low precision; a value beyond about 3.4e38 is an error (it would be stored as infinity) |
| `DOUBLE PRECISION`, `FLOAT`, `DECIMAL`, `NUMERIC` | `D` (64-bit float) | **`DECIMAL`/`NUMERIC` are not exact** |
| `BOOLEAN` | `I` (0/1) | `TRUE` / `FALSE` literals |
| `VARCHAR(n)`, `CHAR(n)`, `TEXT` | `S` | the length is ignored |
| `BLOB`, `BINARY` | `B` | literals: `X'CAFE'` |
| `DATE`, `TIME`, `TIMESTAMP` | `S` (ISO-8601 text) | see [Dates](#dates-and-intervals) |

**NULL.** Metakit has no NULL, so a stored value is never NULL. NULLs appear while a query runs (`LEFT JOIN`,
`SELECT NULL`, `SUM` of no rows, `NULLIF`, ...) and obey standard three-valued logic. Writing a NULL stores the
column default (`0` or empty text), so `WHERE col IS NULL` never matches stored rows. Result grids show NULL
as `NULL` (`::mkitsql::nullText`). NULL cannot be forged: inside the engine it is a tagged value built on
U+FDD0 (a Unicode *noncharacter*), and no value can ever contain that character: it is rejected in SQL text and
parameters, `CHR(64976)` refuses to create it, and text read from a file has it replaced by U+FFFD (a statement
that read such a value will not write, so the replacement is never saved). `INTERVAL` values use the same prefix, so
text such as `'ivl:5'` is just text.

**Typing is static and standard.** `7 / 2` is `3`; `'2' < '10'` is false (text comparison); text and numbers
compare as numbers when the text is numeric; `LIKE` is case-sensitive (`ILIKE` is not); text sorts by code
point; a number or `0`/`1` can stand in for a condition (`WHERE active`).

## Queries

```sql
SELECT [DISTINCT] item [, ...]
FROM source [, ...]
[WHERE cond] [GROUP BY expr|position|alias [, ...]] [HAVING cond]
[WINDOW name AS (spec) [, ...]]
[ORDER BY expr|position|alias [ASC|DESC] [NULLS FIRST|LAST] [, ...]]
[LIMIT n [OFFSET m]]  |  [OFFSET m ROWS] [FETCH FIRST n ROWS ONLY]
```

Items are `*`, `alias.*` or `expr [[AS] alias]`. Names are case-insensitive; use `"quotes"` for reserved words.
`SELECT 1 + 2` needs no `FROM`. `ORDER BY` / `GROUP BY` accept output aliases and 1-based positions.
Only the columns a query uses are read from Metakit.

## Joins

`INNER`, `LEFT`, `RIGHT`, `FULL`, `CROSS`, comma joins, `ON`, `USING (cols)`, `NATURAL`, self-joins, any number
of tables. Equality conditions between the two sides run as **hash joins**; `WHERE` conditions are applied to
each table's scan before joining (never across an outer join's nullable side).

```sql
SELECT e.name, d.name FROM employees e JOIN departments d ON d.id = e.dept;
SELECT d.name, COUNT(e.id) FROM departments d LEFT JOIN employees e ON e.dept = d.id GROUP BY d.name;
```

**`LATERAL`** lets a subquery use columns of the tables to its left - the standard way to write top-N-per-group:

```sql
SELECT d.name, t.name, t.salary
FROM departments d
CROSS JOIN LATERAL (SELECT name, salary FROM employees e
                    WHERE e.dept = d.id ORDER BY salary DESC LIMIT 2) t;
```

`LEFT JOIN LATERAL (...) ON TRUE` keeps rows with no match. `RIGHT`/`FULL` with `LATERAL` is not supported.

## Subqueries

Scalar `(SELECT ...)`, `[NOT] IN (SELECT ...)`, `[NOT] EXISTS (SELECT ...)`, `op ANY|SOME|ALL (SELECT ...)`,
derived tables `FROM (SELECT ...) alias [(cols)]`, correlated at any depth, also inside `GROUP BY` queries
(which may refer to the grouped columns). Row values work too: `(a, b) = (1, 2)`, `(a, b) < (...)`,
`(a, b) IN ((1, 2), (3, 4))`, `(a, b) IN (SELECT x, y ...)`.

A correlated subquery whose condition has the form `inner.col = <outer expression>` becomes a hash lookup
built once per statement; other correlated forms re-filter a cached copy of the inner table (so they cost
rows x rows, as in any engine without indexes).

A subquery may also unnest a subview of the *enclosing* row: `WHERE (SELECT COUNT(*) FROM d.files) > 5`,
`EXISTS (SELECT 1 FROM e.skills s WHERE s.level = 5)`.

## Set operations and CTEs

`UNION [ALL]`, `INTERSECT [ALL]`, `EXCEPT [ALL]` (`INTERSECT` binds tighter), `VALUES (...), (...)`,
parenthesised queries, and `ORDER BY`/`LIMIT` over the result by column name or position.

```sql
WITH recent AS (SELECT * FROM orders WHERE id > 1010), c(n) AS (SELECT COUNT(*) FROM recent)
SELECT n FROM c;

WITH RECURSIVE nums(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM nums WHERE x < 10)
SELECT x FROM nums;
```

A CTE sees only the CTEs defined before it, never itself (that needs `RECURSIVE`).
`WITH RECURSIVE` evaluates round by round; `UNION` (not `ALL`) drops repeated rows, which also stops cycles. A
plain `LIMIT` over a recursive query stops the recursion early. A runaway recursion stops after
`::mkitsql::maxRecursion` rounds (default 100000) with an error that says what to add.

## Aggregates and window functions

Aggregates: `COUNT(*)`, `COUNT/SUM/AVG/MIN/MAX([DISTINCT] x)`, `STRING_AGG(x, sep)` (`GROUP_CONCAT`), each with
an optional `FILTER (WHERE cond)`. `HAVING` without `GROUP BY` treats the whole input as one group.

Window functions: `ROW_NUMBER`, `RANK`, `DENSE_RANK`, `PERCENT_RANK`, `CUME_DIST`, `NTILE(n)`,
`LAG/LEAD(x [, offset [, default]])`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE(x, n)`, and every aggregate
above as `agg(...) OVER (...)`.

```sql
SELECT name, dept, salary,
       RANK() OVER (PARTITION BY dept ORDER BY salary DESC)                 AS rank_in_dept,
       SUM(salary) OVER (PARTITION BY dept ORDER BY id)                     AS running,
       AVG(salary) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) AS moving_avg
FROM employees;

SELECT id, SUM(salary) OVER w FROM employees WINDOW w AS (PARTITION BY dept ORDER BY id);
```

Frames: `ROWS`, `RANGE` (offsets need exactly one numeric `ORDER BY` column) and `GROUPS`, with `UNBOUNDED
PRECEDING/FOLLOWING`, `n PRECEDING/FOLLOWING` and `CURRENT ROW`. The default frame is the standard one (up to
the last peer row with `ORDER BY`, the whole partition without). Windows may be used in the select list and
`ORDER BY` only, and may wrap aggregates: `RANK() OVER (ORDER BY SUM(x))`. Not supported: `EXCLUDE`,
`DISTINCT` inside a window aggregate.

## Expressions and functions

Operators: `+ - * / %`, `||`, `= <> < <= > >=`, `AND OR NOT`, `IS [NOT] NULL | TRUE | FALSE | DISTINCT FROM`,
`[NOT] BETWEEN`, `[NOT] IN`, `[NOT] LIKE | ILIKE [ESCAPE c]`, `CASE` (both forms), `CAST(x AS type)` (a real cast to an integer type *rounds* to the nearest whole number, halves away from zero, as in PostgreSQL and MySQL; SQLite truncates). There is no negative zero: `-0.0` is `0.0` everywhere (grouping, sorting, joins, storage).
Integer `/` truncates toward zero; `%` takes the sign of the left side; division by zero is an error.
`AND`/`OR`/`CASE` evaluate lazily, so `WHERE b <> 0 AND a / b > 1` is safe.

Functions: ABS, ACOS, ASCII, ASIN, ATAN, ATAN2, CEIL/CEILING, CHAR_LENGTH/CHARACTER_LENGTH, CHR, COALESCE, CONCAT,
CONCAT_WS, COS, CURRENT_DATE/TIME/TIMESTAMP, DEGREES, EXP, EXTRACT, FLOOR, GREATEST, IFNULL, INITCAP, INSTR, LEAST,
LEFT, LENGTH, LN, LOCALTIME/LOCALTIMESTAMP, LOG10, LOWER, LPAD, LTRIM, MOD, NOW, NULLIF, NVL, OCTET_LENGTH, PI,
POSITION, POW/POWER, RADIANS, RANDOM, REPEAT, REPLACE, REVERSE, RIGHT, ROUND, RPAD, RTRIM, SIGN, SIN, SQRT, SUBSTR/
SUBSTRING, TAN, TRIM, TRUNC/TRUNCATE, UPPER. `TRIM([LEADING|TRAILING|BOTH] [chars] FROM x)`,
`SUBSTRING(x FROM a FOR n)`, `POSITION(a IN b)` and `EXTRACT(field FROM x)` use the standard syntax.

`ROUND`, `TRUNC`, `CEIL` and `FLOOR` return a real. `ROUND` rounds the number as written (ties away from zero),
so `ROUND(2.675, 2)` is `2.68` and `ROUND(2.5)` is `3.0`.

## Dates and intervals

Dates are ISO-8601 text, so they sort and compare correctly. Typed literals: `DATE '2026-03-05'`,
`TIME '14:30:00'`, `TIMESTAMP '2026-03-05 14:30:00'`; `CAST(col AS DATE)` converts a text column.
`CURRENT_DATE`, `CURRENT_TIME`, `CURRENT_TIMESTAMP`, `NOW()`, `EXTRACT(YEAR|MONTH|DAY|HOUR|MINUTE|SECOND|DOW|DOY|EPOCH FROM x)`.

`INTERVAL` literals: `INTERVAL '5' DAY`, `INTERVAL '1-2' YEAR TO MONTH`, `INTERVAL '3 04:05:06' DAY TO SECOND`,
or PostgreSQL text such as `INTERVAL '2 hours 30 minutes'`.

```sql
SELECT DATE '2026-01-31' + INTERVAL '1' MONTH;          -- 2026-02-28 (clamps to month end)
SELECT TIMESTAMP '2026-03-05 23:30:00' + INTERVAL '45' MINUTE;   -- 2026-03-06 00:15:00
SELECT DATE '2026-03-05' - DATE '2026-01-01';           -- 63 days  (an interval)
SELECT EXTRACT(DAY FROM DATE '2026-03-05' - DATE '2026-01-01');  -- 63
```

`date +/- interval`, `date - date`, `interval +/- interval`, `interval * n`, `interval / n`, interval
comparison and sorting work. A day counts as 24 hours. Intervals cannot be stored in a column (store
seconds, or `CAST(iv AS VARCHAR)`), and `SUM`/`AVG`/`MIN`/`MAX` over intervals are not supported. To do date
arithmetic on a text column, cast it first: `CAST(hired AS DATE) + INTERVAL '7' DAY`.

## Changing data

```sql
INSERT INTO t [(cols)] VALUES (...), (...);   INSERT INTO t [(cols)] SELECT ...;   INSERT INTO t DEFAULT VALUES;
UPDATE t [alias] SET col = expr [, ...] [WHERE cond];
DELETE FROM t [alias] [WHERE cond];           TRUNCATE [TABLE] t;
```

Every write is **all-or-nothing**: all values are validated and converted before anything is written, so one bad
value cannot leave a half-applied statement. Values are range-checked (`INT` rejects 3000000000) and converted
(`'42'` into an `INT` column is fine, `'many'` or `1.5` is an error). `UPDATE ... SET a = b, b = a` swaps.

```sql
MERGE INTO stock s USING incoming i ON s.sku = i.sku
  WHEN MATCHED AND i.qty = 0 THEN DELETE
  WHEN MATCHED THEN UPDATE SET qty = s.qty + i.qty
  WHEN NOT MATCHED THEN INSERT (sku, qty) VALUES (i.sku, i.qty);
```

`MERGE` needs no keys - the `ON` condition does the matching. The source may be a table, `(subquery) alias` or
`(VALUES ...) AS v(cols)`. It is an error if one target row is matched by more than one source row.

## Changing structure

```sql
CREATE TABLE [IF NOT EXISTS] t (col type, ..., sub TABLE (col type, ...));    CREATE TABLE t AS SELECT ...;
DROP TABLE [IF EXISTS] t;
ALTER TABLE t ADD [COLUMN] col type | DROP [COLUMN] col | RENAME [COLUMN] a TO b
           | RENAME TO new_name;
```

Names may only contain letters, digits and underscores, and may not start with `__mks` (reserved for the scratch views
and columns the engine and MK Studio create and delete themselves). Renaming a column moves it to the end of the table
(Metakit limitation). Renaming a table copies it (subviews included).

**`ALTER COLUMN ... TYPE` is refused, on purpose.** Metakit identifies a column by name *and* type; changing the type
under the same name makes it keep the old storage, and on real Metakit that corrupted data and could hang the file on
close. The error shows the safe recipe: add a new column, fill it with `CAST`, drop the old one, rename if wanted. The
same Metakit rule applies to dropping a table or column and re-creating the name with another type in the same open
file: while changes are pending the engine refuses with a clear message (`COMMIT`, then close and reopen, or reopen
automatically when nothing is pending and the engine owns the file) instead of letting the file be damaged.
`PRIMARY KEY`, `UNIQUE`, `FOREIGN KEY`, `CHECK`, `NOT NULL`, `DEFAULT` are rejected with a clear message because
Metakit stores none of them; `::mkitsql::ignoreConstraints 1` parses and drops them instead.

## Transactions

Files are opened `-nocommit`, so changes stay in memory until `COMMIT`; `ROLLBACK` discards them. `BEGIN` is
accepted but unnecessary. `COMMIT`/`ROLLBACK` without a name apply to every open database that has pending
changes; `COMMIT db` targets one. `::mkitsql::autocommit 1` commits after each successful write statement.
There are no savepoints (Metakit can only roll back to the last commit).

## Subviews (nested tables)

A column that is itself a table is a *subview*.

```sql
CREATE TABLE people (id INT, name TEXT, pets TABLE (pet TEXT, age INT));
SELECT * FROM people;                    -- the pets column shows as a row count
SELECT name FROM people WHERE pets > 1;  -- compares that count
SELECT p.name, x.pet FROM people p JOIN p.pets x ON x.age > 2;   -- unnest (also LEFT JOIN)
SELECT * FROM people[3].pets;            -- one row's subview (row numbers start at 0)
INSERT INTO people[0].pets (pet, age) VALUES ('Rex', 3);   -- UPDATE / DELETE work too
```

## Introspection

`information_schema.tables` (table_catalog, table_name, table_type, row_count) and `information_schema.columns`
(table_catalog, table_name, column_name, ordinal_position, data_type, metakit_type). MK Studio extras:
`SHOW TABLES [db]`, `SHOW DATABASES`, `DESCRIBE table`, `USE db`. `_rowid` is a pseudo-column holding a row's
Metakit index.

## Parameters

`?` (positional) and `:name`. Pass a list for positional parameters or a dict for named ones:

```tcl
::mkitsql::query {SELECT * FROM employees WHERE dept = ? AND salary > ?} $db {3 50000}
::mkitsql::query {SELECT * FROM employees WHERE name = :n} $db {n Ada}
```

Parameters are values, never SQL text, so they cannot inject SQL. To pass NULL, name the parameter in the
`nulls` argument (positions for `?`, names for `:name`); no text value, however it is spelled, ever becomes NULL:

```tcl
::mkitsql::query {SELECT ? IS NULL, ? IS NULL} $db {a b} {} {2}      ;# -> {0 1}
```

## Large tables and memory

A query never has to fit in memory. Scans are read in chunks and every operator that has to hold rows (sort,
`GROUP BY`, `DISTINCT` and `DISTINCT` aggregates, joins, `UNION/INTERSECT/EXCEPT`, windows over big inputs, and
the row sets that `INSERT ... SELECT`, `UPDATE`, `MERGE` and `CREATE TABLE AS` build before touching the file) is
limited by `::mkitsql::memBytes` (default 32 MB per operator) and spills to temporary files beyond that
(`::mkitsql::tempDir`, default the system temp directory; removed after every statement). Use `stream` to
process a result without ever holding it:

```tcl
proc onRows {rows} { foreach r $rows { ... } ; return 0 }          ;# return 1 to stop (after this chunk)
::mkitsql::stream {SELECT * FROM big ORDER BY name} $db {} onRows
```

`query` and `run` return the whole result (at most `::mkitsql::maxRows` rows are kept; the result says
`truncated`). What is still held in memory, by design: one *partition* of a window function that does not fit
(a single partition larger than memory), the value set of an `IN (SELECT ...)` (capped at 5,000,000 values with a
clear error), the row ids of a `DELETE`, and the final text of `STRING_AGG`.

Metakit shifts every later row when a row is deleted and every later string when a string changes length, so
scattered deletes and string updates are quadratic there. A `DELETE` or a string `UPDATE` touching
`::mkitsql::bulkMin` (20,000) or more rows therefore rebuilds the table through a scratch view instead (linear).

## Storage layer

The engine reaches Metakit only through `::mkitsql::db` (`mkitsql/db.tcl`, directly on Mk4tcl, no MK Studio
needed). Inside MK Studio, `mkitsql/db_studio.tcl` forwards the same interface to MK Studio's `::store` so both
share the open files. `mk::view delete` leaves a view's rows behind, so `dropView` empties the view first, checks
that it is empty, and only then deletes it; **any failure while emptying aborts the drop with the original error and
the table keeps all its rows** (nothing is caught). If the final delete itself fails the error is reported and the
table is left empty (never with its old rows); `ROLLBACK` restores everything either way. `tests/dropview.tcl` injects
each of these failures on real Metakit.

```tcl
package require mkitsql                                   ;# standalone: loads Mk4tcl itself
set db [::mkitsql::db::openFile game.mk -create]
```

## Query planning, `EXPLAIN` and indexes

`EXPLAIN [QUERY PLAN] <query>` shows how a query would run and runs nothing: the scans, which conditions Metakit
decides itself, the join method (hash join / sort-merge / nested loop), and the aggregate, sort and limit stages.

```sql
EXPLAIN SELECT name FROM employees WHERE id = 5;
--   SCAN demo.employees (20 rows) - METAKIT-SIDE NARROWING (exact id 5); remaining conditions tested on the candidates
```

What the planner does:

* **Metakit-side narrowing.** Top-level `AND` conditions of the form `column = / < / <= / > / >= constant`,
  `BETWEEN`, and `IN (constants)` on number and text columns are handed to Metakit's own `mk::select`, which tests the
  column in C. Only the rows that can match are read, and the complete `WHERE` is still evaluated on them, so this can
  only ever skip rows that cannot match. Applies to tables of at least `::mkitsql::pushMin` (500) rows, and to
  `UPDATE` / `DELETE` too. On a table of 1,000,000 rows `WHERE id = 777777` takes 0.1 s instead of 3.8 s; a range
  takes about 0.6 s. (`::mkitsql::pushdown 0` turns it off.)
* **`COUNT(*)` of a whole table** is the row count: 1 ms instead of 1.5 s on 1,000,000 rows.
* **Equality joins** are hash joins (sort-merge when the build side exceeds the memory budget); a correlated
  subquery's `inner.col = outer expression` becomes a hash lookup built once per statement; conditions are pushed
  below joins (never across the nullable side of an outer join).

**There are no persistent secondary indexes** (`CREATE INDEX` is refused). Mk4tcl has no hash or ordered view
that could serve as one, so an index would have to be an ordinary view that *every* program writing the file keeps in
step, and MK Studio (and any other Metakit tool) edits tables directly. An index that goes stale is worse than a
slow query: it returns wrong rows silently, and a stale entry cannot be detected when a row is changed in place.
The honest options are to maintain such an index inside the shared storage layer that all writers use, or not to have
one; for now a lookup is a scan, but a scan done inside Metakit.

## Concurrency, locking and transactions

Metakit has no locking of its own. What mkit-sql guarantees, and what it does not:

* **One writer per file.** Opening a file for writing creates `<file>.lock` containing `pid host [role [endpoint]]`
  exclusively (`O_EXCL`). This is the protocol of MK Studio's `docs/CONCURRENCY.md`, implemented to the letter: the two
  exclude each other, and a server can announce itself (`::mkitsql::db::lockRole`, `lockEndpoint`, set before opening).
  A second writer is refused with `-errorcode {MKIT LOCKED pid host role endpoint}`. A lock is *held* when its process
  is alive on this host or it names another host (a network share: always respected), *stale* when the process is gone
  or the file is empty/garbled and older than 5 seconds, and *ours* when it names this process; stale and ours are
  taken over under `<file>.lock.guard` (created exclusively, abandoned after 10 seconds, the lock classified again with
  the guard held), so two processes finding the same stale lock cannot both win, and closing never removes a lock that
  is no longer ours. Beyond the letter of the protocol, and only ever stricter: a lock path that is not a regular file
  (a link, a folder, a fifo) is refused and never followed or read, a lock file is read with a bound, a recycled pid
  counts as dead when that process is younger than the lock file (Linux), and the database path is resolved through
  symbolic links so two names of one file share one lock. `tests/locking.tcl` runs the spec's checks against this code,
  races real processes, kills holders with `kill -9`, and (with `MKSTUDIO_DIR`) runs MK Studio's own `store.tcl` against
  it in both directions. If the folder is read-only, or the disk is full, no lock can be made and the file opens unlocked;
  `::mkitsql::db::requireLock 1` turns that into an error. **Limits:** the lock is advisory (a program that does not
  follow it is not stopped); a *hard link* is a different name Metakit cannot tell apart, so two hard links to one file
  can both be opened for writing; and processes in different PID namespaces (containers) that share a folder *and* a
  host name cannot see each other's pids - give such containers different host names, or run one server.
* **Readers are not locked.** `openFile -readonly` always works, notes who holds the write lock
  (`::mkitsql::db::lockedBy`), and write statements on it say so. A reader that is open while a writer commits can see a
  half-written state: that is Metakit, not something advisory locks can fix. Keep readers short, or have the writing
  process serve the reads.
* **Inside one process statements are serial.** A statement cannot be started while another is running (it fails with a
  clear error instead of corrupting the first), so a single-threaded server must finish a statement before the next
  starts and must not run queries from a `stream` callback or progress hook.
* **Transactions belong to the database, not to a connection.** `BEGIN`/`COMMIT`/`ROLLBACK` act on all pending changes
  of the database. A server that shares one database between clients sets `::mkitsql::session` to the client's id around
  each statement: the first session to write owns the open transaction until it commits or rolls back, and other
  sessions get `Database 'x' has uncommitted changes from another session (alice)` instead of silently joining it.
  Reads are not blocked and see uncommitted changes (read uncommitted).
* A server that exposes the engine should keep **one process as the only opener of the file** and put the network in
  front of that process; the lock keeps everything else out.

## Temporary files

Statements that exceed `::mkitsql::memBytes` spill to disk. Spill files live in a **private folder** this process creates
inside `::mkitsql::tempDir` (default: `TMPDIR`, `TEMP`, `TMP`, `/tmp`): `mkitsql-<user>-<pid>-<pid namespace>-<16 random hex digits>`,
mode 0700, checked to be a real folder owned by the caller, with every file created exclusively (`O_EXCL`, so an existing
file or symbolic link is never opened) with mode 0600. The folder is removed at the end of every statement, whether it
succeeded, failed or was cancelled. Folders and `mkitsql_<pid>_<n>.spill` files left by a crashed run are removed by the
next run (`::mkitsql::cleanTemp`): only those that belong to the caller, are real folders / files (never links) holding
nothing but spill files, whose process is gone, and that were made in this process's PID namespace. The folder of a
running process is never touched, however old (a long statement may hold spill files for hours), and a folder made in
another PID namespace (a container sharing the folder) is never touched, because its pid means nothing here. Every spill
file ends with a trailer line holding its record count: a file that ends early, is damaged, or was removed behind the
engine's back stops the statement with an error instead of returning fewer rows, and a failed final write (a full disk)
is reported at close, never ignored. Two users sharing a
machine, or a process planting links in `/tmp`, cannot read, overwrite or redirect another user's spill files
(`tests/tempsec.tcl`). Unusable folders and full disks are reported as errors that say what to set.

## Damaged files, untrusted files, and what Metakit remembers

Mk4tcl opens a damaged or truncated file as an *empty database*, and a later `COMMIT` would then overwrite the real
data. `openFile` therefore checks the file's frame (header, size word, 16-byte footer) first and refuses a file that is
not a complete Metakit file (`-errorcode {MKIT DAMAGED ...}`), and it checks again after opening that the number of views
matches the file. Metakit has no checksums, so damage *inside* the data can still crash the process that reads it:
`openFile ... -verify` reads the whole file in a throw-away child process first (with a timeout) and refuses the file if
that process crashes, hangs or reports an error. Use it for files you did not create. `-unchecked` skips both checks (only
for tools that repair files). Metakit also remembers a column's type by name for as long as the file is open; the engine
tracks that (see `ALTER COLUMN ... TYPE` under *Changing structure*) and forgets it when the file is closed.

## Known bug in Tcl 8.5 and 8.6.3 (MK Studio's runtimes), and how the engine copes

When the string form of a list is made, Tcl 8.5 and 8.6.3 damage a list whose *first element* starts with `#` and
contains certain characters (`]` or `"` together with others; for example `#]]x`): stray blanks or bytes appear after
the element and the element count can change. A row whose first cell is such text is exactly that, so anywhere a row's
string form is made - writing it to a spill file, using it as a dictionary key (`DISTINCT`, `GROUP BY`, joins, `UNION`),
searching it as text, or handing it to a caller that prints it - the data could silently change. The engine detects the
bug when it loads (`::mkitsql::listBug`), and on an affected Tcl it reads Metakit one property at a time (a multi-property
`mk::get` returns exactly such a list) and writes the affected lists with `::mkitsql::rt::sk`, which produces the string a
healthy Tcl would. `tests/listbug_forms.tcl` checks that string, for 111,110 short strings, against a healthy Tcl, and
`tests/listbug.sh` runs ~55 query shapes (joins, grouping, windows, set operations, CTEs, recursion, `INSERT ... SELECT`,
`UPDATE`, `DELETE`, `MERGE`, `CREATE TABLE AS`) over data of this kind on both old runtimes and on a healthy Tcl at eight
memory budgets and both storage layers, and requires identical results (switching the workaround off makes it fail).
**Limits:** the workaround protects the engine's own lists; a list *your* code builds from query results has the same bug
on those runtimes, and MK Studio's own `::store::rows` (used if you force `MKIT_BACKEND=studio` and read rows through it
yourself) is not changed. The bug does not exist on Tcl 8.6.4 and later.

## Running statements

A statement keeps its plans and working state in the engine, so **one statement cannot be started while another is
running** (for example from a `stream` callback or a progress hook): it fails with a clear error and the outer
statement is unaffected. Run it after the first has returned. Every statement, whether it succeeds, fails or is
cancelled, leaves behind no temporary file, no scratch table and no working state (`tests/robustness.tcl`). A
statement that changes data is all-or-nothing, including when it spills or rebuilds the table; if the *copy back*
of a rebuild fails half way, the error says so and `ROLLBACK` restores the table.

If a write statement fails *after* it has already changed something (a storage error or a full disk while the rows were
being applied), the file must not be left half changed: when it was the first change of the transaction it is rolled
back automatically (the error says so); when earlier uncommitted changes are pending the single statement cannot be
undone on its own, so the transaction is marked failed and only `ROLLBACK` is accepted (no `COMMIT` of a half-applied
statement). Statements that fail *before* writing (type errors, bad values, constraints you asked for) change nothing.

## Errors

Syntax errors carry the character position and length (`-errorcode {MKQL SYNTAX pos len}`) so an editor can
underline the problem. Runtime errors say what was wrong and, where it helps, what was available:
`Unknown column 'nope'.  Available: id, name, ...`.

Every error has an `-errorcode` that says what kind it is: `MKQL SYNTAX ...` (the statement is not valid),
`MKQL ERROR` (the statement was refused or failed for a reason the message explains), `MKQL ERROR DATA` (arithmetic on
the data went out of range: overflow, division by zero, a value that is not a number), `MKQL ERROR MKIT code ...` (the
storage layer: `LOCKED pid host role endpoint`, `DAMAGED`, `TYPECONFLICT`, `BADLOCK`) and `MKQL ERROR RUNTIME ...` (a Tcl
error from inside the engine that no check anticipated: always a bug - please report it; the fuzzer counts these as
failures). A caller never sees a Tcl stack trace as the *only* signal: the message is readable and the code classifies it.

## Not supported

| Left out | Why |
| --- | --- |
| Constraints (`PRIMARY KEY`, `UNIQUE`, `FOREIGN KEY`, `CHECK`, `NOT NULL`), defaults, indexes, `AUTOINCREMENT` | Metakit stores none of these; they are rejected, never silently ignored |
| SQL `VIEW`s, triggers, stored procedures, permissions, cursors, locking | not applicable to a single-process embedded file |
| `ON CONFLICT` / upsert | needs keys; use `MERGE` |
| Savepoints | Metakit can only roll back to the last commit |
| `SELECT TOP n` | T-SQL only; use `LIMIT` or `FETCH FIRST` |
| `INSERT ... RETURNING`, `UPDATE ... FROM` | not in the SQL standard |
| `GROUP BY ROLLUP / CUBE / GROUPING SETS` | not built yet |
| `COLLATE`, `SIMILAR TO`, `EXCLUDE` in window frames, `IGNORE NULLS` | not built yet |
| `INTERVAL` columns; exact `DECIMAL` | Metakit has no such types |
| Two columns of the same name in a derived table or CTE (`SELECT * FROM (SELECT a.id, b.id FROM ...)`) | refused with a clear message (give one an alias); other databases allow it until you refer to the name |
| A statement that expands to more than 4,000 subqueries | a CTE is bound again at every reference, so a chain of CTEs that each use the previous one twice doubles at every level; refused instead of hanging (`::mkitsql::maxBinds`) |
