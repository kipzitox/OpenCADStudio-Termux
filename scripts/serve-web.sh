#!/bin/sh
# Serve the built web app from web-dist/ over loopback and open it in Chrome.
#
# Run from the OpenCADStudio source tree, or anywhere -- the script cds into
# web-dist itself. Serving from the wrong directory is the single most common
# way to get a blank canvas: the bundle asks for ./ocs.js, ./worker_pkg/... and
# ./fonts/... relative to the document, so those three must be siblings of
# index.html.
set -eu

PORT=8097
ROOT=./web-dist

[ -f "$ROOT/index.html" ] || {
	echo "no $ROOT/index.html. Build the web edition first:" >&2
	echo "  sh scripts/build-web.sh   (from the OpenCADStudio tree)" >&2
	exit 1
}

# Serving 71 MB of wasm over loopback is fine, but python's http.server is
# single-threaded: the browser opens several connections at once (wasm, then
# worker, then fonts) and a serialised one makes the page look stuck. That is
# why the launcher uses a threaded server when it can.
cd "$ROOT"

if command -v python3 >/dev/null 2>&1; then
	# ThreadedHTTPServer is what makes concurrent asset fetches not queue.
	exec python3 - "$PORT" <<-'PY'
		import functools, http.server, socketserver, sys
		port = int(sys.argv[1])
		class Handler(http.server.SimpleHTTPRequestHandler):
		    def log_message(self, *a):
		        pass
		class Server(socketserver.ThreadingTCPServer):
		    allow_reuse_address = True
		    daemon_threads = True
		with Server(("127.0.0.1", port), Handler) as httpd:
		    print(f"serving {port}", flush=True)
		    httpd.serve_forever()
	PY
else
	echo "python3 not found" >&2
	exit 1
fi