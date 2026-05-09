/// Native (FFI) implementation of the bash host factory.
///
/// Loads `libwasm_host.dylib` and `wasm_guest.wasm` directly from the
/// dart_wasm_sandbox's release-build paths. Until the spike publishes
/// or we add asset bundling, the path is hard-coded against the
/// developer's local checkout.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_wasm_sandbox/src/wasm_host_ffi.dart';
import 'package:dart_wasm_sandbox/dart_wasm_sandbox.dart';

const _spikeRoot = '/Users/runyaga/dev/dart_wasm_sandbox';
const _dylibPath = '$_spikeRoot/host/target/release/libwasm_host.dylib';
const _wasmPath =
    '$_spikeRoot/guest/target/wasm32-wasip1/release/wasm_guest.wasm';

Future<WasmHostBackend?> openOrNull() async {
  final dylib = File(_dylibPath);
  if (!dylib.existsSync()) return null;
  return WasmHostFfi.open(_dylibPath);
}

Future<Uint8List> loadGuestWasmBytes() async {
  final wasm = File(_wasmPath);
  if (!wasm.existsSync()) {
    throw StateError('wasm_guest.wasm not built at $_wasmPath');
  }
  return wasm.readAsBytesSync();
}
