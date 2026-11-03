# Changelog

All notable changes to mkit-sql. The versioning and compatibility rules are in
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md). Dates are omitted on purpose: the version is the identity.

## 0.4.0 - production-readiness pass (not yet released)

### Breaking
* **`ALTER TABLE ... ALTER COLUMN ... TYPE` is refused.** Metakit identifies a column by name *and* type; retyping under
  the same name corrupted data on real Metakit (found by `tests/differential/features.py`). The error shows the safe
  recipe (add a column, fill it with `CAST`, drop the old one). A type change by dropping and re-creating a name inside
  one open file is refused while changes are pending, and is done by reopening the file when nothing is pending.
* **Lock files follow MK Studio's `docs/CONCURRENCY.md` exactly**: content `pid host [role [endpoint]]` (the old
  third field, a process start token, is gone), takeover guard `<file>.lock.guard` (was `.lock.takeover`), 5 s / 10 s
  abandonment thresholds. The error code of a refused open is now `{MKIT LOCKED pid host role endpoint}` (six elements,
  was four) and `::mkitsql::db::lockedBy` returns `pid host role endpoint`.
* Spill folders are named `mkitsql-<user>-<pid>-<pid namespace>-<random>`; the folder of a running process is never swept
  (the `::mkitsql::staleHours` setting is gone).
* Names starting with `__mks` are reserved (tables, columns, renames). Two columns of the same name in a derived table,
  CTE or `VALUES ... AS v(a, a)` are refused (they used to silently return the last column's value for both).
* `REAL` columns (32-bit) refuse values beyond about 3.4e38 instead of storing infinity; whole-number columns refuse
  `1e999`, infinities and values beyond 64 bits; a numeric literal that is not finite (`1e999`) is a syntax error.

### Added
* **Interrupted commits and power loss** (found by MK Studio's power-loss tests, which showed that a kill inside a commit leaves a database Metakit opens as EMPTY): commit record `<file>.commit` + `sync`, repair on open for writing, same mechanism and file formats as MK Studio, guarded so a damaged header cannot cut data away; `tests/power_loss.tcl` (406 synthesised states, 18 real kills with strace) and `tests/studio_repair.tcl`. **The earlier claim that a kill mid-commit always leaves a whole committed batch was wrong** (random kills rarely hit that window). `integration/mkstudio.patch` adds the same guard to MK Studio's own `repairFile`, whose truncation trusted the header blindly.
* `::mkitsql::db::layout` of a subview path (`d.t!0.kids`) returns the subview's own layout (Mk4tcl answers with the parent's).
* **Tcl 9.0 support** (`package require Tcl 8.5-10`), tested on a source build in CI. Found and fixed a latent bug on the way: file modes
  were written as `0600` / `0644`, which Tcl 9 reads as decimal, giving spill and lock files odd permissions; they are decimal numbers now, and
  lint refuses a leading-zero file mode.
* **Damaged-file protection**: frame check before and after opening (a truncated or damaged file is refused instead of
  being opened as an empty database that a `COMMIT` would then overwrite), and `openFile -verify` to read an untrusted
  file in a throw-away child process first. Test: `tests/damage.tcl` (kills mid-commit, truncations, fuzzed bytes).
* **Metakit-side query narrowing** (`mk::select` for `=`, ranges, `IN`, `BETWEEN` on stored numbers and text),
  `COUNT(*)` from the row count, `EXPLAIN`.
* **Temp-file security**: private 0700 folder, exclusive 0600 files, safe sweep of abandoned folders, PID-namespace aware.
* **Locking** compatible with MK Studio, sessions and transaction ownership for a server.
* **Spill files are checked**: a trailer with the record count; a short, damaged or removed file stops the statement; a
  failed final write (full disk) is reported.
* **A statement that fails after changing data** is rolled back (first change of the transaction) or marks the
  transaction failed (earlier changes pending), instead of leaving a half-applied statement that could be committed.
* **Workaround for a bug in the list code of Tcl 8.5 and 8.6.3** that corrupted rows whose first cell is text starting
  with `#` (see docs/SQL.md); verified against a healthy Tcl by `tests/listbug.sh` and `tests/listbug_forms.tcl`.
* `integration/mkstudio.patch` also fixes MK Studio's own row readers on the Tcl 8.5 / 8.6.3 list bug.
* `MKQL ERROR DATA` error class for arithmetic that goes out of range; `MKQL ERROR RUNTIME` marks a Tcl error from
  inside the engine (always a bug).
* Limit on statement expansion (`::mkitsql::maxBinds`, 4,000 subqueries).
* Tests: oracle differentials for numeric edges, strings/`LIKE`, dates, features (MERGE, LATERAL, ALTER, subviews,
  information_schema, recursive CTEs), stateful DML; damage, review-regression, list-bug and benchmark suites.

### Fixed
* **Lock race (found by MK Studio's tests):** when a competitor deleted a stale lock between our failed create and our look at it, we concluded "this folder cannot hold a lock" and opened the file unlocked next to the competitor (2-3 winners in ~3 of 60 races). Only a folder that refuses files means "unlocked" now; a vanished lock is retried. Regression: `tests/lock_crash.tcl` (deterministic hook plus kill-at-every-step, 60 stale-lock races, chaos).
* The wait for another process's takeover guard is bounded (about 2.4 s) as the protocol says; an abandoned takeover guard is tidied when the lock is created.
* Nested derived tables took time doubling with every level (a bound query was stored twice per level): now linear.
* `CHR`, `SUBSTR`, `LEFT`, `RIGHT`, `REPEAT`, `LPAD`, `RPAD`, `ROUND`, `TRUNC`, `POWER`, `ASIN`, `ACOS`, `ABS`, `SQRT`,
  `SIN`, interval multiplication and comparisons with huge numbers raised raw Tcl errors or could build the reserved NULL
  character; all are clean engine errors now (`tests/review_regress.tcl`).
* Several Tcl 8.5 incompatibilities (`lrepeat 0`).
* `DROP TABLE` followed by `CREATE TABLE` of the same name with another column type no longer corrupts the file.
* `openFile` errors name the path; the studio storage adapter checks the file signature like the standalone one.
* Transaction ownership is claimed before a write starts and a stale owner is dropped when the transaction ended through
  the storage layer.

## 0.3.0

Bounded-memory streaming executor with spilling operators; unforgeable NULL; audited string-to-code boundaries;
standalone storage layer (`mkitsql/db.tcl`) next to the MK Studio adapter; Tcl 8.5.17 and 8.6.3 targets; rebuild strategy
for big deletes/updates.

## 0.2.0 and earlier

Window functions, `WITH RECURSIVE`, `ANY/ALL/SOME`, `FILTER`, row values, dates and intervals, `MERGE`, `LATERAL`,
differential testing against SQLite.
