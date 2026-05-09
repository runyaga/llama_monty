/// `run_bash` host function — exposes the dart_wasm_sandbox's allow-listed
/// shell to Python code running inside the agent's MontyRuntime.
///
/// Mirrors the shape of `buildRunScriptFunction` in dart_monty 0.17.1
/// (see `~/.pub-cache/hosted/pub.dev/dart_monty-0.17.1/lib/src/extensions/run_script.dart`).
/// Plan: `~/.claude/plans/twinkling-imagining-reddy.md`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';

/// Builds a `run_bash(cmd: str) -> dict` HostFunction that the agent's
/// Python code can call to execute an allow-listed shell command in
/// the dart_wasm_sandbox's WASM sandbox. The returned dict has the
/// keys `exit_code` (0 on success; negative sentinel parsed from the
/// guest's `<host error -N>` marker on disallowed/failed commands),
/// `stdout` (captured WASI stdout, with any trailing error marker
/// stripped), and `stderr` (currently always `''` — the spike pipes
/// errors into stdout as inline markers).
///
/// [host] is a long-lived [WasmHostBackend] (typically opened once at
/// app launch via `openWasmHost()`); [wasmBytes] is the bytes of
/// `wasm_guest.wasm` from the spike's release build, also loaded
/// once. Both are reused on every call.
HostFunction buildRunBashFunction({
  required WasmHostBackend host,
  required Uint8List wasmBytes,
}) {
  return HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'run_bash',
      description:
          'Run an allow-listed shell command in the wasmtime sandbox. '
          'Available commands: pwd / cd / ls / cat / find / echo. '
          'Supports && chaining and relative paths. cwd persists '
          'across calls. Returns dict {exit_code, stdout, stderr}.',
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
      final stdinBytes = Uint8List.fromList(utf8.encode(cmd));
      final outBytes = await host.run(wasmBytes, stdin: stdinBytes);
      final raw = utf8.decode(outBytes, allowMalformed: true);

      // Errors come back inline as `<host error -N>\n` per the
      // spike's guest. Pull the code into `exit_code`, strip the
      // marker out of `stdout`, and surface a human-readable message
      // in `stderr`. The model reflexively prints stdout and ignores
      // exit_code; with stderr populated, even reflexive printing
      // gives the model an actionable signal when chains fail.
      // (Per upstream PHASE_N1.5_NOTE recommendation.)
      final markerMatch = RegExp(r'<host error (-?\d+)>').firstMatch(raw);
      final exitCode = markerMatch != null
          ? int.parse(markerMatch.group(1)!)
          : 0;
      final stdout = markerMatch != null
          ? raw.replaceAll(markerMatch.group(0)!, '').trimRight()
          : raw;
      final stderr = switch (exitCode) {
        0 => '',
        -3 =>
          'host error -3: command not on allow-list (run `help` to see '
              'available commands)',
        -4 => 'host error -4: I/O error (missing file or directory)',
        _ => 'host error $exitCode',
      };

      return <String, Object?>{
        'exit_code': exitCode,
        'stdout': stdout,
        'stderr': stderr,
      };
    },
  );
}
