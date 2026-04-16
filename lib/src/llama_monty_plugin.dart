import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llamadart/llamadart.dart';

import 'llama_engine_ref.dart';

/// A [MontyPlugin] that exposes a local LLM to Python code running in Monty.
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
/// - The dart_monty bridge must be configured with `useFutures: true` so that
///   async host functions are dispatched via the `MontyFutureCapable` path.
class LlamaMontyPlugin extends MontyPlugin {
  /// Creates a [LlamaMontyPlugin] backed by [engineRef].
  LlamaMontyPlugin(this._engineRef)
    : _chatSession = ChatSession(_engineRef.engine);

  final LlamaEngineRef _engineRef;
  final ChatSession _chatSession;

  @override
  String get namespace => 'llm';

  @override
  List<HostFunction> get functions => [
    _llmCompleteFunction,
    _llmChatFunction,
    _llmChatResetFunction,
  ];

  late final HostFunction _llmCompleteFunction = HostFunction(
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

  Future<Object?> _handleLlmComplete(Map<String, Object?> args) async {
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

  Future<Object?> _handleLlmChat(Map<String, Object?> args) async {
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

  Future<Object?> _handleLlmChatReset(Map<String, Object?> args) async {
    final keepSystemPrompt = args['keep_system_prompt'] as bool? ?? true;
    _chatSession.reset(keepSystemPrompt: keepSystemPrompt);
    return null;
  }
}
