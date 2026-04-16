import 'package:dart_monty/dart_monty_bridge.dart' show HostFunctionSchema;
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

import 'package:llama_monty/llama_monty.dart';

/// Minimal [LlamaBackend] stub that allows constructing [LlamaEngine]
/// without any native / WebGPU infrastructure.
class _StubBackend implements LlamaBackend {
  @override
  bool get isReady => false;
  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async => 0;
  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double)? onProgress,
  }) async => 0;
  @override
  Future<void> modelFree(int modelHandle) async {}
  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 0;
  @override
  Future<void> contextFree(int contextHandle) async {}
  @override
  Future<int> getContextSize(int contextHandle) async => 0;
  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) => const Stream.empty();
  @override
  void cancelGeneration() {}
  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async => [];
  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => '';
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
  Future<String> getBackendName() async => 'stub';
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
  ) async => null;
  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}
  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;
  @override
  Future<bool> supportsAudio(int mmContextHandle) async => false;
  @override
  Future<({int free, int total})> getVramInfo() async =>
      (total: 0, free: 0);
  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async => '';
}

void main() {
  late LlamaMontyPlugin plugin;

  setUp(() {
    final engine = LlamaEngine(_StubBackend());
    final ref = LlamaEngineRef(engine);
    plugin = LlamaMontyPlugin(ref);
  });

  group('LlamaMontyPlugin', () {
    test('namespace is "llm"', () {
      expect(plugin.namespace, equals('llm'));
    });

    test('exposes three functions', () {
      expect(plugin.functions, hasLength(3));
    });

    test('function names are correct', () {
      final names = plugin.functions.map((f) => f.schema.name).toList();
      expect(names, containsAll(['llm_complete', 'llm_chat', 'llm_chat_reset']));
    });

    group('llm_complete', () {
      late HostFunctionSchema schema;
      setUp(() {
        schema = plugin.functions
            .firstWhere((f) => f.schema.name == 'llm_complete')
            .schema;
      });

      test('"prompt" is required', () {
        final p = schema.params.firstWhere((p) => p.name == 'prompt');
        expect(p.isRequired, isTrue);
      });

      test('"system_prompt" is optional', () {
        final p = schema.params.firstWhere((p) => p.name == 'system_prompt');
        expect(p.isRequired, isFalse);
      });
    });

    group('llm_chat', () {
      late HostFunctionSchema schema;
      setUp(() {
        schema = plugin.functions
            .firstWhere((f) => f.schema.name == 'llm_chat')
            .schema;
      });

      test('"message" is required', () {
        final p = schema.params.firstWhere((p) => p.name == 'message');
        expect(p.isRequired, isTrue);
      });

      test('"system_prompt" is optional', () {
        final p = schema.params.firstWhere((p) => p.name == 'system_prompt');
        expect(p.isRequired, isFalse);
      });
    });

    group('llm_chat_reset', () {
      late HostFunctionSchema schema;
      setUp(() {
        schema = plugin.functions
            .firstWhere((f) => f.schema.name == 'llm_chat_reset')
            .schema;
      });

      test('"keep_system_prompt" is optional and defaults to true', () {
        final p = schema.params.firstWhere(
          (p) => p.name == 'keep_system_prompt',
        );
        expect(p.isRequired, isFalse);
        expect(p.defaultValue, isTrue);
      });
    });

    test('no stream wrapper by default', () {
      expect(plugin.hasStreamWrapper, isFalse);
    });
  });

  group('LlamaEngineRef', () {
    test('exposes the underlying engine', () {
      final engine = LlamaEngine(_StubBackend());
      final ref = LlamaEngineRef(engine);
      expect(ref.engine, same(engine));
    });

    test('withLock serialises concurrent calls', () async {
      final engine = LlamaEngine(_StubBackend());
      final ref = LlamaEngineRef(engine);
      final log = <String>[];

      // Fire two withLock calls without awaiting the first.
      final f1 = ref.withLock(() async {
        log.add('start-1');
        await Future<void>.delayed(Duration.zero);
        log.add('end-1');
        return 'a';
      });
      final f2 = ref.withLock(() async {
        log.add('start-2');
        log.add('end-2');
        return 'b';
      });

      final results = await Future.wait([f1, f2]);
      expect(results, equals(['a', 'b']));
      // f2 must not start until f1 finishes.
      expect(log, equals(['start-1', 'end-1', 'start-2', 'end-2']));
    });
  });
}
