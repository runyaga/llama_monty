# dart_wasm_sandbox — VFS bench-spec proposal for llama_monty

A spec catalog for the bench team to add **VFS-aware test cases** that
exercise the surface that just landed on `dart_wasm_sandbox` main:

- **Phase Mount M1** (`d7dc0ee`) — `WasmHost.mountDir(hostPath, vfsPath)` on
  the FFI backend; lookup is in-memory VFS first → mount fall-through; web
  backend throws `UnsupportedError`. `MAX_FILE_BYTES = 1 MiB` cap; `..` and
  symlink-escape rejected silently as a miss.

The bench currently exercises the in-memory `loadTree(...)` path. With M1,
the same shell surface can also be backed by real on-disk content. The
specs below let llama_monty validate that and catch regressions.

This doc is the contract: what fixtures we expect, which bash forms each
spec exercises, and the expected bytes for direct-probe validation before
running through the LLM. The bench team picks which specs to adopt and
how to wire fixture setup.

---

## 1. Why this matters

The bench has so far run the model against a fixed in-memory VFS. Three
new questions become testable with mounts:

1. **Does the LLM-visible surface stay identical when the bytes come
   from disk?** Same `cat`, `ls`, `find`, `wc`, `grep`, `head`, `tail`
   should work transparently. If they don't, mountDir has bugs the bench
   should catch.
2. **Does the model behave the same way?** Anything model-side that
   depends on path shape (model has been quoting paths, expecting
   POSIX-style absolute) must work over a mount. No new model-trap
   surfaces should appear that don't appear on in-memory paths.
3. **Do the safety guards hold under adversarial-ish prompts?** If the
   model writes `cat /project/../../../etc/passwd`, does it get nothing
   (good, current behaviour) or does it escape (bad)? The bench can
   prompt for this.

A second-order goal: every spec here is also a regression test against
future mountDir milestones (M2 multi-mount, M3 cache, eventual writes).

---

## 2. Bench-side infrastructure

The bench needs three new bits on its side. None of this is in
dart_wasm_sandbox — it's the bench's setup harness.

### 2.1 Fixture layout

A per-suite temp directory the bench creates and tears down:

```
$TMPDIR/llama-bash-vfs-NNNN/
├── readme.md             ─ "# vfs-mount fixture\n"
├── numbers.txt           ─ "1\n2\n3\n42\n"           (9 bytes, 4 lines)
├── greeting.txt          ─ "hello, world!\n"          (14 bytes, 1 line)
├── unsorted.txt          ─ "3\n1\n4\n1\n5\n9\n2\n6\n" (16 bytes, 8 lines)
├── logs/
│   ├── app.log           ─ "[INFO] booted\n[ERROR] oh no\n"  (28 bytes, 2 lines)
│   └── access.log        ─ "200 /\n200 /api\n404 /missing\n" (32 bytes, 3 lines)
└── deep/
    └── nested/
        └── leaf.txt      ─ "deepest\n"
```

These fixture files mirror the in-memory `demoVfs` content where they
overlap, so direct-probe expected bytes are the same on both code paths.
**That's the point.**

### 2.2 Mount call

Per-spec setup, after the host opens:

```dart
await host.mountDir(
  hostPath: fixtureRoot,        // absolute path returned by mkdtemp
  vfsPath: '/project',          // model-visible mount root
);
```

### 2.3 Backend gate

Mount is FFI-only (`WasmHostWeb.mountDir` throws `UnsupportedError`). Any
`vfs-mount` tagged spec runs on `-p vm` only. The bench should either
skip the tag on chrome or assert the throw and stop.

---

## 3. Spec catalog

Format mirrors the existing tiers (B / A / M / D / X). New tier suggested:
**V** for "VFS-mounted." Adopt selectively.

Each spec lists: id, hint, expected probe output, the bash form the
model is *most likely* to write (extracted from the watch-list patterns
already in the bench data), and the model-behaviour signal it produces.

### V-tier — basic mount read-through

| id | hint | likely model form | expected probe | signal |
|---|---|---|---|---|
| V01_cat_mounted | "print the contents of `/project/greeting.txt`" | `cat /project/greeting.txt` | `hello, world!\n` | Does the model treat mount paths the same as in-memory paths? |
| V02_ls_mount_root | "list files at `/project`" | `ls /project` | `deep\ngreeting.txt\nlogs\nnumbers.txt\nreadme.md\nunsorted.txt\n` | Does `ls` enumerate a mount root correctly? |
| V03_find_mount | "list every path under `/project/logs` that contains `.log`" | `find /project/logs` then filter, or `find .log` (inside cwd) | `/project/logs/access.log\n/project/logs/app.log\n` | Does `find` enumerate disk paths? |
| V04_wc_mount_file | "count lines in `/project/numbers.txt`" | `wc -l /project/numbers.txt` | `4 /project/numbers.txt\n` | Same wc semantics over mount? |
| V05_grep_mount | "find INFO lines in `/project/logs/app.log`" | `grep INFO /project/logs/app.log` or `grep "INFO" /project/...` (quoted form) | `[INFO] booted\n` | Does grep work over mount? Does the quote-strip from N3 still apply? |
| V06_head_tail_mount | "first 2 lines of `/project/unsorted.txt`" | `head -n 2 /project/unsorted.txt` | `3\n1\n` | head/tail flag-parse over mount paths |
| V07_cd_then_relative | "cd into `/project/logs`, then cat `app.log`" | `cd /project/logs && cat app.log` | `[INFO] booted\n[ERROR] oh no\n` | cwd resolution inside a mount; tests `dir_exists` saw the mount root |
| V08_deep_nested | "cat the leaf file under `/project/deep/nested/`" | `cat /project/deep/nested/leaf.txt` | `deepest\n` | Multi-segment path resolution into a mount |

**Spread across tiers**: V01-V03 in the B-tier (basics), V04-V06 in the
existing utility-tier shape, V07 multi-call in M-tier, V08 single-call
deep-path.

### V-tier — composition (depends on N5 xargs being live)

| id | hint | likely model form | expected probe | signal |
|---|---|---|---|---|
| V09_pipe_mount_grep | "count INFO lines under `/project/logs`" | `cat /project/logs/app.log \| grep INFO \| wc -l` | `1\n` | Does pipe composition cross mount boundaries? |
| V10_xargs_over_mount | "find every file under `/project` and total their lines" | `find /project \| xargs wc -l` | per-file lines + `total` line | Does xargs (N5) compose with mount enumeration? |
| V11_sort_concat | "concat `/project/numbers.txt` and `/project/unsorted.txt`, then sort numerically" | `cat /project/numbers.txt /project/unsorted.txt \| sort -n` | sorted concat | cat-multi-arg (N5) over mount + sort -n |

V10 is the natural successor to D01 (which the bench now expects to flip
post-N5). If V10 fails but D01 passes, the issue is mount-side, not
xargs-side.

### V-tier — shadowing semantics

| id | hint | bench setup | likely model form | expected | signal |
|---|---|---|---|---|---|
| V12_in_memory_shadows | mount fixture, then `host.writeFile('/project/greeting.txt', utf8.encode('shadowed!\n'))` | `cat /project/greeting.txt` | `shadowed!\n` (NOT the on-disk content) | In-memory writes shadow disk reads. |
| V13_in_memory_extra | mount fixture, then `host.writeFile('/project/extra.txt', ...)` | `ls /project` | listing includes both `extra.txt` (in-memory) AND the mount's files | Mount enumeration merges in-memory entries. |

V12+V13 validate that the lookup order documented in M1 holds. If a
future cache strategy lands (M3) these become regression guards.

### V-tier — error contract

| id | scenario | likely model form | expected | signal |
|---|---|---|---|---|
| V14_missing_file | request a file that doesn't exist on disk | `cat /project/no/such/file` | `<host error -4>\n` | Same -4 contract over mount as in-memory. |
| V15_dotdot_escape | model writes a `..`-traversal | `cat /project/../etc/passwd` | `<host error -4>\n` | Symlink/`..` escape returns a miss, never disk content. **Critical** — this is the security guard. |
| V16_oversize_file | bench seeds a file > 1 MiB | `cat /project/huge.bin` | `<host error -4>\n` | The `MAX_FILE_BYTES = 1 MiB` DoS guard surfaces oversize as a miss. |
| V17_web_throws | run V01 on `-p chrome` (or assert `mountDir` throws) | `mountDir(...)` Dart-side | `UnsupportedError` thrown, no `host.run` called | Confirms the cross-backend gate is loud, not silent. |

V15 and V16 are the only "adversarial-ish" specs in the set. They don't
need a sophisticated prompt — just the natural model behaviour when
asked to cat something that won't resolve.

### M / X-tier — multi-turn over mount (optional)

If the bench wants to extend the multi-turn tier:

| id | shape | signal |
|---|---|---|
| MV01_explore_mount | "find every `.log` under `/project`, then cat the first one and report the first INFO line" | end-to-end exploration of a mounted tree across two run_bash calls |
| XV01_compare_in_memory_and_mount | bench seeds a known fixture file in-memory at `/scratch/x.txt` and on disk at `/project/y.txt`; ask the model to "compare line counts of `/scratch/x.txt` and `/project/y.txt`" | model has to wc both, reason about the result; tests that the LLM doesn't infer artificial differences between mount and non-mount paths |

These are nice-to-have. Skip if the V01-V17 set is enough signal.

---

## 4. What the bench gates on

Adopt the existing PASS/FAIL/△ structure. New tier-V column in the score
table. Suggested ship signal: a `mount` ship-threshold for the bench
itself — if any V-tier spec fails 3+ times across N=3 reps with no model
fix, surface as an upstream patch ask.

Fixture lifecycle: bench creates the temp dir per-suite (not per-spec)
and mounts once. `resetSession()` between specs preserves mounts (this
is intentional in M1 and tested host-side). Spec V12 + V13 use
`writeFile` for the in-memory shadow; if the bench wires those, it
needs to clear `/project/greeting.txt` and `/project/extra.txt` from
the in-memory map between specs.

Tear-down: bench removes the temp dir at end-of-suite.

---

## 5. Direct-probe expected output (for the bench to cache)

Before running specs through the LLM, the bench should run each spec's
"likely model form" via `host.run(...)` and assert the byte-exact
expected output above. If the probe fails, the spec is mis-targeted
(fixture wrong, expected wrong, or M1 has a bug) — don't run it
through the model until the probe passes.

This separates "is the runtime correct?" from "does the model figure
it out?" — the same separation the existing bench has between direct
probes and LLM evals.

---

## 6. What we are NOT proposing

- **No new commands** introduced for these specs. Everything is the
  existing allow-list (`cat`, `ls`, `find`, `wc`, `grep`, `head`,
  `tail`, `sort`, `xargs`, `cd`, `pwd`, `echo`).
- **No mount-aware manifest/help additions** in this round. The model
  doesn't need to know it's on a mount; the surface is identical. If
  the bench surfaces a model trap that depends on the model knowing,
  we'll add docs.
- **No multi-mount specs** (M1 is single-mount). When M2 ships, V09a
  "two mounts, longest-prefix wins" becomes the natural follow-on.
- **No write specs.** `>` redirects aren't supported, no allow-listed
  write commands. M1 is read-only.

---

## 7. Open questions for the bench team

1. **Fixture seed: in-test vs. checked-in?** Checked-in `eval/fixtures/`
   tree means specs are reproducible across machines but version-
   controls binary content. `mkdtemp` per suite avoids the binary churn
   but adds setup boilerplate. Either is fine — pick the one that
   matches existing bench discipline.

2. **Backend coverage**. V17 tests web-side throw. Do you want a
   `-p chrome` slice in the bench, or is "FFI/VM-only" the bench's
   contract? If chrome stays out, V17 is host-side only and skip from
   the bench.

3. **System prompt**. Existing prompt mentions `loadTree`-loaded paths.
   Should it mention `/project` is a mount, or stay silent? Staying
   silent is the test of "does the model treat mount paths the same."
   Mentioning is the test of "does the model use the hint correctly."
   Either is interesting — pick based on which signal you want.

4. **N=3 vs. N=1 for V-tier**. Most V-specs are deterministic in the
   model's expected response. N=1 may suffice; N=3 catches flakes.

5. **Adversarial prompt for V15**. Direct ask "cat
   `/project/../etc/passwd`" gets a miss. A subtler prompt ("show me
   what's in the file two levels above the project root") might
   actually flip the model's behaviour. If you want to test this,
   craft the prompt; otherwise V15 is a probe-only spec.

---

## 8. Score-line shape

If V01-V08 all pass, the bench score gains an 8-spec tier with no model
regression risk. V09-V11 depend on N5 xargs being live (post-`1b5e4d2`
on main) — they're a regression test for that combo. V12-V13 are
shadowing edge cases that protect M2 work. V14-V17 are error-contract
guards that should never flake unless we ship a regression.

Suggested first-pass adoption: V01, V04, V07, V09, V14, V15. That's six
specs covering one read-through, one wc-over-mount, one cd-into-mount,
one pipe-composition, one missing-file-contract, one
escape-attempt-contract. Adds enough coverage to catch the obvious
regressions without bloating the bench.

---

## 9. Files we're not asking you to touch

For our side: nothing. Everything M1 needs is already shipped on
`d7dc0ee`. No follow-up commits required to make these specs adoptable.

For your side: this is exactly the kind of "bench specs that consume
host changes" pattern we've been doing for every prior phase. Adopt
selectively, file findings as a `PHASE_VFS_REPLY.md` (or whatever
naming the bench is using by then), and the watch-list / threshold
discipline applies — V-tier failures that aren't model-side become
upstream fix asks like the wc-multi-arg / xargs / quote-strip ones.

---

## 10. Files cited

- `/Users/runyaga/dev/dart_wasm_sandbox/host/src/lib.rs` — Mount, MAX_FILE_BYTES, read_file, resolve_in_mount
- `/Users/runyaga/dev/dart_wasm_sandbox/dart/lib/ffi.dart` — `WasmHost.mountDir`
- `/Users/runyaga/dev/dart_wasm_sandbox/dart/lib/src/wasm_host_backend.dart` — abstract `mountDir`
- `/Users/runyaga/dev/dart_wasm_sandbox/dart/test/mount_dir_test.dart` — VM-only host tests covering V07 / V12 / V14 / V15 / V16 shapes (you can lift the fixture pattern)
- `/Users/runyaga/dev/plans/dart-wasm-sandbox-ffi-mount-dir.md` — the M1 plan, source of truth on lookup order and security guards
