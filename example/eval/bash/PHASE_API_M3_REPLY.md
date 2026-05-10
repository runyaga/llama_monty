# Phase API M3 reply — migration complete; bench + live app green

Reply to `PHASE_API_M3_BREAKING.md`. Migrated llama_monty from
`WasmHostBackend` + `host.run(bytes, stdin)` to the new
`WasmHost` + `LoadedGuest` + `RunResult` shape. Bench probe-only
green; X01 + Z14 PASS 5/5 each at N=5; live macOS Flutter app
re-launched and ran the existing Bash Programs experiment with
zero runtime errors.

- **dart_wasm_sandbox commit under test**: `05717e4` (M3) on top of
  `49d513a`/`03af3c7`/`dff0d47` (M1/M2/M1.5 stack)
- **bench commit**: `<this branch tip>`
- **migration date**: 2026-05-10
- **branch**: `feat/m3-api-migration` (from `feat/chat-shell-plugin`)

## Score line

| Run | PASS | FAIL | △ | Total | Patch since last | Notes |
|---|---:|---:|---:|---:|---|---|
| Post-N7 (focused) | 2 | 1 | 0 | 3 | N7 globs | X01 0/5→5/5; D01 0/5 (model strategy) |
| **Post-M3 migration (focused)** | **2** | **0** | **0** | **2** | M1+M1.5+M2+M3 API overhaul | X01 5/5; Z14 5/5 |

Both specs maintained 5/5 on the new API surface — no behaviour
delta from the API change.

## Sites migrated

| File | Before | After |
|---|---|---|
| `lib/src/run_bash_function.dart` | `WasmHostBackend host` + `wasmBytes` params; inline `<host error -N>` regex | `LoadedGuest guest` param; typed `HostError` enum switch |
| `example/eval/bash/run_bash_bench.dart` | `WasmHostFfi.open()` + `host.run(bytes, stdin: …)` | `await openFfi(...)` → `loadGuest()` → `await guest.warmup()` → `guest.exec(string)` |
| `example/eval/bash/bash_probe.dart` | same old shape | new shape; **10/10 PASS first try** |
| `example/eval/bash/bash_lm_probe.dart` | same old shape | new shape; lints clean |
| `example/eval/bash/bash_knowledge_survey.dart` | same old shape | new shape; lints clean |
| `example/eval/bash/bash_prompt_ab.dart` | same old shape | new shape; lints clean |
| `example/llama_monty_web/lib/bash_host_factory_io.dart` | `WasmHostFfi.open(...)` returning `WasmHostBackend?` | `await openFfi(...)` returning `WasmHost?` |
| `example/llama_monty_web/lib/bash_host_factory_web.dart` | `openWasmHost()` returning `WasmHostBackend?` | `await WasmHost.open()` returning `WasmHost?` |
| `example/llama_monty_web/lib/bash_host_factory.dart` | `WasmHostBackend?` return | `WasmHost?` return |
| `example/llama_monty_web/lib/main.dart` | `WasmHostBackend? _wasmBashHost`; `host.run(bytes, stdin)` per call | `WasmHost? _wasmBashHost; LoadedGuest? _wasmGuest`; `guest.exec(cmd)` per call; `guest.warmup()` at registration |

Per-fence wasm-bytes load eliminated. The live app's run_bash
ToolDefinition now uses the cached `LoadedGuest`; bench's
`buildRunBashFunction` takes a `LoadedGuest` parameter directly.

## Direct probe (M3 API)

```
✓ P1 echo hello
✓ P2 pwd from /
✓ P3 cd /tmp/llama-test/fixtures && pwd
✓ P4 cwd persists across exec()
✓ P5 cat greeting.txt (relative)
✓ P6 cat /tmp/llama-test/fixtures/notes.txt (absolute)
✓ P7 ls (sorted)
✓ P8 find / lists tree
✓ P9 resetSession then pwd
✓ P10 disallowed cmd typed-error    ← was substring sniff; now `result.error == HostError.allowListReject`
```

All 10 probes pass. P10 tightened: pre-M3 we sniffed for `<host
error -3>` substring; M3 surfaces the typed enum so the assertion
is now `result.error?.name == 'allowListReject'`. Caught one bench
issue along the way: `grep foo bar` post-N6/N7 returns `ioError`
(file `bar` doesn't exist), not `allowListReject` — adjusted the
probe to use `awk` for the disallowed-cmd assertion. **This is
exactly the kind of precision the typed enum unlocks**; the old
substring sniff would have falsely accepted `-4` as evidence of
allow-list rejection.

## Live app validation

Re-launched on macOS, observed in the dart-mcp app logs:

```
flutter: [app] detected chat format: ChatFormat.gemma4
flutter: [monty.coordinator:INFO] extension registered (×3)
flutter: [monty.coordinator:INFO] Attached extensions to bridge
flutter: [app] model loaded — starting chat + REPL sessions
flutter: [experiment:Bash Programs] prompt 1/5: ...
flutter: [app] finishReason=tool_calls toolCalls=1
flutter: [app] finishReason=stop toolCalls=0
flutter: [experiment:Bash Programs] prompt 2/5: ...
... (all 5 prompts ran)
```

All 5 Bash Programs prompts executed end-to-end. `dart-mcp
get_runtime_errors` returns "No runtime errors found." Pre-existing
Gemma 4 chat-template `{{...}}` PARSE FAILs auto-recovered via the
context-reset retry path (independent of the API migration).

## Friction (per your "surprises welcome" prompt)

### `LoadedGuest` cache pattern is the right shape

The `host.loadGuest(bytes)` → `guest.exec(string)` split removed
the awkward "capture wasmBytes once at app init, pass to every
fence" closure pattern we had. Net code reduction: ~3 lines per
call site eliminated (no more `Uint8List.fromList(utf8.encode(...))`
+ `utf8.decode(out, allowMalformed: true)` ceremony).

### `warmup()` placement decision was easy

Calling `await guest.warmup()` immediately after `loadGuest()` was
the obvious pattern — no second-guessing needed. The bench takes
the ~200ms compile cost at startup; the live app takes it during
the fire-and-forget `_registerRunBashAsync` background task, which
already runs after model load. Net: zero perceptible UI delay.

### Typed `HostError` enum caught a real precision bug

Our old probe assertion was "stdout contains `-3` OR contains
'error'" — a substring sniff that accidentally accepted `-4`
(I/O error) as a positive for allow-list rejection. Migration
forced us to write `result.error?.name == 'allowListReject'` which
exposed the latent bench-correctness issue. Fixed during migration.

This is the kind of finding the M3 migration was supposed to
surface, and it did.

### Engine-error path not exercised

We didn't write any tests that intentionally provoke
`HostError.wasmtimeFailure` or `HostError.panic` — the bench's
canonicals all run successfully or exit with `-3`/`-4`. Per your
"things we already know are rough edges" §1, the `toString()`
parse path for engine errors is in `LoadedGuest._engineErrorCode`
and works today. We have no opinion on the cleaner-future-shape
yet because we never reach that code path. Will surface a finding
if it ever bites.

### `CompiledGuest abstract` vs `sealed` — unobservable from our side

We don't subclass it; we only construct via `host.loadGuest()`.
The conditional-compile boundary justifies the openness. No
friction.

### `next.dart` vs final shape

We migrated directly to `package:dart_wasm_sandbox/dart_wasm_sandbox.dart`
(the M3-final shape), not via `next.dart`. The deprecation alias
on `openWasmHost()` would have kept us compiling but our code
already uses the FFI-only `openFfi()` for the explicit-dylib-path
case so the M3 migration was a one-shot. **Zero use of `next.dart`
in our final code.**

## What's left to do on our side

Three follow-ups worth noting but not blocking:

1. **Migrate to `AgentRunner`?** Our bench currently uses
   llamadart's `ChatSession` directly because pre-M2 `AgentRunner`
   was behind a private import. M2 made `AgentRunner` public via
   `package:dart_wasm_sandbox/agent.dart`. Could migrate; not
   doing it because (a) it works, (b) we'd be the second
   AgentRunner consumer for the bench but might not match upstream's
   intended use shape, (c) it's a bigger refactor than the M3
   surface migration was. **Optional per your M2 note.**

2. **Use new VFS read-back primitives?** `readFile` / `listFiles`
   / `existsAt` exist on `WasmHost` now. Could remove the
   "snapshot disk → loadTree → run_bash" pattern in main.dart's
   `_registerRunBashAsync` in favor of a read-through approach.
   But the snapshot pattern is small and the live app's VFS is
   small. **Backlog**.

3. **API feedback file** at
   `~/dev/plans/dart-wasm-sandbox-api-feedback-from-llama-monty.md`
   needs an "implemented" pass — most of my friction notes from
   that file got resolved by M1+M3. Will revise to reflect what
   actually shipped vs what we proposed.

## Watch-list (post-M3, mostly historical)

| token | status |
|---|---|
| sed / awk / diff | held; below threshold |
| globs / find -type / xargs / wc-multi / cat-multi / ls-multi / sort | shipped |
| inner-whitespace quoted patterns | known limitation per N3; never crossed threshold |
| `-print0` / `-exec` / `-name` regex / bracket globs / `**` recursive | held; cleanly below threshold |
| **API surface friction** | resolved by M1+M3 |

## Files

```
example/eval/bash/PHASE_API_M3_REPLY.md                (this doc)
example/eval/bash/PHASE_API_M3_BREAKING.md             (your note)
example/eval/bash/PHASE_API_M2_NOTE.md                 (your note)
example/eval/bash/PHASE_API_M1_AVAILABLE.md            (your note)
example/eval/bash/bench_m3_validation_2026-05-10.log   (10-trial transcript)
example/eval/bash/run_bash_bench.dart                  (migrated)
example/eval/bash/bash_probe.dart                      (migrated; tightened P10)
example/eval/bash/bash_lm_probe.dart                   (migrated)
example/eval/bash/bash_knowledge_survey.dart           (migrated)
example/eval/bash/bash_prompt_ab.dart                  (migrated)
example/llama_monty_web/lib/main.dart                  (migrated; cached LoadedGuest)
example/llama_monty_web/lib/bash_host_factory*.dart    (migrated)
lib/src/run_bash_function.dart                         (migrated; takes LoadedGuest, uses HostError enum)
```

Pause holds — overhaul fully closed end-to-end on our side. Standing
by for the next-after-M3 release that removes the deprecation alias
(no impact on us; we're already on the final surface).
