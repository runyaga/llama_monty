// Pressure-tests the llm_stream_open/next/close pull-handle pair. Each
// scenario probes one way the LLM-written Python could mishandle a stream
// and records what the host observed.
//
// Run: dart run example/stream_pressure_demo.dart
//
// Output is structured PASS / LEAK / DEADLOCK lines so we can decide what
// invariants the host needs to enforce next.

import 'dart:async';
import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());
  stdout.writeln('Loading model …');
  await engine.loadModel(_modelPath,
      modelParams: ModelParams(contextSize: 4096));
  stdout.writeln('Loaded.\n');

  final engineRef = LlamaEngineRef(engine);
  final plugin = LlamaMontyPlugin(engineRef);
  final monty = MontyRuntime(
    os: defaultOsHandler(),
    extensions: [plugin],
  );

  Future<bool> healthCheck() async {
    // Use raw engineRef so it queues behind any leaked stream still
    // holding the lock — and time it out so we don't hang forever.
    try {
      final reply = await engineRef.complete([
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Reply with: OK',
        ),
      ]).timeout(const Duration(seconds: 30));
      return reply.trim().toUpperCase().contains('OK');
    } catch (e) {
      stdout.writeln('  health check failed: $e');
      return false;
    }
  }

  Future<void> scenario(String name, String code) async {
    stdout.writeln('--- $name ---');
    final beforeCount = plugin.streamHandleCount;
    final beforeIds = plugin.streamHandleIds;
    final result = await monty.execute(code).result;
    final afterCount = plugin.streamHandleCount;
    final afterIds = plugin.streamHandleIds;
    final out = (result.printOutput ?? '').trim();
    if (out.isNotEmpty) stdout.writeln('  py.stdout: $out');
    if (result.error != null) {
      stdout.writeln('  py.error:  ${result.error!.message}');
    }
    final delta = afterCount - beforeCount;
    final newIds = afterIds.where((id) => !beforeIds.contains(id)).toList();
    final tag = delta > 0 ? 'LEAK' : 'CLEAN';
    stdout.writeln('  handles: before=$beforeCount after=$afterCount '
        'delta=$delta newlyLeaked=$newIds [$tag]');
    final healthy = await healthCheck();
    stdout.writeln('  engine.complete after: ${healthy ? 'OK' : 'STUCK'}');
    stdout.writeln();
  }

  // S1: clean baseline — open, drain, close. Should not leak.
  await scenario('S1 clean baseline (open → drain → close)', '''
h = llm_stream_open('Reply: OK')
buf = ''
while True:
  c = llm_stream_next(h)
  if c is None: break
  buf = buf + c
llm_stream_close(h)
print('done', repr(buf))
''');

  // S2: drained but never closed.
  await scenario('S2 drain without close', '''
h = llm_stream_open('Reply: OK')
buf = ''
while True:
  c = llm_stream_next(h)
  if c is None: break
  buf = buf + c
print('drained', repr(buf))
''');

  // S3: Python exception thrown after open, before close.
  await scenario('S3 raise mid-stream (no close)', '''
h = llm_stream_open('Reply: OK')
first = llm_stream_next(h)
print('first chunk', repr(first))
raise ValueError('LLM bug — bail before close')
llm_stream_close(h)
''');

  // S4: close on a handle that was never opened.
  await scenario('S4 close unknown handle id', '''
llm_stream_close(99999)
print('returned cleanly')
''');

  // S5: next on a closed handle (post-close use-after).
  await scenario('S5 next on already-closed handle', '''
h = llm_stream_open('Reply: OK')
while True:
  c = llm_stream_next(h)
  if c is None: break
llm_stream_close(h)
try:
  llm_stream_next(h)
  print('ERROR: should have thrown')
except Exception as e:
  print('threw as expected:', e)
''');

  // S6: open many without closing — does the engine still serve?
  await scenario('S6 open 5 streams without close', '''
ids = []
for i in range(5):
  ids.append(llm_stream_open('Reply: ' + str(i)))
print('opened ids', ids)
''');

  // S7: cross-execute health check — call llm_complete from a fresh
  // execute() AFTER the previous execute() leaked. Did the engine
  // recover, or did we hang waiting for a leaked stream's lock?
  stdout.writeln('--- S7 cross-execute llm_complete after leaks ---');
  stdout.writeln('  pre-call leaked handles: ${plugin.streamHandleCount}');
  final t0 = DateTime.now();
  try {
    final r = await monty
        .execute('print(llm_complete("Reply: OK"))')
        .result
        .timeout(const Duration(seconds: 60));
    final dt = DateTime.now().difference(t0).inMilliseconds;
    stdout.writeln('  llm_complete returned after ${dt}ms');
    if (r.printOutput != null) {
      stdout.writeln('  output: ${r.printOutput!.trim()}');
    }
  } on TimeoutException {
    final dt = DateTime.now().difference(t0).inMilliseconds;
    stdout.writeln('  DEADLOCK after ${dt}ms waiting for llm_complete');
  } catch (e) {
    stdout.writeln('  llm_complete threw: $e');
  }
  stdout.writeln();

  // Final tally — are these handles ever going to be closed?
  stdout.writeln('=== final state ===');
  stdout.writeln('leaked handles still in plugin: ${plugin.streamHandleCount}');
  stdout.writeln('ids: ${plugin.streamHandleIds}');

  // Dump the streams journal — the plugin writes one line per open / close /
  // eos. The LLM-written Python never touches it, so it's tamper-proof.
  stdout.writeln();
  stdout.writeln('=== /journal/streams.jsonl ===');
  final journalScript = '''
from pathlib import Path
p = Path('/tmp/llama_monty/streams.jsonl')
if p.exists():
  print(p.read_text())
else:
  print('(no journal file)')
''';
  final j = await monty.execute(journalScript).result;
  stdout.write(j.printOutput ?? '');
  if (j.error != null)
    stdout.writeln('journal read error: ${j.error!.message}');

  await monty.dispose();
  await engine.dispose();
}
