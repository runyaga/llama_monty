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

    test('exposes exactly one function', () {
      expect(plugin.functions, hasLength(1));
    });

    test('function is named "llm_complete"', () {
      expect(plugin.functions.first.schema.name, equals('llm_complete'));
    });

    test('"prompt" param is required', () {
      final params = plugin.functions.first.schema.params;
      final prompt = params.firstWhere((p) => p.name == 'prompt');
      expect(prompt.isRequired, isTrue);
    });

    test('"system_prompt" param is optional', () {
      final params = plugin.functions.first.schema.params;
      final systemPrompt = params.firstWhere((p) => p.name == 'system_prompt');
      expect(systemPrompt.isRequired, isFalse);
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
  });
}
