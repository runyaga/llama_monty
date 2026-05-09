// Demonstrates the multi-step summarization pipeline on a long, realistic
// conversation that exceeds 3000 tokens — the regime where one-shot
// summarization breaks down on a 2B model.
//
// Two passes against the SAME content:
//
//   1. Replay as a chat session through ChatSessionSource (the
//      "completions" path: user/assistant turns build up a ChatSession
//      and we summarize that).
//
//   2. Replay as an AG-UI event stream through AgUiEventsSource
//      (TEXT_MESSAGE_START / TEXT_MESSAGE_CONTENT / TEXT_MESSAGE_END +
//      a couple of TOOL_CALL_RESULT events) and summarize the reduced
//      view. Demonstrates that the pipeline is protocol-agnostic.
//
// Both passes print:
//   - turn count, char count, approx token count
//   - extracted fact table
//   - decisions / open questions
//   - rendered summary
//   - did-it-fall-back-to-deterministic-rendering
//   - LLM call count + wall clock
//
// Run: dart run example/long_conversation_demo.dart

import 'dart:io';

import 'package:llama_monty/llama_monty.dart';
import 'package:llamadart/llamadart.dart';

const _modelPath = '/Users/runyaga/models/gemma-4-E2B-it-Q4_K_M.gguf';

/// 30-turn design discussion — hand-written so we know exactly what
/// facts SHOULD survive a summarize. Picks engineering decisions,
/// dates, names, numbers, and a couple of negations. About ~3.5K
/// tokens by char-count / 4 estimate.
const List<({String role, String text})> _conversation = [
  // ---- introduction & context (turns 1-6) ----
  (
    role: 'user',
    text:
        "Hi, I'm Priya — I'm leading an internal audit team at Acme Robotics "
        "and we're rolling out a new safety-event review process. Looking "
        "for advice on the architecture."
  ),
  (
    role: 'assistant',
    text:
        "Hi Priya — happy to help. Let's start with constraints. What's the "
        "expected event volume per day, and are these events live-streamed "
        "from the robots or batched?"
  ),
  (
    role: 'user',
    text:
        "Live-streamed. We expect about 4,000 events per day across our "
        "fleet of 220 robots in the Portland warehouse, ramping to 8,000 "
        "as we add the Austin facility next quarter."
  ),
  (
    role: 'assistant',
    text:
        "OK. So peak ~10/sec sustained — well within a single Postgres "
        "instance for ingestion if you're not doing ML on every event "
        "synchronously. What does the audit workflow look like end to end?"
  ),
  (
    role: 'user',
    text:
        "Each event lands in a queue, gets auto-classified by severity "
        "(low/med/high), then routed: low events are auto-archived after "
        "30 days, mediums need a single human reviewer, highs need two "
        "independent reviewers and a written justification."
  ),
  (
    role: 'assistant',
    text:
        "Got it — that maps to a state machine per event with branching "
        "on severity. I'd model it as `triage → review (one or two) → "
        "decision`. Are reviewers internal-only or do you have external "
        "auditors in the loop?"
  ),

  // ---- regulatory + tooling (turns 7-12) ----
  (
    role: 'user',
    text:
        "Internal only for now, but the upcoming federal warehouse-safety "
        "rule (effective 2026-04-01) requires external auditors for any "
        "high-severity event involving injury. So we need to be ready to "
        "let outside reviewers in by April."
  ),
  (
    role: 'assistant',
    text:
        "Important — that's a hard deadline. External reviewers means "
        "row-level access control, audit trail of who saw what, and "
        "probably a separate review queue per organization. Are you "
        "thinking SAML SSO or magic links for external folks?"
  ),
  (
    role: 'user',
    text:
        "We do NOT want SAML — too heavy. Magic links scoped to a single "
        "event for the external reviewer, expiring 14 days after issue. "
        "And every action they take is logged immutably."
  ),
  (
    role: 'assistant',
    text:
        "That's a clean choice for the volume you're describing. For the "
        "immutable log I'd lean toward append-only Postgres tables with "
        "a hash chain, plus daily snapshot to S3 with object lock for "
        "regulatory cover. Acceptable?"
  ),
  (
    role: 'user',
    text:
        "S3 object lock — yes. We already have a compliance bucket. "
        "Hash chain — sure, we'll need to expose the chain integrity "
        "check as an internal audit endpoint."
  ),
  (
    role: 'assistant',
    text:
        "Will do. One question on the classifier — auto-classification "
        "is currently rule-based, ML, or undecided?"
  ),

  // ---- ML & data (turns 13-18) ----
  (
    role: 'user',
    text:
        "Currently a 27-rule decision tree the safety team hand-tunes. "
        "It misclassifies about 8% of events — we have a labelled dataset "
        "of 47,000 events from the last 18 months we'd like to use to "
        "train a real classifier."
  ),
  (
    role: 'assistant',
    text:
        "47K labelled is a comfortable size for a small transformer or "
        "even gradient-boosted trees. Class balance — what fraction are "
        "high severity?"
  ),
  (
    role: 'user',
    text:
        "About 4% high, 18% medium, 78% low. The classifier needs to be "
        "very high-recall on 'high' — missing one is a regulatory issue. "
        "False positives on 'high' are tolerable; humans will correct."
  ),
  (
    role: 'assistant',
    text:
        "Right calibration — recall over precision on high. I'd train a "
        "multiclass model with class-weighted loss, then tune the high "
        "threshold to keep recall ≥ 99%. Track the precision@99-recall "
        "as the headline metric."
  ),
  (
    role: 'user',
    text:
        "Sold. We also need on-device inference for the warehouse — no "
        "external network calls during the classification step. The "
        "operations VP is firm about that."
  ),
  (
    role: 'assistant',
    text:
        "Understood. That points away from API-only services. A small "
        "ONNX model deployed to each warehouse's local GPU box, with the "
        "training pipeline in the cloud, model artifacts pulled nightly."
  ),

  // ---- timelines, team, budget (turns 19-26) ----
  (
    role: 'user',
    text:
        "Yes. Timeline-wise: rule engine v2 by Feb 1, ML classifier "
        "shadow-deploy by March 1, full cutover by March 15, external "
        "reviewer access live by March 20 — buffer to the April 1 "
        "regulatory deadline."
  ),
  (
    role: 'assistant',
    text:
        "Tight but achievable. Who's running the ML side — same team as "
        "the audit workflow?"
  ),
  (
    role: 'user',
    text:
        "Different teams. ML is led by Marcus Webb (he reports to the "
        "CTO Lila Tran). Audit workflow is led by my team. We coordinate "
        "weekly."
  ),
  (
    role: 'assistant',
    text:
        "Make sure the model artifact + inference contract is frozen "
        "well before March 1 — once shadow deploy starts, surprise "
        "schema changes will burn a week each. What's the budget?"
  ),
  (
    role: 'user',
    text:
        "\$340,000 hard cap for the workflow side, separate budget for "
        "ML on Marcus's side. Most of mine is loaded into 4 engineers "
        "for 6 months and the compliance audit at the end."
  ),
  (
    role: 'assistant',
    text:
        "Reasonable. Compliance audit cost — have you scoped that with "
        "an external firm?"
  ),
  (
    role: 'user',
    text:
        "Quoted at \$45K from Schmidt & Hannigan. They've done two of "
        "our prior compliance audits, so they know the codebase."
  ),
  (
    role: 'assistant',
    text:
        "Familiar auditor saves at least a week of onboarding. Anything "
        "else giving you concern?"
  ),

  // ---- worry, outstanding decisions, wrap (turns 27-30) ----
  (
    role: 'user',
    text:
        "Two open questions: (1) we have NOT decided whether to do "
        "active learning on the misclassified events to improve the "
        "model post-launch, and (2) we don't yet have a pager rotation "
        "set up for high-severity events that the classifier flags but "
        "no human reviews within 1 hour."
  ),
  (
    role: 'assistant',
    text:
        "On (1): defer. Get the model stable first, add active learning "
        "after 2-3 months of production data. On (2): set up the pager "
        "BEFORE March 1 cutover — the regulator will ask. PagerDuty "
        "+ Slack with a 1-hour SLA on 'high' is the obvious shape."
  ),
  (
    role: 'user',
    text:
        "Agreed. Final: are there any blind spots you'd watch out for? "
        "Things our team typically misses on rollouts like this?"
  ),
  (
    role: 'assistant',
    text:
        "Three: data retention policy collisions with state law (some "
        "states have specific retention rules for warehouse incidents); "
        "language localization for external auditors who may not work "
        "in English; and capacity planning for that 8K/day target — "
        "test at 12K to leave headroom."
  ),
];

int _approxTokens(String text) => (text.length / 4).ceil();

void _printResult(String label, SummaryResult r) {
  stdout.writeln('\n=== $label ===');
  stdout.writeln('  llmCalls=${r.llmCalls}, usedFallback=${r.usedFallback}, '
      'issues=${r.validationIssues}');
  stdout.writeln('  facts (${r.facts.length}):');
  for (final f in r.facts) {
    stdout.writeln('    - ${f.renderLine()}');
  }
  if (r.decisions.isNotEmpty) {
    stdout.writeln('  decisions:');
    for (final d in r.decisions) stdout.writeln('    - $d');
  }
  if (r.openQuestions.isNotEmpty) {
    stdout.writeln('  open_questions:');
    for (final q in r.openQuestions) stdout.writeln('    - $q');
  }
  stdout.writeln('  --- summary ---');
  for (final l in r.summary.split('\n')) stdout.writeln('  $l');
}

Future<void> main() async {
  final totalChars = _conversation.fold(0, (a, t) => a + t.text.length);
  final totalTokens = (totalChars / 4).ceil();

  stdout.writeln('Conversation: ${_conversation.length} turns, '
      '$totalChars chars, ~$totalTokens tokens.\n');

  stdout.writeln('Loading model …');
  final engine = LlamaEngine(LlamaBackend());
  await engine.loadModel(_modelPath, modelParams: ModelParams(contextSize: 8192));
  // Gemma 4's recommended sampling.
  final ref = LlamaEngineRef(
    engine,
    defaultParams: const GenerationParams(temp: 1.0, topP: 0.95),
  );
  final pipeline = ChatSummarizePipeline(
    engineRef: ref,
    oneShotThreshold: 12, // production default — pipeline will engage
  );

  // ---- Pass 1: ChatSessionSource ------------------------------------------
  stdout.writeln('\n----------------------------------------------------------');
  stdout.writeln('PASS 1: ChatSessionSource (completions-style)');
  stdout.writeln('----------------------------------------------------------');
  final session = ChatSession(engine,
      systemPrompt: 'You are a helpful design-review assistant.');
  for (final t in _conversation) {
    session.addMessage(LlamaChatMessage.fromText(
      role: t.role == 'user' ? LlamaChatRole.user : LlamaChatRole.assistant,
      text: t.text,
    ));
  }
  final t1 = DateTime.now();
  final r1 = await pipeline.runFromChatSession(session);
  final dt1 = DateTime.now().difference(t1).inMilliseconds;
  _printResult('PASS 1 result (${dt1}ms)', r1);

  // ---- Pass 2: AgUiEventsSource -------------------------------------------
  // Encode the same conversation as AG-UI events: each turn becomes a
  // TEXT_MESSAGE_START / _CONTENT / _END triple. Add a synthetic
  // TOOL_CALL_CHUNK in the middle to prove the AG-UI source preserves
  // tool-call turns through the pipeline.
  stdout.writeln('\n----------------------------------------------------------');
  stdout.writeln('PASS 2: AgUiEventsSource (streaming-events shape)');
  stdout.writeln('----------------------------------------------------------');
  final events = <Map<String, Object?>>[];
  for (var i = 0; i < _conversation.length; i++) {
    final t = _conversation[i];
    final id = 'm$i';
    events.add({'type': 'TEXT_MESSAGE_START', 'messageId': id, 'role': t.role});
    events.add({'type': 'TEXT_MESSAGE_CONTENT', 'messageId': id, 'delta': t.text});
    events.add({'type': 'TEXT_MESSAGE_END', 'messageId': id});
    // Inject a synthetic tool_call midway to exercise the AG-UI tool path.
    if (i == 14) {
      events.add({
        'type': 'TOOL_CALL_CHUNK',
        'toolCallId': 'tc1',
        'toolCallName': 'check_compliance_deadline',
        'delta': '{"rule": "warehouse-safety-2026", "effective": "2026-04-01"}',
      });
      events.add({
        'type': 'TOOL_CALL_RESULT',
        'toolCallId': 'tc1',
        'toolCallName': 'check_compliance_deadline',
        'content':
            'Rule effective 2026-04-01. Requires external auditor for high-severity events involving injury.',
      });
    }
  }
  final t2 = DateTime.now();
  final r2 = await pipeline.runFromAgUiEvents(events);
  final dt2 = DateTime.now().difference(t2).inMilliseconds;
  _printResult('PASS 2 result (${dt2}ms)', r2);

  // ---- Diff ---------------------------------------------------------------
  stdout.writeln('\n----------------------------------------------------------');
  stdout.writeln('DIFF');
  stdout.writeln('----------------------------------------------------------');
  final f1Keys = r1.facts.map((f) => f.key).toSet();
  final f2Keys = r2.facts.map((f) => f.key).toSet();
  final onlyP1 = r1.facts.where((f) => !f2Keys.contains(f.key)).toList();
  final onlyP2 = r2.facts.where((f) => !f1Keys.contains(f.key)).toList();
  final shared = r1.facts.where((f) => f2Keys.contains(f.key)).length;
  stdout.writeln('  shared facts: $shared');
  stdout.writeln('  only in PASS 1 (chat): ${onlyP1.length}');
  for (final f in onlyP1) stdout.writeln('    - ${f.renderLine()}');
  stdout.writeln('  only in PASS 2 (ag-ui + tool result): ${onlyP2.length}');
  for (final f in onlyP2) stdout.writeln('    - ${f.renderLine()}');

  await engine.dispose();
}
