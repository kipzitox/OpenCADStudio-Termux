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
#     --skip-build    prepare everything but do not compile (useful for testing
#                     the setup, or if you want to compile later by hand)
#     --prefix DIR    container name, default: debian
#     -h, --help      this text
#
# What it does, in order:
#   1. preflight        Termux from F-Droid, free disk space, required packages
#   2. container        proot-distro container with a new enough Rust
#   3. source           upstream checkout, pinned to the tag the patches match
#   4. patches          0001 + 0002, which the builds need to work at all
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

for arg in "$@"; do
	case "$arg" in
		--web-only)    MODE=web ;;
		--native-only) MODE=native ;;
		--skip-build)  BUILD=0 ;;
		--prefix)      shift; DISTRO=${1:?--prefix needs a name} ;;
		-h|--help)     sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)             echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
	esac
	shift
done

PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
CONTAINER_ROOT="$PREFIX/var/lib/proot-distro/containers/$DISTRO/rootfs"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    AVISO: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n\n' "$*" >&2; exit 1; }
skip() { printf '    ya estaba: %s\n' "$*"; }

# Run a command inside the container through a *login* shell.
#
# The -l is not optional. A plain `sh -c` does not source /root/.cargo/env, so
# cargo resolves to /usr/bin/cargo (rustc 1.85) and the build dies with a wall
# of "requires rustc 1.9x" errors that read like a dependency problem but are
# only a PATH problem. Everything that compiles goes through here.
in_container() {
	proot-distro login "$DISTRO" -- /bin/sh -lc "$1"
}

# ---------------------------------------------------------------- 1. preflight
say "1/7  Comprobaciones previas"

for t in git pkg proot-distro; do
	command -v "$t" >/dev/null 2>&1 || die "$t no está instalado.
  Instala Termux desde F-Droid (la versión de Play Store está abandonada) y luego:
      pkg install $t"
done

# The Play Store build cannot run proot-distro and reports a much older prefix.
case "$PREFIX" in
	/data/data/com.termux/files/usr) : ;;
	*) warn "prefix inesperado: $PREFIX
    Si instalaste Termux desde otro sitio, dime cuál usaste: los scripts
    asumen el prefix estándar." ;;
esac

if [ -d "$PREFIX/etc/apt/sources.list.d" ] && \
   ! grep -rqs 'termux-x11' "$PREFIX/etc/apt/sources.list.d/"; then
	warn "el repo de X11 no está añadido.
    La edición nativa lo necesita. Añádelo con:
        pkg install x11-repo"
fi

# Android's df does not accept -P together with -m, so read POSIX output and
# convert from KB ourselves.
avail_kb=$(df -Pk "$PREFIX" 2>/dev/null | awk 'NR==2 {print $4}')
case "${avail_kb:-}" in
	''|*[!0-9]*) avail_kb=0 ;;
esac
avail_mb=$(( avail_kb / 1024 ))
if [ "$avail_mb" -lt "$MIN_FREE_MB" ]; then
	warn "quedan ${avail_mb} MB libres y harían falta unos $MIN_FREE_MB MB.
    El contenedor ocupa ~1.5 GB y cada compilación deja target/ en ~2 GB.
    Libera espacio antes de seguir o la compilación fallará a medias."
else
	note "espacio libre: ${avail_mb} MB"
fi

# Check for the *commands* these packages provide. termux-api installs
# termux-open-url, not a binary called termux-api, so test the commands.
note "paquetes de Termux que hacen falta"
missing=""
for t in xdotool python3 termux-open-url; do
	command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
	note "instalando:$missing"
	pkg install xdotool python termux-api >/dev/null 2>&1 || \
		warn "no pude instalarlos automáticamente; ejecuta:
        pkg install xdotool python termux-api"
else
	skip "xdotool, python3, termux-open-url"
fi
note "para la ventana nativa también hace falta la app Termux:X11 (APK aparte)"

# ---------------------------------------------------------------- 2. container
say "2/7  Contenedor proot ($DISTRO)"

if [ ! -d "$CONTAINER_ROOT" ]; then
	note "instalando el contenedor; esto descarga unos cientos de MB"
	proot-distro install "$DISTRO" || die "no se pudo instalar el contenedor $DISTRO"
else
	skip "contenedor $DISTRO"
fi

# Rust: Debian ships one that is too old for the dependency tree.
rust_minor=$(in_container 'rustc --version 2>/dev/null' | sed -n 's/.*rustc 1\.\([0-9]*\).*/\1/p' | head -1)
if [ -n "$rust_minor" ] && [ "$rust_minor" -ge "$MIN_RUST_MINOR" ] 2>/dev/null; then
	skip "rustc $(in_container 'rustc --version' | head -1)"
else
	note "instalando rustup (el rustc de Debian es demasiado antiguo)"
	in_container 'curl -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal' \
		|| die "falló la instalación de rustup"
	note "comprobando"
	in_container 'rustc --version' || die "rustc sigue sin aparecer tras instalar rustup"
fi

# ---------------------------------------------------------------- 3. source
say "3/7  Código fuente de OpenCADStudio ($UPSTREAM_TAG)"

if [ -d "$CONTAINER_ROOT$TREE_IN_CONTAINER/.git" ]; then
	skip "$TREE_IN_CONTAINER ya existe"
else
	note "clonando --depth 1 --branch $UPSTREAM_TAG (rápido, poco disco)"
	in_container "git clone --depth 1 --branch '$UPSTREAM_TAG' '$UPSTREAM_REPO' '$TREE_IN_CONTAINER'" \
		|| die "falló el clon de $UPSTREAM_REPO"
fi

# Detect whether the patches are already applied by trying to reverse them:
# `git apply --reverse --check` succeeds only when the change is present. This
# beats a marker flag, because it stays correct when someone applied the patches
# by hand (or a previous bootstrap run died before writing any marker).
patches_applied() {
	in_container "cd '$TREE_IN_CONTAINER' && git apply --reverse --check '$HERE/patches/0001-termux-web-and-mali.patch' >/dev/null 2>&1"
}

say "4/7  Parches de compatibilidad"
if patches_applied; then
	skip "parches ya aplicados"
else
	note "sin estos, el canvas sale en blanco y los .dxf se guardan como .txt"
	# cargo fetch first: apply-patches.sh vendors naga from the registry cache,
	# and an empty cache makes it stop with a message about cargo fetch.
	if [ "$BUILD" = 1 ]; then
		note "descargando dependencias de Cargo (una sola vez, varios cientos de MB)"
		in_container "cd '$TREE_IN_CONTAINER' && (cargo fetch --locked 2>/dev/null || cargo fetch)" \
			|| warn "cargo fetch devolvió error; si el paso de parches lo pide, reintenta"
	fi
	in_container "cd '$TREE_IN_CONTAINER' && sh '$HERE/patches/apply-patches.sh' ." \
		|| die "falló la aplicación de los parches

  Si el error menciona wasm-bindgen, winit o naga, casi siempre es que este
  checkout no corresponde a $UPSTREAM_TAG. Para empezar de cero:
      proot-distro login $DISTRO -- /bin/sh -lc \\
          'rm -rf $TREE_IN_CONTAINER && git clone --depth 1 --branch $UPSTREAM_TAG $UPSTREAM_REPO $TREE_IN_CONTAINER'
  y vuelve a ejecutar este script."
	note "comprobando"
	patches_applied || die "los parches parecían aplicados pero no lo están"
fi

# ------------------------------------------------------------------- builds
if [ "$BUILD" = 1 ]; then
	if [ "$MODE" != native ]; then
		say "5/7  Compilando la edición web (wasm, con GPU)"
		note "es la parte lenta: puede tardar 10-25 min según el dispositivo"
		note "si se corta, vuelve a ejecutar este script: continúa donde se quedó"
		if in_container "command -v wasm-bindgen >/dev/null 2>&1" ; then
			skip "wasm-bindgen ya instalado"
		else
			note "instalando wasm-bindgen-cli 0.2.108 (debe coincidir con la versión del crate)"
			in_container 'cargo install wasm-bindgen-cli --version 0.2.108 --locked' \
				|| die "falló la instalación de wasm-bindgen-cli
    Si el error habla de compilar, suele ser falta de espacio o de memoria."
		fi
		in_container "cd '$TREE_IN_CONTAINER' && sh '$HERE/scripts/build-web.sh'" \
			|| die "falló la compilación web; vuelve a ejecutar este script para reintentar"
		note "comprobando web-dist"
		in_container "test -f '$TREE_IN_CONTAINER/web-dist/index.html'" \
			|| die "la compilación terminó pero web-dist/index.html no existe"
		in_container "test -d '$TREE_IN_CONTAINER/web-dist/worker_pkg'" \
			|| warn "falta worker_pkg/; los DWG se quedarán colgados al 10%"
	else
		say "5/7  Compilación web omitida (--native-only)"
	fi

	if [ "$MODE" != web ]; then
		say "6/7  Compilando la edición nativa (glibc, sin GPU)"
		note "también lenta: 5-15 min"
		note "la app Termux:X11 puede necesitar estar abierta (ver README)"
		in_container "cd '$TREE_IN_CONTAINER' && sh '$HERE/scripts/build-native.sh'" \
			|| die "falló la compilación nativa; vuelve a ejecutar este script para reintentar"
	else
		say "6/7  Compilación nativa omitida (--web-only)"
	fi
else
	say "5-6/7  Compilación omitida (--skip-build)"
	note "para compilarla más tarde, sigue los pasos manuales del README"
fi

# ---------------------------------------------------------------- 7. launchers
say "7/7  Instalando los lanzadores"
sh "$HERE/scripts/install-launcher.sh" || warn "install-launcher.sh falló; puedes copiar los archivos a mano (ver README)"

# --------------------------------------------------------------------- done
cat <<EOF

$(printf '\033[1;32m')Instalación terminada.$(printf '\033[0m')

  Abre la app Termux:X11 en Android antes de usar la edición nativa; si no,
  la ventana sale a 1280x1024 o directamente no abre.

  Luego, desde Termux:

    opencadstudio          menú interactivo
    opencadstudio web      edición web en Chrome (GPU real)
    opencadstudio native   edición nativa en Termux:X11 (CPU)
    opencadstudio close    cerrar la ventana nativa

  Para comprobar la web:
    curl -sI http://localhost:8097     debe responder 200
EOF