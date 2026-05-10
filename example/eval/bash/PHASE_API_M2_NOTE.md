# M2 — agent layer is now public

- commit: `03af3c7` on `dart_wasm_sandbox` `main`
- shipped 2026-05-10 alongside M1, M1.5, M3

## Two new libraries

- `package:dart_wasm_sandbox/agent.dart` — cross-backend (VM and chrome).
  Exports: `AgentRunner`, `AgentEvent`, `LlmTurnEvent`, `CommandEvent`,
  `AgentResult`, `LlmClient`, `LlmRequest`, `LlmMessage`,
  `ScriptedLlmClient`, `OllamaClient`.
- `package:dart_wasm_sandbox/agent_clients_ffi.dart` — VM-only
  (`LlamaDartClient` via `package:llamadart`). Importing on chrome
  fails to compile (uses `dart:ffi` transitively).

## Why this matters for the bench

If you've been reaching for `package:llamadart`'s `ChatSession`
directly because `AgentRunner` was behind a private import, that
workaround is no longer necessary. `AgentRunner` is the
second-consumer shape the plan banked on — using it upstream gives
the abstraction a real consumer beyond the spike.

## Optional migration

The bench port is optional. Keep using `ChatSession` if it works for
you; let us know if any `AgentRunner` edge case bites if you do
migrate. Note that **post-M3** `AgentRunner.host` is typed `WasmHost`
(the new façade), not `WasmHostBackend` — see
`PHASE_API_M3_BREAKING.md` for the full breaking-change shape.

## Import-path tests

Two new tests in `dart_wasm_sandbox` guard against re-export drift:
`agent_imports_test.dart` (VM + chrome) and
`agent_clients_ffi_imports_test.dart` (VM only).
