#!/bin/sh
# Apply the Termux/Android compatibility patches to an OpenCADStudio checkout.
#
# Run from the root of an OpenCADStudio source tree:
#     sh /path/to/apply-patches.sh
#
# Order matters. 0001 carries the `[patch]` stanza that points Cargo at
# vendor/naga and drops `smol` from the wasm target; 0002 rewrites a file
# inside vendor/naga, so the tree has to exist and 0001 has to have landed
# first. This script vendors naga 29.0.4 from the Cargo registry cache between
# the two, which is why 0002 is a single-file diff rather than a whole-tree one.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=${1:-.}

if [ ! -f "$root/Cargo.toml" ]; then
	echo "apply-patches: $root does not look like an OpenCADStudio checkout" >&2
	echo "  (no Cargo.toml there). Pass the path as the first argument." >&2
	exit 1
fi
cd "$root"

command -v git >/dev/null 2>&1 || {
	echo "apply-patches: git is required" >&2
	exit 1
}

# Re-running is a normal thing to do (an install that failed halfway gets
# retried), and applying twice is not an error worth a wall of hunk failures.
# `git apply --reverse --check` succeeds only if the change is already there.
if git apply --reverse --check "$here/0001-termux-web-and-mali.patch" >/dev/null 2>&1; then
	echo "==> 0001-termux-web-and-mali"
	echo "    ya aplicado, nada que hacer"
else
	echo "==> 0001-termux-web-and-mali"
	git apply --check "$here/0001-termux-web-and-mali.patch"
	git apply "$here/0001-termux-web-and-mali.patch"
	echo "    ok"
fi

NAGA_VER=29.0.4

# Vendor naga 29.0.4 pristine, exactly as Cargo.toml now expects it, so that
# 0002 has something to apply to. Prefer the already-downloaded registry copy;
# fall back to letting Cargo fetch it by resolving the (vendored) path dep.
if [ ! -d vendor/naga ]; then
	echo "==> vendoring naga $NAGA_VER into vendor/naga"
	mkdir -p vendor
	src=$(ls -d "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/naga-$NAGA_VER 2>/dev/null | head -n1 || true)
	if [ -n "$src" ]; then
		cp -r "$src" vendor/naga
	else
		echo "    not in the registry cache; run 'cargo fetch' first, then re-run this script" >&2
		exit 1
	fi
fi

echo "==> 0002-naga-glsl-array-elementwise"
if git apply --reverse --check "$here/0002-naga-glsl-array-elementwise.patch" >/dev/null 2>&1; then
	echo "    ya aplicado, nada que hacer"
else
	git apply --check "$here/0002-naga-glsl-array-elementwise.patch"
	git apply "$here/0002-naga-glsl-array-elementwise.patch"
	echo "    ok"
fi

echo
echo "Both patches applied. Next, depending on what you want to run:"
echo "  native:  cargo build --release --bin OpenCADStudio"
echo "  web:     scripts/build-web.sh from this repo"