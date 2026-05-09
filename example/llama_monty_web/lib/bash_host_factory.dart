/// Cross-platform opener for the wasmtime-spike `WasmHostBackend`.
///
/// `openWasmHost()` from `package:wasm_host_dart` works fine on web
/// (no dylib needed) but on native it tries to load the dylib via a
/// relative `defaultLibraryPath(repoRoot: '..')` that's wrong from
/// the Flutter app's cwd. This file paves over that with a platform-
/// split factory:
///
///   - native:  imports `wasm_host_ffi.dart` directly and constructs
///              `WasmHostFfi.open(absolutePath)` with the real path
///              to `libwasm_host.dylib`.
///   - web:     just delegates to `openWasmHost()`.
///
/// Until the wasmtime-spike publishes (or we wire bundling), the
/// native path is hard-coded. Returns `null` if the dylib/wasm
/// artefacts aren't available — caller logs and skips registration.
library;

import 'dart:typed_data';

import 'package:wasm_host_dart/wasm_host.dart';

import 'bash_host_factory_io.dart' if (dart.library.js_interop) 'bash_host_factory_web.dart' as platform;

/// Opens the WasmHostBackend if the platform's artefacts are
/// available; returns null otherwise.
Future<WasmHostBackend?> openBashHostOrNull() => platform.openOrNull();

/// Loads `wasm_guest.wasm` bytes for the platform.
Future<Uint8List> loadGuestWasmBytes() => platform.loadGuestWasmBytes();
