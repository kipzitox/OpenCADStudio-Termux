#!/bin/sh
# Install OpenCADStudio on Android/Termux.
#
# Run this from Termux (not from inside the proot container):
#
#     sh bootstrap.sh
#
# It is idempotent: every step checks before it acts, so re-running it after a
# failure resumes instead of starting over. That matters because the builds take
# a while and phones run out of battery, not disk.
#
# Options:
#     --web-only      build only the web edition (GPU; the one most people want)
#     --native-only   build only the native edition (CPU; needs Termux:X11)
#     --skip-build    prepare everything but do not compile; still downloads
#                     Cargo dependencies (the patches need them)
#     --prefix NAME   name of the proot-distro container (default: debian)
#     --distro NAME   alias for --prefix
#     --container NAME
#                     alias for --prefix
#     -h, --help      this text
#
# What it does, in order:
#   1. preflight        Termux from F-Droid, free disk space, required packages
#   2. container        proot-distro container with a new enough Rust
#   3. source           upstream checkout, pinned to the tag the patches match
#   4. patches          0001-0003, which the builds need to work at all
#   5. web build        wasm, served to Chrome -- this is the GPU path
#   6. native build     glibc binary, software rendered into Termux:X11
#   7. launchers        `opencadstudio` into $PREFIX/bin
#
# After it finishes:
#     opencadstudio web       # or `opencadstudio` for the menu
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Upstream tag the patches were written and tested against. Changing this
# without re-testing the patches will break the build in confusing ways.
UPSTREAM_REPO=https://github.com/HakanSeven12/OpenCADStudio.git
UPSTREAM_TAG=v2026.39
# Where the tree must live. Not arbitrary: the launchers look for the binary at
# /usr/local/bin/ocs in the container, symlinked from /root/OpenCADStudio.
TREE_IN_CONTAINER=/root/OpenCADStudio
MIN_RUST_MINOR=92
# container ~1.5 GB, wasm target/ ~2 GB, native release target/ ~2 GB
MIN_FREE_MB=6000

MODE=both
BUILD=1
DISTRO=debian

while [ $# -gt 0 ]; do
	arg=$1
	case "$arg" in
		--web-only)    MODE=web ;;
		--native-only) MODE=native ;;
		--skip-build)  BUILD=0 ;;
		--prefix|--distro|--container)
			shift
			[ $# -gt 0 ] || { echo "error: $arg necesita un nombre de contenedor" >&2; exit 2; }
			DISTRO=$1 ;;
		-h|--help)     sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
	esac
	shift
done

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}