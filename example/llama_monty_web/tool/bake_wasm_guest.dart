// Bakes assets/wasm_guest.wasm into test/support/wasm_guest_bytes.g.dart
// for browser-side integration tests that cannot fetch the asset
// directly via flutter test --platform chrome.
//
// Run from example/llama_monty_web/:
//   dart tool/bake_wasm_guest.dart

import 'dart:convert';
import 'dart:io';

void main() {
  final src = File('assets/wasm_guest.wasm');
  if (!src.existsSync()) {
    stderr.writeln('assets/wasm_guest.wasm not found');
    exit(2);
  }
  final bytes = src.readAsBytesSync();
  final b64 = base64.encode(bytes);

  final buf = StringBuffer()
    ..writeln('// GENERATED FILE — do not edit by hand.')
    ..writeln('//')
    ..writeln('// Base64-encoded bytes of `assets/wasm_guest.wasm` for')
    ..writeln('// browser-side integration tests that cannot fetch the asset')
    ..writeln('// directly. `flutter test --platform chrome` does not serve')
    ..writeln('// `assets/` to the test runner. Mirrors the upstream pattern')
    ..writeln('// at dart_wasm_sandbox/dart/test/support/echo_wasm_bytes.g.dart.')
    ..writeln('//')
    ..writeln('// Regenerate with: dart tool/bake_wasm_guest.dart')
    ..writeln('library;')
    ..writeln()
    ..writeln("import 'dart:convert';")
    ..writeln("import 'dart:typed_data';")
    ..writeln()
    ..writeln('/// Decoded bytes of `assets/wasm_guest.wasm`')
    ..writeln('/// (${bytes.length} bytes, base64-encoded as ${b64.length} chars).')
    ..writeln('final Uint8List wasmGuestBytes = base64Decode(_b64);')
    ..writeln()
    ..writeln('const String _b64 =');
  for (var i = 0; i < b64.length; i += 76) {
    final end = (i + 76 < b64.length) ? i + 76 : b64.length;
    buf.write("    '${b64.substring(i, end)}'");
    if (end < b64.length) {
      buf.writeln();
    } else {
      buf.writeln(';');
    }
  }

  final out = File('test/support/wasm_guest_bytes.g.dart');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(buf.toString());
  stdout.writeln(
    'wrote ${out.path} (${bytes.length} bytes → ${b64.length} b64 chars)',
  );
}
