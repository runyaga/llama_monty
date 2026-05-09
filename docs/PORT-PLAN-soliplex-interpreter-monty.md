# Port plan: `soliplex_interpreter_monty` → `dart_monty 0.17.1`

## Goal

Port [`runyaga/soliplex-packages/packages/soliplex_interpreter_monty`](https://github.com/runyaga/soliplex-packages/tree/main/packages/soliplex_interpreter_monty)
from its current `dart_monty: { git: ref: main }` dependency onto the
**published `dart_monty 0.17.1`** that `llama_monty` already depends
on, so the two packages can coexist in one app without dependency
conflict.

This is groundwork for routing `llama_monty`'s heavy LLM calls
(summarization, multi-step extraction, planning) onto a bigger model
served via Soliplex rooms (Qwen 35B / 8B, gpt-oss 20B).

## Why we need this

Today:

| | dart_monty version |
|---|---|
| `llama_monty` (this repo) | `^0.17.1` (pub.dev) |
| `soliplex_interpreter_monty` | `git: ref: main` of `runyaga/dart_monty` |

These are different revisions of the same package. Pub will reject a
direct `add` of `soliplex_interpreter_monty` into our example app's
pubspec because the constraint `dart_monty: ^0.17.1` collides with the
git ref.

We need to either:

- **(A)** Pin `soliplex_interpreter_monty` to depend on
  `dart_monty: ^0.17.1` from pub.dev, OR
- **(B)** Pin our own dep on `dart_monty: { git: ref: main }` to
  match.

The plan picks **(A)**. Reasons:
1. Pub.dev versions are reproducible across machines; git refs drift.
2. `dart_monty 0.17.1` is the documented stable surface — what
   downstream consumers will install.
3. The work is small (the package is 169 LOC across 6 files; see
   [`runyaga/soliplex-packages/packages/soliplex_interpreter_monty/lib/src`](https://github.com/runyaga/soliplex-packages/tree/main/packages/soliplex_interpreter_monty/lib/src)).
4. It also forces us to discover any API divergence between the
   `main` branch and the published 0.17.1, which is information
   we want anyway.

## Investigation step (do this first)

Before any code changes, the agent should produce a written
"divergence report" answering:

1. **Which dart_monty SHA does `runyaga/dart_monty:main` currently point at?**
   `git ls-remote https://github.com/runyaga/dart_monty.git main`
2. **Which classes / methods does `soliplex_interpreter_monty` use,
   and how do they map to `dart_monty 0.17.1`?**
   Grep for these specifically in `packages/soliplex_interpreter_monty/lib/src/**/*.dart`:
   - `MontyPlugin` (note: 0.17.1 calls this `MontyExtension`)
   - `MontyBridge`, `DefaultMontyBridge`
   - `EventLoopBridge`
   - `BridgeEvent` and its subtypes (`BridgeRunStarted/Finished/Error`,
     `BridgeStepStarted/Finished`, `BridgeTextStart/Content/End`,
     `BridgeToolCallStart/Args/Result/End`, `BridgeUiRendered`,
     `BridgeEventLoopWaiting/Resumed`)
   - `HostFunction`, `HostFunctionHandler`, `HostFunctionSchema`,
     `HostParam`, `HostParamType`
   - `MontyPlatform`, `Monty`, `MontyLimits`
3. For each, **does it exist in 0.17.1 with the same signature?**
   Cross-reference against
   `~/.pub-cache/hosted/pub.dev/dart_monty-0.17.1/lib/dart_monty.dart`
   and `dart_monty_bridge.dart`.

The expected divergences (from a quick scan of both sides) are:

| symbol in `soliplex_interpreter_monty` | likely 0.17.1 equivalent |
|---|---|
| `MontyPlugin` | `MontyExtension` |
| `BridgeTextStart/Content/End` | unknown — need to check |
| `BridgeToolCallStart/Args/End/Result` | unknown — may be split into separate types in 0.17.1 |
| `BridgeStepStarted/Finished` | unknown |
| `BridgeUiRendered` | unknown |
| `BridgeEventLoopWaiting/Resumed` | unknown |
| `DefaultMontyBridge` | maybe directly in 0.17.1? Or rename? |
| `MontyBridge` | base class — likely renamed `MontyRuntime` |
| `EventLoopBridge` | unknown |

Most of these are **export-shape concerns only** — the package's
business logic touches very little. The fix may be as simple as
updating one barrel file (`lib/soliplex_interpreter_monty.dart`)
plus a handful of import paths in `lib/src/`.

Reference:
- target API surface: https://pub.dev/documentation/dart_monty/0.17.1/
- source API surface: https://github.com/runyaga/dart_monty/tree/main/lib/

## Scope

```
soliplex_interpreter_monty/
  lib/
    soliplex_interpreter_monty.dart   ← barrel; re-exports renamed types
    src/
      bridge/
        tool_definition_converter.dart
      console_event.dart
      execution_result.dart
      input_variable.dart
      monty_execution_service.dart    ← largest file, uses Monty/MontyPlatform
      monty_limits_defaults.dart
      schema_executor.dart
  pubspec.yaml                        ← change dart_monty constraint
  test/                               ← needs to pass after migration
  example/example.dart                ← currently a stub; verify the
                                        snippets in its comments work
                                        against the new API
```

Total: 6 source files in `lib/src/`, ~250 LOC. Plus tests + pubspec.

## Concrete steps

### Step 0 — Branch + workspace

1. Fork or clone `runyaga/soliplex-packages`.
2. Create branch `feat/dart-monty-0.17.1`.
3. The workspace pubspec also overrides `dart_monty_ffi`, `dart_monty_platform_interface`, `dart_monty_wasm` — confirm whether those are needed at all once we go to 0.17.1. They might be redundant.

### Step 1 — Pubspec change

In `packages/soliplex_interpreter_monty/pubspec.yaml`:

```diff
 dependencies:
   dart_monty:
-    git:
-      url: https://github.com/runyaga/dart_monty.git
-      ref: main
+    ^0.17.1
   meta: ^1.11.0
```

Run `dart pub get`. If errors complain about resolution, also touch
the workspace root pubspec to update the `dependency_overrides:` block
that pins `dart_monty_ffi/platform_interface/wasm` to git refs — most
likely they should be removed entirely once `dart_monty` is on pub.

### Step 2 — Static error pass

Run `dart analyze --fatal-infos packages/soliplex_interpreter_monty`.
Each error is a divergence point. Map them one at a time using the
investigation report from above.

Expected order of operations:
1. Update `lib/soliplex_interpreter_monty.dart` barrel — replace each
   re-export of a removed/renamed type with the 0.17.1 equivalent.
2. Update imports in `lib/src/*.dart` to match the renamed packages
   (note: 0.17.1 splits `dart_monty_bridge` and `dart_monty` cleanly —
   make sure each file imports from the right one).
3. Adapt class hierarchies (`MontyPlugin extends X` → `MontyExtension extends X`).
4. Adapt event subtype matching — Dart pattern matching relies on the
   exact class name, so `case BridgeTextContent(:final text)` must
   match the 0.17.1 type name, even if the runtime shape is identical.

### Step 3 — Tests

`packages/soliplex_interpreter_monty/test/` exists. Run them.
Anything that breaks is a real regression — fix or update fixtures.

If the tests rely on test doubles for `MontyPlatform`, `Monty`, etc.,
re-check that those test doubles are still valid in 0.17.1.

### Step 4 — Example smoke test

Make `packages/soliplex_interpreter_monty/example/example.dart` actually
runnable (today its body is commented out as illustration). It should
load a real `Monty` platform, register a host function, execute a
trivial Python expression, and assert the result. This is the
acceptance check.

### Step 5 — Verify against `llama_monty`

Once the port lands, swap into our example app to prove the
constraint-conflict is resolved:

```yaml
# example/llama_monty_web/pubspec.yaml
dependencies:
  llama_monty: { path: ../.. }
  llamadart:    # already path-overridden
  dart_monty:   ^0.17.1
  soliplex_interpreter_monty:
    git:
      url: https://github.com/runyaga/soliplex-packages.git
      path: packages/soliplex_interpreter_monty
      ref: feat/dart-monty-0.17.1   # the branch from this work
```

`flutter pub get` must succeed.

## Acceptance criteria

The follow-on agent's PR on `runyaga/soliplex-packages` is done when:

- [ ] `packages/soliplex_interpreter_monty/pubspec.yaml` declares
      `dart_monty: ^0.17.1` (no git ref).
- [ ] `dart analyze --fatal-infos packages/soliplex_interpreter_monty`
      passes clean.
- [ ] `dart test packages/soliplex_interpreter_monty` passes (or
      tests have been updated with rationale in commit message).
- [ ] `example/example.dart` is uncommented, runnable, and prints
      a non-trivial result.
- [ ] PR description includes the "divergence report" from the
      investigation step.
- [ ] `llama_monty/example/llama_monty_web` can `pub get` with both
      `dart_monty ^0.17.1` and `soliplex_interpreter_monty` from this
      branch — proven by a CI run or a screenshot in the PR.

## Out of scope

- Porting `soliplex_completions`, `soliplex_scripting`, etc. They live
  in the same monorepo but are independent. Only port what the
  `llama_monty` integration needs.
- Adding new features to `soliplex_interpreter_monty`. Just port the
  existing surface.
- Removing the `runyaga/dart_monty` git overrides from the WORKSPACE
  pubspec. That's a separate concern — only fix the per-package
  pubspec for `soliplex_interpreter_monty`. The workspace can keep
  using its own pinning strategy.

## Estimated cost

| Step | Effort |
|---|---|
| Investigation (divergence report) | 1 hr |
| Pubspec + barrel + import fixes | 1-2 hr |
| Tests pass | 30 min |
| Example smoke test | 30 min |
| Cross-repo verification with `llama_monty` | 30 min |
| **Total** | **~3-4 hr** |

If divergence is heavier than expected (e.g. event types substantially
restructured), plan up to 6 hr.

## Pointers

- Source package: https://github.com/runyaga/soliplex-packages/tree/main/packages/soliplex_interpreter_monty
- Target API: https://pub.dev/packages/dart_monty (version 0.17.1)
- Workspace root: https://github.com/runyaga/soliplex-packages/blob/main/pubspec.yaml
- Reference consumer: this repo (`llama_monty`), specifically:
  - `lib/src/llama_monty_plugin.dart` — known-working `MontyExtension`
    subclass on dart_monty 0.17.1 — use as the canonical example of
    the target API shape.
  - `lib/src/chat_shell_plugin.dart` — same.
