# [RETRACTED] Finding — `find -type f` and `-type d` silently ignored

> **2026-05-09 retraction**: This finding is **incorrect**. Re-probing
> against current main (post-M1 commit `d7dc0ee`) shows `-type f` and
> `-type d` ARE honored:
> ```
> $ find /tmp           → 6 paths (3 files + 3 inferred dirs)
> $ find /tmp -type f   → 3 file paths     ✓
> $ find /tmp -type d   → 3 dir paths      ✓
> ```
> The original probe in this memo must have hit a stale dylib (or
> a different VFS shape) where directory inference wasn't surfacing.
> Apologies for the noise.
>
> **What's still true**: `-exec` IS silently dropped. Probe:
> ```
> $ find /tmp -type f -exec wc -l {} +   → just paths, no wc output
> $ find /tmp -type f -exec wc -l {} \;  → just paths, no wc output
> ```
> The `-exec` action is parsed but the action never fires; results
> identical to bare `find -type f`. Model that writes the canonical
> `find ... -exec wc {} +` form gets a path list, not line counts.
>
> Severity downgraded: `-exec` has a clean workaround (`find ... |
> xargs wc`) and the model often pivots there. Below ship-threshold;
> watch-list only.
>
> Original (incorrect) finding follows for archive purposes.
>
> ---


For the dart_wasm_sandbox owner. Standalone bug-finding memo, parallel
to `FINDING_quoted_pattern_with_spaces.md`. Surfaced from a live
agent interaction in the macOS app, not from a probe.

- **dart_wasm_sandbox commit reference**: `1b27039` / `1b5e4d2` /
  `0cdb5c5` — present across N3, N4, N5; not introduced by any
  recent ship
- **scope**: `find` ignores POSIX `-type f` / `-type d` filter flags
- **severity**: **silent misleading output** to the LLM. Model gets
  identical counts for "files" and "dirs" with no error signal.
- **status**: not asking for a fix today; flagging the prediction.
  Same shape as xargs / globs findings.

## What's broken

Live observation from the macOS app:

```
user: how many files are in /tmp?
asst: run_bash: find /tmp -type f | wc -l
       → 15
       Tells me 15.

user: how many folders are in /tmp?
asst: run_bash: find /tmp -type d | wc -l
       → 15
       Tells me 15.
```

15 ≠ 15 (in expected reality). Direct probe confirms:

```
$ find /tmp                  → /tmp/a/file1.txt
                               /tmp/a/file2.log
                               /tmp/b/file3.txt
$ find /tmp -type f          → same 3 paths
$ find /tmp -type d          → same 3 paths   ← should be 0 or some directory list
$ find /tmp -type f | wc -l  → 3
$ find /tmp -type d | wc -l  → 3              ← bug: should differ
```

The `-type f` and `-type d` arguments are tokenized but the filter
is never applied. They're either treated as positional substring
patterns (matching nothing in any path), or silently dropped at the
parser layer.

## Two compounding root causes

### 1. `-type` flag not parsed

Our find is "substring-on-path" per `host/src/help.md`:

> `find [pattern]` — list every VFS path matching the substring `[pattern]`.

`-type` isn't in that grammar. The token gets ignored or treated as
a no-match substring; either way the filter doesn't fire. Other find
flags the model has reached for in surveys + benches:
`-name "*.log"` (8 attempts, accidentally works since paths happen
to contain ".log"), `-print0` (2 attempts, silently dropped via N5
xargs `-0` strip), `-exec` (2 attempts, treated as substring → empty).

**`-type` is the highest-impact unhandled flag** because unlike the
others, it produces a wrong-but-non-empty answer. `-exec`'s empty
output prompts the model to retry. `-type`'s "all paths" output
*looks like a successful query*.

### 2. No directory entries in the VFS

Even if `-type` were parsed, the VFS stores file paths only. Per
upstream's lookup model, there's no walkable directory entry — `/tmp`
isn't a "directory object" with a children list; it's a path prefix
some files happen to share.

For `-type d` to mean anything semantically, the runtime would need
to *infer* directory entries from path prefixes:

```
input paths: /tmp/a/file1.txt, /tmp/a/file2.log, /tmp/b/file3.txt
inferred dirs: /tmp, /tmp/a, /tmp/b           # 3 directories
```

Inference is unambiguous (every path prefix that's a parent of ≥1
file). But it's a real implementation choice, not a free byproduct
of the existing VFS shape.

## Why this is the highest-impact find-flag gap

Three reasons:

1. **Model canonical form**: "count files" → `find /dir -type f | wc -l`
   isn't an option in the model's training data — it's THE canonical
   form. Any agent asked "how many files" will write it. We've seen
   it 5+ times across our bench transcripts already.

2. **Same shape silently passes for `-type f`**: a flat VFS where
   every entry IS a file means `find /tmp -type f | wc -l` happens to
   return the right answer (the file count). The model sees the
   "right" answer once and trusts the form.

3. **Then they ask `-type d` and get garbage**. Both query forms
   return the same total path count. With our flat-VFS storage, the
   directory count is *always* equal to the file count, which is a
   coincidence-that-feels-like-a-bug. The model has no way to
   detect this without out-of-band knowledge.

## Bench impact

We had no spec testing `-type d` directly because the bench's VFS
is small (8-15 files) and the failure looks like "find returns
slightly more than expected." Adding this as a Z-tier
canary spec is a 5-minute change post-this-finding:

```dart
BashSpec(
  id: 'Z14_find_type_d_distinct',
  prompt:
      'Use run_bash with `find /tmp -type d | wc -l` and `find /tmp '
      '-type f | wc -l` and tell me both counts. They should differ.',
  knownFail: true,  // until upstream ships
  verify: _v(
    proseDoesNotContain: ['equal', 'same number', 'identical'],
  ),
),
```

But that's a known-fail until you ship. So it's a probe, not a
behavior test.

## Suggested upstream fix (if/when you ship it)

```rust
// host/src/lib.rs exec_find:
fn exec_find(args, vfs) -> Result<Vec<u8>> {
  let mut want_files = true;
  let mut want_dirs = true;
  let mut path_args = vec![];
  let mut i = 0;
  while i < args.len() {
    match args[i].as_str() {
      "-type" if i + 1 < args.len() => {
        match args[i + 1].as_str() {
          "f" => { want_dirs = false; }
          "d" => { want_files = false; }
          _ => {}  // unknown -type, fall back to permissive
        }
        i += 2;
      }
      _ => { path_args.push(&args[i]); i += 1; }
    }
  }
  // existing substring match on path_args, with results filtered
  // by (want_files, want_dirs)
}
```

Inferring directories from path prefixes:

```rust
fn collect_inferred_dirs(vfs: &Vfs, root: &str) -> BTreeSet<String> {
  let mut dirs = BTreeSet::new();
  for path in vfs.iter_paths().filter(|p| p.starts_with(root)) {
    let mut p = std::path::Path::new(path).parent();
    while let Some(d) = p {
      dirs.insert(d.to_string_lossy().to_string());
      if d.to_string_lossy() == root || d == std::path::Path::new("/") { break; }
      p = d.parent();
    }
  }
  dirs
}
```

Both backends mirror.

## Counter-argument

You may decide to defer this on the same logic as our other deferred
flags (`-print0`, `-exec`): "below threshold, model has workarounds."
But `-type` has no model-side workaround — the model literally
cannot count files vs directories without it (no `ls` filtering
either, no `stat`).

This means the agent loop, today, **cannot answer "how many files
under X" or "how many directories under X" correctly**. That's a
load-bearing capability for any file-system-agent workflow. We hit
it on the first live agent interaction in the macOS app.

## When to revisit

- If the bench grows a Z-spec for this and it stays 0/N, that's
  signal-confirmed.
- If the live agent UI gets used more and the same misleading
  answer pattern recurs, that's another data point.
- Cheap lower-bound fix: implement `-type f` only (returns all
  paths since VFS is files-only — but explicitly, not by accident).
  Defer `-type d` and inferred-directories until needed.

## What I'm not asking for

- A fix today. Decide based on cost/benefit.
- A change to bash_specs.dart on our side. The Z-tier canary above
  is opt-in; not adding it to the bench unless you ask.
- Any change to the help.md grammar — `-type` is a POSIX expectation,
  not something we want models to consult docs about.

---

**Files**:
```
example/eval/bash/FINDING_find_type_filter_ignored.md  (this doc)
example/eval/bash/FINDING_quoted_pattern_with_spaces.md  (parallel finding)
```
