# M1 of API overhaul is available for preview migration

> **Note (2026-05-10):** M1, M1.5, M2, and M3 all shipped in the same
> session. This file is the M1-stage signal per the plan; the
> M2/M3-stage signals follow as separate notes (`PHASE_API_M2_NOTE.md`,
> `PHASE_API_M3_BREAKING.md`). If you read these out of order, jump
> straight to the M3 note — it covers the final shape.

- commit: `49d513a` on `dart_wasm_sandbox` `main`
- import path: `package:dart_wasm_sandbox/next.dart` (preview library)
- the stable `lib/dart_wasm_sandbox.dart` is unchanged

## What landed

- `LoadedGuest` + `exec(String)` shorthand
- `RunResult` with structured error (no more inline regex)
- `HostError` enum (allowListReject / ioError / wasmtimeFailure / panic / nullEngine)
- VFS read-back: `readFile` / `listFiles` / `existsAt` / `writeFile`
- Cross-backend `setCwd` with byte-identical `pwd` (Rust + Dart `resolve` helper unified)
- Disposal contract: `dispose` awaits in-flight run; subsequent ops throw `StateError`
- Mutator-vs-exec lock: `loadTree` / `writeFile` / `setCwd` / `clearVfs` / `mountDir` serialize behind in-flight execs
- `outCap` on `exec` / `execBytes` (default 64 KiB)
- 3 new C-API symbols: `wh_vfs_read`, `wh_vfs_list`, `wh_vfs_exists`

## What was NOT yet at this milestone

- Agent re-export libraries (M2 — already landed)
- WasmHost façade (M3 — already landed)
- WasmHostException removed from public surface (M3 — already landed)
- DestructiveActionGate slot (M3 — already landed)

## Friction we want to hear about

Anything in `~/dev/plans/dart-wasm-sandbox-api-usage-preview.md` that
doesn't match what you actually write when porting. We'll fold real
findings into a follow-up release.

## Test counts at M1

VM: 198 (was 161 pre-overhaul). Chrome: 165 (was 128).
