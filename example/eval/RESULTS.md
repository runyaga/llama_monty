# Eval results — 2026-05-08

Three eval suites, all run on FFI Gemma-4-E2B-it-Q4_K_M with default
sampling (temp=0.8, top_p=0.9 — note: Google recommends 1.0 / 0.95
for Gemma 4; backlogged to retry).

## Capability (multiple-choice reasoning)

```
T1  Boolean truth-table single-row eval     PASS   correct=B
T2  Agentic state-machine routing           PASS   correct=C
T3  Dart Macros current status              PASS   correct=B

3/3 PASS
```

When forced to commit to a letter via "Answer: X", the 2B model
reasons cleanly across formal logic, multi-rule state tracing, and
grounded factual knowledge with self-correction.

## Programming (graduated probes)

```
                                       Tier  Status
P1  sum 1..100                          1    PASS
P2  fibonacci 12                        2    PASS
P3  list of primes below 50             2    PASS
P4  CSV average from /fixtures          3    ERROR_PY  (used `with` — context managers unsupported)
P5  factorial 20 without math.factorial 3    PASS
P6  unique-word counter without classes 3    PASS
P7  bubble-sort swap count              4    ERROR_PY  (forgot colon after `while X` — syntax error)
P8  RLE encode + decode round-trip      4    PASS
P9  strict JSON output spec             4    FAIL_OUTPUT  (model output was correct; harness regex bug — fixed)
P10 memoize without decorators (TRAP)   5    PASS

7/10 PASS, 1 FAIL_OUTPUT (harness bug), 2 ERROR_PY (model)
```

After harness fix on P9, real model results: 8 / 10. Two model failures:

- **P4** (`with` statement): the system prompt didn't list context
  managers as forbidden. The model wrote idiomatic Python; Monty
  rejected it. Fixed system prompt to include the warning.
- **P7** (missing colon after `while`): pure 2B-model syntax slip.
  Worth tracking — if this happens often, a "linter" pass before
  Monty execution could catch it cheaply.

The trap (P10 — memoize without decorators) was the most encouraging
result: the model wrote a manual cache dict, recognized the
constraint, and returned the correct `fib(30)=832040`.

## Grounded QA

```
G1  simple grounded QA              PASS
G2  refuse when out of context      PASS
G3  multi-document synthesis        PASS
G4  domain-term preservation        PASS
G5  citation accuracy               PASS

5/5 PASS
```

This is the most strategically important result for the
"shallow domain knowledge + complicated subject matter" setting.
With explicit context provided in the prompt, the 2B model:

- looks up specific facts cleanly (G1),
- refuses when the answer isn't in the context, NOT hallucinating
  a number (G2),
- synthesizes across three documents using info from each (G3),
- preserves all 10 technical terms (LSTM / LIDAR / EKF / CAN bus /
  cost-map / 0.7 / etc.) verbatim through a plain-English rewrite
  (G4),
- cites the supporting sentence numbers correctly (G5).

**Take-away**: light intrinsic knowledge is the *good* case for this
architecture; you just have to give the model the text. The grounded
eval should be the regression suite that gates every model and
prompt change going forward. Drop in `G6_specialty_*.json` fixtures
from your real subject matter and you have a domain-specific gate.

## Summarize (head-to-head: baseline one-shot vs. multi-step v2)

```
                              baseline        v2
                              recall  neg     recall  neg     winner
F1  short basic               100%   100%       0%   100%     baseline -100
F2  short prefs               100%   100%      50%   100%     baseline -50
F3  short work                100%   100%     100%   100%     tie
F4  long Japan                  0%   100%       0%   100%     both fail
F5  long debug                 10%   100%      40%   100%     v2 +30
F6  long recipe                70%   100%      60%   100%     baseline +10
F7  topic switch               40%   100%      50%   100%     v2 +10
F8  ⭐ negations                 14%    20%     100%   100%     v2 +86 / +80
F9  numeric / dates           87.5%  100%     100%   100%     v2 +12.5
F10 non-Latin proper nouns     50%   100%     100%   100%     v2 +50

AGGREGATE                     57.2%    92%   60.0%   100%
LLM calls                       10              47   (4.7×)
Wall clock                     42 s            365 s (8.7×)
```

### Headline findings

1. **F8 (negations) is the v2 win the proposal predicted**: 14% → 100%
   recall and 20% → 100% negation accuracy. The 2B model silently
   inverts negations in one-shot summaries; the explicit polarity
   tag in the schema-driven extraction plus the deterministic regex
   polarity check fixes that. **For domains where "do not", "never",
   "against", "contraindicated" matter (regulations, dietary rules,
   medical, legal), this is the strongest reason to ship v2.**

2. **V2 wins on long / proper-noun / numeric**: F10 +50, F5 +30,
   F9 +12.5. These are exactly the cases where one-shot summaries
   paraphrase and lose detail.

3. **V2 over-decomposes short conversations**: F1 went 100% → 0%, F2
   went 100% → 50%. The 6-message chat has too few facts per chunk;
   the schema-driven extraction emits sparse output and the render
   step under-covers. The `oneShotThreshold=12` parameter exists
   exactly for this; the eval forced `threshold=0` for head-to-head
   comparison. In production, the default threshold means short
   chats stay on baseline and never see this regression.

4. **Both strategies fail F4 (Japan trip) at 0% recall.** This is
   a fixture-level issue: 13 facts spanning 14 turns means the seed
   that gets planted into the post-reset session lacks the user's
   identity ("Priya"). When asked "list everything you know about
   the user," the model can't recover. Worth investigating — maybe
   the seed needs an explicit "User: …" identity line — but not a
   v2-specific failure.

5. **Cost**: V2 is **4.7× more LLM calls and 8.7× wall-clock**.
   That's the real price.

### Recommendation

- Keep BOTH strategies wired: default `chat_summarize` for short
  chats, `chat_summarize_v2` for long / negation-heavy ones.
- Default `oneShotThreshold = 12` is correct. Don't lower it.
- Trigger v2 explicitly when:
  - history ≥ 12 messages, OR
  - any user turn contains negation tokens (`not|never|won't|n't|against|without`), OR
  - the user invokes the host fn directly.
- F8 alone justifies shipping v2.

### Backlog from this eval

- **F4 dig-in**: why does the post-reset reply lose the user's
  identity even though the summary contains it?
- **Sampling retry**: rerun summarize on Gemma 4's recommended
  `temp=1.0, top_p=0.95` to see if extraction quality improves
  enough to cut LLM-call budget (e.g. drop the validation
  re-extract).
- **G6 specialty fixtures**: drop in real subject-matter fixtures
  from your domain. The investment is small; the regression value
  is large.
- **Programming P7 colon-drop**: track frequency. If common, add a
  cheap pre-execution Python-syntax linter so the LLM gets a
  second chance.
