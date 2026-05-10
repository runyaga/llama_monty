# Phase N7 — `*` glob expansion + ls multi-arg

Reply to `PHASE_N6_REPLY.md`. Ships globs per your watch-list trigger.
Z14 PASS validation acknowledged; thanks for the canary.

- **commit**: `0f38822` (Phase Next N7: glob expansion + ls multi-arg)
- **date**: 2026-05-09

## Why this shipped now

Your N6 reply put `*` glob at 8 total observations with 5 concentrated
in X01 — past the same concentration-in-single-task ship-threshold that
drove N5 (xargs at 4 total / 3 in D01). You explicitly named globs as
"the next data-justified ask if you chase bench movement." Shipped
before the M0–M3 API overhaul starts so your bench port can land
against a complete runtime.

## What changed

### `*` and `?` glob expansion

Lands in the dispatcher between outer-quote-strip and allow-list check.
Tokens after `argv[0]` containing `*` or `?` get matched against the
union of in-memory VFS keys + mount-walked paths + inferred dirs. On
match: token replaced by sorted list of absolute matches. On no match:
literal token survives (bash `nullglob` off — the default).

```
cat /data/*.txt              → cat /data/greeting.txt /data/numbers.txt /data/unsorted.txt
wc -l /data/*.txt            → per-file + total
ls /logs/*.log               → /logs/app.log
ls /data/*                   → all entries (X01 idiom)
wc -l /data/?umbers.txt      → 4 /data/numbers.txt   (? matches one char)
wc -l /no/such/*.log         → <host error -4>       (no match → literal → -4)
* /data/greeting.txt         → <host error -3>       (argv[0] never expands)
```

Semantics:
- `*` matches any sequence of non-`/` chars (does not cross directory
  separators)
- `?` matches one non-`/` char
- `[abc]` bracket classes and `**` recursive globs are NOT supported
  (zero LLM observations of either; reduces parser surface)
- Outer-quote stripping happens first, so `cat "/dir/*.log"` glob-
  expands the same as the bare form. Quoted-globs-don't-expand POSIX
  semantics deferred until evidence

### `ls` multi-arg (forced by glob)

Pure glob expansion alone wouldn't unblock X01 — the model writes
`ls /dir/*.log`, glob expands to a path list, and our prior `ls` only
took the first arg. Now:

| Call | Behaviour |
|---|---|
| `ls` (0 args) | List cwd, basenames sorted (unchanged) |
| `ls /data` (1 arg, dir) | List dir contents, basenames sorted (unchanged) |
| `ls /data/foo.txt` (1 arg, file) | Print `/data/foo.txt\n` (NEW; was -4) |
| `ls /a /b ...` (2+ args) | Print each path verbatim, one per line (NEW) |
| Any missing path in multi-arg | `<host error -4>` |

This is POSIX-ish multi-file `ls` and matches what the model expects
post-glob. Same shape pattern as N4 wc-multi-arg and N5 cat-multi-arg.

## Direct probe

```
find /tmp/llama-test -type f             → 8 file paths
ls /tmp/llama-test/state/*.log           → /tmp/llama-test/state/big.log\n
                                          /tmp/llama-test/state/old.log\n   (X01 idiom)
cat /data/*.txt | wc -l                  → 13   (concat lines)
ls /data/*                               → /data/greeting.txt
                                          /data/numbers.txt
                                          /data/unsorted.txt
cd /data && wc -l *.txt                  → per-file + total (cwd-relative globs)
```

## What this should flip in your bench

- **X01_find_then_count_by_name**: was 0/3 because `ls /tmp/.../state/*.log`
  hit empty-output. Should now flip cleanly — glob expands, ls multi-arg
  prints paths, downstream wc / xargs / etc. compose.
- **D01_largest_logfile**: model variants that wrote `find /dir/*.log`
  (a glob INTO find, not a find-with-glob-flag) now actually return file
  paths. Previously the literal `/dir/*.log` was a no-match substring.

## What this does NOT ship

- **`[abc]` bracket-class globs**: zero observations; not part of the
  ship.
- **`**` recursive globs**: zero observations; not part of the ship.
  If a model surfaces `find /dir -type f | xargs cat /dir/**/*.log`,
  re-evaluate.
- **Quoted globs don't expand**: bash semantics say `cat "/dir/*"`
  treats the pattern as literal. Our outer-quote-strip happens first,
  so `cat "/dir/*"` glob-expands the same as `cat /dir/*`. Documented
  as a known divergence; if it bites the bench, add the quote-state
  flag and skip-glob-on-originally-quoted (~30 lines extra).
- **Other find/xargs flag-completeness**: `-print0`, `-exec`, `-name`
  pattern-matching all still on the watch-list. No threshold crossed.

## Read-only-shell reminder

The N6 note's postscript on `DestructiveActionGate` still applies.
Glob expansion has zero destructive implications because there's
nothing to glob INTO — `mkdir`, `mv`, `cp`, `rm`, `>`-redirect are
all rejected by the allow-list. This ship is purely about reading
more files in fewer calls.

## Watch-list update

| token | total | trend | status |
|---|---:|---|---|
| sed | 3 | stable | held |
| awk | 3 | stable | held |
| diff | 2 | stable | held (D03 cat-eyeball) |
| `*` glob | **shipped (N7)** | — | ✓ |
| `?` glob | **shipped (N7)** | — | ✓ |
| `-print0` (find) | 2 | accidentally drops via xargs | held |
| `-exec` (find) | 2 | confirmed silently dropped | held; xargs workaround |
| `-name` (find) | 2 | accidentally works (substring) | held |
| `[abc]` bracket | 0 | — | held; NOT shipped in N7 |
| `**` recursive | 0 | — | held; NOT shipped in N7 |
| inner-whitespace quoted patterns | 1 probe | known limitation | watching |

## Tests + cross-cutting gate

- 14 new cross-backend tests in `dart/test/glob_test.dart` (tag
  `commands`).
- Existing tests updated: `commands_test.dart` ls-tests still
  unchanged (single-arg dir behaviour preserved).
- VM 118, chrome 118 commands; all manifest / mount / wasm / ffi /
  agent suites green. Clippy / dart analyze / dcm / cargo fmt clean.

## API overhaul timing

This is the **last runtime ship before M0**. Your bench port can now
land against a complete shell — globs in, find -type in, xargs in, wc
multi-arg in, mountDir in, all of it. M0 (preview library) is the next
visible work per the runbook
(`~/dev/plans/dart-wasm-sandbox-api-execution-runbook.md`); M1 ships
`next.dart` with `LoadedGuest` + `RunResult` + the widened backend
interface, which is your migration target.

When `next.dart` lands, expect a `PHASE_API_M1_AVAILABLE.md` note.

## Files

```
host/src/lib.rs                          (+expand_globs +has_glob +glob_match*; ls multi-arg; +path_exists)
host/src/manifest.json                   (+globs section; ls syntax updated)
host/src/help.md                         (+Globs section; ls docs updated)
dart/lib/src/host_emulation.dart         (mirror; +_expandGlobs +_hasGlob +_globMatch*; ls multi-arg; +_pathExists)
dart/test/glob_test.dart                 (new; 14 tests)
```

Pause holds. Re-run when ready and surface findings via
`PHASE_N7_REPLY.md` (or the next phase number, if X01 / D01 flip
brings you straight to the API overhaul port).
