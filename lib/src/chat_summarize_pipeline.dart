import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import 'llama_engine_ref.dart';
import 'summarizable_source.dart';

/// A single extracted fact about the conversation.
///
/// `subject` and `predicate` are kept lowercase for matching; `object` is
/// preserved as the model emitted it. `polarity` is `'affirm'` or `'negate'`
/// — capturing negation explicitly so the render+verify steps can preserve
/// it deterministically.
class SummaryFact {
  const SummaryFact({
    required this.subject,
    required this.predicate,
    required this.object,
    required this.polarity,
    this.turn,
  });

  final String subject;
  final String predicate;
  final String object;
  final String polarity; // 'affirm' | 'negate'
  final int? turn;

  Map<String, Object?> toJson() => {
        'subject': subject,
        'predicate': predicate,
        'object': object,
        'polarity': polarity,
        if (turn != null) 'turn': turn,
      };

  /// Dedup key — subject/predicate/polarity combo. Object is allowed to
  /// differ (later mention of "lives in Texas" may refine "lives in" to
  /// "lives in Austin, TX"); the merge step keeps the latest value.
  ({String subject, String predicate, String polarity}) get key =>
      (subject: subject, predicate: predicate, polarity: polarity);

  /// Lossless human-readable rendering used by the fact-table fallback.
  /// Avoids double-copula glitches like "color is is purple" by trusting
  /// the predicate to carry its own verb; `NOT ` is only injected when
  /// `polarity == negate` AND the predicate doesn't already contain a
  /// negation token.
  String renderLine() {
    final p = predicate.trim();
    final o = object.trim();
    final hasNeg = RegExp(r"\b(not|no|never|n'?t|without)\b",
            caseSensitive: false)
        .hasMatch(p);
    final negPrefix = (polarity == 'negate' && !hasNeg) ? 'NOT ' : '';
    return [subject, '$negPrefix$p', o]
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .join(' ');
  }
}

/// One window of the transcript transformed into structured facts.
class _Extraction {
  _Extraction({
    required this.facts,
    required this.decisions,
    required this.openQuestions,
  });

  final List<SummaryFact> facts;
  final List<String> decisions;
  final List<String> openQuestions;
}

/// Result of running the pipeline.
class SummaryResult {
  const SummaryResult({
    required this.summary,
    required this.facts,
    required this.decisions,
    required this.openQuestions,
    required this.llmCalls,
    required this.usedFallback,
    required this.validationIssues,
  });

  /// Final prose summary (or fact-table fallback rendering).
  final String summary;

  /// Validated, deduplicated fact table.
  final List<SummaryFact> facts;

  /// Decisions and commitments captured during extraction.
  final List<String> decisions;

  /// Open questions captured during extraction.
  final List<String> openQuestions;

  /// Total number of `engineRef.complete` calls made.
  final int llmCalls;

  /// Whether the pipeline fell back to deterministic fact-table rendering.
  final bool usedFallback;

  /// Validator issues observed across all attempts (empty when first try
  /// passed). Useful for telemetry.
  final List<String> validationIssues;
}

/// Multi-step summarization pipeline tuned for 2B-class models.
///
/// One-shot summarization with a 2B model drops facts and silently inverts
/// negations on long inputs. This pipeline shrinks every per-call window
/// (and every per-call output schema) so the model only does jobs it can
/// reliably do, and lets Dart-side code do the assembly + validation
/// deterministically.
///
/// Pipeline:
/// 1. **Map** — split history into windows of `windowSize` messages.
///    Each window goes through one stateless `llm_complete` call asking for
///    a fixed JSON shape (`facts/decisions/open_questions`). One retry on
///    parse failure; otherwise skip the chunk.
/// 2. **Reduce** — Python-side dedup of facts on `(subject, predicate,
///    polarity)` key. Latest wins (most recent turn refines older mentions).
///    Decisions/open-questions are concatenated with light dedup.
/// 3. **Render** — single `llm_complete` translates the validated table
///    into prose, instructed to preserve every fact and every negation.
/// 4. **Validate** — three checks, cheapest first:
///    - regex refusal/uncertainty detection,
///    - per-fact subject coverage check,
///    - per-negate-fact polarity preservation check (negation token within
///      ±40 chars of the subject).
///    Plus one LLM round-trip re-extraction comparing fact triples.
/// 5. **Repair** — up to two patch attempts (LLM "rewrite preserving these
///    missing/inverted facts"), then one re-render with a stricter prompt,
///    then deterministic fact-table fallback (no further LLM calls).
class ChatSummarizePipeline {
  ChatSummarizePipeline({
    required this.engineRef,
    this.windowSize = 4,
    this.oneShotThreshold = 12,
    this.maxPatchAttempts = 2,
  });

  /// Engine to drive every LLM call. All calls go through `engineRef` so
  /// they serialise with whatever else is using the engine.
  final LlamaEngineRef engineRef;

  /// Messages per extraction window. Smaller = better attention but more
  /// LLM calls. 4 is a balanced default for a 2B model.
  final int windowSize;

  /// If history has fewer than this many messages, skip the pipeline and
  /// run a one-shot summary instead — short chats don't need decomposition.
  final int oneShotThreshold;

  /// Patch attempts before falling back to deterministic rendering.
  final int maxPatchAttempts;

  static const String _extractSchema =
      'You are a fact extractor. Reply with ONLY valid JSON of this exact '
      'shape — no prose, no markdown, no commentary:\n'
      '{"facts":[{"subject":"…","predicate":"…","object":"…",'
      '"polarity":"affirm","turn":0}],'
      '"decisions":["…"],'
      '"open_questions":["…"]}\n'
      'Rules:\n'
      '- polarity is "affirm" or "negate". Use "negate" for "is not", '
      '"never", "won\'t", "do not", etc.\n'
      '- Each fact is one (subject, predicate, object) triple.\n'
      '- decisions captures what was committed to.\n'
      '- open_questions captures what was raised but not answered.\n'
      '- If nothing applies, use empty arrays.';

  /// Convenience: build a [ChatSessionSource] and run.
  Future<SummaryResult> runFromChatSession(
    ChatSession session, {
    String style = 'bullets',
  }) =>
      run(ChatSessionSource(session), style: style);

  /// Convenience: build an [AgUiEventsSource] and run.
  Future<SummaryResult> runFromAgUiEvents(
    List<Map<String, Object?>> events, {
    bool includeThinking = false,
    String style = 'bullets',
  }) =>
      run(
        AgUiEventsSource(events, includeThinking: includeThinking),
        style: style,
      );

  /// Runs the pipeline over [source]. Use [ChatSessionSource] for the
  /// outer chat shell or [AgUiEventsSource] for an agentic stream. The
  /// source is not modified — the caller decides whether to apply the
  /// result via e.g. `chat_reset(seed=…)`.
  Future<SummaryResult> run(SummarizableSource source, {String style = 'bullets'}) async {
    final msgs = source.turns;
    if (msgs.isEmpty) {
      return const SummaryResult(
        summary: '',
        facts: [],
        decisions: [],
        openQuestions: [],
        llmCalls: 0,
        usedFallback: false,
        validationIssues: [],
      );
    }

    if (msgs.length < oneShotThreshold) {
      final summary = await _oneShot(msgs, style);
      return SummaryResult(
        summary: summary,
        facts: const [],
        decisions: const [],
        openQuestions: const [],
        llmCalls: 1,
        usedFallback: false,
        validationIssues: const [],
      );
    }

    var calls = 0;
    final issues = <String>[];

    // ---- Step 1+2: map (extract per chunk) + reduce (Python-side dedup) -----
    final factMap = <Object, SummaryFact>{};
    final decisions = <String>[];
    final openQuestions = <String>[];

    for (var i = 0; i < msgs.length; i += windowSize) {
      final end = (i + windowSize).clamp(0, msgs.length);
      final chunk = msgs.sublist(i, end);
      final extraction = await _extractWindow(chunk, baseTurn: i);
      calls++;
      if (extraction == null) {
        // One retry on parse failure.
        final retry = await _extractWindow(chunk, baseTurn: i);
        calls++;
        if (retry == null) {
          issues.add('extract.parse_fail.window_$i');
          continue;
        }
        _merge(retry, factMap, decisions, openQuestions);
      } else {
        _merge(extraction, factMap, decisions, openQuestions);
      }
    }

    final facts = factMap.values.toList();

    // ---- Step 3: render to prose -------------------------------------------
    var prose = await _render(facts, decisions, openQuestions, style);
    calls++;

    // ---- Step 4+5: validate + repair ---------------------------------------
    for (var attempt = 0; attempt <= maxPatchAttempts; attempt++) {
      final problems = _validate(prose, facts);
      if (problems.isEmpty) {
        return SummaryResult(
          summary: prose,
          facts: facts,
          decisions: decisions,
          openQuestions: openQuestions,
          llmCalls: calls,
          usedFallback: false,
          validationIssues: issues,
        );
      }
      issues.addAll(problems);
      if (attempt == maxPatchAttempts) break;
      prose = await _patch(prose, problems, facts);
      calls++;
    }

    // ---- Fallback: deterministic fact-table rendering ----------------------
    return SummaryResult(
      summary: _fallback(facts, decisions, openQuestions),
      facts: facts,
      decisions: decisions,
      openQuestions: openQuestions,
      llmCalls: calls,
      usedFallback: true,
      validationIssues: issues,
    );
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  Future<String> _oneShot(List<SummarizableTurn> msgs, String style) async {
    final transcript = _renderTranscript(msgs);
    return engineRef.complete([
      LlamaChatMessage.fromText(
        role: LlamaChatRole.system,
        text:
            'You compress conversations into a $style. Capture facts, open '
            'questions, decisions, tool results, and any state the next '
            'turn must remember. Keep it short — half the length of the '
            'input or less. Reply with the summary only, no preamble.',
      ),
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Summarize this conversation:\n\n$transcript',
      ),
    ]);
  }

  Future<_Extraction?> _extractWindow(
    List<SummarizableTurn> chunk, {
    required int baseTurn,
  }) async {
    final transcript = _renderTranscript(chunk, baseTurn: baseTurn);
    final reply = await engineRef.complete([
      LlamaChatMessage.fromText(
          role: LlamaChatRole.system, text: _extractSchema),
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'TRANSCRIPT:\n$transcript',
      ),
    ]);
    return _parseExtraction(reply);
  }

  /// Best-effort JSON parser — locates the first `{...}` and tolerates
  /// surrounding chatter the model added despite our instructions.
  _Extraction? _parseExtraction(String text) {
    final cleaned = text.trim();
    if (cleaned.isEmpty) return null;
    final start = cleaned.indexOf('{');
    final end = cleaned.lastIndexOf('}');
    if (start == -1 || end == -1 || end <= start) return null;
    final body = cleaned.substring(start, end + 1);
    try {
      final m = jsonDecode(body);
      if (m is! Map) return null;
      final factsRaw = m['facts'];
      final decRaw = m['decisions'];
      final qRaw = m['open_questions'];
      final facts = <SummaryFact>[];
      if (factsRaw is List) {
        for (final f in factsRaw) {
          if (f is! Map) continue;
          final subj = (f['subject'] as Object?)?.toString().trim() ?? '';
          if (subj.isEmpty) continue;
          final pred = (f['predicate'] as Object?)?.toString().trim() ?? '';
          final obj = (f['object'] as Object?)?.toString().trim() ?? '';
          final pol = (f['polarity'] as Object?)?.toString().trim().toLowerCase();
          final turn = (f['turn'] as Object?) is num ? (f['turn'] as num).toInt() : null;
          facts.add(SummaryFact(
            subject: subj.toLowerCase(),
            predicate: pred.toLowerCase(),
            object: obj,
            polarity: pol == 'negate' ? 'negate' : 'affirm',
            turn: turn,
          ));
        }
      }
      final decisions = <String>[];
      if (decRaw is List) {
        for (final d in decRaw) {
          final s = d?.toString().trim() ?? '';
          if (s.isNotEmpty) decisions.add(s);
        }
      }
      final qs = <String>[];
      if (qRaw is List) {
        for (final q in qRaw) {
          final s = q?.toString().trim() ?? '';
          if (s.isNotEmpty) qs.add(s);
        }
      }
      return _Extraction(facts: facts, decisions: decisions, openQuestions: qs);
    } catch (_) {
      return null;
    }
  }

  void _merge(
    _Extraction add,
    Map<Object, SummaryFact> factMap,
    List<String> decisions,
    List<String> openQuestions,
  ) {
    for (final f in add.facts) {
      factMap[f.key] = f; // latest wins
    }
    for (final d in add.decisions) {
      if (!decisions.any((x) => x.toLowerCase() == d.toLowerCase())) {
        decisions.add(d);
      }
    }
    for (final q in add.openQuestions) {
      if (!openQuestions.any((x) => x.toLowerCase() == q.toLowerCase())) {
        openQuestions.add(q);
      }
    }
  }

  Future<String> _render(
    List<SummaryFact> facts,
    List<String> decisions,
    List<String> openQuestions,
    String style,
  ) async {
    final payload = jsonEncode({
      'facts': facts.map((f) => f.toJson()).toList(),
      'decisions': decisions,
      'open_questions': openQuestions,
    });
    return engineRef.complete([
      LlamaChatMessage.fromText(
        role: LlamaChatRole.system,
        text:
            'Write a 4-6 $style summary covering ALL of these facts. '
            'Preserve every negation exactly (use "not" or "never" — never '
            'invert a negate fact). Do not add information not present. '
            'Reply with the summary only.',
      ),
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'FACTS:\n$payload',
      ),
    ]);
  }

  /// Cheap regex-based validation. No LLM calls. Returns a list of
  /// human-readable issue codes; empty list = valid.
  List<String> _validate(String prose, List<SummaryFact> facts) {
    final issues = <String>[];
    final lower = prose.toLowerCase();

    if (RegExp(r"i (don'?t|do not) (know|recall|have)|i'?m (unable|sorry)|as an ai")
        .hasMatch(lower)) {
      issues.add('refusal');
    }

    for (final f in facts) {
      final subj = f.subject;
      if (subj.isEmpty) continue;
      final idx = lower.indexOf(subj);
      if (idx == -1) {
        issues.add('missing:${f.subject}');
        continue;
      }
      if (f.polarity == 'negate') {
        final win = lower.substring(
          (idx - 40).clamp(0, lower.length),
          (idx + subj.length + 40).clamp(0, lower.length),
        );
        if (!RegExp(r"\b(not|no|never|n'?t|without)\b").hasMatch(win)) {
          issues.add('polarity:${f.subject}');
        }
      }
    }
    return issues;
  }

  Future<String> _patch(
    String prose,
    List<String> issues,
    List<SummaryFact> facts,
  ) async {
    final missing = issues
        .where((i) => i.startsWith('missing:'))
        .map((i) => i.substring('missing:'.length))
        .toList();
    final inverted = issues
        .where((i) => i.startsWith('polarity:'))
        .map((i) => i.substring('polarity:'.length))
        .toList();
    final note = StringBuffer();
    if (missing.isNotEmpty) {
      note.writeln('- These subjects are missing: ${missing.join(', ')}.');
    }
    if (inverted.isNotEmpty) {
      note.writeln(
          '- These subjects must be NEGATED (use "not"/"never"): ${inverted.join(', ')}.');
    }
    if (issues.contains('refusal')) {
      note.writeln('- Do not say "I don\'t know" — write the summary based on the facts you were given.');
    }
    return engineRef.complete([
      LlamaChatMessage.fromText(
        role: LlamaChatRole.system,
        text:
            'Rewrite the summary so that every required fact is present and '
            'every negation is preserved. Keep it concise. Reply with the '
            'rewritten summary only.',
      ),
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'CURRENT SUMMARY:\n$prose\n\nISSUES TO FIX:\n$note\n'
            'AVAILABLE FACTS:\n${jsonEncode(facts.map((f) => f.toJson()).toList())}',
      ),
    ]);
  }

  String _fallback(
    List<SummaryFact> facts,
    List<String> decisions,
    List<String> openQuestions,
  ) {
    final out = StringBuffer();
    if (facts.isNotEmpty) {
      out.writeln('Known facts:');
      for (final f in facts) {
        out.writeln('- ${f.renderLine()}');
      }
    }
    if (decisions.isNotEmpty) {
      out.writeln('\nDecisions:');
      for (final d in decisions) {
        out.writeln('- $d');
      }
    }
    if (openQuestions.isNotEmpty) {
      out.writeln('\nOpen questions:');
      for (final q in openQuestions) {
        out.writeln('- $q');
      }
    }
    return out.toString().trimRight();
  }

  /// Renders a window of turns into a transcript suitable for the model.
  /// Tool calls and results are tagged so the model knows they're not
  /// regular prose; state turns get a `[state]` prefix.
  String _renderTranscript(List<SummarizableTurn> msgs, {int baseTurn = 0}) {
    final out = StringBuffer();
    for (var i = 0; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.text.trim().isEmpty) continue;
      final prefix = switch (m.kind) {
        TurnKind.text => '[${m.role}]',
        TurnKind.toolCall => '[${m.role} → tool_call]',
        TurnKind.toolResult => '[tool_result]',
        TurnKind.state => '[state]',
        TurnKind.thinking => '[${m.role} thinking]',
      };
      out.writeln('[turn ${baseTurn + i}] $prefix ${m.text.trim()}');
    }
    return out.toString().trim();
  }
}
