# Open CAD Studio on Android with Termux

How to run [Open CAD Studio](https://github.com/HakanSeven12/OpenCADStudio) on
an Android phone or tablet under Termux. There are two ways, and both work:

- **web** — the wasm build in Chrome. **This is the one that uses the real GPU.**
- **native** — the glibc build inside a proot container, drawn into Termux:X11.
  It works, but it renders on the CPU.

> [Versión en español](README.md)

Licensed GPL-3.0, matching the original project. See [LICENSE](LICENSE).

## At a glance

| | Web (Chrome) | Native (proot + Termux:X11) |
|---|---|---|
| GPU | **Real** — ANGLE on the Mali GPU | None; llvmpipe on the CPU |
| Windowing | Chrome tab / PWA | Termux:X11 window + matchbox |
| Build | `wasm32-unknown-unknown`, ~71 MB wasm | `aarch64-unknown-linux-gnu` (glibc) |
| Speed | Smooth | Slow; see [Performance](#performance) |
| Hatch rendering | Not drawn (WebGL2 has no vertex storage buffers) | Drawn |
| DWG/DXF open | Yes, via the parse worker | Yes |
| Native plugins | No (browsers cannot load native libs) | Yes |

If you want the GPU, use **web**. That is the whole story on Android: proot
cannot reach the phone's GPU, so the native build is always software. The reason
is explained in [Why there is no GPU in the native build](#why-there-is-no-gpu-in-the-native-build).

## Screenshots

### Native edition inside Termux:X11

![The native build running in a Termux:X11 window, with the Properties panel open on the left, the editor's tab bar across the top, and the Android key row below the window.](docs/screenshots/native-termux-x11.jpg)

A screenshot of the **native** edition: a real Termux:X11 window on Android, with
the drawing loaded and the Properties panel open. You can see the key row
(`ESC`, `CTRL`, `ALT`, `HOME`) under the window — that is Termux mapping the
physical keyboard into the app.

## Requirements

- **Termux installed from F-Droid.** The Play Store build is unmaintained and too
  old for `proot-distro`.
- **The Termux:X11 app** (a separate APK). Only needed for the native build.
- **Chrome** on the device, for the web build.
- **~6 GB free.** The proot container takes ~1.5 GB and each build leaves a
  `target/` of ~2 GB.

## Quick install

In **Termux**, copy and paste this:

```sh
pkg install x11-repo
pkg install git proot-distro python termux-api xdotool
pkg install termux-x11-nightly
```

> **Mind the X11 package name.** The package is called `termux-x11-nightly`, but
> the command it installs is `termux-x11`. Typing `termux-x11-nightly` as a
> command **fails**.

`matchbox-window-manager` is optional but recommended: without it the window
still works, just without tiling or fullscreen control.

```sh
pkg install matchbox-window-manager
```

Now the full install:

```sh
git clone https://github.com/kipzitox/OpenCADStudio-Termux.git
sh OpenCADStudio-Termux/bootstrap.sh
```

That installs the container, Rust, clones OpenCADStudio, applies the patches,
builds both editions and makes the `opencadstudio` command available. **It takes
15-30 minutes** depending on the device.

If it gets cut short (battery dies, you close Termux), run the same command
again: it resumes where it left off instead of starting over.

### `bootstrap.sh` options

```sh
sh OpenCADStudio-Termux/bootstrap.sh --web-only     # web only (GPU)
sh OpenCADStudio-Termux/bootstrap.sh --native-only  # native only
sh OpenCADStudio-Termux/bootstrap.sh --skip-build   # prepare, do not compile
```

## Commands

Once installed:

```sh
opencadstudio          # interactive menu
opencadstudio web      # web build in Chrome (real GPU)
opencadstudio native   # native window in Termux:X11
opencadstudio native plan.dxf   # open a specific file
opencadstudio close    # close the native window
opencadstudio stop     # stop the web server
```

The menu offers web, native, close and exit.

Note that the menu labels themselves are in Spanish (`Web`, `Nativo`, `Cerrar`,
`Salir`) — they are kept that way because the guide and the launcher were
written for a Spanish-speaking audience.

## Verify it works

**Web:**

```sh
opencadstudio web
curl -sI http://localhost:8097     # must reply 200 OK
```

A Chrome tab should open with the editor and the GPU active. To confirm the GPU
is in use, `chrome://gpu` should list a Mali renderer via ANGLE.

**Native:**

```sh
opencadstudio native
```

A window titled `Open CAD Studio 2026.39 - Start` should appear.

> **Open the Termux:X11 app on Android first.** The X11 server on its own gives
> you a black 1280x1024 screen. Open the app and the window takes the panel's
> real size.

## Manual steps

If you would rather see what each step does, or something failed and you want to
understand why. Every block is copy-pasteable as-is.

These commands run **inside the container**, which is why they carry the
`proot-distro login debian -- /bin/sh -lc`. The `-lc` is not optional: a plain
`sh -c` does not load `/root/.cargo/env`, so `cargo` resolves to Debian's
`rustc 1.85` and the build dies with a wall of `requires rustc 1.9x` errors that
look like a dependency problem but are a `PATH` problem.

### 1. Container and Rust

```sh
pkg install proot-distro
proot-distro install debian

proot-distro login debian -- /bin/sh -lc 'curl https://sh.rustup.rs -sSf | sh -s -- -y'
proot-distro login debian -- /bin/sh -lc 'rustc --version'   # want >= 1.92
```

### 2. Source, at the right version

The patches in this repo target `v2026.39`. Pinning the version matters: if you
clone `main` in a few months the patches will stop applying, or worse, apply
wrongly.

```sh
proot-distro login debian -- /bin/sh -lc \
  'git clone --depth 1 --branch v2026.39 https://github.com/HakanSeven12/OpenCADStudio.git /root/OpenCADStudio'
```

### 3. Patches

```sh
proot-distro login debian -- /bin/sh -lc \
  'cd /root/OpenCADStudio && sh /path/to/OpenCADStudio-Termux/patches/apply-patches.sh .'
```

Replace `/path/to/OpenCADStudio-Termux` with wherever you cloned this guide. If
`apply-patches.sh` says it cannot find naga in the Cargo cache, run `cargo fetch`
inside the container and repeat.

See [PATCHES.md](PATCHES.md) for what each patch does and why.

### 4. Build the web edition

First `wasm-bindgen-cli`, which must match the crate version (0.2.108 at
`v2026.39`):

```sh
proot-distro login debian -- /bin/sh -lc \
  'cargo install wasm-bindgen-cli --version 0.2.108 --locked'
```

Then the build:

```sh
proot-distro login debian -- /bin/sh -lc \
  'cd /root/OpenCADStudio && sh /path/to/OpenCADStudio-Termux/scripts/build-web.sh'
```

> Why not `trunk`? Upstream uses it, and it does not run here: its dependency
> tree pulls two incompatible `cssparser` versions and the build dies resolving
> them. `build-web.sh` does by hand what `trunk` would do.

### 5. Build the native edition

```sh
proot-distro login debian -- /bin/sh -lc \
  'cd /root/OpenCADStudio && sh /path/to/OpenCADStudio-Termux/scripts/build-native.sh'
```

### 6. Launchers

```sh
sh /path/to/OpenCADStudio-Termux/scripts/install-launcher.sh
```

## Performance

The native build is CPU-only, so the lever that matters is how many cores feed
the rasteriser. `LP_NUM_THREADS` defaults to 4, which measured fastest on an
8-core device:

| threads | ms/frame | fps |
|---|---|---|
| 1 | 1091 | 0.92 |
| 2 | 892 | 1.12 |
| **4** | **428** | **2.33** |
| 8 | 472 | 2.12 |

8 is slower than 4: past four, the rasteriser threads contend with the UI
threads for the same eight cores, and proot's `ptrace` interception adds cost
per syscall.

To compare:

```sh
OCS_LP_THREADS=1 ocs
OCS_LP_THREADS=8 ocs
```

The app's PERF panel shows ms/frame live while you drag the drawing around.

## Why there is no GPU in the native build

proot is a `ptrace`-based syscall translator, not a virtual machine. The Android
GPU is only reachable through a bionic userspace driver talking to the Mali HAL,
and none of that exists inside a glibc container. Concretely:

- `/dev/dri/card0` is `root:system`, mode 660 — the app gets `Permission denied`.
- There is no `/dev/dri/renderD*` node at all.
- The only real driver is `/vendor/lib64/hw/vulkan.mali.so`, a **bionic** `.so`.

Mesa is installed and includes `panfrost_icd.json` (PanVK, the correct driver
for Mali) — but Panfrost needs a DRM render node to open a GPU fd, and there
isn't one.

The other backends do not help either, which is worth stating so nobody
re-litigates it:

| Backend | Result |
|---|---|
| `vulkan` | no hardware adapters |
| `gl` | no adapters at all, not even software — Termux:X11 has no GLX and Mesa's EGL cannot reach it |
| `sw` | `llvmpipe (LLVM 19.1.7)` — the only rasteriser available |

So the native build runs llvmpipe either way. Switching from Vulkan to another
API would change nothing, because both would end up rasterising on the same CPU
cores. What moves the number is the thread count.

If you need the GPU on Android, use the web build.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Blank canvas | serving from the wrong directory | serve from `web-dist/` |
| Opening a DWG hangs at ~10% | `worker_pkg/` missing | run `build-web.sh`; don't hand-assemble `web-dist/` |
| Saves download as `.txt` | MIME patch not applied | apply `0001`; rebuild wasm |
| Blank canvas on Android Chrome, no error | naga array-constructor driver bug | apply `0002` |
| Every `[gpu]` line printed twice | notice printed by both prober and app | apply `0001`; rebuild |
| `XOpenDisplayFailed` panic | `.X11-unix` not bound into container | `mkdir -p $PREFIX/tmp/.X11-unix` |
| "Termux:X11 did not come up" | X11 server already running as the Android app service | open the Termux:X11 app, or `pkill termux-x11` then relaunch |
| 1280x1024 window | X11 app not connected to the server | open the Termux:X11 app |
| `rustc 1.85.1 is not supported` | used `sh -c` instead of `sh -lc` | use a login shell |
| Patches don't apply | checkout is not `v2026.39` | re-clone with `--branch v2026.39` |
| `git add -A` tries to commit 76 MB | `web-dist/` not ignored upstream | `echo web-dist/ >> .git/info/exclude` |
| `command not found: termux-x11-nightly` | that's the package, not the command | the command is `termux-x11` |

## Repository layout

```
bootstrap.sh              one-command installer (idempotent)
README.md                 this guide
README.en.md              the same guide, in English
PATCHES.md                what each patch does and why
docs/screenshots/         screenshots
patches/                  0001, 0002, apply-patches.sh
scripts/                  build-web.sh, build-native.sh, install-launcher.sh,
                          serve-web.sh
termux/                   ocs, opencadstudio, ocs-termux.sh, ocs-perf.scr
web/index.html            bootstrap used in place of trunk's
```

## Licence and attribution

GPL-3.0, matching [Open CAD Studio](https://github.com/HakanSeven12/OpenCADStudio),
whose authors are those of the original project. The patches in this repo are
modifications of GPL code and are therefore published under the same licence.

If you think a fix should reach the original project, the natural route is a PR
upstream rather than keeping a permanent fork.