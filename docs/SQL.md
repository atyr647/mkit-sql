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

`GROUP BY` also takes `ROLLUP (...)`, `CUBE (...)`, `GROUPING SETS (...)` and `()`, combined with plain expressions
(`GROUP BY a, ROLLUP (b, c)`), and `GROUPING(e, ...)` gives the bit mask of the expressions a row does *not* group:

```sql
SELECT dept, COUNT(*), SUM(salary), GROUPING(dept) FROM employees GROUP BY ROLLUP (dept);
SELECT dept, hired, COUNT(*) FROM employees GROUP BY GROUPING SETS ((dept), (hired), ());
```

The query runs as one ordinary `GROUP BY` per grouping set, joined with `UNION ALL` (a grouping set is scanned once per set).
Consequences: `ORDER BY` must name output columns or positions, `SELECT *` is refused, and a group expression that is not
grouped in a row reads NULL there.

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

`USING (c)` and `NATURAL` joins merge the common columns: `SELECT *` shows the column once, and an unqualified `c` means the merged column - for `RIGHT` and
`FULL` joins `COALESCE(left.c, right.c)`, so a row that exists only on the right still has its key (`a.c` and `b.c` still name the original columns, and `a.*` shows `a`'s own).
Checked against SQLite on 29 query shapes (`tests/differential/using.sql`).

`LEFT JOIN LATERAL (...) ON TRUE` keeps rows with no match. `RIGHT`/`FULL` with `LATERAL` is not supported.

## Subqueries

Scalar `(SELECT ...)`, `[NOT] IN (SELECT ...)`, `[NOT] EXISTS (SELECT ...)`, `op ANY|SOME|ALL (SELECT ...)`,
derived tables `FROM (SELECT ...) alias [(cols)]`, correlated at any depth (a derived table inside a subquery cannot itself reach outward, see the end of this page), also inside `GROUP BY` queries
(which may refer to the grouped columns). Row values work too: `(a, b) = (1, 2)`, `(a, b) < (...)`,
`(a, b) IN ((1, 2), (3, 4))`, `(a, b) IN (SELECT x, y ...)`.

A correlated subquery whose condition has the form `inner expression = <outer expression>` becomes a hash lookup
built once per statement, and **its answer is remembered per distinct value of the outer columns it reads**: many outer
rows with the same key (`WHERE w > (SELECT AVG(w) FROM t t2 WHERE t2.k = t.k)`) cost one run per key, not one per row (the
memory is bounded by `::mkitsql::maxMemo`, 200,000 keys; a subquery that calls `RANDOM()` is never shared). What stays
quadratic: a correlation that is only an inequality (`WHERE t2.d <= t.d`, a running total) with a different key on every row;
use a window function for those (`SUM(x) OVER (ORDER BY d)`), which is linear.

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
`ORDER BY` only, and may wrap aggregates: `RANK() OVER (ORDER BY SUM(x))`.

```sql
SELECT id, SUM(salary) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING EXCLUDE CURRENT ROW) FROM employees;
SELECT id, COUNT(DISTINCT dept) OVER (ORDER BY id ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) FROM employees;
SELECT id, LAG(salary) IGNORE NULLS OVER (ORDER BY id) FROM employees;
```

* `EXCLUDE CURRENT ROW | GROUP | TIES | NO OTHERS` after the frame (it needs a frame). Checked against SQLite on 1,100+ queries.
* `DISTINCT` inside a window aggregate (`COUNT/SUM/AVG/MIN/MAX/STRING_AGG`) counts each value of the frame once. PostgreSQL and
  SQLite refuse this; here it is an extension, computed per row from its own frame (cost: frame size per row).
* `IGNORE NULLS` / `RESPECT NULLS` (the default) on `LAG`, `LEAD`, `FIRST_VALUE`, `LAST_VALUE`, `NTH_VALUE` skip NULL rows.
* `SUM`, `AVG`, `MIN`, `MAX` also work over intervals (below), as plain and as window aggregates.

## Expressions and functions

Operators: `+ - * / %`, `||`, `= <> < <= > >=`, `AND OR NOT`, `IS [NOT] NULL | TRUE | FALSE | DISTINCT FROM`,
`[NOT] BETWEEN`, `[NOT] IN`, `[NOT] LIKE | ILIKE [ESCAPE c]`, `[NOT] SIMILAR TO pattern [ESCAPE c]`, `expr COLLATE name`, `CASE` (both forms), `CAST(x AS type)` (a real cast to an integer type *rounds* to the nearest whole number, halves away from zero, as in PostgreSQL and MySQL; SQLite truncates; a value outside `INT` or `BIGINT` is an error, as in PostgreSQL). There is no negative zero: `-0.0` is `0.0` everywhere (grouping, sorting, joins, storage).
Integer `/` truncates toward zero; `%` takes the sign of the left side; division by zero is an error.
`AND`/`OR`/`CASE` evaluate lazily, so `WHERE b <> 0 AND a / b > 1` is safe.

`SIMILAR TO` is the SQL regular expression: `%` any string, `_` any character, `|` alternation, `* + ?` and `{m,n}` repetition,
`( )` grouping and `[a-z]` / `[^0-9]` / `[[:alpha:]]` classes; every other character is literal - including `.`, `^` and `$` (unlike a
regular expression) - and the backslash escapes unless `ESCAPE` names another character. It is case-sensitive and the whole text
must match: `'abc' SIMILAR TO '%(b|d)%'` is true.

`COLLATE` supports `BINARY` (the default, code point order; also `C`, `POSIX`) and `NOCASE` (also `CASE_INSENSITIVE`). It works on the
operands of comparisons, `IN`, `BETWEEN` and `LIKE`, in `ORDER BY` (also inside `OVER`), in `GROUP BY` (groups case-insensitively,
shows the smallest original text) and in the select list (no effect there). Anywhere else it is an error, not silently ignored.

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
seconds, or `CAST(iv AS VARCHAR)`). `SUM`, `AVG`, `MIN` and `MAX` work over intervals: months and seconds are added separately
(so `SUM` of two `1 mon` is `2 mons`; a fractional month from `AVG`, `/` or `*` becomes days of 30 days: `AVG` of `1 mon` and `2 mons` is `1 mon 15 days`), **equality is exact** (`1 mon` is not `30 days`, in `=`, `IN`, joins, `DISTINCT` and `GROUP BY` alike) while ordering compares the length of time with 30-day months (equal lengths, by months, so `1 mon` and `30 days` are never interleaved - in memory or spilled); seconds are kept to the microsecond, `MIN`/`MAX` return a value of the data compared by length of time (30-day months), `AVG` is the
sum divided by the count. To do date
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

## Speed: where the time goes, and what to do about it

Measured on real Metakit (tclkit 8.6.3, one core): a statement costs about **0.1 ms** of fixed overhead for `SELECT 1`, and a point
`SELECT ... WHERE id = ?` on a 3,000-row table about **0.9 ms**, of which Metakit's own scan is 0.3 ms, execution 0.05 ms, compiling the
query 0.26 ms (a third of that is the safety check of the generated code), binding 0.09 ms and parsing 0.13 ms. Per-row work in the
engine is 5-10 us (`SUM/AVG` over 20,000 rows 160 ms, a `LIKE` prefix scan 100 ms): that is the speed of interpreted Tcl.

* The **parse** of a statement text is remembered (the last 256 texts up to 4 KB; the result depends on nothing but the text and
  `::mkitsql::ignoreConstraints`), and generated code that passed the safety check once is not checked again. So a statement that
  repeats with **parameters** (`INSERT INTO t VALUES (?, ?, ?, ?)` with a list each time) costs 105 us instead of 265 us, and `SELECT 1` 43 us instead of 108 us.
  A statement whose text is different every time (values pasted into the SQL) gets no help.
* **Loading many rows: use `::mkitsql::insertRows $db table {columns} $rows ?-null token?`** (the table is written as in SQL, subview paths included: `sv[1].kids`). Parsing the SQL text of a big `INSERT ... VALUES (...),(...)`
  is most of its cost. The tokenizer is one capture-free regular expression with the kind decided from the first character (3.3x faster, identical
  on 41,000 test texts) and a lone literal skips the operator-precedence climb: a 1,000-row `INSERT ... VALUES` text went from 190 us a row to 85 us
  (22 ms to tokenize, 38 ms to parse, 25 ms to run). `insertRows` takes the rows as Tcl lists, does the same checks and conversions
  (range errors, text to number, NULL, all-or-nothing, transactions) and costs 13 us a row (5,000 rows in 65 ms).
* **Aggregates fold a whole chunk at a time**: `COUNT`, `SUM`, `AVG`, `MIN`, `MAX` over numbers group the chunk's rows by key and add each group's
  values with one C-speed command (`::tcl::mathop::+`) instead of one proc call per row and aggregate; `SUM/AVG` over 50,000 rows went from 615 ms to 195 ms, a
  `GROUP BY` from 566 ms to 309 ms (`::mkitsql::fastAgg 0` returns to the row-by-row fold; `tests/aggfast.tcl` compares the two, and the SQLite
  differentials agree). Reading rows is unrolled for one to four columns. What is left is Metakit's own `mk::get` (about 1 us a value).
* **tcl-aot** (the ahead-of-time compiler for Tcl procs in `atyr647/tcl-aot`) was evaluated and is **not usable here yet**: it targets Tcl 8.6.14
  built as a static library with the compiled C linked into the program, while mkit-sql runs on MK Studio's tclkits (8.6.3 and 8.5.17,
  prebuilt) and its hot code is generated at run time from the SQL text, which an ahead-of-time compiler cannot see. Its own figures
  (3-5x on integer and float loops, 1.0-1.5x on code that lives in Tcl's list, string and regexp commands) describe code that is a small
  part of this engine: the per-row cost is `mk::get` calls and list operations. It would help the static runtime procs (`rt::*`, window and
  sort loops) in a custom Tcl build; revisit if MK Studio moves to a Tcl it can compile against.
* Not done, on purpose: a cache of compiled plans (parameters become part of the compiled code, and the plan also depends on table sizes and
  the schema, so entries would rarely be reused and invalidating them is where the bugs would be) and compiled (C) kernels (the engine stays pure Tcl).

## Large tables and memory

**Can the 2 GiB limit be lifted? Yes - with a Metakit built for it; not with the Metakit inside today's MK Studio and tclkits.**
Stock Metakit stores every file position as a signed 32-bit integer (`t4_i32`), so a database file cannot pass 2 GiB. The Metakit fork
at https://github.com/atyr647/metakit (the branch with the 64-bit file positions) removes that: files below 2 GiB are byte for byte what
they always were, and a file that outgrows 2 GiB gets "wide" tails (24 bytes, 64-bit positions) and a flagged header. mkit-sql supports it:

| | stock Mk4tcl (MK Studio, tclkits) | Mk4tcl built from the fork |
|---|---|---|
| file below 2 GiB | works, unchanged | works, byte for byte the same |
| file past 2 GiB | **a commit that would cross is undone**, error `{MKIT COMMITFAILED size}` | commits, reopens, repairs, verifies |
| a wide file (made by the fork) is opened | **refused**, `{MKIT WIDEFILE}` (the stock library would show an EMPTY database, and saving would hide the data) | works |
| `fileHeadroom` / `nearLimit` measure against | 2,147,483,647 bytes | 2^56 - 64 bytes |
| one column (all values of one column of one table) | the file limit comes first | **still 2^31-1 bytes**: refused with `{MKIT COLUMNFULL view column}` |

How the engine knows which Metakit it has: `::mkitsql::db::wideCapable` builds a tiny wide file with the loaded library (an ordinary file
turned into the wide format) and sees whether the library finds its row - a behaviour test, not a version number; the result is kept for the process.
`MKIT_WIDE=0` in the environment forces "cannot" (to test the refusal). A wrong "cannot" can only refuse a file or keep the 2 GiB headroom: it never
risks data. Opening a file for writing also puts right an interrupted commit on a wide file (the commit record and the 24-byte frame check are wide-aware),
and `-verify` reads the whole file in a helper process (it loads the same Mk4tcl as the caller).

**The column limit.** In the 64-bit Metakit one column (and one memo) is still limited to 2^31-1 bytes whatever the size of the file, and
when an edit grows a column past it Metakit **ends the program** (there is no way to report an error from the middle of an edit). With the file limit gone
nothing else stops a big table first, so `INSERT` and `UPDATE` check the column before they write: the check costs nothing until the file plus
what has been written since the last commit nears 2 GiB; then the column is counted once (fixed width: rows x width; text and blobs: one pass over the
column, about a second per million rows) and kept up to date for the session (deletes are not subtracted, so the count only errs on the safe side; it is
reset by `ROLLBACK`, a reopen and a layout change). When a column would pass the limit the statement fails with `{MKIT COLUMNFULL view column}` and
the file is untouched. The remedy is the same as ever: split the table (by year, say) or keep large values outside the database.

**On stock Metakit a file cannot be larger than 2 GiB (2,147,483,647 bytes)** - it keeps its size in one 32-bit word (measured on real
Metakit 2.4.9.7: a commit that would take the file past it fails with "I/O error during commit" and, if it was a large one, leaves
a file that crashes Metakit when opened). mkit-sql undoes such a commit: the file is put back to its last committed state, the
handle is reopened (the changes since the last commit are discarded, as `ROLLBACK` does) and the error is
`{MKIT COMMITFAILED <size>}` with a message that names the limit. What fits: about 55 million rows of three numeric columns
(20,000,000 such rows are a 762 MB file); a table of long text fills it much sooner. To go beyond, split the data over several files - any number
can be open at once and their tables are addressed `dbtag.table` - and watch `::mkitsql::db::fileHeadroom $tag` / `::mkitsql::db::nearLimit $tag 0.9`
to archive or split before a commit has to be undone.

**Do not mix the two Metakits on one wide file.** A program with a stock Mk4tcl that is not mkit-sql (MK Studio's own store, `tclkit`, a script) sees a wide file as
empty, and a commit from it would put a new, small database behind the existing bytes. mkit-sql refuses such a file under a stock Mk4tcl; other programs
do not know. Keep wide files for programs that load the 64-bit Mk4tcl, and keep MK Studio's `integration/` patch for files under 2 GiB until MK Studio itself
ships the 64-bit Metakit (a file only becomes wide when it outgrows 2 GiB: a small file is readable by everything).

Build the library: `tests/build_mk4tcl_wide.sh <dir>` (a pinned commit of the fork; needs `g++`, `make`, `tcl8.6-dev`). CI job `metakit-wide` runs the engine
suites on it, `tests/widefile.tcl` (small files, any Mk4tcl) and `tests/widebig.tcl` (a 3.5 GB database: commits across 2 GiB, every blob intact,
one column refused at 2 GiB, five commits killed in the middle).

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
  `BETWEEN`, `IN (constants)`, and `LIKE 'abc%'` / `'%abc%'` (case-sensitive, no `_` or `ESCAPE`; handed over as Metakit's `-glob`: a 20,000-row prefix scan went from 178 ms to 14 ms) on number and text columns are handed to Metakit's own `mk::select`, which tests the
  column in C. Only the rows that can match are read, and the complete `WHERE` is still evaluated on them, so this can
  only ever skip rows that cannot match. Applies to tables of at least `::mkitsql::pushMin` (500) rows, and to
  `UPDATE` / `DELETE` too. On a table of 1,000,000 rows `WHERE id = 777777` takes 0.1 s instead of 3.8 s; a range
  takes about 0.6 s. (`::mkitsql::pushdown 0` turns it off.)
* **`COUNT(*)` of a whole table** is the row count: 1 ms instead of 1.5 s on 1,000,000 rows.
* **Equality joins** are hash joins (sort-merge when the build side exceeds the memory budget); a correlated
  subquery's `inner.col = outer expression` becomes a hash lookup built once per statement; conditions are pushed
  below joins (never across the nullable side of an outer join).

**Should there be persistent indexes? Not yet, and here is what it would take.** Metakit's own `mk::select` already tests a column in C at
about 0.1 us a row, which beats loading any index into Tcl, so equality and range lookups gain nothing; the real gain would be `ORDER BY ... LIMIT`
and range scans over millions of rows (a 5-million-row sort is 74 s). A design that cannot go stale exists - a sidecar file holding a sorted
row-id list per indexed column, valid only while the main file's `<crc32> <size> <mtime>` (the `.sum` above) is unchanged, rebuilt lazily
otherwise - but it pays off only for read-mostly files above about a million rows, and every commit invalidates it. Build it when a real
workload needs it; the checksum machinery it depends on is now in place.

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
  is no longer ours; a lock file that vanishes between our failed create and our look at it (a competitor released or replaced it) means *try again*, and only a folder that refuses to hold a file means "run unlocked" (this race let two processes both own the database in both implementations until it was found by MK Studio's tests). Beyond the letter of the protocol, and only ever stricter: a lock path that is not a regular file
  (a link, a folder, a fifo) is refused and never followed or read, a lock file is read with a bound, a recycled pid
  counts as dead when that process is younger than the lock file (Linux), and the database path is resolved through
  symbolic links so two names of one file share one lock. `tests/locking.tcl` runs the spec's checks against this code,
  races real processes, kills holders with `kill -9`, and (with `MKSTUDIO_DIR`) runs MK Studio's own `store.tcl` against
  it in both directions. If the folder is read-only, or the disk is full, no lock can be made and the file opens unlocked;
  `set ::mkitsql::db::requireLock 1` turns that into an error. **Limits:** the lock is advisory (a program that does not
  follow it is not stopped); a *hard link* is a different name Metakit cannot tell apart, so two hard links to one file
  can both be opened for writing; and processes in different PID namespaces (containers) that share a folder *and* a
  host name cannot see each other's pids - give such containers different host names, or run one server; **one Tcl interpreter per
process opens a given file for writing** (a second interpreter or thread of the same process has the same pid, so it is taken for the
holder itself and gets the lock too); a **wall-clock step** larger than 2 s forward (a manual `date -s`) can make a live holder look
like a recycled pid, because the check compares its start time with the lock's modification time (MK Studio's protocol has the same
property); file names are compared as spelled, so on Windows and macOS (case-insensitive) always open a file under one spelling; mkit-sql resolves symbolic links before it names the lock, MK Studio's store does not, so **open a database through the same real path from both programs** or they will not exclude each other.
A file in a folder where no lock file can be created opens unlocked (see `requireLock`) and is then **not repaired** (another writer
may be mid-commit); likewise a commit whose record cannot be written still runs, and `::mkitsql::db::commitUnprotected $tag` says so.
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

## Interrupted commits and power loss

A Metakit commit appends the new data and a new tail to the file and writes the 8-byte header at offset 0 **last**; it never
calls fsync. A process killed between the appends and the header leaves the OLD header and a LONGER file, which Metakit opens as
an *empty* database without any error - and a later `COMMIT` would then overwrite the real data. After a power cut the pages
can also reach the disk in any order. mkit-sql therefore writes `<file>.commit` (the committed header and size) before every
commit, forces the file to disk after it where the system has `sync`, and removes the record; opening a file *for writing* (the
write lock is held, so nobody else is mid-commit) puts an unfinished commit back, so the database is exactly what it was before
that commit (`::mkitsql::db::repairedNote $tag` says what was done). Without a record, a file longer than its header says is cut
back to the header's offset. Both repairs happen only if a valid Metakit footer ends exactly where the restored state would
end, so a damaged header can never make them throw data away; read-only opens cannot repair and refuse such a file. The file
names and formats are MK Studio's (`store.tcl` does the same), so either program can repair what the other left behind. The record of the very first commit of a brand-new file reads `empty 0`: an interrupted first commit is put back to an
empty file (tested by killing a first commit after each of 14 different writes). On Windows the file is flushed through
PowerShell (not testable on the CI runner's stand-in, so best effort). MK Studio's `.sum` / `.bak` sidecar files are left alone.
`set ::mkitsql::db::durable 0` turns the `sync` calls off. **Limits:** a disk that loses data it said was written; Windows, which has
no `sync` command (kills are covered, power loss is as safe as the operating system's own write ordering); a commit that was
confirmed to the caller only counts as durable after the file has been forced out, so a crash after `mk::file commit` but before
that is rolled back.

## Damaged files, untrusted files, and what Metakit remembers

Mk4tcl opens a damaged or truncated file as an *empty database*, and a later `COMMIT` would then overwrite the real
data. `openFile` therefore checks the file's frame (header, size word, 16-byte footer) first and refuses a file that is
not a complete Metakit file (`-errorcode {MKIT DAMAGED ...}`), and it checks again after opening that the number of views
matches the file. Metakit has no checksums, so damage *inside* the data can still crash the process that reads it:
`openFile ... -verify` reads the whole file in a throw-away child process first (with a timeout) and refuses the file if
that process crashes, hangs or reports an error. Use it for files you did not create. `-unchecked` skips both checks (only
for tools that repair files).

**`-verify` is a proof when the file has its checksum, and says so.** After every commit mkit-sql writes `<file>.sum`
(`<crc32> <size> <mtime>` of the finished file - the format MK Studio's store writes too, and the two read each other's;
files over `::mkitsql::db::sumLimit` MB, default 512, are not covered; `0` turns it off). Opening a file for writing (or any open with `-verify`; a plain read-only open does not read the whole file) compares it, and a file whose size and time
still match but whose checksum does not is **proven damaged** and refused (`{MKIT DAMAGED checksum}`). Two refinements keep it honest:
file times have a resolution of one second, so a sum written in the same second as the file's last change cannot tell another program's write from
damage - it reports `changed` (no proof, no alarm) until some later open finds the file intact and stamps the sum a second newer, from which point a difference
is unambiguous; and the sum is removed when a commit starts (a commit rewrites bytes in place) and written again when it finishes, so a commit that is cut off leaves no
sum that vouches for the old bytes. A `<file>.sum` that is not a small plain file (a FIFO, a huge file) is ignored. `-verify` returns the
level in `::mkitsql::db::integrityOf $tag` (`{state level}`):

| level | meaning |
| --- | --- |
| `proven` | the checksum matched: the file is byte for byte what the last commit left, and a file Metakit wrote is well formed, so reading it is safe |
| `evidence` | no usable checksum (a file made by another tool, or changed since its last commit by a program that does not write one): the whole file was read in a helper process without trouble. **Not a proof** - on damaged data Metakit behaves differently from one run to the next (seen on macOS CI) |
| `""` | `-verify` was not asked for |

What "proven" does not cover: a file that was already damaged when it was last committed (the sum vouches for what was written),
tampering (crc32 catches accidents, not an attacker), and a program that changes the file without updating its sum - that makes the sum
"changed", which gives `evidence` at best, never a false alarm. There is no way to prove more without a format validator for Metakit files,
which does not exist; a checksum made by a cooperating writer is the strongest statement available for a format that has none.

Metakit also remembers a column's type by name for as long as the file is open; the engine
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
MK Studio's own row readers (`::store::rows`, `fetch`, `fetchAt`) had the same exposure; `integration/mkstudio.patch` gives
them the same treatment (`tests/studio_listbug.tcl` fails without it and passes with it, on both runtimes).
**Limits:** the workaround protects the engine's lists and MK Studio's row readers; a list *your own* code builds from
query results has the same bug on those runtimes, and an *unpatched* MK Studio still has it in its grid. The bug does not
exist on Tcl 8.6.4 and later.

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
| `COLLATE` names other than `BINARY` and `NOCASE` (locale collations) | text sorts by code point; add a lower-cased column or use `NOCASE` |
| `COLLATE` in `DISTINCT`, `IS DISTINCT FROM`, aggregates, `ORDER BY 1 COLLATE ...` (a position), inside `ROLLUP`/`CUBE` | refused with an error |
| Window functions in the same query as `ROLLUP` / `CUBE` / `GROUPING SETS`; `RANDOM()` there; more than 256 grouping sets (`CUBE` of more than 8) | refused: put the grouping query in a subquery and apply the window to its result (each grouping set is its own scan, so a window or a random value would see different inputs) |
| A subquery that names a grouping column of a `ROLLUP` / `CUBE` / `GROUPING SETS` query (`(SELECT ... WHERE u.k = a)`) | refused ("must appear in the GROUP BY clause"); `a IN (SELECT ...)` on the grouped column works |
| A derived table `FROM (SELECT ...)` inside a subquery that refers to the *enclosing* query's columns | "Unknown table or alias"; the derived table cannot see outward (use `LATERAL`, or move the condition out) |
| An aggregate inside a subquery whose arguments name only the enclosing query's columns (`(SELECT MAX(a.v) FROM u)`) | evaluated inside the subquery (once per row of `u`); standard SQL attaches it to the enclosing query |
| `INTERVAL` columns; exact `DECIMAL` | Metakit has no such types |
| A *reference* to a column name that two columns of a derived table share | refused as ambiguous (the duplicate columns themselves are fine: `SELECT * FROM (SELECT a.id, b.id ...)`); an explicit column list `t(p, p)` must be distinct |
| A statement that expands to more than 4,000 subqueries | a CTE is bound again at every reference, so a chain of CTEs that each use the previous one twice doubles at every level; refused instead of hanging (`::mkitsql::maxBinds`) |
