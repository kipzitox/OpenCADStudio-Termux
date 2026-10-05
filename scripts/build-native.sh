#!/bin/sh
# Build the native (glibc) edition of OpenCADStudio and link it where the
# Termux launcher expects to find it.
#
# Run this from the OpenCADStudio source tree, inside the proot container.
# Use a *login* shell so /root/.cargo/env is sourced and you get rustup's
# rustc (1.99) rather than Debian's /usr/bin/rustc (1.85), which is too old:
#
#     proot-distro login debian -- /bin/sh -lc 'sh /path/to/build-native.sh'
#
# A non-login `sh -c` picks /usr/bin/cargo and fails with
#   "error: rustc 1.85.1 is not supported by the following packages"
# which looks like a dependency problem but is really a PATH problem.
set -eu

BIN_SRC=OpenCADStudio
BIN_DST=/usr/local/bin/ocs

[ -f Cargo.toml ] || { echo "run me from the OpenCADStudio source tree" >&2; exit 1; }

case "$(rustc --version | cut -d' ' -f2)" in
	1.7* | 1.8[0-5]*)
		echo "WARNING: rustc $(rustc --version) is too old for the dependency tree." >&2
		echo "         Run this from a login shell (sh -lc) so rustup's rustc is used." >&2
		;;
esac

echo "==> cargo build --release --bin $BIN_SRC"
cargo build --release --bin "$BIN_SRC"

out=target/release/$BIN_SRC
[ -x "$out" ] || { echo "expected binary missing: $out" >&2; exit 1; }

echo "==> linking $out -> $BIN_DST"
ln -sfn "$PWD/$out" "$BIN_DST"
ls -l "$BIN_DST"

echo
echo "Native binary ready. Launch it from Termux (not from inside the container):"
echo "  ocs"
echo "or pick the native option from the menu:"
echo "  opencadstudio"