# llama_monty

Local LLM inference callable from a sandboxed Python interpreter, on
Flutter web (WebGPU) and native (FFI) — built by bridging
[llamadart](https://github.com/leehack/llamadart) (llama.cpp Dart
bindings, with a [forked WebGPU fix](https://github.com/runyaga/llamadart/tree/fix/web-grammar-drop))
and [dart_monty](https://github.com/runyaga/dart_monty) (the Monty
restricted-Python sandbox).

The package itself is small. The interesting part is the example app
and the eval suite around it: an end-to-end demo that loads a
[Gemma-4-E2B-it](https://huggingface.co/google/gemma-2-2b-it) GGUF in
the browser, lets the user chat with it, and gives the LLM a
sandboxed Python interpreter (with files, datetime, and a recursive
`llm_complete` so Python the LLM writes can call back into the LLM).

## Repo layout

```
lib/
  llama_monty.dart                 barrel
  src/
    llama_engine_ref.dart          serializes engine.create() calls;
                                   default sampling per Gemma 4
                                   (temp=1.0, top_p=0.95)
    llama_monty_plugin.dart        MontyExtension exposing
                                     llm_complete / llm_chat / llm_chat_reset
                                     llm_stream_open/_next/_close
                                   plus tamper-proof streams journal at
                                   /tmp/llama_monty/streams.jsonl
    chat_shell_plugin.dart         MontyExtension that lets LLM-written
                                   Python introspect, summarize, and
                                   reset the OUTER chat shell:
                                     chat_history / chat_history_messages
                                     chat_summarize / chat_summarize_v2
                                     chat_reset
    chat_summarize_pipeline.dart   multi-step pipeline (chunked
                                   schema-driven extraction → Python-
                                   side dedup → render → validate +
                                   repair → deterministic fallback).
    summarizable_source.dart       protocol-agnostic source:
                                     ChatSessionSource (LlamaChatMessage)
                                     AgUiEventsSource (AG-UI events)

example/
  llama_monty_web/                 Flutter web + macOS demo app
  files_demo.dart                  end-to-end "LLM does work with files"
  long_conversation_demo.dart      30-turn / ~1.3K-token capstone, runs
                                   through both ChatSessionSource and
                                   AgUiEventsSource
  stream_demo.dart                 verifies the pull-handle streaming
  stream_pressure_demo.dart        7 adversarial scenarios + journal
                                   reconciliation
  summarize_demo.dart              4-turn chat → chat_summarize → reset
                                   with seed → recall test
  summarize_v2_demo.dart           chunked-pipeline smoke test
  tool_call_demo.dart              native llamadart tool calling
  chat_demo.dart                   bare-bones llm_chat_* demo
  eval/                            see `Eval suite` below

docs/
  PORT-PLAN-soliplex-interpreter-monty.md   spec for the next-agent task:
                                            port soliplex_interpreter_monty
                                            to dart_monty 0.17.1.
  PLAN-llamadart-grammar-upstream.md        spec for the upstream-llamadart
                                            cleanup work (currently a fork
                                            with one fix).
```

## Eval suite (`example/eval/`)

Four families of tests. Run each with `dart run example/eval/<family>/run_*.dart`.

| Family | What it tests | Score |
|---|---|---|
| **capability** | 3 multiple-choice probes for formal logic, multi-rule state-machine tracing, and grounded factual reasoning ("Are Dart Macros canceled?" → B). Forced "Answer: X" output makes scoring deterministic. | **3 / 3 PASS** |
| **programming** | 10 graduated probes (T1 trivial → T5 trap), each scored on a 4-state scale: PASS / FAIL_OUTPUT / ERROR_PY / NO_CODE. The Tier-5 trap (memoize without decorators, since Monty rejects `@`) **passes** — the model adapts to the constraint. | **8 / 10 model-PASS** (P4 used `with`, P7 dropped a colon) |
| **grounded** | 5 fixtures testing what the model does with provided context: factual lookup, refuse-when-OOB, multi-document synthesis, technical-term preservation, sentence-level citations. | **5 / 5 PASS** |
| **summarize** | 10 hand-built conversation fixtures (F1-F10) with ground-truth fact tables. `run_eval.dart --runs N` averages `baseline` (one-shot) vs `v2` (multi-step pipeline). | see [`example/eval/RESULTS.md`](example/eval/RESULTS.md) |

### Headline summarize result (3-run average, Gemma 4 official sampling)

```
                 baseline       v2
recall (μ ± σ)   75.3% ± 24%   46.0% ± 23%      ← v2 is 29pp WORSE
neg-acc (μ ± σ)  99.3%         98.0%            ← tied
LLM calls         30           142              ← v2 is 4.7×
wall clock       122s          775s             ← v2 is 6.3×
```

**Per-fixture, baseline beats v2 on 9 of 10.** The pipeline's chunked
extraction silently drops some content (e.g. F10's non-Latin proper
nouns) because the deterministic fact-table fallback uses subjects
that don't match the gold-standard schema. With one-shot summarization
+ name-preservation prompt + Gemma 4 sampling, the multi-step pipeline
is solving a problem it no longer has on this model.

The pipeline + `SummarizableSource` abstraction stays in the codebase
but is not the default. `chat_summarize` (one-shot) is the recommended
path — `chat_summarize_v2` remains as opt-in via the `/summarize`
slash command.

## Web app (`example/llama_monty_web/`)

Flutter app that runs on:
- **Web** — Gemma 4 E2B-it via the patched llamadart WebGPU bridge.
  See [`patches/llamadart-0.6.11-webgpu-grammar-drop.patch`](example/llama_monty_web/patches)
  for the workaround applied to the bundled bridge. Tool-call grammar
  constraints abort the WASM module on the public bridge; we drop
  grammar on web and rely on a `\`\`\`python` markdown-fence parser
  to extract code from the LLM response.
- **macOS** — same model via FFI, structured tool calls work normally.

Slash commands available in the chat:

```
/help        — list slash commands
/summarize   — run chat_summarize_v2 and print the summary
/compress    — summarize_v2 then chat_reset, seeding the new
               session with the summary
/reset [seed] — chat_reset (wipe history, optional seed text)
/history     — dump chat_history()
/files [path] — list files (default /fixtures)
```

Seed fixtures auto-mount under `/fixtures/` on web (in-memory):
`welcome.md`, `sample.csv`, `notes.txt`. The system prompt advertises
them so the LLM knows what's mounted. `pathlib` is wired through
`defaultOsHandler` so the model can `Path('/fixtures/sample.csv').read_text()`
out of the box.

The system prompt also enforces a typeCheck pre-flight on every
`run_python` tool call: `Monty.typeCheck(code)` runs *before* execution
so missing colons / `with` statements / `.format()` calls are rejected
back to the LLM with a specific error message instead of being executed.

### Running it

```sh
# 1. Install fork of llamadart (path override is already wired).
flutter pub get -C example/llama_monty_web

# 2. Build for web with WASM target.
flutter build web --wasm -C example/llama_monty_web

# 3. Serve with cross-origin-isolation headers
#    (required for SharedArrayBuffer / WebGPU threading).
cd example/llama_monty_web && python3 serve_coi.py 8080

# 4. Open http://localhost:8080
```

The COI server also serves `~/models/*.gguf` under `/models/` so the
3 GB Gemma quant doesn't need to be copied into `build/`.

For native (macOS):

```sh
flutter run -d macos -t example/llama_monty_web/lib/main.dart
```

## Forked llamadart

`example/llama_monty_web/pubspec_overrides.yaml` points
`llamadart` at <https://github.com/runyaga/llamadart/tree/fix/web-grammar-drop>.

That branch holds one fix on top of `v0.6.11`:
[**fix(webgpu): drop tool-call grammar to avoid C++ sampler abort on web**](https://github.com/runyaga/llamadart/commit/94e5385).

The WebGPU C++ grammar sampler aborts the WASM module reliably when
constraining tool-call-shaped GBNF grammars (`Aborted(undefined)` in
`___cxa_throw`, after which the WASM heap is permanently corrupted —
subsequent ccalls hit `null function` / `memory access out of bounds`).
The patch drops grammar before invoking the bridge whenever
`params.grammar != null` and adds verbose probes for further debugging.
Until the bridge ships a fixed sampler this is the only way to keep
tool-call-shaped grammars from aborting WASM.

See [`docs/PLAN-llamadart-grammar-upstream.md`](docs/PLAN-llamadart-grammar-upstream.md)
for the spec to upstream this work properly.

## Filed upstream

| Issue | Repo | Status |
|---|---|---|
| Per-run lifecycle hook for `MontyExtension` (so plugins can clean up resources without ad-hoc bookkeeping) | [`runyaga/dart_monty#421`](https://github.com/runyaga/dart_monty/issues/421) | Open |

## Related repos

- [runyaga/dart_monty](https://github.com/runyaga/dart_monty) — sandboxed Python interpreter for Dart.
- [runyaga/llamadart (fix/web-grammar-drop)](https://github.com/runyaga/llamadart/tree/fix/web-grammar-drop) — fork with the WebGPU sampler workaround.
- [runyaga/soliplex-packages](https://github.com/runyaga/soliplex-packages) — packages monorepo holding `soliplex_interpreter_monty` (next-step integration target — see [`docs/PORT-PLAN-soliplex-interpreter-monty.md`](docs/PORT-PLAN-soliplex-interpreter-monty.md)).
- [leehack/llamadart](https://github.com/leehack/llamadart) — upstream llamadart.

## License

Research / demo repo — match license of parent organization.
