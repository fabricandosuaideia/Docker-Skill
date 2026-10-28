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

**Multi-stage: the source `COPY` belongs in the leaf stages, never in a stage
that other stages build `FROM`.** A stage inherits its parent's layers *and
its parent's invalidation*. If `prod` does `COPY . .` and `prod-claude` is
`FROM prod`, every source edit invalidates the `COPY`, and everything
`prod-claude` installs after it re-runs — even though that install has
nothing to do with your code:

```dockerfile
# BAD — the expensive, stable install sits behind the source COPY
FROM base AS prod
COPY . .
FROM prod AS prod-claude
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && npm install -g some-cli                   # re-runs on every source edit

# GOOD — heavy + stable first, source last, once per leaf
FROM base AS cli-base
RUN apt-get update && apt-get install -y --no-install-recommends curl \
 && npm install -g some-cli
FROM cli-base AS prod-claude
COPY . .
FROM base AS prod
COPY . .
```

Measured 2026-10-28 (Docker 29.9.2): edit one source file, rebuild
`--target prod-claude`. BAD: the `RUN` printed its marker again (re-executed).
GOOD: the `RUN` stayed `CACHED`. `scripts/audit_dockerfile.py` flags the BAD
shape (`install-after-parent-copy`) from the text alone; on a real
three-variant Dockerfile it named exactly the three stages a person had
diagnosed by hand.

- A `dev` stage whose compose service bind-mounts the source (`./:/app`) needs
  no `COPY` at all — the mount shadows it. Keep the `COPY` only if that image
  is also run without the mount (CI, a test target).
- The same logic applies to every variant sharing a base: worker, test,
  debug, "with-CLI" images. Hoist what they share into a stage they all
  derive from; give each leaf its own final `COPY`.
- **Parallel worktrees / agent lanes**: BuildKit keys a `COPY` layer on file
  *contents*, not path or mtime. Measured: the same tree copied to a different
  directory with every mtime refreshed → `COPY` was `CACHED`. So N worktrees
  on the same commit share their cache; the cost multiplies only for trees
  whose contents diverge — and then it multiplies by whatever sits *behind* a
  source `COPY`, which is why the rule above is worth N× in that workflow.

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

**A cache mount never lands in the image**, so it can't trip a "no caches in
the final image" scan gate. Measured 2026-10-28: a `RUN --mount=type=cache`
that wrote a 20 MB file into the mounted directory produced a `0B` layer in
`docker history`, and the directory did not exist in the running container.
Adding cache mounts to a stage that lacked them is safe on that axis.

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

### Measure the context and the `COPY` layer — before and after

Two numbers tell you whether the ignore file works, without reading it:

```sh
# bytes sent to the daemon on every build
docker build --progress=plain . 2>&1 | grep 'transferring context'
# bytes the source COPY wrote into the image
docker history --format '{{.Size}}\t{{.CreatedBy}}' <image> | grep COPY
```

A source tree is megabytes. A whole-tree `COPY . .` in the hundreds of MB is
carrying something that isn't source.

**Cache growth is `layer size × how often it's invalidated`, not size alone.**
Measured 2026-10-28: a 30 MB directory in the context made the `COPY . .` layer
30 MB. Changing one byte inside that directory — nothing the app reads — re-ran
the `COPY` and wrote another full 30 MB layer. A directory that is rewritten by
a dev server (`.next/`, `dist/`, `storybook-static/`) does that on every build,
and each build leaves its own multi-hundred-MB record behind. On one real
108 GB cache, the 122 records that share one `[stage-1 6/6] COPY . .`
description totalled 34 GB (avg 0.28 GB each, ~32% of the cache) — see Phase 5
for the tool that found it.

**Polyglot repos (a Python/Go API next to a `web/` frontend, etc.):** first
prove the image never reads the other toolchain's directory (`grep` the app
source, migrations, scripts, entrypoints, every compose file and every
`COPY --from`); if nothing does, ignore the **whole directory**, not just its
`node_modules`. Listing `web/node_modules` and `web/.next` leaves the next
generated folder (`out/`, `.turbo/`, …) as tomorrow's leak.

**Shared context, different needs.** The root `.dockerignore` applies to
*every* Dockerfile built from that context. Measured: adding `web/` to it took
the API image's `COPY` layer from 30 MB to 82 B — and a second Dockerfile in
the same context doing `COPY web /web` then failed with `"/web": not found`.
When more than one image builds from one context, use a per-Dockerfile file
(`docker/Dockerfile.dockerignore` beside `docker/Dockerfile`; BuildKit prefers
it over the root file): measured, the API build's context dropped to 398 B
while the web build kept its 30 MB.

**Allowlist instead of denylist** when the image needs a few paths out of a
large repo:

```
*
!app
!pyproject.toml
```

A denylist fails *silently* — a new generated folder just bloats every build.
An allowlist fails *loudly*: measured, a `COPY scripts/run.sh` against an
allowlist that omitted `scripts/` stopped the build with
`"/scripts/run.sh": not found`. The price is one `!` line per new path the
image needs. `scripts/audit_dockerfile.py` reports a whole-tree `COPY` with no
`.dockerignore` in sight (`no-dockerignore`).

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

`daemon.json`. **Docker's own pages disagree on the key name** (checked
2026-10-28): the `dockerd` reference
(<https://docs.docker.com/reference/cli/dockerd/>) shows
`"defaultReservedSpace"`, while the GC guide
(<https://docs.docker.com/build/cache/garbage-collection/>) still shows
`"defaultKeepStorage"` for the `docker` driver. Verified on Docker Engine
29.9.2: `defaultReservedSpace` is accepted and resolves to policy rules
(next section shows how to see that). Whether `defaultKeepStorage` is still
accepted was **not** tested (it needs a daemon restart) — an earlier version
of this file called it "the old name"; that is not established.

### Size it for *this* host — there is no portable number

The right budget depends on the disk and on the host's job, so derive it
case by case; do not copy a figure from another machine (including the
examples in this file). Collect, per host:

```sh
df -h /var/lib/docker          # total/free where Docker's data lives (Docker Desktop: the VM's disk limit in Settings)
docker system df               # images, volumes, build cache today
python3 ${CLAUDE_SKILL_DIR}/scripts/cache_report.py   # which layers make up the cache, and how much is shared with images
```

and answer four questions:

1. **What is this host for?**
   - *Dev workstation / WSL2 / VM with a fixed disk* — you want warm
     rebuilds, but the cache shares the disk with images, volumes and the
     OS; the budget must fit what's left, not what's ideal.
   - *CI runner* — usually ephemeral; the Docker-side GC number barely
     matters, the cache lives in a registry or the CI cache instead (see
     `scaffolding-from-zero.md`, CI build cache).
   - *Staging / production* — prefer not to build there at all (build once,
     promote the image; `SKILL.md` Phase -1). If the host does build, favor a
     small budget plus a free-space guard over a large cache, so a build can
     never fill the disk the services run on.
2. **Lower bound — the working set.** The summed size of the *distinct,
   expensive* layers of the projects built on this host (the large,
   low-count groups in `cache_report.py`, plus layers whose cold cost you
   measured per Phase 0). Below this, builds pay cold again.
3. **Upper bound — what the disk can afford.** Free space minus the headroom
   you decide this host must always keep, minus the records shared with images
   (they sit outside the limit, see below). Write the headroom down as a
   rule for the host; don't leave it implicit.
4. **Do the bounds cross?** If the lower bound exceeds the upper, no GC value
   fixes it. Shrink the layers and the invalidation rate (Phases 1 and 3), move
   the heavy builds to a bigger host or a remote cache, or accept cold builds
   for that project.

Pick a value between the bounds, apply it, then re-measure after a couple of
weeks of real use (warm vs. cold rebuild time, `docker system df`) and adjust.
The same project can need different values on a laptop and on a build server.

```json
{
  "builder": {
    "gc": {
      "enabled": true,
      "defaultReservedSpace": "<BUDGET>GB"
    }
  }
}
```

Full policy form (same page) supports per-tier `policy` entries with
`keepDuration`/`filter` if you need finer control than one flat reservation.
**Restarting the Docker daemon to apply this drops every running container** —
schedule it, don't do it silently on a shared machine.

**Where that file actually lives depends on how Docker runs, not just the
OS** (verified against Docker's own docs, 2026-09-03):
- **Linux with Docker Engine installed directly** (including WSL2 without
  Docker Desktop, which is where the 3110s→18s numbers in this playbook were
  measured): `/etc/docker/daemon.json`.
- **Docker Desktop** (macOS, Windows, or WSL2 *with* Docker Desktop as the
  backend): `$HOME/.docker/daemon.json` — edit it directly in a text editor,
  or through the same JSON in Docker Desktop's Settings → Docker Engine
  panel. Same keys, different path — don't go looking for `/etc/docker/` on
  a Docker Desktop install.

Check current usage before guessing a number: `docker system df` (add `-v`
for per-item detail) shows total build-cache size and what's reclaimable
right now.

### Prove the setting took effect — reading needs no restart

A typo'd or ignored key fails silently; the daemon just keeps the defaults.
The resolved policy is visible:

```sh
docker buildx inspect | sed -n '/GC Policy/,$p'
```

Example, measured 2026-10-28 on one host whose budget was set to `80GB`
(illustrative, not a recommendation): rules 1–3 came back with
`Reserved Space: 80GiB`, rule 0 (local contexts and cache mounts older
than 48h) with `Max Used Space: 11.05GiB`. If you still see ~10 GB, your edit
didn't load.

### The number is also the disk bill — and it isn't a hard ceiling

GC trades disk for cache misses; it doesn't make builds cheaper. Raising the
reservation so expensive layers survive is right when the disk can afford it,
and a way to fill a small WSL2/VM disk when it can't. Two observations from
one host, same day (its budget was `80GB`):

- `docker buildx du` showed **84.66 GB private + 23.89 GB shared = 108.55
  GB**. The private records sat near the setting (80 GiB ≈ 85.9 GB) while the
  shared ones were above it. That fits Docker's description of the policies
  (it prunes cache not held by images), but it is one observation, not a
  tested rule — I did not remove images to watch the number fall. Treat the
  budget as "roughly what unshared cache may use", not "the most the cache
  can occupy"; plan the upper bound above with the shared portion on top.
- For a hard guard against *"the disk filled up"* specifically, the `dockerd`
  reference's policy example also lists `minFreeSpace` and `maxUsedSpace`
  keys. Documented, **not tested** here — verify with `docker buildx inspect`
  after applying, as above.

The durable fix for a cache that keeps growing is smaller layers and fewer
invalidations (Phases 1 and 3), not a bigger or smaller GC number.

### Find out *why* the cache is big

`docker system df` says how much, not why. `scripts/cache_report.py` groups
`docker buildx du --format json` records by the instruction that made them
(read-only; prunes nothing; sub-second on 1,158 records):

```sh
python3 ${CLAUDE_SKILL_DIR}/scripts/cache_report.py --top 10
```

On the 108 GB cache above it surfaced, in one screen, a `COPY . .`
description with 122 records averaging 0.28 GB (34 GB), and an
`apt-get install` line recreated under 34 different parent chains (15 GB).
Read the output as evidence, not a verdict: BuildKit keys a layer on its
instruction *and* its parent chain, so the same instruction appearing N times
means N different parents — an upstream layer changed N times, or N projects
share the same boilerplate line. Tell them apart by Dockerfile before
changing anything.

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
