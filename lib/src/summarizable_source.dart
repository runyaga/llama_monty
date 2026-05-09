import 'package:llamadart/llamadart.dart';

/// Kinds of [SummarizableTurn] payloads. Not every protocol uses all of
/// them. AG-UI tool calls become two consecutive turns ([toolCall] then
/// [toolResult]); plain LLM turns are [text]; state snapshots / deltas
/// from agentic runs become [state] turns.
enum TurnKind {
  /// Plain prose from the user, assistant, or system.
  text,

  /// An assistant tool invocation with structured args.
  toolCall,

  /// Result returned from a tool call.
  toolResult,

  /// Aggregated state at a point in the run (snapshot or accumulated delta).
  state,

  /// Thinking / chain-of-thought content. Usually skipped by the
  /// summarizer but kept here for completeness.
  thinking,
}

/// Protocol-agnostic view of a single message inside a conversation /
/// agent run. Both `ChatSession.history` and an AG-UI event stream reduce
/// to a list of these — that's the only shape the summarize pipeline
/// needs to see.
class SummarizableTurn {
  const SummarizableTurn({
    required this.role,
    required this.text,
    this.kind = TurnKind.text,
    this.metadata = const {},
  });

  /// One of `'user' | 'assistant' | 'tool' | 'system'`.
  final String role;

  /// Primary text payload of the turn — assembled prose for [TurnKind.text],
  /// the tool name + args render for [TurnKind.toolCall], the stringified
  /// result for [TurnKind.toolResult], etc. Always non-empty for turns the
  /// pipeline should care about.
  final String text;

  final TurnKind kind;

  /// Protocol-specific extras. For AG-UI tool calls this carries
  /// `{toolCallId, name, argsJson}`. For state turns, the structured diff.
  /// The summarizer renders this into the extraction prompt verbatim.
  final Map<String, Object?> metadata;
}

/// Anything that can yield a list of [SummarizableTurn]s. The pipeline
/// chunks `turns` into windows and extracts facts; the source is
/// responsible for reducing protocol-specific events (deltas, chunks,
/// snapshots) into settled turns first.
abstract class SummarizableSource {
  const SummarizableSource();

  /// Settled turns in order.
  List<SummarizableTurn> get turns;
}

/// Adapter for the existing `ChatSession.history` shape. Tool calls become
/// `toolCall` turns and tool results become `toolResult` turns so the
/// pipeline never silently drops them.
class ChatSessionSource extends SummarizableSource {
  ChatSessionSource(this.session);

  final ChatSession session;

  @override
  List<SummarizableTurn> get turns {
    final out = <SummarizableTurn>[];
    for (final msg in session.history) {
      final role = msg.role.name;
      // Collect text parts, tool calls, and tool results separately —
      // a single LlamaChatMessage may carry several of each.
      final textParts = <String>[];
      for (final part in msg.parts) {
        if (part is LlamaTextContent) {
          if (part.text.trim().isNotEmpty) textParts.add(part.text.trim());
        } else if (part is LlamaToolCallContent) {
          out.add(SummarizableTurn(
            role: role,
            text: '${part.name}(${part.arguments})',
            kind: TurnKind.toolCall,
            metadata: {
              'name': part.name,
              'arguments': part.arguments,
              if (part.id != null) 'id': part.id,
            },
          ));
        } else if (part is LlamaToolResultContent) {
          out.add(SummarizableTurn(
            role: 'tool',
            text: '${part.name} → ${part.result}',
            kind: TurnKind.toolResult,
            metadata: {
              'name': part.name,
              'result': part.result,
              if (part.id != null) 'id': part.id,
            },
          ));
        }
      }
      if (textParts.isNotEmpty) {
        out.add(SummarizableTurn(
          role: role,
          text: textParts.join('\n'),
        ));
      }
    }
    return out;
  }
}

/// Adapter for an AG-UI event stream. Takes the list of opaque event JSON
/// maps (matching `ag_ui.core.events.BaseEvent`'s on-the-wire shape) and
/// reduces them to settled turns:
///
/// - `TEXT_MESSAGE_START` / `TEXT_MESSAGE_CONTENT` / `TEXT_MESSAGE_END`
///   (and `TEXT_MESSAGE_CHUNK`) → one [TurnKind.text] turn per message id.
/// - `TOOL_CALL_START` / `TOOL_CALL_ARGS` / `TOOL_CALL_END` → one
///   [TurnKind.toolCall] turn per tool-call id with assembled args JSON.
/// - `TOOL_CALL_RESULT` → one [TurnKind.toolResult] turn.
/// - `STATE_SNAPSHOT` / final `STATE_DELTA` → one [TurnKind.state] turn
///   with the latest structured state.
/// - `THINKING_*` → optional [TurnKind.thinking] turns (off by default;
///   thinking content is usually noisy for summarization).
///
/// Events stay opaque maps here so this file does NOT take a hard
/// dependency on an AG-UI Dart SDK — projects that already use one can
/// `event.toJson()` before passing the list in.
class AgUiEventsSource extends SummarizableSource {
  const AgUiEventsSource(this.events, {this.includeThinking = false});

  /// Ordered AG-UI events as JSON maps. Each must at least have a `type`
  /// field matching one of the AG-UI EventType strings.
  final List<Map<String, Object?>> events;

  /// When true, thinking-text events are kept as [TurnKind.thinking] turns.
  /// Default false — they're noisy and the summary almost never needs them.
  final bool includeThinking;

  @override
  List<SummarizableTurn> get turns {
    final out = <SummarizableTurn>[];
    final activeText = <String, _TextAccumulator>{};
    final activeThinking = <String, _TextAccumulator>{};
    final activeToolCalls = <String, _ToolCallAccumulator>{};
    Map<String, Object?>? lastState;

    for (final ev in events) {
      final type = ev['type']?.toString() ?? '';
      switch (type) {
        // ---- text messages -------------------------------------------------
        case 'TEXT_MESSAGE_START':
          final id = ev['messageId']?.toString() ?? '';
          activeText[id] = _TextAccumulator(
            role: ev['role']?.toString() ?? 'assistant',
          );
        case 'TEXT_MESSAGE_CONTENT':
          final id = ev['messageId']?.toString() ?? '';
          activeText.putIfAbsent(
            id,
            () => _TextAccumulator(role: 'assistant'),
          );
          final delta = ev['delta']?.toString() ?? '';
          if (delta.isNotEmpty) activeText[id]!.buf.write(delta);
        case 'TEXT_MESSAGE_END':
          final id = ev['messageId']?.toString() ?? '';
          final acc = activeText.remove(id);
          if (acc != null && acc.buf.toString().trim().isNotEmpty) {
            out.add(SummarizableTurn(
              role: acc.role,
              text: acc.buf.toString().trim(),
            ));
          }
        case 'TEXT_MESSAGE_CHUNK':
          // Self-contained chunk event — the wire form combines start +
          // content + end into one. Produce a turn directly.
          final delta = ev['delta']?.toString() ?? '';
          if (delta.trim().isNotEmpty) {
            out.add(SummarizableTurn(
              role: ev['role']?.toString() ?? 'assistant',
              text: delta.trim(),
            ));
          }

        // ---- thinking ------------------------------------------------------
        case 'THINKING_TEXT_MESSAGE_START':
          if (!includeThinking) break;
          final id = ev['messageId']?.toString() ?? 'thinking';
          activeThinking[id] = _TextAccumulator(role: 'assistant');
        case 'THINKING_TEXT_MESSAGE_CONTENT':
          if (!includeThinking) break;
          final id = ev['messageId']?.toString() ?? 'thinking';
          final acc = activeThinking.putIfAbsent(
            id,
            () => _TextAccumulator(role: 'assistant'),
          );
          final delta = ev['delta']?.toString() ?? '';
          if (delta.isNotEmpty) acc.buf.write(delta);
        case 'THINKING_TEXT_MESSAGE_END':
          if (!includeThinking) break;
          final id = ev['messageId']?.toString() ?? 'thinking';
          final acc = activeThinking.remove(id);
          if (acc != null && acc.buf.toString().trim().isNotEmpty) {
            out.add(SummarizableTurn(
              role: acc.role,
              text: acc.buf.toString().trim(),
              kind: TurnKind.thinking,
            ));
          }

        // ---- tool calls ----------------------------------------------------
        case 'TOOL_CALL_START':
          final id = ev['toolCallId']?.toString() ?? '';
          activeToolCalls[id] = _ToolCallAccumulator(
            name: ev['toolCallName']?.toString() ?? 'tool',
          );
        case 'TOOL_CALL_ARGS':
          final id = ev['toolCallId']?.toString() ?? '';
          final acc = activeToolCalls.putIfAbsent(
            id,
            () => _ToolCallAccumulator(name: 'tool'),
          );
          final delta = ev['delta']?.toString() ?? '';
          if (delta.isNotEmpty) acc.argsBuf.write(delta);
        case 'TOOL_CALL_END':
          final id = ev['toolCallId']?.toString() ?? '';
          final acc = activeToolCalls.remove(id);
          if (acc != null) {
            out.add(SummarizableTurn(
              role: 'assistant',
              text: '${acc.name}(${acc.argsBuf})',
              kind: TurnKind.toolCall,
              metadata: {
                'id': id,
                'name': acc.name,
                'arguments': acc.argsBuf.toString(),
              },
            ));
          }
        case 'TOOL_CALL_CHUNK':
          // Self-contained call: name + args in one event.
          final id = ev['toolCallId']?.toString() ?? '';
          final name = ev['toolCallName']?.toString() ?? 'tool';
          final args = ev['delta']?.toString() ?? '';
          out.add(SummarizableTurn(
            role: 'assistant',
            text: '$name($args)',
            kind: TurnKind.toolCall,
            metadata: {'id': id, 'name': name, 'arguments': args},
          ));
        case 'TOOL_CALL_RESULT':
          final name = ev['toolCallName']?.toString() ?? 'tool';
          final res = ev['content']?.toString() ?? '';
          out.add(SummarizableTurn(
            role: 'tool',
            text: '$name → $res',
            kind: TurnKind.toolResult,
            metadata: {
              if (ev['toolCallId'] != null) 'id': ev['toolCallId'],
              'name': name,
              'result': res,
            },
          ));

        // ---- state ---------------------------------------------------------
        case 'STATE_SNAPSHOT':
          final snap = ev['snapshot'];
          if (snap is Map<String, Object?>) lastState = snap;
        case 'STATE_DELTA':
          // Apply JSON-Patch-shaped deltas onto the running snapshot. We
          // keep this minimal — only `add`/`replace` ops on top-level keys
          // — because an exhaustive RFC 6902 implementation belongs in
          // an AG-UI client lib, not here. Out-of-spec ops are recorded
          // verbatim in metadata so nothing is silently dropped.
          final patch = ev['delta'];
          if (patch is List) {
            lastState ??= <String, Object?>{};
            for (final op in patch) {
              if (op is! Map) continue;
              final path = op['path']?.toString() ?? '';
              if (op['op'] == 'add' || op['op'] == 'replace') {
                final key = path.startsWith('/') ? path.substring(1) : path;
                if (!key.contains('/')) lastState[key] = op['value'];
              }
            }
          }
        // Some pipelines emit only deltas with no preceding snapshot —
        // we still want a state turn at the end if anything was set.
      }
    }

    if (lastState != null && lastState.isNotEmpty) {
      out.add(SummarizableTurn(
        role: 'system',
        text: 'state: $lastState',
        kind: TurnKind.state,
        metadata: {'snapshot': lastState},
      ));
    }
    return out;
  }
}

class _TextAccumulator {
  _TextAccumulator({required this.role});

  final String role;
  final StringBuffer buf = StringBuffer();
}

class _ToolCallAccumulator {
  _ToolCallAccumulator({required this.name});

  final String name;
  final StringBuffer argsBuf = StringBuffer();
}
