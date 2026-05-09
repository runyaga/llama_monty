# Plan: cleanly upstream the llamadart WebGPU grammar workaround

## Status

We currently depend on a fork —
[`runyaga/llamadart#fix/web-grammar-drop`](https://github.com/runyaga/llamadart/tree/fix/web-grammar-drop)
— with one commit on top of upstream `leehack/llamadart@v0.6.11`:
[`94e5385 fix(webgpu): drop tool-call grammar to avoid C++ sampler abort on web`](https://github.com/runyaga/llamadart/commit/94e5385).

This plan covers what to do next: either get the fix landed upstream
or build a smaller, properly-gated alternative that does land.

## What the patch does

- **Adds verbose probes** in `lib/src/backends/webgpu/webgpu_backend.dart`
  so consumers can see exactly what reaches the bridge:
  - prompt length, grammar length, `grammarLazy`, `grammarTriggers.length`,
    `preservedTokens.length`, `nPredict`,
  - the first 800 chars of the GBNF grammar string,
  - `[PROBE createCompletion.threw]` with full JS stack trace + Dart
    stack trace when the bridge throws.
- **Drops grammar** before the bridge's `createCompletion` call
  unconditionally when `params.grammar != null` (regardless of
  `params.grammarLazy`). The original idea was to gate on
  `grammarLazy`, but pressure-testing showed the C++ sampler aborts
  on **all** tool-call-shaped grammars whether lazy or eager.

## Why the fix exists (root cause)

The WebGPU C++ grammar sampler reliably aborts the WASM module
when constraining tool-call-shaped GBNF grammars produced by the
JSON-schema-to-GBNF converter for an LLM tool list:

- `~9-13 tokens` of constrained generation succeed.
- Then `RuntimeError: Aborted(undefined)` from `___cxa_throw` deep in
  the sampler at `wasm-function[978]` (offset varies by build).
- After the abort, the WASM heap is permanently corrupted — every
  subsequent ccall hits `null function` / `memory access out of bounds`.

Reproduction: run the example app on web with `tools: [...]` passed to
`ChatSession.create()`. See `example/eval/summarize/run_eval.dart` for
a deterministic harness.

The dropped grammar is not gating on Gemma 4 specifically — it
reproduces with **every** tool-call grammar shape we tested, on every
chat-template handler that uses
`grammarLazy: hasTools` (gemma-4, llama3, qwen3, gpt-oss-20b, etc.).

## Why we can't just upstream commit `94e5385` as-is

1. **Probes are noisy.** They emit at log-level `warn`/`error` which
   pollutes a release build. Upstream wouldn't merge them.
2. **Dropping grammar is a behavior change.** A consumer that relied
   on grammar-constrained generation working on web would silently
   regress to free-form generation. Upstream wants a flag, an env
   gate, or a feature-detect, not an unconditional override.
3. **The real bug is in the C++ sampler, not the Dart wrapper.**
   The Dart-level workaround masks a llama.cpp issue. Upstream
   should drive the fix at the bridge level (compile-time or at
   the C++ sampler).

## Recommended path

Three workstreams. Doing 1+2 produces a clean upstream PR. (3) is the
proper fix — file as an issue and let the bridge maintainer prioritize.

### 1. Split the patch into two commits

a. **`feat(webgpu): debug probes for createCompletion`**
   - Gated by a new `WebGpuLlamaBackend(debugProbes: false)` constructor
     parameter, default false.
   - When true, emit the same probes we have today.
   - When false, no behavior change.
   - Self-contained, low-risk merge.

b. **`fix(webgpu): drop tool-call grammar when bridge sampler is unstable`**
   - Add a constructor param `WebGpuLlamaBackend(disableGrammarOnWeb: false)`
     (or env-var override).
   - When true, replace `grammar: params.grammar` with `grammar: null`
     before the bridge call AND emit one warn-level log explaining why.
   - When false, current behavior (always pass grammar).
   - Document the flag and link to the upstream bridge issue.

This makes the override explicit and recoverable. Anyone wanting the
old behavior can pass `disableGrammarOnWeb: false`.

### 2. File the upstream issue (or PR)

Title: **WebGPU C++ grammar sampler aborts WASM on tool-call GBNF grammars**

Body should include:
- Repro: minimum WASM example (~30 LOC) that reliably aborts.
- Stack trace from `___cxa_throw` at `wasm-function[978]`.
- Affected tags: `v0.1.10`, `v0.1.14` (we tested both).
- Models that trigger: anything with a tool-call template that emits
  a JSON-schema-derived GBNF grammar (Gemma 4, Llama 3, Qwen 3, etc.).
- The 9-13-token prefix the model produces before abort (suggests
  the issue is in the constraint-application path, not parse).

Optional: reference our pressure-test harness so the bridge team can
reuse it.

### 3. Push our fork to a public PR for transparency

Even if (2) is the right long-term fix, our fork should still be a PR
on `leehack/llamadart` so:
- Other consumers of the bridge see they're hitting the same issue.
- Anyone writing a Flutter web LLM app today has a copy-paste
  workaround.
- The discussion lives in one place.

PR title: `Workaround: drop tool-call grammar on WebGPU until C++
sampler fix lands (refs #issue-from-step-2)`.

## Concrete acceptance criteria

The follow-on agent's PR is mergeable when:

- [ ] Probes are gated behind `debugProbes: false` (default off).
- [ ] Grammar drop is gated behind `disableGrammarOnWeb: false`
      (default off — i.e., default behavior matches today's upstream).
      Default-on can be flipped after maintainer sign-off.
- [ ] One unit test demonstrates the flag changes the bridge-call args
      (we don't need to run the bridge to verify; assert on the
      `WebGpuCompletionOptions.grammar` field passed in).
- [ ] No `// ignore:` directives.
- [ ] Both new constructor params are documented in the dartdoc on
      `WebGpuLlamaBackend`.
- [ ] CHANGELOG entry on the fork explains the workaround and links
      to the upstream bridge issue.
- [ ] The fork branch can be tagged (e.g. `v0.6.11+web-grammar-drop.1`)
      for downstream consumers to pin to.

## Files touched (today's fork)

```
lib/src/backends/webgpu/webgpu_backend.dart       +99 / -1
```

That single file is the entire diff. The split into two commits +
flag-gating is the only restructure needed.

## Out-of-scope for this plan

- **Fixing the C++ sampler.** That's a llama.cpp / bridge-build
  concern, not Dart-side. Track in (2) above.
- **`grammarLazy` plumb-through.** The `WebGpuCompletionOptions`
  interop doesn't carry `grammarLazy` or `grammarTriggers`. Adding
  them is bigger than this PR — file a separate issue if it matters.
- **Probe formatting.** Today's probes are good enough for debugging.
  Don't bikeshed.

## Pointers

- Fork: https://github.com/runyaga/llamadart/tree/fix/web-grammar-drop
- Patch file in repo: `example/llama_monty_web/patches/llamadart-0.6.11-webgpu-grammar-drop.patch`
- Repro harness: `example/eval/summarize/run_eval.dart`
