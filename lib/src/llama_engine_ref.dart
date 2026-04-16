import 'dart:async';

import 'package:llamadart/llamadart.dart';

/// Wraps a [LlamaEngine] and serialises concurrent [complete] calls.
///
/// [LlamaEngine.create] is not safe for concurrent invocations — starting a
/// new generation while one is already running aborts the previous via the
/// backend's internal abort controller. [LlamaEngineRef] ensures completions
/// are queued and executed one at a time.
///
/// Usage:
/// ```dart
/// final engine = LlamaEngine(WebAutoBackend(...));
/// await engine.loadModelFromUrl(modelUrl, onProgress: (p) => print('$p%'));
/// final engineRef = LlamaEngineRef(engine);
/// ```
class LlamaEngineRef {
  /// Creates a [LlamaEngineRef] wrapping [engine].
  LlamaEngineRef(this.engine);

  /// The underlying [LlamaEngine].
  final LlamaEngine engine;

  Future<void> _lock = Future.value();

  /// Sends [messages] to the engine and returns the full assistant reply.
  ///
  /// Concurrent calls are queued: each call waits for the preceding one to
  /// finish before starting its own generation.
  Future<String> complete(List<LlamaChatMessage> messages) {
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;

    return prev.then((_) async {
      try {
        return await _collect(messages);
      } finally {
        completer.complete();
      }
    });
  }

  Future<String> _collect(List<LlamaChatMessage> messages) async {
    final buf = StringBuffer();
    await for (final chunk in engine.create(messages)) {
      final content = chunk.choices.firstOrNull?.delta.content;
      if (content != null) buf.write(content);
    }
    return buf.toString();
  }
}
