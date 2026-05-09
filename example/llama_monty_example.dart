// This example demonstrates the intended usage of llama_monty on WASM/Web.
//
// It cannot run on the VM (LlamaEngine.create() requires a loaded model),
// so it serves as documentation only.
//
// Full runnable examples require a loaded GGUF model via loadModelFromUrl().
// See the package README for setup instructions.

import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

// ignore: unreachable_from_main
Future<void> exampleUsage() async {
  // 1. Create the engine with the appropriate backend.
  //    On WASM/Web use WebAutoBackend (wraps WebGpuLlamaBackend).
  //    On native use the default LlamaBackend().
  final engine = LlamaEngine(LlamaBackend());

  // 2. Load a GGUF model (URL-based on Web; path-based on native).
  // Gemma 4 2B instruction-tuned model (Q4_K_M, ~1.5 GB).
  // Full model list: https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF
  await engine.loadModelFromUrl(
    'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf',
    onProgress: (p) => print('Loading: ${(p * 100).toInt()}%'),
  );

  // 3. Wrap in LlamaEngineRef for safe concurrent use.
  final ref = LlamaEngineRef(engine);

  // 4. Create the plugin.
  final plugin = LlamaMontyPlugin(ref);

  // 5. Register the plugin on a dart_monty bridge configured with
  //    useFutures: true, then run Python code that calls llm_complete().
  print('Plugin namespace: ${plugin.namespace}');
  print('Registered functions: ${plugin.functions.map((f) => f.schema.name)}');

  await engine.dispose();
}

void main() {
  print('See exampleUsage() for the intended API.');
}
