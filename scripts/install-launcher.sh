#!/bin/sh
# Install the launcher scripts from this repo into the Termux prefix.
#
# Run from *Termux*, not from inside the proot container:
#     sh /path/to/OpenCADStudio-Termux/scripts/install-launcher.sh
#
# Files land at:
#   $PREFIX/bin/ocs            native launcher
#   $PREFIX/bin/opencadstudio  menu launcher (web / native / close / stop)
#   $PREFIX/lib/ocs-termux.sh  shared helper (X11, WM, proot exec)
#   $PREFIX/lib/ocs-perf.scr   sysvar tweaks applied at every native launch
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$here/termux"
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}

[ -d "$src" ] || { echo "termux/ not found next to this script" >&2; exit 1; }

echo "==> prefix: $PREFIX"
mkdir -p "$PREFIX/bin" "$PREFIX/lib"

echo "==> installing launchers"
cp "$src/ocs"           "$PREFIX/bin/ocs"
cp "$src/opencadstudio" "$PREFIX/bin/opencadstudio"
cp "$src/ocs-termux.sh" "$PREFIX/lib/ocs-termux.sh"
cp "$src/ocs-perf.scr"  "$PREFIX/lib/ocs-perf.scr"
chmod +x "$PREFIX/bin/ocs" "$PREFIX/bin/opencadstudio"

echo "==> X11 socket directory"
# proot-distro --shared-x11 binds this into the container. Missing => the guest
# cannot open :0 and the app panics with XOpenDisplayFailed.
mkdir -p "$PREFIX/tmp/.X11-unix"

echo "==> checking for tools the launchers rely on"
missing=
# termux-api provides termux-open-url, not a binary called termux-api.
for t in xdotool python3 termux-open-url; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
	echo "    missing:$missing"
	echo "    install with: pkg install xdotool python termux-api"
fi

# The package is called termux-x11-nightly but the binary it installs is
# termux-x11. Getting this backwards is a common and confusing dead end, so
# point at it explicitly rather than leaving the user to guess.
if ! command -v termux-x11 >/dev/null 2>&1; then
	echo "    note: no 'termux-x11' binary found."
	echo "          The package is named termux-x11-nightly, the command is not:"
	echo "              pkg install x11-repo && pkg install termux-x11-nightly"
fi

echo
echo "Done. Try:"
echo "  opencadstudio          menu"
echo "  opencadstudio web      web build in Chrome"
echo "  opencadstudio native   window in Termux:X11"
echo
echo "The native build additionally needs the Termux:X11 app running, and the"
echo "native binary itself to exist in the container at /usr/local/bin/ocs"