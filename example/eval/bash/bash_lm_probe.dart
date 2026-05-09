// Drives a SINGLE bash-flavoured prompt through the live agent loop
// and prints exactly what the model writes, what fences get extracted,
// what run_bash returns, and what prose comes back. Lets us see where
// the python/bash mixup is happening without sifting through the full
// 14-spec battery.
//
// Run:
//   dart run example/eval/bash/bash_lm_probe.dart "Use run_bash to print 'hello' via echo. Tell me what it printed."

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';
import 'package:wasm_host_dart/src/wasm_host_ffi.dart';
import 'package:wasm_host_dart/wasm_host.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';
const _spikeRoot = '/Users/runyaga/dev/wasmtime-spike';
const _dylibPath = '$_spikeRoot/host/target/release/libwasm_host.dylib';
const _wasmPath =
    '$_spikeRoot/guest/target/wasm32-wasip1/release/wasm_guest.wasm';

const _systemPrompt = '''
You are a coding agent with a Python sandbox. To DO anything, you
must write a `\`\`\`monty` fence — the harness extracts and executes
the code. Plain prose is just for the final answer AFTER you've
seen the tool output.

`run_bash(cmd)` is a Python function inside the sandbox that runs
allow-listed shell commands (pwd / cd / ls / cat / find / echo;
&& chaining; cwd persists across calls) and returns
{'exit_code': N, 'stdout': '...', 'stderr': ''}. To use it you
write a Python fence that CALLS it:

```monty
out = run_bash('echo hello')
print(out['stdout'])
```

The harness then runs that fence. You will see the printed output
and can answer the user using the EXACT bytes you saw.

CRITICAL: do NOT write `\`\`\`json` blocks pretending to be the tool
output — those are hallucinations and will confuse the harness. Only
write `\`\`\`monty` fences for code; everything else is prose.

GROUNDING: copy values from tool output verbatim. Never substitute
training defaults.
''';

Uint8List _b(String s) => Uint8List.fromList(s.codeUnits);

final Map<String, Uint8List> _vfs = {
  '/notes.txt': _b('todo:\n  - finish the demo\n'),
  '/data/greeting.txt': _b('hello, world!\n'),
  '/data/numbers.txt': _b('1\n2\n3\n42\n'),
};

Future<void> main(List<String> args) async {
  final prompt = args.isNotEmpty
      ? args.first
      : "Use run_bash to print 'hello' via echo. Tell me what it printed.";

  stdout.writeln('=== prompt ===');
  stdout.writeln(prompt);

  // Set up runtime + bash host.
  final os = defaultOsHandler();
  final monty = MontyRuntime(os: os);
  final wasmHost = WasmHostFfi.open(_dylibPath);
  final wasmBytes = File(_wasmPath).readAsBytesSync();
  await wasmHost.loadTree(_vfs);
  monty.register(
    buildRunBashFunction(host: wasmHost, wasmBytes: wasmBytes),
  );

  // Set up LLM.
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath, modelParams: ModelParams(contextSize: 8192));
  final session = ChatSession(engine, systemPrompt: _systemPrompt);
  session.addMessage(LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: prompt,
  ));

  // Get the model's reply.
  final buf = StringBuffer();
  await for (final chunk in session.create(
    const [],
    params: const GenerationParams(temp: 1.0, topP: 0.95),
  )) {
    final s = chunk.choices.firstOrNull?.delta.content;
    if (s != null) buf.write(s);
  }
  final reply = buf.toString().trim();

  stdout.writeln('\n=== model reply (raw) ===');
  stdout.writeln(reply);

  // Extract any fence and run it. Tightened to REQUIRE one of the
  // code-language tags — bare ``` and ```json/```output etc. are
  // hallucinated output blocks, NOT executable code.
  final fenceRe = RegExp(r'```(?:monty|python|py)\s*\n?([\s\S]*?)```');
  final matches = fenceRe.allMatches(reply).toList();
  stdout.writeln('\n=== ${matches.length} fence(s) extracted ===');
  for (var i = 0; i < matches.length; i++) {
    final code = matches[i].group(1)!.trim();
    stdout.writeln('--- fence $i ---');
    stdout.writeln(code);
    final r = await monty.execute(code).result;
    if (r.error != null) {
      stdout.writeln('--- fence $i ERROR ---');
      stdout.writeln(r.error!.message);
    } else {
      stdout.writeln('--- fence $i printOutput ---');
      stdout.writeln(r.printOutput?.trim() ?? '(empty)');
    }
  }

  await wasmHost.dispose();
  await monty.dispose();
  await engine.dispose();
}
