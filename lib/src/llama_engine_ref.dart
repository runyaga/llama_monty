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

  /// Runs [fn] exclusively while holding the engine lock.
  ///
  /// All callers that share this [LlamaEngineRef] are queued: [fn] will not
  /// start until the preceding holder finishes. Use this to protect any
  /// operation that drives the engine (e.g. [ChatSession.create]).
  Future<T> withLock<T>(Future<T> Function() fn) {
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;

    return prev.then((_) async {
      try {
        return await fn();
      } finally {
        completer.complete();
      }
    });
  }

  /// Sends [messages] to the engine and returns the full assistant reply.
  ///
  /// Concurrent calls are queued: each call waits for the preceding one to
  /// finish before starting its own generation.
  Future<String> complete(List<LlamaChatMessage> messages) =>
      withLock(() => _collect(messages));

  Future<String> _collect(List<LlamaChatMessage> messages) async {
    final buf = StringBuffer();
    await for (final chunk in engine.create(messages)) {
      final content = chunk.choices.firstOrNull?.delta.content;
      if (content != null) buf.write(content);
    }
    return buf.toString();
  }
}
