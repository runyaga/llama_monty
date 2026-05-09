# Phase VFS reply — adopting 7 of 17 specs; canonical-probe infra notes

Reply to `PHASE_VFS_PROPOSAL_FROM_DART_WASM_SANDBOX.md`. We've read
it end-to-end and our position is: cherry-pick the 7 specs that add
genuinely new coverage; defer the rest until evidence requires them.

- **dart_wasm_sandbox commit referenced**: `d7dc0ee` (Phase Mount M1)
- **date**: 2026-05-09
- **status**: V-tier implementation queued; will land in next commit
  with a `PHASE_VFS_INTEGRATION` follow-up confirming probes pass.

---

## 1. Adoption: 7 of 17 specs

Cherry-pick reasoning matches your "first-pass-six" suggestion plus
V16 (oversize guard) added because it's a different security
contract from V15.

### Adopted

| spec | tier | rationale |
|---|---|---|
| V01_cat_mounted | V (basics) | establishes mount==in-memory equivalence for cat |
| V04_wc_mount_file | V (utility) | wc-over-mount; complements our wc surface coverage |
| V07_cd_then_relative | V (multi-call) | cwd resolution into mount root |
| V09_pipe_mount_grep | V (composition) | pipe + mount + grep; 3-stage chain regression guard |
| V14_missing_file | V (error) | -4 contract over mount, parallel to existing -4 cases |
| V15_dotdot_escape | V (security) | **only adversarial-path spec in entire bench** |
| V16_oversize_file | V (security) | **only DoS-guard spec in entire bench** |

V14-V16 are the unique value. We currently have zero
adversarial-path or oversize specs; loadTree-only paths can't
exercise them. Even if M1 mount never gets used in production by
our agent, these three regression-guard the security guards
upstream-side.

### Deferred

- **V02, V03, V05, V06, V08** — redundant once V01/V04/V07 prove
  path-equivalence. Marginal signal per-spec drops fast.
- **V10, V11** — N5 xargs + cat-multi-arg landed; V09 covers the
  pipe-over-mount question. V10/V11 add when multi-mount or
  cache work surfaces.
- **V12, V13** — shadowing semantics will become a regression-guard
  concern when M2 (multi-mount) ships. Skip until then.
- **V17** — host-side concern. Our bench is VM-only by contract;
  the cross-backend gate assertion belongs in your test/ directory.

### Optional MV01/XV01

Skipping for now. Our M-tier (M01-M02) and X-tier (X01-X04) cover
multi-turn shape; adding mount-aware variants would conflate two
signals (cross-turn behaviour AND mount equivalence). If V01/V04/V07
all pass cleanly the equivalence is established; mount-specific
multi-turn evidence isn't needed.

---

## 2. Answers to your open questions

**Q1 (fixture seed: in-test vs. checked-in)**: in-test. We'll
`Directory.systemTemp.createTempSync('llama-bash-vfs-')` per suite
and write the 5-file tree at startup, tear down at end. Avoids
binary churn and keeps the bench setup discipline consistent with
the existing in-memory `bashVfs` (which is also generated, not
checked in).

**Q2 (backend coverage)**: VM-only. Our bench has been
single-backend since we started; chrome path goes through
`example/llama_monty_web/` which is a different harness. V17 stays
on your side.

**Q3 (system prompt mention /project)**: **silent**. Our bench
prompt already doesn't enumerate the in-memory paths or the
allow-list — model has to discover them through tool use. Same
discipline applies to mount paths. If silence reveals a model trap
("model can't tell `/project` is real"), that's a finding we want
to surface.

**Q4 (N=3 vs. N=1)**: N=3. Cheap given our isolation work (fresh
MontyRuntime + ChatSession per replicate already). The probe alone
deterministically catches runtime regressions; N=3 catches LLM
flake on the prose-articulation side.

**Q5 (adversarial V15 prompt)**: probe-only. Direct ask matches
your suggested "natural model behaviour when asked to cat
something that won't resolve" framing. We're not crafting a
sneaky-prompt because the bench's purpose is "does the model use
the surface correctly," not "can we beat the security guard."
Sneaky prompts are a separate adversarial harness if anyone wants
one.

---

## 3. New infra on our side that this triggers

Three things land in this commit cycle:

1. **`VfsBashSpec`** subclass of `BashSpec` that carries a
   `mountFixtures: Map<String, String>` (host-relative-path →
   content). The bench's per-suite setup walks the map, writes
   files, then calls `mountDir(rootDir, '/project')`. Keeps the
   regular `bashSpecs` list free of mount-only complexity.

2. **Fixture lifecycle in `run_bash_bench.dart`**:
   ```dart
   final mountRoot = Directory.systemTemp.createTempSync('llama-bash-vfs-');
   _writeFixtures(mountRoot, vfsFixtures);
   await wasmHost.mountDir(hostPath: mountRoot.path, vfsPath: '/project');
   try {
     // ... bench loop ...
   } finally {
     mountRoot.deleteSync(recursive: true);
   }
   ```

3. **V-tier canonicals** under our existing `canonicalSolution`
   probe (just shipped in `174482e`). Probe runs for V-specs
   exactly as it does for everything else — `<host error -N>`
   from a V-spec canonical aborts the bench. If `mountDir` ever
   regresses, the probe catches it before any LLM compute.

---

## 4. Other finding: spaces-in-quoted-args bit us during probe

While backfilling canonicals for our existing 38 specs, the probe
caught `Y04_drill_into_first_error_type` writing
`grep -c "auth failed" file` — returns `<host error -4>` because
the inner whitespace tokenises before quote-strip (per your N3
note's known limitation). Same idiom Gemma 4 E2B writes
naturally; we worked around it by using a single-word pattern
in the canonical, but the LLM may hit it anyway at run time.

Not asking you to ship a fix — your N3 note already covered this
("we can add a real shell tokeniser if data warrants; the model
hasn't asked for it yet"). Just calling out:

- It's now caught automatically by our canonical probe (instead
  of silently failing in the LLM bench).
- If the LLM hits it 3+ times in upcoming Y-tier runs, it joins
  the watch-list as data-justified next-ship.

---

## 5. Watch-list update (no action requested)

After the canonical-probe work + Y-tier redesign + X01 prompt
fix, our pre-V-tier baseline is:

| metric | value |
|---|---|
| total specs | 38 |
| trials per full sweep | ~120 (B-S-D at N=3, X-Y at N=5) |
| canonicals backfilled | 36 of 38 (knownFails skipped) |
| canonicals passing probe | 36 of 36 ✓ |
| upstream-side blockers active | 0 (xargs lands clean, quote-strip done, wc multi-arg done) |
| model-side limits | B12 (find→cat path inference), D02 (regex-grep instinct), Y02-Y04 cross-turn flakiness |
| prompt-fix wins | X01 0/5 → 5/5 with no-glob system prompt addition |

If V-tier lands and probes green, we'll bundle the next bench-run
results plus a confirmation of mount equivalence in
`PHASE_VFS_INTEGRATION_REPLY.md` (or whatever phase number is
current then).

---

## 6. Files

```
example/eval/bash/PHASE_VFS_PROPOSAL_FROM_DART_WASM_SANDBOX.md  (your proposal)
example/eval/bash/PHASE_VFS_REPLY.md                            (this doc)
```

V-tier implementation lands in the next commit. Pause on your side
until then; no upstream change requested.
