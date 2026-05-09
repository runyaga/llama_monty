#!/usr/bin/env python3
"""Serve Flutter web build with Cross-Origin Isolation headers.

Needed for SharedArrayBuffer (llamadart WebGPU threading).
/models/ is served from ~/models/ so the 3.1 GB GGUF is not copied into build/.

Usage: python serve_coi.py [port]
"""
import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
BUILD_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build", "web")
MODELS_DIR = os.path.expanduser("~/models")


class COIHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=BUILD_DIR, **kwargs)

    def translate_path(self, path):
        # Serve /models/* (and the worker-relative /webgpu_bridge/models/* alias)
        # from ~/models/ so the 3 GB GGUF is never copied into build/.
        for prefix in ("/webgpu_bridge/models/", "/models/"):
            if path.startswith(prefix):
                filename = path[len(prefix):]
                return os.path.join(MODELS_DIR, filename)
        return super().translate_path(path)

    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "credentialless")
        super().end_headers()

    def log_message(self, fmt, *args):
        print(f"  {args[0]} {args[1]}")


print(f"Serving {BUILD_DIR}")
print(f"Models  {MODELS_DIR}  →  /models/")
print(f"Open:   http://localhost:{PORT}")
print("Ctrl-C to stop\n")
HTTPServer(("", PORT), COIHandler).serve_forever()
