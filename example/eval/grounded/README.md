# Grounded-QA evaluation suite

Tests whether the model **uses** provided domain text correctly, rather
than relying on its own (limited, 2B-parameter) knowledge. This is the
RAG / agentic-grounding evaluation surface — the most relevant
benchmark when your subject matter is complicated and the model's
intrinsic knowledge of it is thin.

## Fixtures

| Id | Category           | Tests |
|----|--------------------|-------|
| G1 | grounded_factual   | Single-fact lookup in a single passage. |
| G2 | refuse_oob         | Question whose answer ISN'T in the passage — must refuse, not hallucinate. |
| G3 | multi_doc          | Three docs; answer needs information from all three. |
| G4 | term_preservation  | Rewrite a technical paragraph in plain English while keeping every technical term verbatim. |
| G5 | citation           | Answer with sentence-level citations [S1, S3] that actually back each claim. |
| G6 | specialty (TEMPLATE) | Drop-in for your subject matter — copy and fill TODOs. |

## Fixture format

```json
{
  "name": "G1 — short title",
  "system_prompt": "Answer using ONLY the context. If unanswerable, say 'I don't know.'",
  "context": "...passage(s)...",
  "question": "...",
  "gold_must_contain": ["term1", "term2"],
  "gold_must_not_contain": ["banned1", "banned2"],
  "category": "grounded_factual",
  "scoring_note": "free-form note about what's being checked"
}
```

For `category: refuse_oob`, the harness treats `gold_must_contain` as
**alternatives** — any one match counts. For all other categories,
EVERY string in `gold_must_contain` must appear, and NO string in
`gold_must_not_contain` may appear.

## Running

```sh
dart run example/eval/grounded/run_grounded.dart        # all fixtures
dart run example/eval/grounded/run_grounded.dart G3     # only G3
```

## Adding your domain (G6)

Copy `fixtures/G6_specialty_template.json` to a new file
(`G6_my_domain.json`, `G7_…`, etc.), fill in the TODOs from your
actual subject matter, run the harness. The TEMPLATE file is filtered
out automatically.

The investment is small (one passage + one question + a few expected
phrases per fixture) and the regression value is large — every model
upgrade, prompt change, or pipeline tweak gets scored against the
same gold answers.
