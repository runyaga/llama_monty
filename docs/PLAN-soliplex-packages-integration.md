# Plan: integrate llama_monty work into soliplex-packages

## Context

We have two repos doing related work:

1. **`runyaga/llama_monty`** (this repo, branch `feat/chat-shell-plugin`):
   - `LlamaMontyPlugin` — `MontyExtension` exposing `llm_complete` /
     `llm_chat` / `llm_chat_reset` / `llm_stream_open`/`_next`/`_close`,
     plus a tamper-proof streams journal at `/tmp/llama_monty/streams.jsonl`.
   - `ChatShellPlugin` — `MontyExtension` exposing `chat_history` /
     `chat_summarize` / `chat_summarize_v2` / `chat_reset` so LLM-written
     Python can manage its own outer chat shell.
   - `ChatSummarizePipeline` + `SummarizableSource` (with
     `ChatSessionSource` and `AgUiEventsSource` adapters).
   - Eval suite: capability / programming / grounded / summarize
     fixtures. **Empirical finding: one-shot summarization with
     name-preservation prompt + Gemma 4 official sampling beats the
     multi-step pipeline in 9 of 10 fixtures** (3-run average).
   - Flutter web + macOS demo: chat shell with `/help` / `/summarize`
     / `/compress` / `/reset` / `/history` / `/files` slash commands,
     a Files panel (auto-mounted `/fixtures/`, file upload, inline
     viewer), and a Sandbox Workout experiment that exercises files /
     datetime / JSON.

2. **`runyaga/soliplex-packages`** (branch `feat/dart-monty-0.17.1`):
   - Workspace monorepo holding `soliplex_completions`,
     `soliplex_interpreter_monty`, `soliplex_scripting`, `soliplex_mcp`,
     `soliplex_dataframe`, `soliplex_schema`, `soliplex_cli`,
     `soliplex_tui`, `soliplex_showcase`.
   - Currently depends on `dart_monty: { git: ref: main }` (i.e., the
     fork's bleeding edge).
   - Needs porting to the published `dart_monty 0.17.1` —
     [`docs/PORT-PLAN-soliplex-interpreter-monty.md`](PORT-PLAN-soliplex-interpreter-monty.md)
     covers that work.

This document is the plan for **after the port**: what to actually
move from `llama_monty` into `soliplex-packages`, and what to leave
behind in `llama_monty` as a thin demo on top.

## Goal

`soliplex-packages` becomes the published home for the reusable
LLM-agent infrastructure (LlamaMontyPlugin, ChatShellPlugin, summarize
pipeline). `llama_monty` shrinks to a Flutter demo that uses those
packages — no novel API surface, just integration, UI, and eval
fixtures.

## What moves

| Subject | Source location | Destination | Notes |
|---|---|---|---|
| `LlamaMontyPlugin` | `lib/src/llama_monty_plugin.dart` | `packages/soliplex_completions_local/` (new) | Belongs with the LLM providers. Local-llamadart provider. |
| `LlamaEngineRef` | `lib/src/llama_engine_ref.dart` | same as above | Tightly bound to LlamaMontyPlugin. |
| Streams journal | embedded in `LlamaMontyPlugin` | move to `soliplex_interpreter_monty` | Cross-cutting: any extension might want a journal. Lift to a generic `StreamJournal` mixin. |
| `ChatShellPlugin` | `lib/src/chat_shell_plugin.dart` | `packages/soliplex_interpreter_monty/` | It's a Monty extension, fits cleanly. The ChatSession-coupling becomes a `Source` interface — see below. |
| `ChatSummarizePipeline` | `lib/src/chat_summarize_pipeline.dart` | `packages/soliplex_completions/` (or new `soliplex_summarize/`) | Doesn't belong in interpreter_monty — it's pure LLM-driven logic. |
| `SummarizableSource` + `ChatSessionSource` + `AgUiEventsSource` | `lib/src/summarizable_source.dart` | same as above | Co-located with the pipeline that consumes them. |
| Eval fixtures (F1-F10, G1-G6, T1-T3, P1-P10) | `example/eval/` | `packages/soliplex_showcase/eval/` | The showcase package looks like the right place. Or split per-domain into the relevant package's `test/` dirs. |
| Multi-run harness (`run_eval.dart`) | `example/eval/summarize/run_eval.dart` | `packages/soliplex_completions/test/` | Useful for any LLM-routing change in soliplex_completions. |

## What stays in `llama_monty`

- `example/llama_monty_web/` — the Flutter demo. Re-pointed to
  `soliplex_completions_local`, `soliplex_interpreter_monty`,
  `soliplex_summarize` from soliplex-packages.
- `example/files_demo.dart`, `example/long_conversation_demo.dart`,
  `example/stream_demo.dart`, `example/stream_pressure_demo.dart`,
  `example/summarize_demo.dart` — keep as integration smoke tests.
- `lib/llama_monty.dart` becomes a tiny re-export barrel pointing at
  the soliplex-packages versions (or this package gets archived once
  the port is complete).
- `docs/PLAN-llamadart-grammar-upstream.md` —
  llamadart-fork-specific work, not soliplex-related.
- The fork override in `example/llama_monty_web/pubspec_overrides.yaml`
  pointing at our patched llamadart — soliplex-packages' downstream
  will inherit this until the upstream sampler is fixed.

## Phases

### Phase 0 — gate on the port

The `dart_monty 0.17.1` port (separate plan) MUST land first, otherwise
the move is to a moving target. Wait for that branch to merge.

### Phase 1 — move LlamaMontyPlugin into soliplex_completions_local

New package: `packages/soliplex_completions_local`. Pubspec depends on:

- `dart_monty: ^0.17.1`
- `llamadart: ^0.6.11` (or via the fork ref)
- `soliplex_completions: { path: ../soliplex_completions }` — to
  conform to the `LlmProvider` interface so Monty users can swap
  between local-llamadart, Anthropic, Ollama, etc.

Files copied:

```
soliplex-packages/packages/soliplex_completions_local/
  lib/
    soliplex_completions_local.dart        barrel
    src/
      llama_engine_ref.dart                  (move from llama_monty)
      llama_monty_plugin.dart                (move from llama_monty;
                                              renames: keep `llm_*`
                                              namespace for backward-
                                              compat with shipped demos)
      llama_completions_provider.dart        NEW: implements
                                              soliplex_completions'
                                              `LlmProvider` over
                                              llamadart so room/agent
                                              code can pick it.
  test/
    llama_monty_plugin_test.dart             port from llama_monty
    pressure_test.dart                       port stream_pressure_demo
                                              into a test
```

### Phase 2 — move ChatShellPlugin into soliplex_interpreter_monty

`soliplex_interpreter_monty` already exposes a `MontyExecutionService`
that wraps `MontyBridge` lifecycle. `ChatShellPlugin` is a Monty
extension, fits as a sibling. The only coupling is to `ChatSession` —
break it via a `ChatShell` interface so the extension works against
any chat surface (llamadart, soliplex_agent, ag_ui).

```dart
// In soliplex_interpreter_monty
abstract class ChatShell {
  List<ChatTurn> get turns;
  void reset({bool keepSystemPrompt = true});
  void seed(String text);
}

class ChatShellPlugin extends MontyExtension {
  ChatShellPlugin({
    required this.shell,
    required this.completions,    // for chat_summarize host fn
  });
  final ChatShell Function() shell;
  final LlmProvider completions;
  ...
}
```

Adapters:

```dart
// In llama_monty (the demo)
class LlamadartChatShell implements ChatShell {
  LlamadartChatShell(this.session);
  final ChatSession session;
  ...
}
```

### Phase 3 — move summarize pipeline into soliplex_completions/summarize

Pure LLM logic, depends on `LlmProvider` (any provider works), no
Monty coupling. Drop into either `soliplex_completions/lib/src/summarize/`
or a new `soliplex_summarize` package — whichever fits the monorepo's
package-cohesion rules. Recommend the former: summarize is part of
"completions handling," same way streaming is.

The `SummarizableSource` abstraction stays as-is. `ChatSessionSource`
becomes generic over any `ChatShell` (see Phase 2). `AgUiEventsSource`
already takes opaque event maps so it ports verbatim.

### Phase 4 — eval fixtures into soliplex_showcase

`soliplex_showcase` looks designed for end-to-end demos; eval fixtures
fit there. Layout:

```
packages/soliplex_showcase/eval/
  capability/
  grounded/
  programming/
  summarize/
  README.md            (port from llama_monty/example/eval/RESULTS.md)
```

The harnesses (`run_*.dart`) become CLI tools under
`soliplex_showcase/bin/` so anyone with `dart pub global activate
soliplex_showcase` can run them.

### Phase 5 — repoint llama_monty demo

`example/llama_monty_web/pubspec.yaml` becomes:

```yaml
dependencies:
  soliplex_completions:
    git:
      url: https://github.com/runyaga/soliplex-packages
      path: packages/soliplex_completions
  soliplex_completions_local:
    git:
      url: https://github.com/runyaga/soliplex-packages
      path: packages/soliplex_completions_local
  soliplex_interpreter_monty:
    git:
      url: https://github.com/runyaga/soliplex-packages
      path: packages/soliplex_interpreter_monty
  llama_monty:
    path: ../..        # now mostly empty barrel, kept for transition
  flutter:
    sdk: flutter
  ...
```

Update imports in `lib/main.dart`. The slash commands, Files panel,
Sandbox Workout experiment, and other UI stays exactly the same.

### Phase 6 — archive `lib/` in llama_monty

Once Phase 5 is green, the package sources in `lib/src/` are duplicates.
Either:
- Delete them and turn `lib/llama_monty.dart` into a one-line
  re-export barrel pointing at the soliplex-packages packages, OR
- Archive the `llama_monty` repo entirely if soliplex-packages
  becomes the only consumer.

## Acceptance criteria

- [ ] All five soliplex-packages packages above pass `dart analyze
      --fatal-infos` and `dart test`.
- [ ] `llama_monty/example/llama_monty_web` builds and runs against
      the soliplex-packages versions, with the same UX (slash commands,
      Files panel, Sandbox Workout experiment, summarize results).
- [ ] Eval suite re-runs from soliplex_showcase produce numbers
      consistent with `llama_monty/example/eval/RESULTS.md`
      (i.e. baseline summarize beats v2 on the standard fixtures).
- [ ] PR description on soliplex-packages references this doc and
      the two prior planning docs (`PLAN-llamadart-grammar-upstream.md`,
      `PORT-PLAN-soliplex-interpreter-monty.md`).

## Estimated cost

| Phase | Effort |
|---|---|
| 0 — wait for port | n/a |
| 1 — soliplex_completions_local | 2 hr |
| 2 — ChatShellPlugin → interpreter_monty | 2 hr |
| 3 — summarize pipeline → completions | 1 hr |
| 4 — eval fixtures → showcase | 1 hr |
| 5 — repoint llama_monty demo | 1 hr |
| 6 — archive llama_monty/lib | 30 min |
| **Total** | **~7-8 hr** |

## Out of scope

- Publishing any of the packages to pub.dev. They stay path-/git-
  resolved in the workspace until someone formally cuts releases.
- Migrating to soliplex_agent's session model (rooms, threads). That
  was an earlier idea but per the eval results we don't need bigger
  models for our use case — the local 2B Gemma + the right prompts
  is good enough. Leave that integration for a later round if a
  use case demands it.
- Changing the on-the-wire host-function names. `llm_*`, `chat_*`,
  `llm_stream_*` stay so demos / scripts that call them keep working.

## Pointers

- This repo: https://github.com/runyaga/llama_monty/tree/feat/chat-shell-plugin
- soliplex-packages port branch: https://github.com/runyaga/soliplex-packages/tree/feat/dart-monty-0.17.1
- Port plan: [`docs/PORT-PLAN-soliplex-interpreter-monty.md`](PORT-PLAN-soliplex-interpreter-monty.md)
- llamadart cleanup plan: [`docs/PLAN-llamadart-grammar-upstream.md`](PLAN-llamadart-grammar-upstream.md)
- Eval results: [`example/eval/RESULTS.md`](../example/eval/RESULTS.md)
