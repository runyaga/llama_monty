import 'dart:async';
import 'dart:collection';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llamadart/llamadart.dart';

import 'llama_engine_ref.dart';

/// Internal state for a single streaming completion: a buffered queue of
/// already-arrived chunks plus a waiter the consumer awaits when the queue
/// is empty.
class _StreamHandle {
  final ListQueue<String> buffer = ListQueue();
  bool done = false;
  Object? error;
  Completer<void>? waiter;
  StreamSubscription<dynamic>? sub;

  void wake() {
    final w = waiter;
    waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }
}

/// A [MontyExtension] that exposes a local LLM to Python code running in Monty.
///
/// Registers three host functions:
/// - `llm_complete(prompt, [system_prompt])` — stateless single-turn completion
/// - `llm_chat(message, [system_prompt])` — stateful multi-turn chat with history
/// - `llm_chat_reset([keep_system_prompt])` — clears the conversation history
///
/// **Python usage:**
/// ```python
/// # Stateless — no history retained between calls
/// result = llm_complete("What is 2 + 2?")
/// result = llm_complete("Classify this text.", "Reply with one word only.")
///
/// # Stateful — history accumulates within the same Monty session
/// r1 = llm_chat("My name is Alice.")
/// r2 = llm_chat("What is my name?")   # model knows: "Alice"
/// llm_chat_reset()                    # wipe history, keep system prompt
/// r3 = llm_chat("What is my name?")   # model no longer knows
/// ```
///
/// **Prerequisites:**
/// - The [LlamaEngine] inside [LlamaEngineRef] must be loaded before any
///   Python code calls these functions. Use [LlamaEngine.loadModelFromUrl]
///   on the WASM/Web platform.
/// - The dart_monty bridge must be initialised before any Python code calls
///   these functions. Call `DartMonty.ensureInitialized()` on web.
class LlamaMontyPlugin extends MontyExtension {
  /// Creates a [LlamaMontyPlugin] backed by [engineRef].
  LlamaMontyPlugin(this._engineRef)
    : _chatSession = ChatSession(_engineRef.engine);

  final LlamaEngineRef _engineRef;
  final ChatSession _chatSession;

  /// The engine reference backing this plugin.
  ///
  /// Exposed for testing and for consumers that need to share an engine
  /// across multiple plugin instances.
  LlamaEngineRef get engineRef => _engineRef;

  /// The chat session backing `llm_chat` / `llm_chat_reset`.
  ///
  /// Exposed for inspection (e.g. reading `systemPrompt` after a reset).
  ChatSession get chatSession => _chatSession;

  @override
  String get namespace => 'llm';

  /// Children clone this extension with a fresh [ChatSession] but share the
  /// parent's [LlamaEngineRef] (and its lock) so inference is serialised.
  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  LlamaMontyPlugin createChildInstance(ChildSpawnContext context) =>
      LlamaMontyPlugin(_engineRef);

  @override
  List<HostFunction> get functions => [
    _llmCompleteFunction,
    _llmChatFunction,
    _llmChatResetFunction,
    _llmStreamOpenFunction,
    _llmStreamNextFunction,
    _llmStreamCloseFunction,
  ];

  // Open streams keyed by integer handle. Reused across the lifetime of
  // this plugin instance.
  final Map<int, _StreamHandle> _streams = {};
  int _nextStreamId = 1;

  /// Number of currently open stream handles.
  ///
  /// Exposed for pressure tests / leak detection. A non-zero value after a
  /// Python `execute()` returns indicates the LLM-written code did not
  /// `llm_stream_close()` every handle it opened (e.g. crashed before the
  /// close, returned early, etc.).
  int get streamHandleCount => _streams.length;

  /// Snapshot of currently open stream handle ids.
  List<int> get streamHandleIds => List.unmodifiable(_streams.keys);

  /// Public escape hatch: drop every open stream handle. Intended for
  /// shutdown / tests / explicit GC after the host app observes a Python
  /// script ending. Background tasks driving the streams are not cancelled
  /// here — they will release the engine lock at natural EOS.
  ///
  /// **Why this exists as an explicit method**: dart_monty's extension API
  /// does not yet surface a per-run "this execute() finished" callback.
  /// `HostContext.executionId` is per-host-function-call, not per-run, so
  /// the plugin cannot autonomously tell which handles outlived their
  /// owning Python script. Until dart_monty grows `MontyExtension.onRunEnd`
  /// (or equivalent), the host application is the closest thing to a run
  /// observer and must call this when it knows a run has finished.
  ///
  /// See `example/stream_pressure_demo.dart` for the failure modes.
  void disposeAllHandles() => _streams.clear();

  late final HostFunction _llmCompleteFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'llm_complete',
      description:
          'Send a prompt to the local LLM and return the full response as a '
          'string. Optionally supply a system_prompt to set context.',
      params: [
        HostParam(
          name: 'prompt',
          type: HostParamType.string,
          description: 'The user message to send to the model.',
        ),
        HostParam(
          name: 'system_prompt',
          type: HostParamType.string,
          isRequired: false,
          description: 'Optional system instruction prepended before the prompt.',
        ),
      ],
    ),
    handler: _handleLlmComplete,
  );

  Future<Object?> _handleLlmComplete(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final prompt = args['prompt'] as String;
    final systemPrompt = args['system_prompt'] as String?;

    final messages = <LlamaChatMessage>[
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: systemPrompt,
        ),
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
    ];

    return _engineRef.complete(messages);
  }

  // ---------------------------------------------------------------------------
  // llm_chat — stateful multi-turn
  // ---------------------------------------------------------------------------

  late final HostFunction _llmChatFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'llm_chat',
      description:
          'Send a message to the local LLM and return the reply as a string. '
          'Conversation history is maintained across calls within the same '
          'Monty session. Optionally set or update the system_prompt.',
      params: [
        HostParam(
          name: 'message',
          type: HostParamType.string,
          description: 'The user message for this turn.',
        ),
        HostParam(
          name: 'system_prompt',
          type: HostParamType.string,
          isRequired: false,
          description:
              'System instruction. If provided, replaces the current system '
              'prompt for this and all future turns until changed again.',
        ),
      ],
    ),
    handler: _handleLlmChat,
  );

  Future<Object?> _handleLlmChat(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final message = args['message'] as String;
    final systemPrompt = args['system_prompt'] as String?;

    if (systemPrompt != null) {
      _chatSession.systemPrompt = systemPrompt.isEmpty ? null : systemPrompt;
    }

    return _engineRef.withLock(() async {
      final buf = StringBuffer();
      await for (final chunk
          in _chatSession.create([LlamaTextContent(message)])) {
        final content = chunk.choices.firstOrNull?.delta.content;
        if (content != null) buf.write(content);
      }
      return buf.toString();
    });
  }

  // ---------------------------------------------------------------------------
  // llm_chat_reset — wipe history
  // ---------------------------------------------------------------------------

  late final HostFunction _llmChatResetFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'llm_chat_reset',
      description:
          'Clear the conversation history. By default keeps the current system '
          'prompt so the next llm_chat call starts a fresh topic with the same '
          'role. Pass keep_system_prompt=False to also clear the system prompt.',
      params: [
        HostParam(
          name: 'keep_system_prompt',
          type: HostParamType.boolean,
          isRequired: false,
          defaultValue: true,
          description:
              'Whether to keep the current system prompt. Defaults to True.',
        ),
      ],
    ),
    handler: _handleLlmChatReset,
  );

  Future<Object?> _handleLlmChatReset(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final keepSystemPrompt = args['keep_system_prompt'] as bool? ?? true;
    _chatSession.reset(keepSystemPrompt: keepSystemPrompt);
    return null;
  }

  // ---------------------------------------------------------------------------
  // llm_stream_* — pull-handle streaming
  //
  // Three host functions implement a Python-friendly streaming pattern that
  // does not need generators or callbacks (Monty supports neither). The LLM-
  // written Python looks like:
  //
  //     h = llm_stream_open("write a haiku about cats")
  //     while True:
  //         chunk = llm_stream_next(h)
  //         if chunk is None: break
  //         print(chunk, end='')
  //     llm_stream_close(h)
  //
  // The stream is consumed inside the engine's lock so it composes with
  // llm_complete / llm_chat — concurrent stream opens queue.
  // ---------------------------------------------------------------------------

  late final HostFunction _llmStreamOpenFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'llm_stream_open',
      description:
          'Begin a streaming completion. Returns an integer handle that '
          'identifies the stream — pass it to llm_stream_next to read '
          'chunks and to llm_stream_close when you are done.',
      params: [
        HostParam(
          name: 'prompt',
          type: HostParamType.string,
          description: 'The user message to stream a response for.',
        ),
        HostParam(
          name: 'system_prompt',
          type: HostParamType.string,
          isRequired: false,
          description:
              'Optional system instruction prepended before the prompt.',
        ),
      ],
    ),
    handler: _handleLlmStreamOpen,
  );

  Future<Object?> _handleLlmStreamOpen(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final prompt = args['prompt'] as String;
    final systemPrompt = args['system_prompt'] as String?;

    final messages = <LlamaChatMessage>[
      if (systemPrompt != null && systemPrompt.isNotEmpty)
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: systemPrompt,
        ),
      LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
    ];

    final id = _nextStreamId++;
    final handle = _StreamHandle();
    _streams[id] = handle;

    // Start the stream behind the engine lock so this serialises with
    // llm_complete / llm_chat / other open streams. The future is *not*
    // awaited here — we just kick it off and return the handle.
    unawaited(_engineRef.withLock(() async {
      try {
        await for (final chunk in _engineRef.engine.create(messages)) {
          final content = chunk.choices.firstOrNull?.delta.content;
          if (content != null && content.isNotEmpty) {
            handle.buffer.add(content);
            handle.wake();
          }
        }
      } catch (e) {
        handle.error = e;
      } finally {
        handle.done = true;
        handle.wake();
      }
    }));

    return id;
  }

  late final HostFunction _llmStreamNextFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'llm_stream_next',
      description:
          'Read the next chunk from an open stream. Blocks until a chunk '
          'arrives or the stream completes. Returns the chunk as a string, '
          'or None when the stream is finished. Raises if the handle is '
          'unknown or the stream errored.',
      params: [
        HostParam(
          name: 'handle',
          type: HostParamType.integer,
          description: 'The id returned by llm_stream_open.',
        ),
      ],
    ),
    handler: _handleLlmStreamNext,
  );

  Future<Object?> _handleLlmStreamNext(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final id = args['handle'] as int;
    final h = _streams[id];
    if (h == null) {
      throw StateError('llm_stream_next: unknown handle $id');
    }
    while (h.buffer.isEmpty && !h.done) {
      h.waiter ??= Completer<void>();
      await h.waiter!.future;
    }
    if (h.buffer.isNotEmpty) return h.buffer.removeFirst();
    if (h.error != null) {
      throw StateError('llm_stream_next: stream errored: ${h.error}');
    }
    return null; // exhausted
  }

  late final HostFunction _llmStreamCloseFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'llm_stream_close',
      description:
          'Release a stream handle. Safe to call after the stream has '
          'already drained — extra closes are no-ops.',
      params: [
        HostParam(
          name: 'handle',
          type: HostParamType.integer,
          description: 'The id returned by llm_stream_open.',
        ),
      ],
    ),
    handler: _handleLlmStreamClose,
  );

  Future<Object?> _handleLlmStreamClose(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final id = args['handle'] as int;
    _streams.remove(id);
    return null;
  }
}
