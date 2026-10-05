# Patches

Two patches, in order. `patches/apply-patches.sh` applies both and vendors
naga 29.0.4 for the second one to land on.

They are not upstream commits. They are the changes this guide needs on top of
`v2026.39` (`c623a016`) to run on Android under Termux + proot. Nothing here is
pushed upstream.

> **They are pinned to `v2026.39`.** They are diffs against that exact commit, so
> `git apply` against a newer upstream release will either fail with a hunk
> error or, worse, apply to the wrong lines. Clone the tag, not the branch:
>
> ```sh
> git clone --depth 1 --branch v2026.39 https://github.com/HakanSeven12/OpenCADStudio.git
> ```
>
> To move to a newer release, re-apply against it and re-test the blank-canvas
> case; patch 0002 in particular depends on the surrounding naga code.

| | Patch | Files | What it does |
|---|---|---|---|
| 1 | `0001-termux-web-and-mali.patch` | 10 | Web build correctness + the Mali shader fix's Cargo side + performance work |
| 2 | `0002-naga-glsl-array-elementwise.patch` | 1 | The GLSL backend rewrite that makes Mali/ANGLE render at all |

Apply with:

```sh
sh patches/apply-patches.sh /path/to/OpenCADStudio
```

Both are plain `git diff` output, so `git apply` is all that is involved.

## 0001 — termux web and Mali

| File | Change |
|---|---|
| `Cargo.toml` | Adds the `[patch.crates-io]` stanza pointing `naga` at `vendor/naga`; restricts `smol` to the native target so the wasm build links. |
| `Cargo.lock` | Follows from the two above. |
| `src/sys.rs` | **Fixes downloads arriving as `.txt`.** `download_bytes` now builds a `BlobPropertyBag` with a real MIME type (`application/acad`, `application/dxf`) instead of letting the Blob default to text/plain, which is what made Chrome append `.txt` to every save. |
| `src/app/update/mod.rs` | Normalises the extension of a chosen save name to `.dwg`/`.dxf` so the browser cannot hand back a name the app will not reopen. |
| `src/app/mod.rs` | **Removes duplicated `[gpu]` notices.** The fallback and packed-renderer warnings were printed once by `gpu_backend` during probing and again by the app at startup. Now only the in-app command line gets them. |
| `src/app/update/viewport.rs` | Perf: replaces a `window::frames()` subscription (re-rendering every frame just to notice the cursor stopped moving) with a one-shot debounce timer. |
| `src/app/view/mod.rs`, `src/scene/pipeline/{mod,viewcube,hatch_gpu/mod}.rs` | Perf: MSAA count now comes from `msaa_samples()`, which drops to 1x on software rasterisers instead of always allocating a 4x buffer. |
| `src/scene/pipeline/viewcube.rs` | Same: picks the single-sample resolve target when MSAA is 1x. |

## 0002 — naga GLSL array element-wise

This is the one that matters most, and it is a driver bug, not a style choice.

`vendor/naga/src/back/glsl/writer.rs` emitted GLSL ES array constructors for
composed arrays:

```glsl
vec2[N](a, b)      // rejected by the Mali/ANGLE GLSL ES compiler
```

The GLSL ES compiler in ANGLE's Vulkan backend on Mali GPUs accepts the
constructor syntax only when every operand is a literal. With anything computed
it fails to compile, so shaders die on device with no useful error — a blank
canvas. Declaring the operands `highp` does not help; only the emission form
changes matter.

The patch routes those two cases (`write_named_expr` and `Statement::Store`)
through a helper that emits element-wise initialisation instead:

```glsl
vec2 v[N];
v[0] = a;  v[1] = b;
```

Note this only covers arrays used in a named expression or a store. An array
composed inside some other expression position still emits the constructor
form. That has not been hit in practice, but it is the remaining edge.

`vendor/naga` is naga 29.0.4 **otherwise unmodified** — `diff -rq` against the
Cargo registry copy reports only this one file.

## Why `naga = "27"` still appears in Cargo.toml

Line 69 keeps the original `naga = { version = "27", features = ["wgsl-in"] }`.
That is the direct dependency for WGSL front-end types. The `[patch]` stanza
later in the same file redirects resolution to `vendor/naga` (29.0.4) for
everything that goes through `wgpu`. Leave both alone: deleting the direct
dependency compiles fine and then breaks the build deep inside wgpu's
naga-27-era API usage.

## Known gap: upstream does not ignore `web-dist/`

`.gitignore` in the OpenCADStudio tree lists `dist` (trunk's output) but not
`web-dist`, and `dist` does not match `web-dist` as a pattern. After a web build
you have ~23 untracked files including a 71 MB `ocs_bg.wasm` and a 4.6 MB worker
binary. `git add -A` in that tree will try to commit 76 MB of build output.

Add this to your `.git/info/exclude` in the clone (keeps it local, does not
touch a tracked file):

```
web-dist/
```

## Verified

Against a clean export of `c623a016`:

- `git apply --check` passes for both patches in sequence
- after applying, `vendor/naga/src/back/glsl/writer.rs` is byte-identical to
  the tree this guide was developed against
- `diff -rq` against pristine naga 29.0.4 reports only `writer.rs`
- the generated shader compiles under `glslangValidator` as both a vertex and a
  fragment shader