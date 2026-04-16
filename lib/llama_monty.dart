/// llama_monty — local LLM inference callable from the Monty Python sandbox.
///
/// Bridges [llamadart] and [dart_monty_core] so Python code running inside
/// Monty can call `llm_complete(prompt)` to run a local LLM via WebGPU
/// (WASM target) or the native llama.cpp backend.
///
/// **Quick start (WASM/Web):**
/// ```dart
/// final backend = WebAutoBackend(
///   bridgeScriptUrl: 'assets/llamadart/bridge.js',
///   wasmUrl: 'assets/llamadart/llama.wasm',
///   bridgeWorkerUrl: 'assets/llamadart/bridge.worker.js',
/// );
/// final engine = LlamaEngine(backend);
/// await engine.loadModelFromUrl(
///   'https://example.com/model.gguf',
///   onProgress: (p) => print('Loading: ${(p * 100).toInt()}%'),
/// );
///
/// final plugin = LlamaMontyPlugin(LlamaEngineRef(engine));
/// // Register plugin on your dart_monty bridge (useFutures: true required).
/// ```
library;

export 'src/llama_engine_ref.dart';
export 'src/llama_monty_plugin.dart';
