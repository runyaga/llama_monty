# Phase N6 — `find -type f` / `-type d` filter

Reply to `FINDING_find_type_filter_ignored.md` (and its retraction).

- **commit**: `d0a0ff3` (Phase Next N6: find -type filter)
- **date**: 2026-05-09

## TL;DR

Shipping anyway despite the retraction. The bug was real on the prior
dispatch (substring-match over all paths, `-type` token ignored); your
re-probe must have hit a different transcript or a stale dylib. Source
inspection at `0cdb5c5..1b5e4d2..8e444a8` confirms the original finding.

## What changed

`find` is now POSIX-shaped:

```
find /data                  → 4 paths: /data + 3 files (was: 3 files)
find /data -type f          → 3 file paths
find /data -type d          → /data
find /data -type d | wc -l  → 1 (was: same as files)
find -type f | wc -l        → 6 (file count)
find -type d | wc -l        → 2 (dir count)
```

### Inferred-dirs algorithm

Every non-root parent of an in-memory file path is a directory. Empty
in-memory dirs can't exist — the shell is read-only by design (no
`mkdir`, `mv`, `cp`, `rm`, `>` redirects on the allow-list, all
write-side commands rejected with `<host error -3>`). So the prefix-
based inference is *complete* for the in-memory VFS.

Mounted directories (FFI-only) walk on-disk metadata via a new
`walk_mount_dirs` helper. Empty disk subdirs are visible.

Root `/` is excluded from `-type d` enumeration (it's the implicit
root, never something a consumer enumerates against).

### Default change

`find` (no `-type`) now lists files **AND** inferred dirs together.
Previous behaviour was "files only" by accident (we didn't track
dirs). The new default matches POSIX find and your retraction's
probe (`find /tmp` → 6 paths = 3 files + 3 dirs).

This is technically a contract shift. Existing call sites that
relied on "files only" need `-type f` explicit. We updated three
internal tests (`xargs_test.dart`, `mount_dir_test.dart`,
`commands_test.dart`) for this; the bench's existing `find /dir |
xargs cat` patterns may need the same edit.

## Tests

10 new cross-backend tests in `dart/test/find_type_test.dart` (tag
`commands`):

- `find` (no -type) lists files + inferred dirs
- `find -type f` returns files only
- `find -type d` returns directories only
- `find -type f | wc -l` counts files (the canonical idiom)
- `find -type d | wc -l` counts directories (the **previously broken**
  case — would return same count as `-type f`)
- `find PATH -type f` filters by substring + type
- `find PATH -type d` filters by substring + type
- `find -type X` (unknown) falls back to permissive default
- `find PATH -type` (no value) — `-type` dropped, pattern preserved
- `find /logs -type f | xargs wc -l` (canonical "count lines under X")

Both backends (VM + chrome) green: 104 commands tests, 9 manifest, 16
mount, plus the standard 4+5+9 wasm/ffi/agent suites. Clippy / dart
analyze / dcm clean.

## What this should flip in your bench

If you adopt the suggested Z-tier canary spec from your finding
(`Z14_find_type_d_distinct`), it should pass. Any existing M-tier
or X-tier specs that relied on "find returns just files" need
`-type f` updated.

## What this does NOT ship

- `-name pattern` — substring-match-on-path coincidentally covers
  the model's `find -name "*.log"` form (paths happen to contain
  `.log`); below ship-threshold.
- `-exec` / `-print0` — your retraction confirmed `-exec` still
  silently ignored. Workaround exists (`find ... | xargs cmd`).
  Below ship-threshold; watch-list only.
- `-maxdepth`, `-mindepth`, `-newer`, `-mtime` — never observed.

## Read-only shell, formally

The `mkdir / mv / cp` observations during this exchange surfaced
something worth codifying: **the shell allow-list is read-only by
design**. The model cannot mutate the VFS through any shell
command. All writes are embedder-initiated via the typed Dart API
(`loadTree`, `writeFile`, `clearVfs`, `setCwd`, `mountDir`).

This has implications for the upcoming API overhaul (M3 lands in
the next few weeks per the runbook):

- `WasmHost.open()` will gain an optional `DestructiveActionGate`
  parameter. Today it never fires — there's nothing destructive to
  gate. Reserved so future signal-driven additions (rm/mv/cp/`>`)
  can wire through without breaking consumers.

If you ever surface a model-side use case that requires writes
(fixture-generation, scratch space, multi-turn state), let us know
— that signal would be the trigger for the gate to actually fire,
which is the moment we'd want HITL-aware UI integration.

## Files

```
host/src/lib.rs                           (exec_find rewrite; enumerate_dirs; walk_mount_dirs)
host/src/manifest.json                    (find syntax updated)
host/src/help.md                          (find docs updated)
dart/lib/src/host_emulation.dart          (mirror; _enumerateDirs)
dart/test/find_type_test.dart             (new; 10 tests)
dart/test/commands_test.dart              (find expectations updated for new default)
dart/test/mount_dir_test.dart             (find test uses -type f)
dart/test/xargs_test.dart                 (xargs tests use -type f)
```

Pause holds. Next ship is the API overhaul (M0–M3 per
`~/dev/plans/dart-wasm-sandbox-api-execution-runbook.md`). M1
arrives behind `package:dart_wasm_sandbox/next.dart` so your bench
port can dual-import at your pace.
