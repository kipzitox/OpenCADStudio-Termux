#!/data/data/com.termux/files/usr/bin/sh
# Shared environment for the ocs-* launchers.
#
# Open CAD Studio is a glibc/Linux build that runs on Termux through
# proot-distro (Debian) plus Termux:X11.  Sourced by the ocs, ocs-api,
# ocs-mcp and ocs-convert commands; not meant to be run directly.

OCS_DISTRO="${OCS_DISTRO:-debian}"
OCS_BIN="${OCS_BIN:-/usr/local/bin/ocs}"
# OCS_BACKEND is intentionally unset by default; see ocs_run.

# The container has to exist and hold the binary before any of this is useful.
#
# Both checks run *inside* the guest: $OCS_BIN is a container path, so testing
# it on the host would always fail.  proot-distro prints its container list on
# stderr, hence 2>&1 around it.
ocs_need_distro() {
    if ! proot-distro list 2>&1 | grep -qE "^[[:space:]]*[*]?[[:space:]]*$OCS_DISTRO[[:space:]]*$"; then
        echo "ocs: proot container '$OCS_DISTRO' not installed." >&2
        echo "ocs: run  proot-distro install $OCS_DISTRO  once, then retry." >&2
        exit 1
    fi
    if ! proot-distro login "$OCS_DISTRO" -- test -x "$OCS_BIN" >/dev/null 2>&1; then
        echo "ocs: $OCS_BIN missing or not executable inside the container." >&2
        echo "ocs: create it with:" >&2
        echo "      proot-distro login $OCS_DISTRO -- \\" >&2
        echo "        ln -sfn /root/OpenCADStudio/target/release/OpenCADStudio $OCS_BIN" >&2
        exit 1
    fi
}

# Start Termux:X11 if it is not already serving the display we want.
#
# Liveness is decided by asking Xlib directly (via xdotool), never by testing a
# filesystem socket path and never by matching the process table.
#
# Two reasons the old path test was wrong on Android/Termux:
#   * Termux:X11 rewrites its own command line to
#     "termux-x11 com.termux.x11 :0 -legacy-drawing", so a pgrep pattern on the
#     invocation we issued does not match it.
#   * The server listens on an *abstract* unix socket, so there is no
#     $PREFIX/tmp/.X11-unix/X0 file at all. The old `[ -S "$sock" ]` check
#     therefore always failed on a live server, and ocs_ensure_x11 would try to
#     start a duplicate, which then aborts with "server already running" and
#     the launch failed with "Termux:X11 did not come up". Xlib (xdotool)
#     resolves the abstract socket, so asking it is the portable liveness test.
ocs_x11_alive() {
    DISPLAY=":${OCS_DISPLAY_NUM:-0}" xdotool getdisplaygeometry >/dev/null 2>&1
}

ocs_ensure_x11() {
    if ocs_x11_alive; then
        return 0
    fi
    echo "ocs: starting Termux:X11 on :${OCS_DISPLAY_NUM:-0} ..." >&2
    # -legacy-drawing is required: the default indirect GLX path needs a GPU we
    # do not have, and on this device the server refuses to start without it.
    # Note there is no -screen flag; Termux:X11 rejects it as an unrecognised
    # option.
    #
    # -fakescreenfps was tried here (60 and 120) on the theory that the editor
    # throttles to the reported frame rate. It does not help: median GUI-hosted
    # latency was 163 ms with -fakescreenfps 60 versus 155 ms without, i.e. the
    # same within noise, while the tail got worse. Left off deliberately.
    setsid termux-x11 ":${OCS_DISPLAY_NUM:-0}" -legacy-drawing \
        >"$PREFIX/tmp/ocs-termux-x11.log" 2>&1 < /dev/null &
    ocs_wait_x11
}

# A window manager is what makes the editor actually fill the screen.
#
# Termux:X11 runs a bare X server with no WM, and that breaks two things:
#   - `window::Settings { maximized: true }` is a no-op, because there is nobody
#     to honour the request, so the editor kept its 1024x768 default and you
#     saw a corner of it;
#   - input focus is unmanaged, which makes pointer input unreliable.
#
# matchbox-window-manager is a few hundred KB and built for exactly this kind
# of small embedded display. With it running the editor maximises itself and
# input focus behaves.
ocs_ensure_wm() {
    if proot-distro login "$OCS_DISTRO" --shared-x11 -e "DISPLAY=:${OCS_DISPLAY_NUM:-0}" -- \
        sh -c 'ps -eo comm= | grep -qx matchbox-window' >/dev/null 2>&1; then
        return 0
    fi
    setsid proot-distro login "$OCS_DISTRO" --shared-x11 -e "DISPLAY=:${OCS_DISPLAY_NUM:-0}" -- \
        matchbox-window-manager -use_titlebar no \
        >"$PREFIX/tmp/ocs-wm.log" 2>&1 < /dev/null &
    # Give it a moment; the editor asks to maximise during its first frame, so
    # the WM has to be up before the window maps or the request is lost.
    sleep 2
}

# Poll until the server answers on its socket.  Startup is a few seconds: the
# server opens the socket and then has to finish probing DRI before it will
# service a connection, and winit gives up if we hand it a half-open display.
ocs_wait_x11() {
    _i=0
    while [ "$_i" -lt 60 ]; do
        if ocs_x11_alive; then
            return 0
        fi
        sleep 0.5
        _i=$((_i + 1))
    done
    echo "ocs: Termux:X11 did not come up; see $PREFIX/tmp/ocs-termux-x11.log" >&2
    exit 1
}

# exec the editor inside proot.
#
#   --shared-x11  binds $PREFIX/tmp/.X11-unix over the guest's /tmp/.X11-unix
#                 so winit's X11 backend can reach the Termux:X11 server.
#   -e DISPLAY    proot-distro does NOT forward the host DISPLAY into the
#                 guest, so winit would otherwise start with an empty display
#                 and fail to connect.
#
# Do NOT force WGPU_BACKEND by default.
#
# An earlier version of this file pinned WGPU_BACKEND=vulkan here, on the theory
# that the app's probe "failing" was a bug. It is not: the only Vulkan device
# available is Mesa's lavapipe, a CPU rasteriser, and the app deliberately
# rejects software adapters so it can pick its *packed* renderer
# (gpu_backend.rs: "Software rasterizers always take it ... these GPUs are slow
# enough already"). Forcing the backend skipped that decision and handed a
# software rasteriser the heavier storage-buffer pipeline -- the opposite of
# what a slow device wants.
#
# So the backend is only pinned when you ask for it explicitly:
#   OCS_BACKEND=vulkan ocs ...
# Leaving it unset lets gpu_backend.rs choose, which is what you want here.
#
# LP_NUM_THREADS defaults to 4, which measured 2.5x FASTER than 1 thread
# on this device. (An earlier note here claimed 1 thread was fastest; that
# came from reading `user`/`sys` CPU time instead of wall-clock frame time,
# and it was wrong. llvmpipe scales properly here, so give it cores.)
#
# Measured end-to-end per frame, fullscreen canvas 4.14 Mpx, the
# page-setups-metric.dxf fixture (1446 entities), median of 9 runs:
#
#   threads | ms/frame | fps
#   --------+----------+-----
#        1  |      1091 |  0.92
#        2  |       892 |  1.12
#        4  |   428 |  2.33   <- default
#        8  |       472 |  2.12
#
# 8 is slower than 4: past four, the rasteriser threads contend with the
# UI/iced threads for the same eight cores, and every extra thread adds
# proot's ptrace syscall interception. Four leaves headroom for the UI,
# which is what has to stay responsive.
#
# Override with OCS_LP_THREADS to compare (1..8).
ocs_run() {
    ocs_need_distro
    _lp="${OCS_LP_THREADS:-4}"
    if [ -n "${OCS_BACKEND:-}" ]; then
        exec proot-distro login "$OCS_DISTRO" --shared-x11 -e "DISPLAY=:${OCS_DISPLAY_NUM:-0}" -- \
            env "LP_NUM_THREADS=$_lp" "WGPU_BACKEND=$OCS_BACKEND" "$OCS_BIN" "$@"
    fi
    exec proot-distro login "$OCS_DISTRO" --shared-x11 -e "DISPLAY=:${OCS_DISPLAY_NUM:-0}" -- \
        env "LP_NUM_THREADS=$_lp" "$OCS_BIN" "$@"
}

# Grow the editor window to the full X display, in the background.
#
# This has to be a *child process started before ocs_run*, because ocs_run
# execs: every line after an exec call in the caller is dead code, never
# reached.  The watcher outlives that exec because it is a separate process,
# which is the only way to act on the window once the editor owns the tty.
#
# The app asks for `maximized: true` but lands on a fixed 1024x768 instead,
# because iced's initial window::Settings has no size and the winit maximise
# request lands before the X server has settled.  Asking explicitly afterwards
# is what sticks.
#
# Windows already on the display are recorded first and then skipped, so a
# second editor opening a tab resizes its *own* window instead of re-resizing
# whichever window happens to sort first.
#
# Size comes from the live display rather than a hardcoded 1232x715, so a
# Termux:X11 reconfigured to another resolution is handled without edits.
ocs_watch_resize() {
    _pid="$$"
    (
        _i=0
        while [ "$_i" -lt 60 ]; do
            _g="$(xdotool getdisplaygeometry 2>/dev/null)"
            for _w in $(xdotool search --class OpenCADStudio 2>/dev/null); do
                # Match on owning process, never on the window id: X recycles
                # resource ids, so a relaunched editor comes back with the SAME
                # id. An earlier version snapshotted existing ids and skipped
                # them, which meant every relaunch was skipped and the window
                # stayed at the default 1024x768.
                _owner="$(xdotool getwindowpid "$_w" 2>/dev/null)"
                [ -n "$_owner" ] || continue
                [ "$_owner" = "$_pid" ] && continue
                case "$(ps -o comm= -p "$_owner" 2>/dev/null)" in
                    *OpenCADStudio*)
                        # Keep re-checking, and only stop once the window
                        # actually matches the display. The display grows from
                        # the 1280x1024 fallback to the panel's real size only
                        # when the Termux:X11 app connects, which is usually
                        # *after* the editor has already mapped its window. A
                        # one-shot resize fired at launch therefore left the
                        # window at 1024x768 and the user saw a corner of it.
                        if [ -n "$_g" ]; then
                            _cur="$(xdotool getwindowgeometry "$_w" 2>/dev/null \
                                    | sed -n 's/.*Geometry: *\([0-9]*\)x\([0-9]*\).*/\1x\2/p')"
                            [ "$_cur" = "$(echo "$_g" | tr ' ' x)" ] && exit 0
                            xdotool windowsize "$_w" $_g 2>/dev/null
                        fi
                        ;;
                esac
            done
            sleep 2
            _i=$((_i + 1))
        done
    ) >/dev/null 2>&1 &
}
