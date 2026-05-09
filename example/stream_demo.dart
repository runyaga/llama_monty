// Verifies the llm_stream_open / llm_stream_next / llm_stream_close
// pull-handle pair end-to-end on FFI.
//
// Drives a Python snippet that streams a haiku token-by-token, printing
// each chunk on its own line so you can see chunks arriving as the LLM
// generates. Then drains a second stream while the first is closing so
// we exercise the queueing path through LlamaEngineRef.withLock.
//
// Run: dart run example/stream_demo.dart

import 'dart:io';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

Future<void> main() async {
  final engine = LlamaEngine(LlamaBackend());
  stdout.writeln('Loading model …');
  await engine.loadModel(_modelPath, modelParams: ModelParams(contextSize: 4096));
  stdout.writeln('Loaded.\n');

  final engineRef = LlamaEngineRef(engine);
  final monty = MontyRuntime(
    os: defaultOsHandler(),
    extensions: [LlamaMontyPlugin(engineRef)],
  );

  // ---------- Test 1: single stream, count chunks ---------------------------
  stdout.writeln('--- Test 1: single stream, "haiku about cats" ---');
  const t1 = '''
prompt = 'Write a haiku about cats. Just the haiku.'
h = llm_stream_open(prompt)
chunks = 0
total = ''
while True:
    c = llm_stream_next(h)
    if c is None: break
    chunks = chunks + 1
    total = total + c
    print('chunk', chunks, '=>', repr(c))
llm_stream_close(h)
print('--- total ---')
print(total)
print('--- got', chunks, 'chunks ---')
''';
  final r1 = await monty.execute(t1).result;
  stdout.write(r1.printOutput ?? '');
  if (r1.error != null) stdout.writeln('ERROR: ${r1.error!.message}');
  stdout.writeln();

  // ---------- Test 2: two sequential streams (queueing path) ---------------
  stdout.writeln('--- Test 2: open second stream right after closing first ---');
  const t2 = '''
def stream_to_string(prompt):
    h = llm_stream_open(prompt)
    out = ''
    n = 0
    while True:
        c = llm_stream_next(h)
        if c is None: break
        out = out + c
        n = n + 1
    llm_stream_close(h)
    return out, n

a, na = stream_to_string('Reply with the single word: ALPHA')
print('first  =>', repr(a), '(' + str(na) + ' chunks)')
b, nb = stream_to_string('Reply with the single word: BETA')
print('second =>', repr(b), '(' + str(nb) + ' chunks)')
''';
  final r2 = await monty.execute(t2).result;
  stdout.write(r2.printOutput ?? '');
  if (r2.error != null) stdout.writeln('ERROR: ${r2.error!.message}');
  stdout.writeln();

  // ---------- Test 3: close mid-stream ------------------------------------
  stdout.writeln('--- Test 3: close before draining (handle leak guard) ---');
  const t3 = '''
h = llm_stream_open('Count from 1 to 50, slowly.')
first = llm_stream_next(h)
print('first chunk =>', repr(first))
llm_stream_close(h)
print('closed early; new stream still works:')
h2 = llm_stream_open('Reply: OK')
out = ''
while True:
    c = llm_stream_next(h2)
    if c is None: break
    out = out + c
llm_stream_close(h2)
print('after-close stream =>', repr(out))
''';
  final r3 = await monty.execute(t3).result;
  stdout.write(r3.printOutput ?? '');
  if (r3.error != null) stdout.writeln('ERROR: ${r3.error!.message}');

  await monty.dispose();
  await engine.dispose();
}
