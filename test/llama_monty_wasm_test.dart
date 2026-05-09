// WASM dispatch tests — validate DispatchMode.future on the browser platform.
//
// These tests use a fake LlamaBackend that returns deterministic responses
// without WebGPU, so they run on any Chrome instance.
//
// Run with:
//   dart test -p chrome --tags wasm test/llama_monty_wasm_test.dart
//
// For real-model WASM tests (requires WebGPU + COI headers):
//   See README — serve the test with a COI-capable HTTP server and pass
//   --tags integration to download and cache the Gemma model.
@TestOn('browser')
@Tags(['wasm'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty/dart_monty.dart';
import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' as web;

// ---------------------------------------------------------------------------
// Fake backend — deterministic responses, no GPU required.
// ---------------------------------------------------------------------------

const _fakeResponse = 'fake-response';

class _FakeBackend implements LlamaBackend {
  @override
  bool get isReady => true;
  @override
  bool get supportsUrlLoading => true;

  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double)? onProgress,
  }) async {
    onProgress?.call(1.0);
    return 1;
  }

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<int> getContextSize(int contextHandle) async => 4096;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    yield utf8.encode(_fakeResponse);
  }

  @override
  void cancelGeneration() {}

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async =>
      [1, 2, 3];

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async =>
      '';

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {};

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {}

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {}

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {}

  @override
  Future<String> getBackendName() async => 'fake';

  @override
  Future<bool> isGpuSupported() async => false;

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> dispose() async {}

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async =>
      null;

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => false;

  @override
  Future<({int free, int total})> getVramInfo() async => (total: 0, free: 0);

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async =>
      messages.map((m) => '${m['role']}: ${m['content']}').join('\n');
}

// ---------------------------------------------------------------------------
// Bridge initialisation
//
// DartMonty.ensureInitialized() loads the bridge from a Flutter asset path
// that doesn't exist in the dart-test HTTP server. Instead we inject it
// directly from the /packages/ URL that dart test DOES serve, then let
// DartMonty.ensureInitialized() find the bridge already loaded and return.
// ---------------------------------------------------------------------------

@JS('window.DartMontyBridge')
external JSAny? get _dartMontyBridge;

Future<void> _loadBridge() async {
  if (_dartMontyBridge != null) return;
  // dart test serves each package's lib/ at /packages/<name>/.
  const url = 'packages/dart_monty_core/assets/dart_monty_core_bridge.js';
  final completer = Completer<void>();
  final script = web.document.createElement('script') as web.HTMLScriptElement
    ..src = url
    ..onload = (web.Event _) { completer.complete(); }.toJS
    ..onerror = (web.Event _) {
        completer.completeError(
          StateError('Failed to load bridge from $url — '
              'check that dart_monty_core is a transitive dep'),
        );
      }.toJS;
  web.document.head!.appendChild(script);
  await completer.future;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() async {
    await _loadBridge();
    // Bridge is now loaded; ensureInitialized() detects it and returns early.
    await DartMonty.ensureInitialized();
  });

  late LlamaEngine engine;
  late LlamaEngineRef engineRef;
  late MontyRuntime runtime;

  setUp(() async {
    engine = LlamaEngine(_FakeBackend());
    await engine.loadModel('fake-model');
    engineRef = LlamaEngineRef(engine);
    runtime = MontyRuntime(
      extensions: [LlamaMontyPlugin(engineRef)],
    );
  });

  tearDown(() async {
    await runtime.dispose();
    await engine.dispose();
  });

  // -------------------------------------------------------------------------
  // DispatchMode.future — the critical web path
  //
  // On web, dart.library.io is absent so _asyncDispatch == DispatchMode.future.
  // These tests verify the future-resolution round-trip works correctly and
  // that calling a function multiple times on the same runtime does not regress
  // to returning raw coroutine handles (the original bug).
  // -------------------------------------------------------------------------

  group('DispatchMode.future — llm_complete', () {
    test('first call resolves to the fake response', () async {
      final result = await runtime
          .execute("llm_complete('hello')")
          .result;
      expect(result.error, isNull, reason: result.error?.toString());
      final text = (result.value as MontyString).value;
      expect(text, equals(_fakeResponse));
    });

    test('second call also resolves (regression: must not return raw coroutine)',
        () async {
      await runtime.execute("llm_complete('first call')").result;

      final result = await runtime
          .execute("llm_complete('second call')")
          .result;
      expect(result.error, isNull);
      final text = (result.value as MontyString).value;
      // Must be the actual response, not "<coroutine external_future(0)>".
      expect(text, equals(_fakeResponse));
      expect(text, isNot(contains('coroutine')));
    });

    test('third sequential call resolves correctly', () async {
      for (var i = 1; i <= 3; i++) {
        final result = await runtime
            .execute("llm_complete('call $i')")
            .result;
        expect(result.error, isNull, reason: 'call $i failed');
        expect((result.value as MontyString).value, equals(_fakeResponse));
      }
    });

    test('honours optional system_prompt parameter', () async {
      final result = await runtime
          .execute("llm_complete('hello', 'You are a bot.')")
          .result;
      expect(result.error, isNull);
      expect((result.value as MontyString).value, equals(_fakeResponse));
    });
  });

  group('DispatchMode.future — llm_chat', () {
    setUp(() async {
      await runtime.execute('llm_chat_reset(keep_system_prompt=False)').result;
    });

    test('single call resolves', () async {
      final result = await runtime.execute("llm_chat('hello')").result;
      expect(result.error, isNull);
      expect((result.value as MontyString).value, equals(_fakeResponse));
    });

    test('two sequential calls both resolve', () async {
      final r1 = await runtime.execute("llm_chat('turn 1')").result;
      expect(r1.error, isNull);
      expect((r1.value as MontyString).value, equals(_fakeResponse));

      final r2 = await runtime.execute("llm_chat('turn 2')").result;
      expect(r2.error, isNull);
      expect((r2.value as MontyString).value, equals(_fakeResponse));
    });
  });

  group('DispatchMode.future — llm_chat_reset', () {
    test('returns None', () async {
      final result = await runtime.execute('llm_chat_reset()').result;
      expect(result.error, isNull);
      expect(result.value, isA<MontyNone>());
    });

    test('keep_system_prompt=False also returns None', () async {
      final result = await runtime
          .execute('llm_chat_reset(keep_system_prompt=False)')
          .result;
      expect(result.error, isNull);
      expect(result.value, isA<MontyNone>());
    });
  });

  // -------------------------------------------------------------------------
  // App layout on web — agent session + REPL session sharing one engine ref
  // -------------------------------------------------------------------------

  group('two MontyRuntimes, one LlamaEngineRef (web)', () {
    test('REPL calls LLM while agent session runs plain Python', () async {
      final agentSession = MontyRuntime();
      final replRuntime = MontyRuntime(
        extensions: [LlamaMontyPlugin(engineRef)],
      );

      try {
        final agentResult = await agentSession.execute('2 + 2').result;
        expect(agentResult.error, isNull);
        expect((agentResult.value as MontyInt).value, equals(4));

        final replResult = await replRuntime
            .execute("llm_complete('ping')")
            .result;
        expect(replResult.error, isNull);
        expect((replResult.value as MontyString).value, equals(_fakeResponse));
      } finally {
        await agentSession.dispose();
        await replRuntime.dispose();
      }
    });
  });
}
