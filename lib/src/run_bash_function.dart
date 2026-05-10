/// `run_bash` host function — exposes the dart_wasm_sandbox's
/// allow-listed shell to Python code running inside the agent's
/// MontyRuntime.
///
/// Mirrors the shape of `buildRunScriptFunction` in dart_monty 0.17.1.
/// Migrated 2026-05-10 to the M3 façade API: `WasmHost` + `LoadedGuest`
/// + `RunResult` + `HostError` enum. No more inline marker parsing —
/// the runtime surfaces typed errors via `RunResult.error`.
library;

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';

/// Builds a `run_bash(cmd: str) -> dict` HostFunction that the agent's
/// Python code can call to execute an allow-listed shell command in
/// the dart_wasm_sandbox's WASM sandbox. The returned dict has the
/// keys `exit_code` (0 on success; negative sentinel for errors) ,
/// `stdout` (captured shell output as a string), and `stderr` (a
/// human-readable failure reason on non-zero exit).
///
/// [guest] is a long-lived [LoadedGuest] (typically obtained once at
/// app launch via `host.loadGuest(wasmBytes)`); the cached compiled
/// module makes per-call dispatch sub-millisecond after the first
/// call. Caller can pre-warm with `await guest.warmup()` to shift
/// the ~200 ms compile cost to app-init.
HostFunction buildRunBashFunction({
  required LoadedGuest guest,
}) {
  return HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'run_bash',
      description:
          'Run an allow-listed shell command in the dart_wasm_sandbox. '
          'Available commands: pwd / cd / ls / cat / find / echo / wc '
          '/ grep / head / tail / sort / xargs. Supports `&&` chains, '
          '`|` pipes, `*` and `?` glob expansion, `-type f|d` find '
          'filter. cwd persists across calls. Returns dict '
          '{exit_code, stdout, stderr}.',
      params: [
        HostParam(
          name: 'cmd',
          type: HostParamType.string,
          description: 'Shell command to run, e.g. `cd /data && ls`.',
        ),
      ],
    ),
    handler: (args, ctx) async {
      final cmd = args['cmd']! as String;
      final result = await guest.exec(cmd);

      // M3 surfaces errors via the typed RunResult.error enum. Map
      // each variant to a human-readable stderr; the LLM reflexively
      // prints stdout, so a populated stderr gives it actionable
      // signal when chains fail.
      final stdout = result.stdout();
      final stderr = switch (result.error) {
        null => '',
        HostError.allowListReject =>
          'host error: command not on allow-list (run `help` to see '
              'available commands)',
        HostError.ioError =>
          'host error: I/O error (missing file or directory)',
        HostError.wasmtimeFailure => 'host error: wasm engine failure',
        HostError.panic => 'host error: guest panicked',
        HostError.nullEngine => 'host error: backend disposed',
      };

      return <String, Object?>{
        'exit_code': result.exitCode,
        'stdout': stdout,
        'stderr': stderr,
      };
    },
  );
}
