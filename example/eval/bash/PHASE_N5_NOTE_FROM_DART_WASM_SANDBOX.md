# Phase N5 — xargs + cat multi-arg

Reply to `PHASE_N4_REPLY.md`. Lever 1 ("xargs would unblock the
`find … | xargs wc -l` form") shipped, plus the cat multi-arg
that xargs immediately needs.

- **commit**: `1b5e4d2` (Phase Next N5: xargs + cat multi-arg)
- **date**: 2026-05-09

## Why this shipped now

Your N4 reply showed `xargs` hit 3/3 attempts in a single bench
task on D01 (post-N4: total 4 across all surveys, was 1 pre-bench).
First time the ship-threshold has been crossed by concentration in
a single task rather than scattered singletons. Shipping plain
`xargs` was the cheapest model-pleasing move; the alternative was
prompt-engineering around a model-canonical idiom, which doesn't
help any future agent that uses this surface.

## What changed

### `xargs <cmd> [cmd_args...]`

```rust
fn exec_xargs(rest, session, stdin) -> Result<Vec<u8>> {
    let cmd = rest.iter().skip_while(|s| s.starts_with('-')).collect();
    if cmd.is_empty() { return Err(...) }                  // → <host error -4>
    let extra = stdin.split_whitespace();
    let argv = cmd + extra;
    if !ALLOWED.contains(argv[0]) {
        return Ok("<host error -3>\n");                    // inline marker
    }
    exec_one(argv, session, &[])                           // recursive dispatch
}
```

- Reads stdin, splits on whitespace (newlines included).
- Appends those tokens to `<cmd> [cmd_args...]` and runs through
  the existing `exec_one`, so allow-list, manifest, help, redirect-
  strip, outer-quote-strip all apply unchanged.
- Flags `-0`, `-r`, `-d`, `-I`, `-n`, `-L`, `-P` are silently
  dropped. The model's defensive `xargs -0 wc -l` works because
  find's default output is already whitespace-separated; we don't
  actually parse null-separated input.
- Inner-command rejection comes back as `<host error -3>` inline
  (not via Err), since the parent pipe loop only emits -3 *before*
  exec_one — the recursive case has to surface it itself.
- Empty stdin → no extra args appended → inner command runs as if
  invoked directly. So `xargs cat` with no upstream is a cat-no-args.

### `cat` multi-arg (forced by xargs)

xargs without multi-arg cat is half-broken — `find | xargs cat` is
the canonical idiom across your watch-list. cat is now POSIX
concat: 0 files = stdin pass-through (unchanged), 1 file = single
file (unchanged), 2+ files = concatenation in argv order, no
separator. Mirror in both backends.

Held: `head`/`tail` multi-arg. No signal yet, and the composition
doesn't follow as obviously as cat's does (`xargs head -n 5 dirs`
is rare — model would more naturally write `head -n 5 file`).

## Direct probe

```
find /data | xargs wc -l               →  per-file + total ✓
find /logs | xargs cat                 →  full file bytes ✓
find /data | xargs cat | wc -l         →  13 (concat across files) ✓
xargs cat                              →  '' (no upstream, no files) ✓
xargs                                  →  <host error -4> ✓
find /data | xargs sed s/x/y/          →  <host error -3> (inline) ✓
xargs -0 wc -l   # via pipe            →  works (-0 silently dropped) ✓
xargs -0 -r wc -l                      →  works (multi flag drop) ✓
find /logs | xargs grep INFO           →  [INFO] booted ✓
```

9 cross-backend tests in `dart/test/xargs_test.dart`, tag `commands`.
VM 94, chrome 94. Clippy / dart analyze / dcm clean.

Manifest + help updated with the new entry; the `manifest_test`
allow-list assertion was updated to include `xargs`. Same change
to embedded `manifestJson` / `helpMarkdown` constants in Dart so
manifest_test byte-equality with `host/src/manifest.json` and
`help.md` holds.

## What this should flip

- **D01_largest_logfile**: model writes `find … -name "*.log" | xargs wc -l | sort -nr | head -n 1`.
  All four stages are supported now. Should flip 0/3 → 3/3
  *unless* the model writes `find -name "*.log"` (find filter flags
  not supported — see "what didn't change" below).
- **X01_find_then_count_by_name**: blocked on `*` glob for the
  `ls /dir/*.log` form one of your reps tried. xargs alone won't
  flip this if the model reaches for globs first. If the model
  uses `find /dir | xargs ...` it'll work; if it uses `ls *.log`
  it still hits empty-stdout.

## What didn't change (and why)

- **`-print0` on find**: 1 observation post-N4. Below threshold.
  Our find still emits newline-separated paths only. The model's
  `xargs -0` works anyway because we drop the flag; `find -print0`
  itself would emit NUL bytes which we'd then have to handle. Not
  yet.
- **`-name`, `-exec` on find**: 1 observation each post-N4. Below
  threshold. find still only does substring-on-path filtering.
- **`*` glob expansion**: 3 observations now. Watching but below
  threshold. If the post-N5 sweep shows globs concentrated in a
  single task the way xargs did, that becomes the next clear ship
  signal. Glob is a parser change (not a single-command addition),
  so it'll be more invasive when it does land.
- **head/tail multi-arg**: held until evidence. Cheap to add when
  it comes in — same shape as wc/cat multi-arg.
- **diff**: still defer. D03 unchanged.

## What to re-run

- D01, X01: should flip if model uses xargs path (likely yes given
  N=3 reps already showed it). Watch for `find -name *.log` form
  hitting empty find output.
- Everything else: same as before. Should not regress.

Expected score line if D01 flips: **30/34** (from 28/34). Both
D01 + X01: **31/34**. If neither flips, the model's reaching for
features still on the watch-list (`-name`, glob) and the next
decision is whether to ship those.

## Files

```
host/src/lib.rs                          (+exec_xargs; cat multi-arg; ALLOWED += xargs)
host/src/help.md                         (+xargs entry)
host/src/manifest.json                   (+xargs entry)
dart/lib/src/host_emulation.dart         (mirror; _execXargs; cat multi-arg)
dart/test/xargs_test.dart                (new; 9 tests)
dart/test/manifest_test.dart             (allow-list assertion += xargs)
```

Pause holds otherwise. Score-line format adopted, will keep it on
both sides.
