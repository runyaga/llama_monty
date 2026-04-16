import 'dart:async';

import 'package:dart_monty/dart_monty_bridge.dart';
import 'package:llamadart/llamadart.dart';

import 'llama_engine_ref.dart';

/// A [MontyPlugin] that exposes a local LLM to Python code running in Monty.
///
/// Registers a single host function `llm_complete(prompt, [system_prompt])`
/// that runs inference through the provided [LlamaEngineRef] and returns the
/// full assistant response as a plain string.
///
/// **Python usage:**
/// ```python
/// # Simple prompt
/// result = llm_complete("What is 2 + 2?")
///
/// # With a system prompt
/// result = llm_complete("Classify this text.", "Reply with one word only.")
/// ```
///
/// **Prerequisites:**
/// - The [LlamaEngine] inside [LlamaEngineRef] must be loaded before any
///   Python code calls `llm_complete`. Load via
///   [LlamaEngine.loadModelFromUrl] on the WASM/Web platform.
/// - The dart_monty bridge must be configured with `useFutures: true` so that
///   async host functions are dispatched via the `MontyFutureCapable` path.
class LlamaMontyPlugin extends MontyPlugin {
  /// Creates a [LlamaMontyPlugin] backed by [engineRef].
  LlamaMontyPlugin(this._engineRef);

  final LlamaEngineRef _engineRef;

  @override
  String get namespace => 'llm';

  @override
  List<HostFunction> get functions => [_llmCompleteFunction];

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
}
