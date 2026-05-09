// Integration tests — require a real GGUF model and native LlamaBackend.
// Run with:
//   dart test --tags integration test/llama_monty_integration_test.dart
//
// The model is downloaded automatically if not present at ~/models/<name>.
@Tags(['integration'])
library;

import 'dart:io';

import 'package:dart_monty/dart_monty.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _modelFilename = 'gemma-4-E2B-it-Q4_K_M.gguf';
const _modelUrl =
    'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/'
    '$_modelFilename?download=true';

/// Downloads [url] following redirects, optionally with a Bearer token read
/// from the HF_TOKEN (or HUGGING_FACE_HUB_TOKEN) environment variable.
Future<void> _download(String url, IOSink dest) async {
  final token = Platform.environment['HF_TOKEN'] ??
      Platform.environment['HUGGING_FACE_HUB_TOKEN'];

  final client = HttpClient();
  try {
    // Follow up to 5 redirects manually so we can re-send auth headers.
    var currentUrl = url;
    for (var redirects = 0; redirects < 5; redirects++) {
      final req = await client.getUrl(Uri.parse(currentUrl));
      if (token != null && token.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $token');
      }
      final res = await req.close();

      if (res.statusCode == 301 ||
          res.statusCode == 302 ||
          res.statusCode == 307 ||
          res.statusCode == 308) {
        final location = res.headers.value('location');
        if (location == null) throw StateError('Redirect with no Location header');
        await res.drain<void>();
        currentUrl = location;
        continue;
      }

      if (res.statusCode == 401 || res.statusCode == 403) {
        await res.drain<void>();
        throw StateError(
          'HTTP ${res.statusCode} — model may be gated. '
          'Set HF_TOKEN env var to a HuggingFace access token.',
        );
      }

      if (res.statusCode != 200) {
        await res.drain<void>();
        throw StateError('HTTP ${res.statusCode} downloading $currentUrl');
      }

      await res.pipe(dest);
      return;
    }
    throw StateError('Too many redirects downloading $url');
  } finally {
    client.close();
  }
}

Future<String> _ensureModel() async {
  final home = Platform.environment['HOME'] ?? '.';
  final dir = Directory('$home/models');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final path = '${dir.path}/$_modelFilename';
  if (File(path).existsSync()) return path;

  stdout.writeln('Downloading model → $path');
  stdout.writeln('(Set HF_TOKEN env var if download is gated)');
  final sink = File(path).openWrite();
  try {
    await _download(_modelUrl, sink);
  } catch (_) {
    await sink.close();
    // Remove partial file so the next run retries.
    try { File(path).deleteSync(); } catch (_) {}
    rethrow;
  }
  await sink.close();
  stdout.writeln('Download complete.');
  return path;
}

void main() {
  late LlamaEngine engine;
  late LlamaEngineRef engineRef;
  late LlamaMontyPlugin plugin;
  late MontyRuntime runtime;

  setUpAll(() async {
    final modelPath = await _ensureModel();
    engine = LlamaEngine(LlamaBackend());
    await engine.loadModel(modelPath);
    engineRef = LlamaEngineRef(engine);
    plugin = LlamaMontyPlugin(engineRef);
    runtime = MontyRuntime(extensions: [plugin]);
  });

  tearDownAll(() async {
    await runtime.dispose();
    await engine.dispose();
  });

  // -------------------------------------------------------------------------
  // LlamaEngineRef — direct complete() calls (no MontyRuntime)
  // -------------------------------------------------------------------------

  group('LlamaEngineRef.complete', () {
    test('returns a non-empty string', () async {
      final result = await engineRef.complete([
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Reply with exactly one word: hello',
        ),
      ]);
      expect(result.trim(), isNotEmpty);
    });

    test('withLock serialises two concurrent completions', () async {
      // Launch both before awaiting either — the lock must queue them so
      // neither aborts the other.
      final f1 = engineRef.complete([
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Say A.'),
      ]);
      final f2 = engineRef.complete([
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'Say B.'),
      ]);
      final results = await Future.wait([f1, f2]);
      expect(results[0].trim(), isNotEmpty);
      expect(results[1].trim(), isNotEmpty);
    });
  });

  // -------------------------------------------------------------------------
  // ChatSession — mirrors the app's chat panel
  // -------------------------------------------------------------------------

  group('ChatSession', () {
    late ChatSession session;

    setUp(() => session = ChatSession(engine));
    tearDown(() => session.reset(keepSystemPrompt: false));

    test('single-turn response is non-empty', () async {
      final buf = StringBuffer();
      await for (final chunk in session.create([
        LlamaTextContent('Say hello in one sentence.'),
      ])) {
        final content = chunk.choices.firstOrNull?.delta.content;
        if (content != null) buf.write(content);
      }
      expect(buf.toString().trim(), isNotEmpty);
    });

    test('system prompt is honoured', () async {
      session = ChatSession(engine, systemPrompt: 'Always reply with exactly: PONG');
      final buf = StringBuffer();
      await for (final chunk in session.create([LlamaTextContent('ping')])) {
        final content = chunk.choices.firstOrNull?.delta.content;
        if (content != null) buf.write(content);
      }
      expect(buf.toString().toUpperCase(), contains('PONG'));
    });
  });

  // -------------------------------------------------------------------------
  // App layout — agent session + REPL session sharing one engine
  // -------------------------------------------------------------------------

  group('two MontyRuntimes, one LlamaEngineRef', () {
    test('REPL can call llm functions while agent session runs plain Python',
        () async {
      // Mirrors the app: _agentSession has no plugin, _replRuntime has plugin.
      final agentSession = MontyRuntime();
      final replRuntime = MontyRuntime(
        extensions: [LlamaMontyPlugin(engineRef)],
      );

      try {
        // Agent session executes plain Python.
        final agentResult = await agentSession.execute('2 + 2').result;
        expect(agentResult.error, isNull);
        expect(agentResult.value, isA<MontyInt>());
        expect((agentResult.value as MontyInt).value, equals(4));

        // REPL calls the LLM via LlamaMontyPlugin.
        final replResult = await replRuntime
            .execute("llm_complete('Reply with exactly: READY')")
            .result;
        expect(replResult.error, isNull);
        final text = (replResult.value as MontyString).value;
        expect(text.trim(), isNotEmpty);
      } finally {
        await agentSession.dispose();
        await replRuntime.dispose();
      }
    });
  });

  group('llm_complete', () {
    test('returns a non-empty string', () async {
      final result = await runtime
          .execute("llm_complete('Say hello in one sentence.')")
          .result;
      expect(result.error, isNull, reason: result.error.toString());
      final text = (result.value as MontyString).value;
      expect(text.trim(), isNotEmpty);
    });

    test('honours system_prompt', () async {
      final result = await runtime
          .execute(
            "llm_complete('What is the capital of France?', "
            "'Reply with exactly one word.')",
          )
          .result;
      expect(result.error, isNull);
      final text = (result.value as MontyString).value.trim().toLowerCase();
      expect(text, contains('paris'));
    });
  });

  group('llm_chat', () {
    setUp(() async {
      // Always start each chat group test with a clean session.
      await runtime.execute("llm_chat_reset(keep_system_prompt=False)").result;
    });

    test('returns a non-empty string', () async {
      final result = await runtime
          .execute("llm_chat('Say hello in one sentence.')")
          .result;
      expect(result.error, isNull);
      final text = (result.value as MontyString).value;
      expect(text.trim(), isNotEmpty);
    });

    test('retains history across turns', () async {
      final r1 = await runtime
          .execute("llm_chat('My favourite colour is ultraviolet.')")
          .result;
      expect(r1.error, isNull);

      final r2 = await runtime
          .execute("llm_chat('What colour did I just mention?')")
          .result;
      expect(r2.error, isNull);
      final reply = (r2.value as MontyString).value.toLowerCase();
      expect(reply, contains('ultraviolet'));
    });
  });

  group('llm_chat_reset', () {
    test('wipes history so model no longer knows earlier facts', () async {
      // Teach the model something distinctive.
      await runtime
          .execute("llm_chat('Remember: xyzzy42 is my secret codeword.')")
          .result;

      // Reset without keeping the system prompt.
      final reset = await runtime
          .execute("llm_chat_reset(keep_system_prompt=False)")
          .result;
      expect(reset.error, isNull);

      // Ask about the codeword — model should not know it.
      final r = await runtime
          .execute("llm_chat('What is my secret codeword?')")
          .result;
      expect(r.error, isNull);
      final reply = (r.value as MontyString).value.toLowerCase();
      expect(reply, isNot(contains('xyzzy42')));
    });

    test('keep_system_prompt=True preserves the system prompt', () async {
      const prompt = 'Always end replies with DONE.';
      await runtime
          .execute(
            "llm_chat('Hi', system_prompt='$prompt')",
          )
          .result;
      // reset() with default keep_system_prompt=True must not clear the prompt.
      await runtime.execute('llm_chat_reset()').result;

      // Verify at the Dart level — system prompt is still set on the session.
      expect(plugin.chatSession.systemPrompt, equals(prompt));
    });

    test('returns null (None in Python)', () async {
      final result = await runtime.execute('llm_chat_reset()').result;
      expect(result.error, isNull);
      expect(result.value, isA<MontyNone>());
    });
  });
}
