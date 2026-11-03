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
| `REAL` | `F` (32-bit float) | low precision |
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
`[NOT] BETWEEN`, `[NOT] IN`, `[NOT] LIKE | ILIKE [ESCAPE c]`, `CASE` (both forms), `CAST(x AS type)`.
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
           | ALTER COLUMN col [SET DATA] TYPE type | RENAME TO new_name;
```

Names may only contain letters, digits and underscores. Renaming or retyping a column moves it to the end of
the table (Metakit limitation). Renaming a table copies it (subviews included).
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

## Storage layer

The engine reaches Metakit only through `::mkitsql::db` (`mkitsql/db.tcl`, directly on Mk4tcl, no MK Studio
needed). Inside MK Studio, `mkitsql/db_studio.tcl` forwards the same interface to MK Studio's `::store` so both
share the open files. `mk::view delete` leaves a view's rows behind, so `dropView` empties the view first and
abandons the drop with the original error if that fails.

```tcl
package require mkitsql                                   ;# standalone: loads Mk4tcl itself
set db [::mkitsql::db::openFile game.mk -create]
```

## Errors

Syntax errors carry the character position and length (`-errorcode {MKQL SYNTAX pos len}`) so an editor can
underline the problem. Runtime errors say what was wrong and, where it helps, what was available:
`Unknown column 'nope'.  Available: id, name, ...`.

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
