# Build-speed reference

Full detail behind `SKILL.md`'s Phase 0. Load this file when actually
rewriting a Dockerfile for speed, not for a quick sanity check.

## Phase 1 — Order layers least-changing-first

Put whatever changes least at the top of the Dockerfile, whatever changes most
at the bottom — every layer after the first invalidated one rebuilds.

**The dependency-before-source split, done right (Python/setuptools
editable-install example):**

```dockerfile
WORKDIR /app
# Only the dependency manifest — NOT the source tree — so an app.py edit
# can't invalidate this layer.
COPY pyproject.toml README.md ./
RUN mkdir -p app && touch app/__init__.py   # stub so `pip install -e .` has
                                              # something to discover
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -e ".[extras]"

# Real tree lands after the expensive install. Because the install above was
# editable, the package is already import-mapped to this directory — nothing
# needs to be redone except regenerating metadata, which is seconds.
COPY . ./
RUN --mount=type=cache,target=/root/.cache/pip pip install -e . --no-deps
```

Measured effect of this exact pattern in one Dockerfile: a full dependency
install (`~20 min`, cold) stayed cache-hit on a source-only edit; only the
`COPY` and a `--no-deps` metadata reinstall re-ran (`~10s` total).

The equivalent Node/npm form (`COPY package.json package-lock.json ./` →
`npm ci` → `COPY . .`) and Go form (`COPY go.mod go.sum ./` → `go mod
download` → `COPY . .`) follow the identical shape. **Modern equivalent using
`uv`** (Astral's own documented Docker pattern, verified 2026-09-03,
<https://docs.astral.sh/uv/guides/integration/docker/>):

```dockerfile
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project
COPY . /app
RUN --mount=type=cache,target=/root/.cache/uv uv sync --locked
```

Note the `--mount=type=bind` for the lockfile instead of `COPY` — it's needed
to resolve, not to persist in a layer.

## Phase 2 — Cache mounts, and the two ways to defeat them by accident

BuildKit's `--mount=type=cache` survives *between* builds, unlike a normal
layer. Use it for every package manager:

```dockerfile
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -r requirements.txt

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-<distro>,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,id=apt-lists-<distro>,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
 && apt-get update \
 && apt-get install -y --no-install-recommends <packages>
```

**Two traps that silently defeat the mount, both confirmed present in a real
project until fixed:**

1. **`PIP_NO_CACHE_DIR=1` (as an `ENV`) and `--no-cache-dir` (as a pip flag)
   tell pip to never populate the cache directory in the first place** — the
   mount has nothing to persist. Remove both wherever a cache mount is in use.
   This is a very common copy-pasted "best practice" that was written for the
   *pre-BuildKit-cache-mount* era (when the goal was keeping the cache out of
   the *layer*) and is actively counterproductive once a cache mount exists.
2. **Debian/Ubuntu base images ship `/etc/apt/apt.conf.d/docker-clean`**,
   which deletes downloaded `.deb` files immediately after install —
   confirmed present in both `python:3.11-slim` (Debian) and
   `pytorch/pytorch:*` (Ubuntu 20.04) base images. `rm -f` it before
   `apt-get update` in the same `RUN`, or the apt cache mount stays empty too.
   Conversely: if you're **not** using an apt cache mount, `rm -rf
   /var/lib/apt/lists/*` at the end of the same `RUN` is still correct and
   recommended (Docker's official best-practices page) — don't do both; a
   cache mount and an `rm -rf` of the same path fight each other.

**Effect of fixing both, measured on the same project across two builds:** a
554 MB PyTorch wheel that had been downloaded **twice in one build** (once per
build stage, same version, same index) downloaded once; the second full
`docker compose build` after the cache warmed dropped from **3110s to 18s**
for 9 images.

**Same cache mount is reusable across stages in a multi-stage build** — a
wheel a builder stage downloads is available to the final stage for free if
both mount the same `target`.

## Phase 3 — `.dockerignore` hygiene beyond the obvious

Everyone excludes `.git`, `node_modules`, `.venv`. The category people miss:
**tool caches that live inside the source tree and get silently `COPY`'d.**

Confirmed on a real project: `.mypy_cache` (119 MB) had no `.dockerignore`
entry, so it was baked into **four** images via a single `COPY backend/ ./`
— roughly 476 MB of pure waste, and it was **94% of the build context**
transferred to the daemon on every single build. Worse: running `mypy`
locally changes that cache's contents, which changes the context's hash, which
invalidates the `COPY` layer — a purely local, non-code-affecting action was
silently causing rebuilds.

Add these defensively, even to a repo that doesn't currently have them (a
teammate's editor/tool will eventually create one):

```
**/.mypy_cache
**/.ruff_cache
**/.pytest_cache
**/*.egg-info
**/__pycache__
**/.venv
**/venv
**/node_modules
**/.next
```

Verify by grepping the built image for what actually landed (don't assume the
ignore file worked — it's silent when it doesn't match what you expect):

```
docker run --rm --entrypoint sh <image> -c 'du -sh /app/.mypy_cache 2>/dev/null || echo clean'
```

## Phase 4 — Pin upstream references correctly, not just present-tense-correctly

**`git clone --depth 1 <url> && git checkout <sha>` only ever downloads the
default branch's current tip.** It works for exactly as long as your pinned
SHA happens to still BE the tip — which is an accident, not a pin. The moment
upstream pushes past it, the build fails with `fatal: unable to read tree
<sha>`. Confirmed: 3 of 4 pinned dependencies in one real Dockerfile were one
upstream push away from this; the 4th had already broken.

**Fetch the SHA directly instead** — GitHub (and most forges) serve any
reachable commit by SHA, not just branch tips:

```sh
git init "$dir"
git -C "$dir" remote add origin "$url"
git -C "$dir" fetch -q --depth 1 origin "$sha"
git -C "$dir" checkout -q FETCH_HEAD
```

This is strictly better, not just safer: one commit, no branch history, same
or less data transferred than the `clone --depth 1` form.

**Pin exact versions across a multi-stage ABI boundary.** If stage A compiles
a native extension (C++/CUDA) against library version X, and stage B (the
runtime) installs "the same" library unpinned, an upstream index bump between
builds can silently produce a version mismatch — stage B gets a newer
version, the compiled extension's ABI no longer matches, and you get either a
build-time header error (if headers changed enough) or a load-time
`undefined symbol` (if only the binary layout changed). Confirmed on a real
build: an unpinned `pip install torch` in a CUDA-extension-building stage
picked up a new torch minor between builds; the new version's headers required
a newer C++ standard than the extension's own build script hard-coded,
turning a silent version drift into a hard compile failure. Fix: pin the
**exact** version in both stages, identically, with a comment stating *why*
they must match.

## Phase 5 — GC configuration, so the cache you just built survives

BuildKit's cache has a size budget; once past it, GC evicts — and it doesn't
prioritize "the layer that took 20 minutes to produce" over "the layer that
took 2 seconds." A build cache sized for casual use (default `reservedSpace`
≈ 10 GB) on a project with multi-gigabyte CUDA/ML layers will evict exactly
the expensive layers, making a "cache hit" build silently pay full price
again with no error message explaining why.

`daemon.json`, current key verified against Docker's own reference
(2026-09-03; `defaultKeepStorage` is the **old**, no-longer-current name —
don't use it):

```json
{
  "builder": {
    "gc": {
      "enabled": true,
      "defaultReservedSpace": "80GB"
    }
  }
}
```

Full policy form (same page) supports per-tier `policy` entries with
`keepDuration`/`filter` if you need finer control than one flat reservation.
**Restarting the Docker daemon to apply this drops every running container** —
schedule it, don't do it silently on a shared machine.

Check current usage before guessing a number: `docker system df` (add `-v`
for per-item detail) shows total build-cache size and what's reclaimable
right now.

## Phase 6 — Install the smallest package set that satisfies the actual need

Large metapackages drag in far more than the one tool you need. Measured on a
real repo: `cuda-toolkit-13-2` (apt metapackage) pulled **269 packages, 3.3
GB** — including OpenJDK 21, systemd, and GTK — to get one thing, `nvcc`.
`cuda-minimal-build-13-2` (compiler + `cudart-dev` + `cccl` + `culibos-dev` +
profiler API, still no cuBLAS) is **71 packages, ~194 MB**. Measure the
narrower set's actual closure before adopting it — verify with `apt-get
install --print-uris -d <package>` (sums reported sizes) — and validate that
whatever you're compiling against it still links: a minimal set can be missing
a library the full metapackage happened to also provide (in the CUDA case,
`libcublas-dev` is not in the minimal-build closure; add it explicitly if a
link error proves it's needed).

Same principle, general form: `--no-install-recommends` on every `apt-get
install`, and periodically audit what a "kitchen sink" package actually
installs versus what you use.

## Phase 7 — Parallelism tooling for native/CUDA extension builds

If a `RUN` compiles a C++/CUDA extension via `torch.utils.cpp_extension`
(directly, or through a `setup.py bdist_wheel` that uses it), and the log
shows:

```
Attempted to use ninja as the BuildExtension backend but we could not
find ninja.. Falling back to using the slow distutils backend.
```

install `ninja` (a PyPI package, `pip install ninja`) in the same build stage,
before the compile step. This is the actual parallelism lever for this class
of build — not whatever job-count env var the project's build script exposes
(see `SKILL.md` Phase 0's corollary: verify what a flag actually controls
before relying on it).
