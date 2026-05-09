import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llamadart/llamadart.dart';

import 'chat_summarize_pipeline.dart';
import 'llama_engine_ref.dart';

/// A [MontyExtension] that lets LLM-written Python introspect, summarize and
/// reset the **outer chat shell** — the [ChatSession] the host application is
/// driving for user-visible conversation.
///
/// This is what makes the LLM a *first-class participant* in managing its own
/// context: when the assistant notices the conversation getting long, the
/// Python it writes can call `chat_summarize()` to compress prior turns and
/// `chat_reset(seed=summary)` to start fresh with that summary as seed.
///
/// Registers four host functions (all under the `chat_` namespace because
/// dart_monty requires every host function to be prefixed with its
/// extension's namespace):
/// - `chat_history()` → str — markdown rendering of the outer session
/// - `chat_history_messages()` → list[dict] — programmatic per-message view
/// - `chat_summarize([style])` → str — LLM-generated summary of the history
/// - `chat_reset([keep_system_prompt], [seed])` → None — reset and optionally
///   replant the conversation with a seed string
///
/// **Wiring example:**
/// ```dart
/// final chatSession = ChatSession(engine, systemPrompt: '...');
/// final plugin = ChatShellPlugin(
///   engineRef: LlamaEngineRef(engine),
///   shell: () => chatSession,           // returns the *current* session
/// );
/// final monty = MontyRuntime(extensions: [plugin, LlamaMontyPlugin(ref)]);
/// ```
///
/// **Python usage:**
/// ```python
/// # Read what the user has been talking about so far.
/// transcript = chat_history()
///
/// # Compress and replant.
/// summary = chat_summarize()
/// chat_reset(keep_system_prompt=True, seed=f"Summary so far:\n{summary}")
/// ```
class ChatShellPlugin extends MontyExtension {
  /// Creates a plugin that operates on the [ChatSession] returned by [shell].
  ///
  /// [shell] is a getter so that the host can swap the underlying session
  /// (e.g. on a "New Chat" button) without re-registering the plugin.
  ChatShellPlugin({
    required LlamaEngineRef engineRef,
    required ChatSession Function() shell,
  })  : _engineRef = engineRef,
        _shell = shell;

  final LlamaEngineRef _engineRef;
  final ChatSession Function() _shell;

  @override
  String get namespace => 'chat';

  @override
  ChildPolicy get childPolicy => ChildPolicy.clone;

  @override
  ChatShellPlugin createChildInstance(ChildSpawnContext context) =>
      ChatShellPlugin(engineRef: _engineRef, shell: _shell);

  @override
  List<HostFunction> get functions => [
        _chatHistoryFunction,
        _chatHistoryMessagesFunction,
        _summarizeChatFunction,
        _summarizeChatV2Function,
        _resetChatFunction,
      ];

  late final ChatSummarizePipeline _pipeline =
      ChatSummarizePipeline(engineRef: _engineRef);

  // ---------------------------------------------------------------------------
  // chat_history — markdown transcript
  // ---------------------------------------------------------------------------

  late final HostFunction _chatHistoryFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'chat_history',
      description:
          'Return the outer chat session as a markdown-formatted transcript: '
          'one block per message tagged with its role. Useful for feeding to '
          'chat_summarize or reasoning about prior turns.',
      params: [],
    ),
    handler: (args, ctx) async => _formatHistoryMarkdown(_shell()),
  );

  // ---------------------------------------------------------------------------
  // chat_history_messages — programmatic view
  // ---------------------------------------------------------------------------

  late final HostFunction _chatHistoryMessagesFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'chat_history_messages',
      description:
          'Return the outer chat session as a list of {role, text} dicts. '
          'Tool calls and tool results are rendered as text descriptions.',
      params: [],
    ),
    handler: (args, ctx) async => _historyAsList(_shell()),
  );

  // ---------------------------------------------------------------------------
  // chat_summarize — LLM-driven compression
  // ---------------------------------------------------------------------------

  late final HostFunction _summarizeChatFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'chat_summarize',
      description:
          'Ask the LLM to summarize the outer chat history. Returns the '
          'summary as a string. Use the optional `style` to bias the form: '
          '"bullets" (default), "narrative", or any free-form instruction.',
      params: [
        HostParam(
          name: 'style',
          type: HostParamType.string,
          isRequired: false,
          defaultValue: 'bullets',
          description:
              'How the summary should be shaped. Free-form; passed through to '
              'the summarizer system prompt.',
        ),
      ],
    ),
    handler: _handleSummarizeChat,
  );

  Future<Object?> _handleSummarizeChat(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final style = (args['style'] as String?) ?? 'bullets';
    final transcript = _formatHistoryMarkdown(_shell());
    if (transcript.trim().isEmpty) return '';
    final messages = <LlamaChatMessage>[
      LlamaChatMessage.fromText(
        role: LlamaChatRole.system,
        text:
            'You compress conversations into a $style. Capture facts, open '
            'questions, decisions, and any state the next turn must remember. '
            'Keep it short — half the length of the input or less. Reply with '
            'the summary only, no preamble.',
      ),
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Summarize this conversation:\n\n$transcript',
      ),
    ];
    return _engineRef.complete(messages);
  }

  // ---------------------------------------------------------------------------
  // chat_summarize_v2 — multi-step pipeline tuned for small (2B) models
  // ---------------------------------------------------------------------------

  late final HostFunction _summarizeChatV2Function = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'chat_summarize_v2',
      description:
          'Run the multi-step summarization pipeline over the outer chat '
          'history. Uses chunked schema-driven extraction + Python-side '
          'merge + render + validate + repair, with a deterministic '
          'fact-table fallback. Designed for small (2B-class) models that '
          'drop facts in one-shot summaries. Returns the validated summary '
          'string. Pass `style` to bias prose form (default "bullets").',
      params: [
        HostParam(
          name: 'style',
          type: HostParamType.string,
          isRequired: false,
          defaultValue: 'bullets',
          description: 'Free-form style hint for the render step.',
        ),
      ],
    ),
    handler: _handleSummarizeChatV2,
  );

  Future<Object?> _handleSummarizeChatV2(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final style = (args['style'] as String?) ?? 'bullets';
    final result = await _pipeline.runFromChatSession(
      _shell(),
      style: style,
      // Forward each pipeline-stage status string into the bridge event
      // stream as a BridgeFunctionEmit. Subscribers to MontyRuntime.events
      // (e.g. a UI progress bar / status line) see them in real time.
      onProgress: (msg) => ctx.emitText('[summarize_v2] $msg'),
    );
    return result.summary;
  }

  // ---------------------------------------------------------------------------
  // chat_reset — wipe + optional seed
  // ---------------------------------------------------------------------------

  late final HostFunction _resetChatFunction = HostFunction(
    dispatch: DispatchMode.sync,
    schema: const HostFunctionSchema(
      name: 'chat_reset',
      description:
          'Wipe the outer chat history. Pass `keep_system_prompt=False` to '
          'also clear the system prompt. Pass `seed` to plant a single '
          'assistant turn (e.g. a summary) so the next user message has '
          'context to anchor on.',
      params: [
        HostParam(
          name: 'keep_system_prompt',
          type: HostParamType.boolean,
          isRequired: false,
          defaultValue: true,
          description: 'Whether to keep the current system prompt.',
        ),
        HostParam(
          name: 'seed',
          type: HostParamType.string,
          isRequired: false,
          description:
              'Optional assistant message to plant at the start of the new '
              'history (e.g. the result of chat_summarize).',
        ),
      ],
    ),
    handler: _handleResetChat,
  );

  Future<Object?> _handleResetChat(
    Map<String, Object?> args,
    HostContext ctx,
  ) async {
    final keep = args['keep_system_prompt'] as bool? ?? true;
    final seed = args['seed'] as String?;
    final session = _shell();
    session.reset(keepSystemPrompt: keep);
    if (seed != null && seed.isNotEmpty) {
      session.addMessage(
        LlamaChatMessage.fromText(role: LlamaChatRole.assistant, text: seed),
      );
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _formatHistoryMarkdown(ChatSession session) {
    final out = StringBuffer();
    for (final msg in session.history) {
      final role = msg.role.name;
      final text = _renderMessage(msg).trim();
      if (text.isEmpty) continue;
      out
        ..writeln('### $role')
        ..writeln(text)
        ..writeln();
    }
    return out.toString().trimRight();
  }

  static List<Map<String, Object?>> _historyAsList(ChatSession session) {
    return session.history.map((m) {
      return <String, Object?>{
        'role': m.role.name,
        'text': _renderMessage(m).trim(),
      };
    }).toList();
  }

  static String _renderMessage(LlamaChatMessage msg) {
    final buf = StringBuffer();
    for (final part in msg.parts) {
      if (part is LlamaTextContent) {
        buf.write(part.text);
      } else if (part is LlamaToolCallContent) {
        buf
          ..write('\n[tool call: ${part.name}(')
          ..write(part.arguments)
          ..write(')]\n');
      } else if (part is LlamaToolResultContent) {
        buf
          ..write('\n[tool result for ${part.name}: ')
          ..write(part.result)
          ..write(']\n');
      }
    }
    return buf.toString();
  }
}
