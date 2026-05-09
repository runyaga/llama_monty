# Patches

## llamadart-0.6.11-webgpu-grammar-drop.patch

Workaround for a crash in the llamadart WebGPU bridge's C++ grammar
sampler when constraining tool-call JSON GBNF grammars. Symptoms:
`RuntimeError: Aborted(undefined)` deep inside the WASM sampler ~9-13
tokens into a constrained generation, after which the WASM heap is
permanently corrupted (subsequent ccalls hit `null function` /
`memory access out of bounds`). Confirmed via probes — see the
`[BRIDGE PROBE]` and `[PROBE webgpu]` traces in the bridge JS and
webgpu_backend.dart respectively.

The patch:
- Drops grammar (`grammar: null`) before calling the bridge whenever
  `params.grammar != null`. Until the bridge ships a fixed grammar
  sampler this is the only way to keep tool-call-shaped grammars from
  aborting WASM.
- Adds verbose probes around `bridge.createCompletion` so further
  debugging is easy.

The example app pairs this with two things:
1. `kIsWeb` branches in `lib/main.dart` that skip `tools:` to ChatSession
   on web and use a markdown-fence system prompt.
2. A fence/raw-Python extractor that feeds the LLM-written code back
   into Monty for execution.

## Apply

```sh
# from this directory
patch -p0 -d /path/to/llamadart-0.6.11 < llamadart-0.6.11-webgpu-grammar-drop.patch
```

`pubspec_overrides.yaml` in this example points `llamadart` at a local
copy where the patch is applied.
