"""Serve the built web bundle on 127.0.0.1:8080.

    python tool/serve_web.py

python -m http.server mostly works, but it does not know the .wasm MIME type
on every platform — drift's sqlite3.wasm must arrive as application/wasm.
"""
import http.server
import sys

PORT = 8080
ROOT = "build/web"


class Handler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
    sys.exit(0)
