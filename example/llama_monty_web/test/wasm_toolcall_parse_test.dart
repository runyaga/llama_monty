// Reproduces the WASM tool-call parse bug observed live in the chrome
// app on 2026-05-10:
//
//   On WASM, llamadart-web's grammar-dropped sampler doesn't recognize
//   Gemma 4's tool-call special-token format. The model still emits the
//   right text — `<|tool_call>call:run_bash{cmd:<|"|>echo 'hello'<|"|>}<tool_call|>` —
//   but llamadart returns `finishReason='stop'` with empty `toolCalls`.
//   Before the gate-relaxation fix in main.dart, the app rendered a
//   blank chat bubble because no fence matched and no tool was routed.
//
// This test feeds known WASM-style raw content into ChatTemplateEngine
// and asserts the parser CAN extract tool calls. If this test passes,
// the bug is purely the gate condition (which we relaxed). If it fails,
// the parser itself needs fixing in the llamadart fork.
//
// VM-only — exercises the Dart-side ChatTemplateEngine, no engine load.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

void main() {
  group('Gemma 4 tool-call special-token format parser', () {
    test('parses FFI-style JSON-arg form', () {
      const raw =
          '<|tool_call>call:run_bash{{"cmd":"echo \'hello\'"}}<tool_call|>';
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.gemma4.index,
        raw,
        parseToolCalls: true,
      );
      expect(parsed.hasToolCalls, isTrue,
          reason: 'FFI JSON-arg form should parse');
      expect(parsed.toolCalls.first.function?.name, 'run_bash');
    });

    test('parses WASM-style <|"|>-quoted-arg form (the live bug repro)',
        () {
      const raw =
          "<|tool_call>call:run_bash{cmd:<|\"|>echo 'hello'<|\"|>}<tool_call|>";
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.gemma4.index,
        raw,
        parseToolCalls: true,
      );

      // If this assertion fails, ChatTemplateEngine on WASM doesn't
      // recognize the format — the bug is in the llamadart fork, not
      // just main.dart's gate. We'd then need to either teach
      // ChatTemplateEngine the <|"|> token shape, or write a parallel
      // regex-based extractor in main.dart.
      expect(parsed.hasToolCalls, isTrue,
          reason: 'WASM <|"|>-quoted form should parse — if false, '
              'fix llamadart fork or add parallel extractor');
      expect(parsed.toolCalls.first.function?.name, 'run_bash');

      final args = parsed.toolCalls.first.function?.arguments;
      expect(args, isNotNull, reason: 'cmd argument must be extracted');
      if (args != null && args.isNotEmpty) {
        final decoded = jsonDecode(args);
        expect(
          decoded,
          isA<Map<String, Object?>>().having(
            (m) => m['cmd'],
            'cmd',
            "echo 'hello'",
          ),
        );
      }
    });

    test('parses multi-call WASM-style sequence', () {
      const raw =
          "<|tool_call>call:run_bash{cmd:<|\"|>cd /tmp/llama-test/fixtures<|\"|>}<tool_call|>"
          "<|tool_call>call:run_bash{cmd:<|\"|>pwd<|\"|>}<tool_call|>";
      final parsed = ChatTemplateEngine.parse(
        ChatFormat.gemma4.index,
        raw,
        parseToolCalls: true,
      );
      expect(parsed.hasToolCalls, isTrue);
      expect(parsed.toolCalls.length, greaterThanOrEqualTo(1),
          reason: 'should extract at least the first call; multi-call '
              'extraction is bonus');
    });
  });
}
