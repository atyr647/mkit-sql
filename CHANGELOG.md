# Changelog

All notable changes to mkit-sql. The versioning and compatibility rules are in
[docs/COMPATIBILITY.md](docs/COMPATIBILITY.md). Dates are omitted on purpose: the version is the identity.

## 0.6.1 - a finished commit can no longer be undone by a lost record deletion; the native flush; a Metakit that refuses to write

* **Fixed: an acknowledged commit could be undone after a power cut** (standalone storage layer; MK Studio's own store already had the
  fix). `db::endCommit` flushed the file and deleted the commit record. A deletion that had not reached the disk brought the old record
  back, which described the file *before* the commit, and the next writer put that state back: the commit had returned, its rows were
  gone. Reproduced by `tests/commit_ack.tcl` with a model of a lost deletion (not a real power cut): with the checksum off (`sumLimit 0`,
  files over `sumLimit`, runtimes without `zlib`) 25 of 75 rows were lost; with the checksum on the default setup was covered only by
  accident, because `sumWrite` flushes the folder after the deletion. `endCommit` now follows MK Studio's `store.tcl`: flush the file,
  **rewrite the record to describe the finished file** (temp file and rename, in place where the rename fails), flush it, then delete it.
  `::mkitsql::db::commitHook` (a test hook, like `lockHook`) names each step of a commit; `tests/commit_crash.tcl` stops a commit at each
  of the 8 steps three ways (a process that exits, the same with the lost-deletion model, a raised error) and checks the next writer finds
  the old or the new database, no record, a later commit working.
* **The native flush is used when there is one.** `syncDisk` calls `::mksync::flush` (MK Studio's `native/mksync`) when that command exists or
  `package require mksync` works, and otherwise runs `sync` as before. Nothing is required; `MKIT_NATIVE=0` never looks;
  `::mkitsql::db::flushMethod` reports the choice. A refusal by the native call is "not flushed", never raised and not retried by program.
  `tests/native_flush.tcl`: no library, a command, a package, a package without the command, a broken one, a refusal, durable 0, and a real
  mksync when installed.
* **A Metakit that refuses to write is reported as such.** A refusal of `mk::file open` / `mk::file commit` by a Metakit's own write lock or
  stale-write check is now `{MKIT LOCKED 0 unknown {} {}}` or the new `{MKIT STALEWRITE}` (`MKQL ERROR` in front), not "the commit failed, most
  likely a full disk". Nothing is rolled back, the commit record is dropped (it must never undo another writer's commit), the changes stay
  pending. Detected by `-errorcode {METAKIT|MK4|MK4TCL LOCKED|STALE}` or by words in the message (`::mkitsql::db::refusalWords`); a Metakit
  without the lock behaves as before. **Simulated only**: `tests/metakit_refusal.tcl` wraps `mk::file`; the real fork's wording is not
  known yet. README: the honest limit (one writer at a time; let one process own the file).
* **Not done:** a backup copy of the file in standalone mkit-sql (README, "What it does not have").
* Tests: `tests/commit_ack.tcl` 10, `commit_crash.tcl` 150, `native_flush.tcl` 30 (34 with a real mksync), `metakit_refusal.tcl` 34; the lint
  inventory of `open` calls in `db.tcl` is 13 (was 14). Verified with Tcl 8.6.14 and the fork's Mk4tcl (`kit-fixes`), the stand-in, both
  storage layers where they apply; tclkit 8.6.3 / 8.5.17 are exercised by CI only.

## 0.6.0 - big blobs by reference; checksums of files without a header; the kitfmt pin checked without Ribbon

* **Big blobs by reference** (new, off by default). `::mkitsql::blobLimit N` (N >= 0) makes a stored blob that the outermost `SELECT`
  returns as it is - a bare item or `*`, from a table or subview of its own `FROM` clause, mentioned nowhere else in the statement, in a
  `SELECT` without `DISTINCT`, `GROUP BY` or aggregates - come back as itself when it has at most N bytes and otherwise as a
  *reference* holding its size and first N bytes, read with `mk::get -size` and `mk::channel` (the 0.5.0 machinery) instead of the
  value. `::mkitsql::blobRef`, `blobRead ref ?offset? ?count?` and `blobCopy ref channel` (1 MiB at a time) read the rest. Joins,
  `WHERE` / `ORDER BY` on other columns, `LIMIT`, spilling sorts and `::mkitsql::stream` carry references; a reference becomes stale
  (`{MKIT BLOBSTALE db}`) when its database changes, rolls back, reopens or closes. Everything that looks at the value - conditions,
  `ORDER BY`/`DISTINCT` on the blob, expressions, derived tables, CTEs, `UNION`, subqueries - and every statement that stores what it
  selects (`INSERT ... SELECT`, `CREATE TABLE AS`, `UPDATE`, `MERGE`) gets values as before. **Unchanged by default** (`blobLimit` -1:
  whole values), so callers that rely on the value keep it. The storage layers gained `db::generation` (a change counter; MK Studio's
  `::store::generation` in the studio layer). docs/SQL.md ("Large tables and memory"), docs/COMPATIBILITY.md (stable surface).
* **MK Studio uses it** (`mkitsql/engine_studio.tcl`): with a MK Studio whose `engine.tcl` declares `::engine::blobPreview` (10 bytes:
  what its grid shows of a bytes cell) the limit is set to that and `::engine::blobRef` answers for references, so a query that selects
  a 1 GB value no longer loads it. An older MK Studio keeps whole values.
* **Fixed: a commit of a file without a Metakit header left its old checksum behind.** `db::beginCommit` returned before removing
  `<file>.sum` when no commit record can describe the file (no header at offset 0), and `commit` wrote no new one, so a stale checksum
  sat beside every later commit of such a file (next to a newer file of the same size and second it would call that file damaged). The
  sum is now removed before every commit and rewritten after it, record or not. (The same fix as MK Studio's store; found there by its
  UI tests on the stand-in Mk4tcl, whose files have no Metakit header.)
* **The pinned kitfmt is checked without Ribbon.** Ribbon is private, so CI could not compare `tests/vendor/kitfmt` with it.
  `tests/sync-kitfmt.sh` now records, in `SOURCE`, each vendored file's git blob id at the pinned commit and its SHA-256; `--verify`
  checks the copies against them with no Ribbon at all (CI job `kitfmt`, every push), `--check RIBBON` compares with any clone that has
  the commit, `--upstream RIBBON` warns when Ribbon's kitfmt has moved on, and `--compare SOURCE` compares two pins. CI runs `--check` and
  `--upstream` when the secret `RIBBON_READ_TOKEN` can read atyr647/ribbon (otherwise a visible warning, never a pass), and the `mkstudio`
  job compares this pin with the kitfmt MK Studio carries and runs `tests/kittables.tcl` on MK Studio's copy (`KITFMT_DIR`). The pin
  moved to ribbon `49fd4b0` (the commit MK Studio carries; kitfmt gained `extract -progress`).
* Tests: `tests/blobs.tcl` 29 -> 89 (references: inline and referenced values, head and size, ranged and whole reads, copy, every
  form that passes a reference and every one that must read the value, the storing statements, a spilling sort, stream, stale and
  forged references, limit 0, both storage layers, the stand-in); `tests/kittables.tcl` checks it read with the kitfmt it was given.
  Verified with tclkit 8.6.3 and 8.5.17 (built-in Mk4tcl), Tcl 8.6.14 with the fork's Mk4tcl, both storage layers and the stand-in.

## 0.5.0 - virtual tables, the kit.* tables, big blobs read only when needed

* **Virtual tables.** `::mkitsql::registerVirtual schema table columns rowsCmd` adds a read-only table whose rows come from Tcl code;
  `unregisterVirtual` and `virtualTables` go with it (docs/SQL.md, "Virtual tables"; on the stable surface, docs/COMPATIBILITY.md).
  Rows are checked (width, numbers in number columns, no forged NULL). `information_schema.tables` / `columns` are now its first two
  tables (same rows; the list in the "unknown table" message is sorted). Another schema never hides an open database's tables.
* **`kit.*` tables** over a Ribbon kit (`kit.info`, `manifest`, `needs`, `provides`, `perms`, `entries`, `effects`, `files`, `chunks`,
  `image`, `verify`), through Ribbon's reference reader **kitfmt**, which mkit-sql loads with `package require` when a `kit.*` table is
  read and does not carry (MK Studio does). The kit is the statement's default database or the only open kit; kitfmt opens it read-only
  on its own, checks seal and root first, and never fetches a chunk whole without its size. `kit.verify` hashes every chunk.
* **Big blob values are read only when a statement needs them.** On a view with a 300 MB blob, `SELECT name, LENGTH(data)`,
  `SELECT * ... WHERE n = 1` and `SELECT * ... LIMIT 1` went from about 5 s to about 1 ms (a 953 MB blob had taken 29 s):
  `LENGTH` / `CHAR_LENGTH` / `OCTET_LENGTH` of a blob column use Metakit's stored size, literal `SUBSTR` ranges are read through
  `mk::channel`, blobs a scan's filter does not look at are read only for the rows that pass, one at a time, and the column guard
  measures committed values by their size. **Changed:** `OCTET_LENGTH` of a blob column is its size in bytes (it counted bytes above 127
  twice); on a computed value it is unchanged.
* **Fixed: the sort-merge join missed matches on keys with a NUL byte.** An equality join whose right side passes the memory budget
  sorted with `lsort -ascii` and merged with `[string compare]`, which order byte arrays differently (a NUL byte sorts last for lsort,
  first for string compare); blob keys such as `X'00FF'` found no partner. The merge now uses the sort's own order.
* Removed the stray empty file `&1` from the repository again (it came back in c9c0f45).
* Tests: `tests/blobs.tcl` (29: every rewritten form against the plain function on the whole value, whole-value reads counted by
  wrapping `mk::get`, the merge-join regression), `tests/kittables.tcl` (50: the registry's checks and name rules, `information_schema`,
  every `kit.*` table on Ribbon's golden kits incl. a damaged one, read-only and no side files, the error without kitfmt). The pinned kitfmt
  and three golden kits are in `tests/vendor/kitfmt` (`tests/sync-kitfmt.sh`, `SOURCE` names the commit). The stand-in Mk4tcl answers
  `mk::get -size`. Verified with tclkit 8.6.3 and 8.5.17 (built-in Mk4tcl), Tcl 8.6.14 with the fork's Mk4tcl (`kit-fixes`), both
  storage layers, and the stand-in; lint, fuzz, the SQLite differentials (diff, dml) and the review regressions pass.

## 0.4.2 - the column guard counts what Metakit really keeps in a column; the 64-bit Metakit's size errors

* **A blob or text column can hold far more than 2 GiB** (the 64-bit Metakit). The column guard added in 0.4.0 counted every value of a column against
  the 2^31-1 byte limit, so a table of big blobs was refused at 2 GiB although Metakit can hold it. Read from Metakit's `format.cpp` and checked on a real
  database: all values of a text or blob property live in one shared column, **except** that each commit moves every value over 10,000 bytes (and, in
  tables of very many rows, smaller ones) into a column of its own, which has the limit alone. The shared column therefore holds what has been written
  since the last commit (all of it) plus the committed values of at most 10,000 bytes - and that is what the guard counts now (per column: the bytes
  written since the commit, the part of them in big values that leaves at the commit, and the committed small values, found by one pass over the column
  the first time it matters and kept up to date after). `tests/widebig.tcl` writes 2.1 GiB into ONE blob column (committing every 50 rows) and reads it back;
  about 2 GiB of uncommitted values in one column are still refused, with a message that says to commit.
* **The 64-bit Metakit's "size errors"** (commit `2e2e482` of the fork): an edit that would still pass the limit no longer ends the program; Mk4tcl returns an
  error and marks the storage, which can then only be rolled back (every commit fails until it is). `appendRow`, `setCell` and the column copy of `ALTER ... TYPE` turn that
  into `{MKIT COLUMNFULL view column}` (the studio layer: `{STORE COLUMNFULL ...}` from MK Studio's store), the handle remembers the mark and a commit
  is refused at once - nothing written, no commit record, the checksum kept - with `{MKIT TAINTED}`; `ROLLBACK` lifts it. `ALTER ... TYPE` also runs its copy through the guard now.
* `tests/build_mk4tcl_wide.sh` pins the fork at `2e2e482`. Tests: `tests/widefile.tcl` (the stand-in for Mk4tcl's error, both layers; the studio layer only with a store.tcl that has
  the handling: `MKIT_STORE=<MK Studio's current store.tcl>`), `tests/widebig.tcl` (one blob column past 2 GiB; 2 GiB uncommitted refused; Metakit's real error with the guard off).

## 0.4.1 - lock takeover, unreadable locks, Windows flush

* **The takeover of a stale lock no longer deletes it by name.** A killed process leaves the takeover guard behind; every waiter
  deletes it once it is 10 s old, by name, and one of them can delete the *fresh* guard another has just made, so two processes were
  inside the takeover together - and the second then destroyed the first one's brand-new lock (found by MK Studio's lock soak on a macOS runner, reproduced on
  demand by `tests/lock_takeover.tcl`). The lock is now *looked at without moving it* (a hard link gives the file under the name a second name; the slow judgement - is its process
  alive? how old? - happens while the lock keeps its place, and a live lock is simply left alone); only a stale one is moved, by one atomic rename, after checking that the name still
  names the file that was judged and checking again what was moved (a lock replaced in the last instant is put back). A wrongly removed guard can no longer hurt. Files a killed process
  leaves are named `<file>.lock.take.<second>.<pid>.<n>` and tidied once older than a minute and their process is gone.
* **After writing its pid into a new lock a process checks the file under the name still holds it.** A process held up between creating the file and writing it
  (taken for dead and overtaken) used to "acquire" while the other owned the database; it now notices and starts again.
* **A lock file that exists but cannot be read counts as held** (it used to count as free: another user's lock under a strict umask was taken over).
* **The Windows flush runs** when the host is a GUI program (a wish-based tclkit): PowerShell started straight from a program without a console does nothing at all
  (status 0, no output, no effect); it is now started through `cmd /c` with `-EncodedCommand`, which also carries accented file names intact. `tests/syncdisk.tcl` now requires that a script really wrote a file.
* `integration/install-into-mkstudio.sh` says so and exits 0 when the MK Studio it is given already carries mkit-sql.
* **The checksum file is flushed after it is rewritten** (`sumWrite`), as MK Studio's store does: with the commit record and the removal of the old sum at the start of a commit
  (already done here) a power cut now leaves either this file's own checksum or none - found by MK Studio's block-level crash test, where an old checksum next to a newer good
  file of the same size and modification second was called "damaged".
* `tests/damage.tcl` reads a file the verifier passed **in a child process** (retried twice; killed after 90 s): Metakit can crash or loop on damaged data, and one CI run in four
  used to lose the whole suite to a segmentation fault in the test process.
* `ORDER BY ... LIMIT n` over hundreds of thousands of rows is measured, not guessed: 300,000 rows take 2.3 s here, and Metakit's own `mk::select -sort` takes 2.2 s for the same
  rows (and its `-count` limits the selection *before* sorting, so it cannot give a top-N) - there is nothing cheaper to push down; docs/SQL.md has the numbers.
* Added the `LICENSE` file (MIT); removed a stray empty file and a compiled Python cache that had been committed.
* Tests: `tests/lock_takeover.tcl` (29: claimStale step by step, three starved-process scenarios, two reapers of one guard; `tests/lock_stall_child.tcl`),
  `tests/lock_crash.tcl` gained the kill after moving the lock aside. Verified with both tclkits, `kill -9` chaos (0 violations), and MK Studio's own lock tests in both directions.

## 0.4.0 - production-readiness pass

* First-commit record (`empty 0`) and Windows flush follow MK Studio's newest `store.tcl`; `integration/mkstudio.patch` rebased onto its current HEAD (list-bug-safe row reads, footer guard in its `repairFile`).

* Verified at release: 138 local suites (both tclkits, both backends, memory-pressure configs, differential vs SQLite, 20M-row run on real Metakit) and all 8 CI jobs, including real Metakit on Windows and macOS and MK Studio's own interop checks.
* What this release does not claim: a real power-cut test (commits are tested by killing the process and by simulated torn writes, not by cutting power), Windows multi-user stress testing, and anything beyond Metakit's own limits (2 GiB file, no persistent indexes) - see docs/SQL.md.

### Ready for the 64-bit Metakit (files over 2 GiB)
* **`::mkitsql::db::wideCapable`** finds out whether the loaded Mk4tcl reads files over 2 GiB by trying a tiny wide file it builds itself (a behaviour test, no version number); `MKIT_WIDE=0` forces "no". `fileLimit`, `fileHeadroom` and `nearLimit` follow it.
* **A wide file under a Mk4tcl that cannot read it is refused** (`{MKIT WIDEFILE}`, both storage layers, every open mode): stock Metakit would show an empty database and a commit would hide the data.
* **Wide-aware frame checks:** `headerInfo`, `footerOkAt` (24-byte footer), the open-time frame check, the commit-record repair and its safety check all understand the wide format.
* **Column guard:** in the 64-bit Metakit one column is still limited to 2^31-1 bytes and Metakit ends the program when an edit grows past it; `INSERT` / `UPDATE` check first and fail with `{MKIT COLUMNFULL view column}` (costs nothing until the file nears 2 GiB).
* The `-verify` helper process loads the same Mk4tcl as its caller (it used to need `package require Mk4tcl`, which a Mk4tcl loaded by path does not provide).
* Tests: `tests/widefile.tcl` (any Mk4tcl, small files), `tests/widebig.tcl` (2.9 GB, commits across 2 GiB, a column refused at 2 GiB, six commits killed mid-write), `tests/build_mk4tcl_wide.sh`; CI job `metakit-wide`. `tests/bigfile.tcl` (the stock ceiling) skips itself on the 64-bit Metakit.

### Closing the known limits
* **Metakit's 2 GiB file limit** (measured: a commit that would cross it fails and, if big, leaves a file that crashes Metakit on open):
  the commit is undone from its record, the handle reopened, and the error `{MKIT COMMITFAILED size}` names the limit. `tests/bigfile.tcl`.
* **Correlated subqueries are remembered per distinct outer key** (`::mkitsql::maxMemo`), so a correlated scalar / `EXISTS` / `IN` / `ANY` / `ALL`
  subquery costs one run per key instead of one per outer row. The 20,000-row / 10-key case: 0.3 s (it was quadratic). `tests/decorrelate.tcl`
  compares 25 query shapes with the shortcut on and off.
* **Window functions:** `EXCLUDE CURRENT ROW | GROUP | TIES | NO OTHERS` (1,152 queries agree with SQLite), `DISTINCT` in window aggregates (extension),
  `IGNORE NULLS` / `RESPECT NULLS` on `LAG LEAD FIRST_VALUE LAST_VALUE NTH_VALUE`. `tests/window_ext.tcl` (brute-force reference).
* **`GROUP BY ROLLUP / CUBE / GROUPING SETS / ()` and `GROUPING()`**, also combined with plain keys; run as one `GROUP BY` per set joined by `UNION ALL`.
* **`SIMILAR TO`** (SQL regular expressions), **`COLLATE BINARY | NOCASE`** (comparisons, `IN`, `BETWEEN`, `LIKE`, `ORDER BY`, `GROUP BY`).
* **`SUM`, `AVG`, `MIN`, `MAX` over intervals**, plain, grouped, `DISTINCT` and windowed (also with spilling aggregation).
* **Duplicate column names in derived tables and CTEs** (`SELECT * FROM (SELECT a.id, b.id ...)`).
* Fixes from the storage review: a commit record that cannot be deleted after a successful commit is emptied (it used to roll the acknowledged commit back at the next open; an `empty 0` record could empty a finished database), a failed commit on MK Studio's store is undone and reported too, a partial commit record is removed, `commitUnprotected`, no repair without the lock, a read-only open that fails no longer leaks the handle, an undeletable stale lock gets its own error, the interrupted-first-commit repair truncates before it removes its record, `commitFailed` closes before repairing and checks the file before reopening. `tests/commitfail.tcl` (file-size limit via `prlimit`, both layers).
* **Windows:** `int()` keeps only 32 bits on 64-bit Windows Tcl 8 (found by the real-Metakit Windows CI run: dates before 1901 and BIGINT casts went wrong); every `int(` is `entier(` now and lint refuses `int(`.
* **Speed of repeated statements:** the parse of a text is remembered (256 texts) and verified generated code is not verified twice (parameterised `INSERT` 265 us -> 105 us, `SELECT 1` 108 -> 43 us); a faster tokenizer loop; and **`::mkitsql::insertRows`** for bulk loads from Tcl lists (13 us a row, against 150 us a row for a big `INSERT ... VALUES`, whose cost is the SQL parse). A profile of where the rest of a statement goes is in docs/SQL.md ("Speed").
* **Gold-standard pass:** `-verify` is a proof when the file has its checksum (`<file>.sum`, MK Studio's format, written after every commit; levels `proven` / `evidence`, `integrityOf`; `tests/attest.tcl`, MK Studio's own check agrees); the aggregate fold works a chunk at a time (`SUM/AVG` over 50,000 rows 615 -> 195 ms, `GROUP BY` 566 -> 309 ms; `tests/aggfast.tcl`); row reads unrolled; a 3.3x faster tokenizer and a lone-literal parse shortcut (bulk `INSERT ... VALUES` text 190 -> 85 us a row; `tests/tokenizer.tcl` against the original on 41,000 texts); `fileHeadroom` / `nearLimit` for the 2 GiB ceiling; the 2 GiB, persistent-index and tcl-aot questions answered in docs/SQL.md.
* `MKIT_DURABLE=0` turns the post-commit flush off (test machines); `tests/syncdisk.tcl` proves the flush works on the system.
* CI: real-Metakit runs on Windows and macOS (MK Studio's own tclkits, fetched by SHA1), `tests/fetch-tclkit.sh windows|macos`.
* `tests/bench/big.tcl`: 20,000,000 rows on real Metakit.

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
* Names starting with `__mks` are reserved (tables, columns, renames). Two columns of the same name in a derived table or CTE are
  allowed, and only a *reference* to that name is an error ("ambiguous"); an explicit column list `t(a, a)` must be distinct. (They used
  to silently return the last column's value for both.)
* `REAL` columns (32-bit) refuse values beyond about 3.4e38 instead of storing infinity; whole-number columns refuse
  `1e999`, infinities and values beyond 64 bits; a numeric literal that is not finite (`1e999`) is a syntax error.

### Added
* `tests/perf_guard.tcl` (coarse performance ceilings in CI) and `tests/soak.tcl`.
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
