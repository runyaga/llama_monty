# Summarize evaluation suite

Hand-built fixtures + a Dart harness that scores summarization strategies
against ground-truth fact tables.

## Layout

```
fixtures/
  F1_short_coherent.json
  F2_short_coherent.json
  F3_short_coherent.json
  F4_long_coherent.json
  F5_long_coherent.json
  F6_long_coherent.json
  F7_topic_switch.json
  F8_negations.json
  F9_numeric_dates.json
  F10_mixed_proper_nouns.json
```

Each fixture is a single JSON object:

```json
{
  "name": "F1 — short coherent",
  "system_prompt": "You are a helpful assistant.",
  "turns": [
    {"role": "user",      "content": "..."},
    {"role": "assistant", "content": "..."}
  ],
  "facts": [
    {"subject": "alan", "predicate": "name",     "polarity": "affirm", "object": "Alan"},
    {"subject": "alan", "predicate": "favorite color", "polarity": "affirm", "object": "purple"}
  ]
}
```

`facts` is the *ground truth* the summarizer must preserve through a
summarize → reset → "what do you know about me" cycle. Subjects and
predicates are matched case-insensitively. `polarity:negate` facts must
appear with a negation token within ±60 chars of the subject; otherwise
the fact is counted as INVERTED (worse than missing).

## Running the harness

```sh
dart run example/eval/summarize/run_eval.dart
```

The harness:

1. Loads the FFI Gemma 4 model.
2. For each fixture:
   - Replays `turns` into a `ChatSession`.
   - Runs the **baseline** (one-shot `chat_summarize`) and **v2** (multi-step
     pipeline) against a fresh copy of the session.
   - For each strategy: applies `chat_reset(seed=summary)`, then asks
     `"List everything you know about the user."`, then scores the reply.
3. Reports per-fixture and aggregate metrics:
   - **recall** — fraction of ground-truth facts that appear in the reply.
   - **negation accuracy** — fraction of `negate` facts that retain
     negation in the reply.
   - **llm calls** — total engineRef.complete() invocations.
   - **wall clock** — ms.

## Fixture mix

| Id  | Length | Theme                  | Notes |
|-----|--------|------------------------|-------|
| F1  | short  | coherent               | regression guard for the existing one-shot |
| F2  | short  | coherent               | "" |
| F3  | short  | coherent               | "" |
| F4  | long   | single-topic           | attention-drift test |
| F5  | long   | single-topic           | "" |
| F6  | long   | single-topic           | "" |
| F7  | long   | topic switch midway    | early facts must survive |
| F8  | mixed  | explicit negations     | the 2B failure mode we most want to catch |
| F9  | mixed  | numeric / dates        | hallucination-prone |
| F10 | mixed  | non-Latin proper nouns | known weak spot, document the failure |

## Acceptance bar (proposal)

The new pipeline must beat baseline by **≥+25 percentage points recall**
on F4–F8, with **negation accuracy ≥90%** on F8, at **no more than 5×
the baseline LLM-call count**.
