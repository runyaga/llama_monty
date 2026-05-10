/// Web (browser-native WebAssembly) implementation of the bash host
/// factory. Uses `openWasmHost()` from `wasm_host_dart` directly —
/// no dylib needed, the chrome backend implements the host imports
/// in pure Dart.
///
/// `wasm_guest.wasm` is bundled as a Flutter asset and loaded via
/// `rootBundle.load`. Until that asset is registered we return an
/// empty Uint8List and openOrNull throws — caller logs and skips
/// registration.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';

const _wasmAssetKey = 'assets/wasm_guest.wasm';

Future<WasmHost?> openOrNull() async {
  try {
    return await WasmHost.open();
  } on Object {
    return null;
  }
}

Future<Uint8List> loadGuestWasmBytes() async {
  final data = await rootBundle.load(_wasmAssetKey);
  return data.buffer.asUint8List();
}
