#!/bin/sh
# Build the wasm (web) edition of OpenCADStudio into web-dist/.
#
# Run this from the OpenCADStudio source tree, inside the proot container:
#     sh /path/to/OpenCADStudio-Termux/scripts/build-web.sh
#
# Why this script exists instead of `trunk build`
# ------------------------------------------------
# Upstream builds the web app with trunk (see docs/native-vs-web.md). On a
# Termux/proot setup trunk does not run: its dependency tree pulls two
# incompatible `cssparser`/`cssparser` versions and the build dies resolving
# them. Rather than fight that, this script does what trunk would do, by hand:
#
#   1. cargo build the wasm binary
#   2. wasm-bindgen it to ocs.js + ocs_bg.wasm
#   3. build the DWG/DXF parse worker and wasm-bindgen it into worker_pkg/
#   4. copy the static assets from web/
#   5. drop in an index.html that loads the bundle
#
# Step 3 is the one that bites people. scripts/build-web-worker.sh in upstream
# needs $TRUNK_STAGING_DIR to know where to put worker_pkg/. Without trunk we
# set the destination ourselves. If worker_pkg/ is missing, the app loads and
# renders but opening a DWG hangs at ~10% forever, because the worker 404s.
set -eu

TARGET=wasm32-unknown-unknown
OUT=web-dist

command -v cargo >/dev/null 2>&1 || { echo "cargo not found" >&2; exit 1; }
command -v wasm-bindgen >/dev/null 2>&1 || {
	echo "wasm-bindgen not found. Install the CLI that matches the crate version:" >&2
	echo "  cargo install wasm-bindgen-cli --version 0.2.108 --locked" >&2
	exit 1
}
command -v python3 >/dev/null 2>&1 || { echo "python3 not found (needed to serve the app)" >&2; exit 1; }

[ -f Cargo.toml ] || { echo "run me from the OpenCADStudio source tree" >&2; exit 1; }

echo "==> rustup target add $TARGET"
rustup target add "$TARGET" >/dev/null 2>&1 || true

echo "==> building wasm binary"
cargo build --release --target "$TARGET" --bin OpenCADStudio

echo "==> wasm-bindgen -> $OUT"
mkdir -p "$OUT"
wasm-bindgen \
	--target web \
	--out-dir "$OUT" \
	--out-name ocs \
	"target/$TARGET/release/OpenCADStudio.wasm"

echo "==> building parse worker"
cargo build --locked --release --target "$TARGET" --package ocs_web_worker
mkdir -p "$OUT/worker_pkg"
wasm-bindgen \
	--target web \
	--out-dir "$OUT/worker_pkg" \
	--out-name ocs_web_worker \
	"target/$TARGET/release/ocs_web_worker.wasm"

echo "==> copying web assets"
# Fonts are needed at runtime; the JSON files drive the splash/locale picker.
mkdir -p "$OUT/fonts"
cp -r web/fonts/. "$OUT/fonts/" 2>/dev/null || true
for f in ocs-parse-worker.js discussions.json videos.json locale-labels.json clipboard.js; do
	[ -f "web/$f" ] && cp "web/$f" "$OUT/$f"
done
# logo for the favicon, if the source tree has it
[ -f assets/logo.svg ] && cp assets/logo.svg "$OUT/logo.svg"

echo "==> index.html"
# Copy the hand-written bootstrap from the guide repo next to us, if present.
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$here/../web/index.html" ]; then
	cp "$here/../web/index.html" "$OUT/index.html"
else
	echo "    !! no index.html found; copy $here/../web/index.html to $OUT/index.html by hand" >&2
	echo "    !! trunk is not usable here (cssparser conflict), so nothing generated it for you" >&2
fi

echo
echo "Built. Serve it with:"
echo "  python3 -m http.server 8097 --bind 127.0.0.1 --directory $OUT"
echo
echo "Reminder: http.server must be started from inside $OUT, or the wasm,"
echo "worker_pkg/ and fonts/ 404 and the app opens blank / DWG hangs at 10%."