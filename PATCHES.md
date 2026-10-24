# Patches

Three patches, in order. `patches/apply-patches.sh` applies all three: 0001 and 0002
patch the OpenCADStudio tree (with 0001 adding `[patch.crates-io]` for naga and
0002 vendoring naga 29.0.4), and 0003 patches `opencadcodec` in the Cargo git
checkout after `cargo fetch`. Nothing here is pushed upstream.

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
| 3 | `0003-dxf-text-oblique-degrees.patch` | 1 (`opencadcodec`) | DXF TEXT oblique angle written in degrees (prevents decay on every save) |

Apply with:

```sh
sh patches/apply-patches.sh /path/to/OpenCADStudio
```

They are plain `git diff` output, so `git apply` is all that is involved. 0003 is
applied to the cached `opencadcodec` checkout and forces a rebuild of that
dependency because Cargo does not recompile it when files are edited in place.

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

## 0003 — DXF TEXT oblique angle in degrees

`opencadcodec/src/io/dxf/writer/section_writer.rs` writes DXF group 51 (TEXT
oblique angle) in radians even though DXF defines it as degrees. The reader
converts group 51 from degrees to radians on load, so writing it raw means a
15° slant comes out as 0.26°. Each subsequent save treats that 0.26 as degrees
and writes 0.0046, so the angle decays toward zero with every save/reload
cycle — silently.

STYLE group 50 already converts with `to_degrees()` (and has a regression
test). ATTDEF, ATTRIB and SHAPE already do too. TEXT is the only one that was
missing it. This patch adds the conversion plus a short comment.

Because this lives in `opencadcodec` (a git dependency) rather than in the
OpenCADStudio tree, `apply-patches.sh` applies it to
`$CARGO_HOME/git/checkouts/opencadcodec-*/42b44d2` and runs `cargo clean -p
opencadcodec` for both native and wasm release targets so Cargo rebuilds it
(despite the rev never changing). If `cargo fetch` has not been run yet, the
script stops with instructions to fetch first.
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