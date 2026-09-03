---
name: docker-image-playbook
description: Cut Docker/BuildKit build time and harden images for production. Use when writing/editing a Dockerfile or docker-compose.yml, when a build "feels slow," or before shipping a container.
license: MIT
metadata:
  author: Fabricando Sua Ideia - github.com/fabricandosuaideia
  version: "1.0.0"
---

# Docker / BuildKit Image Playbook

This playbook exists because a real build broke three ways in one session
(floating base-image version, a `--depth 1` git pin that only worked by
accident, a relative-path script that silently no-op'd) and, once fixed,
still took 52 minutes cold and 18 seconds warm — the 170× gap was entirely
cache hygiene, not the Dockerfile's actual work. Every rule here is either
something measured on a real build or a claim from an official source, tagged
with when it was checked. Docker/BuildKit/NVIDIA's container stack changes
fast enough that this file will go stale — re-verify anything you're about to
build a decision on, the same way you'd re-verify a library API. See "How to
keep this file honest" at the bottom.

## The map — what's where

| File | Load it when |
|---|---|
| **This file** | Always — Phase 0, the fast checklist, and navigation |
| [`dev-speed.md`](dev-speed.md) | Actually rewriting a Dockerfile for build speed (Phases 1–7: layer order, cache mounts, `.dockerignore`, pinning refs, GC config, package sizing, `ninja`) |
| [`production-hardening.md`](production-hardening.md) | Shipping a container — non-root, secrets, multi-stage, CUDA base tiers, scanning, SBOM, `HEALTHCHECK`, size, GPU exposure (CDI), read-only rootfs, lockfiles |
| [`scripts/audit_dockerfile.py`](scripts/audit_dockerfile.py) | Run it first on any Dockerfile: `python3 ${CLAUDE_SKILL_DIR}/scripts/audit_dockerfile.py <Dockerfile...>` — a mechanical pass over the checklist's grep-able subset (contradictory flags, fragile pins, missing `USER`/`HEALTHCHECK`, secret-shaped `ARG`/`ENV` names, floating tags). Advisory, not a substitute for Trivy/Grype/Docker Scout — see "Vulnerability scanning" in `production-hardening.md`. |

## Phase 0 — Measure before you optimize

**The single most important lesson here.** A build that looks catastrophically
slow may be **resource contention, not the layer itself**. On one real
machine, a CUDA-toolkit `apt-get install` layer measured **1478s** inside a
full `docker compose build` (9 images, BuildKit running stages concurrently,
plus ~30 unrelated containers from other projects competing for the same
CPUs/disk/network) — and **307.5s** when rebuilt in isolation on an otherwise
idle box. Both numbers are real; only one of them describes the layer's
actual cost.

Before changing anything:
- Re-run the slow step in isolation (`docker build --target <stage>`) on as
  idle a machine as you can get.
- Check what else is running (`docker ps`, host load average) during a full
  build — BuildKit parallelizes independent stages, so two unrelated
  multi-gigabyte downloads/compiles can share one pipe and inflate each
  other's wall clock without either one being "slow" on its own.
- Only diagnose and fix the layer itself once you have a number you trust.

Corollary: don't trust an env var's name to describe what it does. This
project's `SageAttention` build passed `EXT_PARALLEL=4` believing it
parallelized compilation — reading the actual `setup.py` showed it only
controls how many **extensions** build concurrently (irrelevant when only two
exist for the target arch); the real lever missing was `ninja`, unrelated to
that variable. **Read the source before trusting what a flag's name implies.**

## Fast checklist

Run `scripts/audit_dockerfile.py` first — it catches everything below marked
(script). What's left needs a human call.

**Build speed** (detail: `dev-speed.md`):
- [ ] Dependency install comes before `COPY <source>` (script can't check this — it's about instruction order, not text)
- [ ] `--mount=type=cache` on every `pip`/`apt`/`npm`/`uv` install; `PIP_NO_CACHE_DIR`/`--no-cache-dir` NOT set anywhere a cache mount is used (script)
- [ ] `.dockerignore` excludes tool caches (`.mypy_cache`, `.ruff_cache`, `.pytest_cache`, `*.egg-info`), not just `.git`/`node_modules`
- [ ] Every pinned upstream commit is fetched by SHA (`git fetch --depth 1 origin <sha>`), not `clone --depth 1 && checkout <sha>` (script)
- [ ] A version compiled against another stage's library is pinned identically in both stages
- [ ] `daemon.json` `builder.gc.defaultReservedSpace` is sized for the project's actual layer sizes, not the ~10GB default
- [ ] Installing the narrowest package set that satisfies the need, not a kitchen-sink metapackage
- [ ] `ninja` installed wherever a C++/CUDA extension compiles

**Before shipping** (detail: `production-hardening.md`):
- [ ] Non-root `USER`; GPU device access verified under that user, not assumed (script flags root as INFO)
- [ ] Multi-stage: build tooling absent from the shipped image
- [ ] Correct CUDA tier per stage (`-devel` to compile, `-runtime` to run) — or confirmed a PyPI-wheel-only path is smaller
- [ ] No secret via `ARG`/`ENV` (script flags secret-shaped names); `--mount=type=secret` used instead
- [ ] Base image(s) pinned by digest, with an automated bump path (script flags missing tags/digests as INFO)
- [ ] Vulnerability scan in CI, gated with `--ignore-unfixed` or equivalent
- [ ] `HEALTHCHECK` present (script flags if entirely absent), never triggers GPU inference, `--start-period` sized for real model-load time
- [ ] Image size ranked by measured bytes, not convention
- [ ] GPU exposure verified against current Compose/toolkit docs, not a stale blog post
- [ ] `read_only: true` attempted, write paths enumerated empirically, JIT/model caches on a named volume
- [ ] Lockfile with hash/lock enforcement (`uv sync --locked`, `pip --require-hashes`, `npm ci`), same installer in CI and Dockerfile
- [ ] Multi-platform explicitly decided, not defaulted — usually skip for a GPU image

## Explicitly unverified — re-check before relying on these

Carried forward honestly rather than silently asserted:

| Claim | Status (as of 2026-09-03) |
|---|---|
| Docker Scout per-plan repository limits | Not on any official Docker docs page found; third-party sources only |
| "Kubernetes ignores the Dockerfile `HEALTHCHECK` instruction" | Strongly supported (k8s probe docs never mention it) but not directly stated on kubernetes.io |
| Distroless Python is "experimental/unsupported" | Not verifiable against the current README — historically true, don't assert now |
| Distroless infeasible for CUDA/PyTorch | Reasoning from verified facts, not a citation — no primary source states this either way |
| PyTorch JIT cache env var names (`TRITON_CACHE_DIR`, `TORCHINDUCTOR_CACHE_DIR`) | Community-sourced; verify against pytorch.org before hard-coding |
| `dpkg path-exclude` doc/locale stripping | Blog posts only, no official Docker/Debian doc |
| Whether NVIDIA prefers CDI over the legacy runtime for Docker specifically | The toolkit changed its *default* and deprecated legacy mode, but NVIDIA's own sample-workload page still shows the legacy `--runtime=nvidia --gpus all` form for Docker without labeling either as preferred |

## How to keep this file honest

This ecosystem moves fast enough that "current" has a shelf life — the CDI
default flip (NVIDIA Container Toolkit 1.18, Docker Engine 28.3) is a
concrete example of a fact that was correct, then wrong, within about one
release cycle, and neither Docker's nor NVIDIA's user-facing docs had fully
caught up with their own toolkit's default change at time of writing.

Before asserting a Docker/BuildKit/NVIDIA-toolkit fact you're not sure is
still current: run a research pass (a web-search agent, or this user's own
research tooling if available) against official sources —
`docs.docker.com`, `docs.nvidia.com`, `catalog.ngc.nvidia.com`, the OWASP
Docker Security Cheat Sheet, and the tool's own repo/release notes — rather
than asserting from memory. Prefer official vendor docs over blog posts.
When you can't verify something, write "unverified" explicitly (see the
table above) rather than asserting it — an honest gap is more useful to the
next reader than a confident guess that turns out stale.

## Worked example

One real project's ComfyUI (CUDA 13 + PyTorch + a source-compiled
SageAttention extension) + backend/worker (Python/FastAPI/Celery) image set,
worked through this exact playbook in one session:

| Phase | What broke / what was applied | Result |
|---|---|---|
| dev-speed Phase 4 (pin refs) | Unpinned `pip install torch` in a CUDA-extension builder stage; upstream index moved a minor version; new torch required a newer C++ standard than the extension's build script hard-coded | Pinned exact version, identically, across both build stages |
| dev-speed Phase 4 (pin refs) | `git clone --depth 1 && checkout <sha>` on 4 pinned custom-node repos; one had already drifted past its pin | Switched to `fetch --depth 1 origin <sha> && checkout FETCH_HEAD` for all 4 |
| dev-speed Phase 1 (layer order) | `COPY backend/ ./` sat before the dependency install in 4 images; any source edit invalidated a ~20-minute install | Moved dependency install before the source copy, with a stub package directory |
| dev-speed Phase 3 (`.dockerignore`) | `.mypy_cache` (119 MB) had no ignore entry; baked into 4 images, 94% of build context transferred every build | Added `.mypy_cache`/`.ruff_cache`/`*.egg-info` to `.dockerignore` |
| dev-speed Phase 2 (cache mounts) | `PIP_NO_CACHE_DIR=1` + `--no-cache-dir` on every image; no apt cache mount; a 554 MB torch wheel downloaded twice per build | Removed both pip-cache-disabling settings, added pip+apt cache mounts across 4 Dockerfiles |
| dev-speed Phase 5 (GC) | No `builder.gc` section in `daemon.json`; default ~10 GB reservation was almost certainly evicting the expensive layers between builds | Set `defaultReservedSpace: "80GB"` |
| dev-speed Phase 7 (ninja) | SageAttention's C++/CUDA extension compiled without `ninja`, falling back to distutils' slow serial backend | Added `pip install ninja` to the builder stage |
| dev-speed Phase 6 (package set) | Noted but not applied yet: `cuda-toolkit-13-2` (3.3 GB) vs `cuda-minimal-build-13-2` (~194 MB) for a compile-only stage | Left for a follow-up change — needs a real compile validation before swapping |

Net measured effect: a cold `docker compose build` (9 images) went from a
build that failed outright (unpinned torch + C++20 mismatch) to **3110s**
once fixed cold, to **18s** warm on the very next build — the 170× gap
between cold and warm is what Phases 1, 2, 3, and 5 bought, on top of the
correctness fixes from Phase 4.
