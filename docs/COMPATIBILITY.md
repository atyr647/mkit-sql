# Versioning and compatibility policy

mkit-sql is **0.x software**: it is carefully tested, but its public interface is not frozen yet. This page says what you
can rely on and how changes are announced, so a program or MK Studio can depend on it knowingly.

## What is public

| Surface | Stability |
| --- | --- |
| `package require mkitsql`; `::mkitsql::run`, `::mkitsql::query`, `::mkitsql::stream` (arguments and result shape) | stable within a minor version |
| The documented configuration variables: `memBytes`, `chunk`, `tempDir`, `maxRows`, `maxRecursion`, `maxBinds`, `autocommit`, `session`, `nullText`, `ignoreConstraints`, `pushdown`, `pushMin`, `bulkMin`, `progressHook` | stable within a minor version |
| The storage interface `::mkitsql::db::*` (`openFile closeFile tags views layout size rows rowsAt subSize appendRow setCell deleteRows deleteRange clearView createView dropView restructure rebuildColumn commit rollback dirty readonly lockedBy holdsLock`) | the contract between the engine and its two storage layers; changes only together with `db.tcl`, `db_studio.tcl` and a version bump |
| The SQL accepted and its results, as written in docs/SQL.md | additions are compatible; behaviour that docs/SQL.md states changes only in a minor version, listed under *Breaking* in the changelog |
| `-errorcode` classes: `MKQL SYNTAX pos len`, `MKQL ERROR`, `MKQL ERROR DATA`, `MKQL ERROR MKIT code ...` (`LOCKED`, `DAMAGED`, `TYPECONFLICT`, `BADLOCK`) | the first three words are stable; later words may gain elements (callers should index from the front and ignore extras) |
| The lock-file format and takeover guard | the protocol of MK Studio's docs/CONCURRENCY.md; it changes only if that document does |
| Everything else: other `::mkitsql::*` procs and variables, generated code, plan dictionaries, `::mkitsql::rt::*`, spill-file format, `EXPLAIN` text | **internal**; may change in any release |

## Versions

* `MAJOR.MINOR.PATCH`. While MAJOR is 0, a **minor** bump (0.3 -> 0.4) may contain breaking changes; a **patch** bump
  (0.4.0 -> 0.4.1) only fixes bugs and never changes documented behaviour except where the old behaviour was wrong
  (a wrong result, a crash, a security problem).
* At 1.0.0 the stable surface above freezes and normal semantic versioning applies: breaking changes only in a new major
  version.
* Every release has a `CHANGELOG.md` entry; breaking changes are listed first, with what to do instead.

## Deprecation

A documented feature is not removed without notice where that is possible: it is announced in the changelog and, where it
can be detected at run time, kept working with a clear message for one minor version. Exceptions, which are removed or
refused at once and say why: anything that **corrupted or could corrupt data** (`ALTER COLUMN TYPE` was removed for this
reason), and anything that was a **security hole**.

## Runtimes and file format

* Supported Tcl runtimes are the two MK Studio is built on: tclkit **8.6.3** (primary) and **8.5.17**. Support for a
  runtime is not dropped within a minor version; `tests/lint.tcl` keeps the code free of anything newer. **Tcl 9.0 is supported** too: the engine requires `Tcl 8.5-10`, and CI runs the whole suite that does not need real Metakit (engine,
  injection, NULL forgery, spill, robustness, review regressions, temp files, locking, lock crashes, soak, fuzzing, and the SQLite / oracle
  differentials) on Tcl 9.0.1 built from source, using the pure-Tcl stand-in - Mk4tcl itself has no Tcl 9 build, so real-Metakit tests
  stay on the 8.x runtimes. Newer 8.6 versions (8.6.14) are exercised the same way.
* The database file format is Metakit's. mkit-sql never changes the format: files it writes are ordinary Metakit files
  that MK Studio and every other Metakit tool can read, and the reverse.
* Platforms: Linux is tested on every change. macOS (Tcl 8.6) and Windows (Tcl 9) run the platform-neutral part of the suite on the stand-in in CI, and macOS also the
  temp-file and locking tests. The locking and temp-file hardening that rely on Unix semantics (`/proc`, 0700 folders,
  `kill -0`) have lighter Windows fallbacks that are **not** equivalent in strength: treat Windows as best-effort, and do
  not rely on it for several users on one machine.

## Reporting a problem

A wrong result, a crash, a hang, a raw Tcl error (`MKQL ERROR RUNTIME`), or data damage is a bug in every case. Please
include the statement, the schema, and the Tcl version (`info patchlevel`).
