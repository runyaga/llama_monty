# M3 — breaking change shipped

- commit: `05717e4` on `dart_wasm_sandbox` `main`
- shipped 2026-05-10
- old surface: deprecated for one release (`openWasmHost()` and
  `package:dart_wasm_sandbox/next.dart` keep compiling with
  `@Deprecated` warnings)
- new shape: `package:dart_wasm_sandbox/dart_wasm_sandbox.dart`

If you started porting at M1 (recommended), this is the moment to
finish. If you didn't, the deprecation alias keeps you compiling
through one more release with `@Deprecated` warnings; you'll need
to finish before whatever comes after M3 (which removes the alias
and `next.dart` entirely).

## What's new vs M1+M2

- `final class WasmHost` is now the public type. Construct with
  `await WasmHost.open()` (or `await openFfi(libraryPath: …)` from
  `package:dart_wasm_sandbox/ffi.dart` if you need a non-default
  dylib path).
- `WasmHostBackend` is package-private. Embedders no longer touch
  the abstract.
- `WasmHostException` no longer thrown from embedder-facing code —
  engine errors flow through `RunResult.error == HostError.wasmtimeFailure`
  via `LoadedGuest.exec`. The exception type survives in `lib/src/`
  for FFI rc decoding only.
- `WasmHost.open(gate: …)` takes an optional `DestructiveActionGate`
  (reserved slot; never fires today — no destructive verbs in the
  allow-list).
- `WasmHost.run(bytes, …)` and `WasmHostBackend.run(bytes, …)` are
  REMOVED. Use `host.loadGuest(bytes).exec(...)` (the cached hot
  path; sub-millisecond per call after the first compile).
- `mountDir` is on the façade with the full lifecycle FAQ in
  the dartdoc.
- `host.manifest` getter returns parsed `ManifestData` for prompt
  validation / docs generation without issuing a guest call.

## Migration recipe

```dart
// before (M1+M2 with deprecated openWasmHost):
final WasmHostBackend host = await openWasmHost();
final out = await host.run(wasmBytes, stdin: cmd);  // Future<Uint8List>

// after (M3):
final host = await WasmHost.open();           // Future<WasmHost>
final guest = host.loadGuest(wasmBytes);      // LoadedGuest, lazy-compile
final result = await guest.exec(cmdString);    // Future<RunResult>
final stdout = result.stdoutBytes;             // Uint8List
if (result.error != null) handle(result.error!);  // typed enum
```

For `LlamadartClient` users: it's now `LlamaDartClient` (capital D
in Dart), exported from `package:dart_wasm_sandbox/agent_clients_ffi.dart`
(VM-only).

For Chrome embedders: import
`package:dart_wasm_sandbox/agent.dart` and pair with
`OllamaClient` or your own `LlmClient`.

Migration recipe also lives in
`~/dev/dart_wasm_sandbox/dart/README.md` and in
`~/dev/plans/dart-wasm-sandbox-api-overhaul.md` §4.

## What's new from M1.5 (also shipped 2026-05-10)

`LoadedGuest` caches the compiled `wasmtime::Module` (FFI) /
`WebAssembly.Module` (web). First `exec` pays the ~200 ms compile
cost; subsequent calls are sub-millisecond. Call `guest.warmup()`
to shift the compile to app-init time. Call `guest.dispose()` when
the bench-spec session ends to release the cached module.

## Final test counts

- Rust: 21 (c_api) + 4 (reuse_engine) + 4 (mount_tests)
- Dart VM: 213 tests
- Dart Chrome: 178 tests
- All static gates clean (`cargo build/clippy/test/fmt` +
  `dart analyze/dcm/format`)

## Surprises welcome

If anything in the new surface fights the bench during port,
reply with `PHASE_API_M3_REPLY.md` — that's the verification signal
we're waiting for to consider the overhaul fully closed end-to-end.

Things we already know are rough edges and might want feedback on:

1. Engine errors flow through `RunResult.error` via a `toString()`
   parse of the underlying FFI exception in `LoadedGuest._engineErrorCode`.
   Works correctly today; cleaner solution (a sealed `BackendError`
   type both backends construct directly) is a follow-up.

2. `CompiledGuest` is `abstract class` not `sealed` because the FFI
   and web subclasses can't share a library (conditional-compile
   boundary). M1.5 §8 documents the trade-off. If embedders hit
   anything weird with the type's openness, let us know.

3. `LoadedGuest.exec`'s first call does two backend trips
   (`compile` then `runCompiled`); a host-level mutator queued
   between them can land before the run. After the first exec (or
   `warmup()`), only one trip per exec, so the mutators-serialize-
   behind-exec semantic holds atomically. Embedders that race
   concurrent mutators against the very first `exec` should call
   `warmup()` first.
