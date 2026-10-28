---
name: docker-image-playbook
description: Cut Docker/BuildKit build time and harden images for production. Use when creating, writing, or editing a Dockerfile or docker-compose.yml (including scaffolding one from scratch for a project that has none yet), when a build "feels slow" or the build cache / disk keeps growing, or before shipping a container.
license: MIT
metadata:
  author: Fabricando Sua Ideia - github.com/fabricandosuaideia
  version: "1.2.1"
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
| **This file** | Always — Phase 0 (measure first), the fast checklist, Phase -1 (scaffolding from zero), and navigation |
| [`scaffolding-from-zero.md`](scaffolding-from-zero.md) | Full depth behind Phase -1: complete signal tables (every package manager, every framework covered), the full Compose merge/watch mechanics, the monorepo/CI detail, the brownfield reconciliation algorithm, and version floors |
| [`dev-speed.md`](dev-speed.md) | Actually rewriting a Dockerfile for build speed (Phases 1–7: layer order, cache mounts, `.dockerignore`, pinning refs, GC config, package sizing, `ninja`) |
| [`production-hardening.md`](production-hardening.md) | Shipping a container — non-root, secrets, multi-stage, CUDA base tiers, scanning, SBOM, `HEALTHCHECK`, size, GPU exposure (CDI), read-only rootfs, lockfiles |
| [`scripts/audit_dockerfile.py`](scripts/audit_dockerfile.py) | Run it first on any Dockerfile: `python3 ${CLAUDE_SKILL_DIR}/scripts/audit_dockerfile.py <Dockerfile...>` — a mechanical pass over the checklist's grep-able subset (contradictory flags, fragile pins, missing `USER`/`HEALTHCHECK`, secret-shaped `ARG`/`ENV` names, floating tags, and two instruction-order checks: an install behind a source `COPY` in the same stage, or in a stage built `FROM` one that already copied the source). Advisory, not a substitute for Trivy/Grype/Docker Scout — see "Vulnerability scanning" in `production-hardening.md`. |
| [`scripts/cache_report.py`](scripts/cache_report.py) | The build cache is huge or the disk is filling and you need to know *why*: `python3 ${CLAUDE_SKILL_DIR}/scripts/cache_report.py` groups `docker buildx du` records by the instruction that made them and ranks them by bytes. Read-only; prunes nothing. See `dev-speed.md` Phase 5. |

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

**Measure the disk, not just the clock.** The same neglect that makes builds slow
makes the build cache grow: `docker system df` can say "255 GB" without saying
why. Rank it before touching anything — `python3
${CLAUDE_SKILL_DIR}/scripts/cache_report.py` — and check the two numbers that
explain most of it: the `transferring context:` size in `docker build
--progress=plain`, and the `COPY` layer size in `docker history`. Cache growth is
*layer size × invalidation frequency*; a GC number only decides how much of it you
keep (`dev-speed.md`, Phase 5), it doesn't shrink the rate.

Corollary: don't trust an env var's name to describe what it does. A
source-compiled CUDA extension (`SageAttention`) build passed `EXT_PARALLEL=4` believing it
parallelized compilation — reading the actual `setup.py` showed it only
controls how many **extensions** build concurrently (irrelevant when only two
exist for the target arch); the real lever missing was `ninja`, unrelated to
that variable. **Read the source before trusting what a flag's name implies.**

## Fast checklist

Run `scripts/audit_dockerfile.py` first — it catches everything below marked
(script). What's left needs a human call.

**Build speed** (detail: `dev-speed.md`):
- [ ] Dependency install comes before `COPY <source>` — also across stages: the source `COPY` lives in leaf stages, never in a stage another stage is built `FROM` (script, heuristic: `copy-before-install`, `install-after-parent-copy`)
- [ ] The source `COPY` layer and the `transferring context:` size are megabytes, not hundreds of them; if several Dockerfiles share one context, each has its own `<Dockerfile>.dockerignore` rather than one root file that suits only one of them
- [ ] `--mount=type=cache` on every `pip`/`apt`/`npm`/`uv` install; `PIP_NO_CACHE_DIR`/`--no-cache-dir` NOT set anywhere a cache mount is used (script)
- [ ] `.dockerignore` excludes tool caches (`.mypy_cache`, `.ruff_cache`, `.pytest_cache`, `*.egg-info`), not just `.git`/`node_modules`
- [ ] Every pinned upstream commit is fetched by SHA (`git fetch --depth 1 origin <sha>`), not `clone --depth 1 && checkout <sha>` (script)
- [ ] A version compiled against another stage's library is pinned identically in both stages
- [ ] `daemon.json` `builder.gc.defaultReservedSpace` is sized per host — above the working set of expensive layers, below what that disk can afford with its required free headroom, judged by the host's role (dev / CI / staging / prod), never copied from another machine (dev-speed.md, Phase 5); confirm it loaded with `docker buildx inspect` (the GC Policy rules)
- [ ] Installing the narrowest package set that satisfies the need, not a kitchen-sink metapackage
- [ ] *(native/CUDA extensions only)* `ninja` installed wherever a C++/CUDA extension compiles

**Before shipping** (detail: `production-hardening.md`):
- [ ] Non-root `USER`; if the container uses a GPU, device access verified under that user, not assumed (script flags root as INFO)
- [ ] Multi-stage: build tooling absent from the shipped image
- [ ] *(CUDA images only)* Correct CUDA tier per stage (`-devel` to compile, `-runtime` to run) — or confirmed a PyPI-wheel-only path is smaller
- [ ] No secret via `ARG`/`ENV` (script flags secret-shaped names); `--mount=type=secret` used instead
- [ ] Base image(s) pinned by digest, with an automated bump path (script flags missing tags/digests as INFO)
- [ ] Vulnerability scan in CI, gated with `--ignore-unfixed` or equivalent
- [ ] `HEALTHCHECK` present (script flags if entirely absent), never triggers expensive work (GPU inference, a model load), `--start-period` sized for the real startup time
- [ ] Image size ranked by measured bytes, not convention
- [ ] *(GPU images only)* GPU exposure verified against current Compose/toolkit docs, not a stale blog post
- [ ] `read_only: true` attempted, write paths enumerated empirically, JIT/model caches on a named volume
- [ ] Lockfile with hash/lock enforcement (`uv sync --locked`, `pip --require-hashes`, `npm ci`), same installer in CI and Dockerfile
- [ ] Multi-platform explicitly decided, not defaulted (usually skip for a GPU image)

## Phase -1 — Scaffolding from zero: infer, verify, ask sparingly

**Why this is its own phase.** The official tools that already do this job stop at the
easy 80%: `docker init` is Docker Desktop-only, interactive-only (one flag, `--version`;
two tracked requests for a non-interactive mode were never shipped), produces a
single-service artifact with no dev/prod split and a commented-out database block, and
its only brownfield move is "overwrite everything, unrecoverable" (verified empirically
2026-09-03: absent entirely from Docker Engine 29.7.2 Linux — `docker: unknown command:
docker init`; docs.docker.com/reference/cli/docker/init/). Docker's own AI agent, Gordon
(`docker ai`, GA 2026-05-19, docs.docker.com/ai/gordon/), is the 2026 competitive
baseline — it reads the repo, asks essentially nothing, and gates every mutation behind
approval — but it documents zero mechanism for keeping dev and prod apart, which is
exactly where a generated stack breaks. And the strongest empirical evidence available,
Repo2Run (NeurIPS 2025 Spotlight, arXiv 2502.13681), showed that removing the actual
Dockerfile-generation step and asking an LLM to transcribe its own session history
collapses build success from 100% to 19.5% — while of the failures that remained with
the real generator in place, only 1.7% needed something a human had to supply (a
credential). **The lesson that governs this whole phase: infer from the repo, verify by
running real commands, and reserve questions for the small number of decisions that are
both genuinely unresolvable from the repo and costly to get wrong.**

Full signal tables, every failure mode, the complete brownfield algorithm, and version
floors: [`scaffolding-from-zero.md`](scaffolding-from-zero.md). What follows here is the
condensed, actionable version.

### Order of operations

Stop at the first step that changes the answer — don't do step *n+1*'s work if step
*n* already settled it.

1. **Brownfield check.** A `Dockerfile`, `compose.yaml`/`docker-compose.yml`, or
   `.devcontainer/` already present changes this from a generation task to a
   reconciliation task — see "Brownfield" below before writing anything.
2. **Bounded repo scan.** `git ls-files` (respects `.gitignore` for free) or
   `find . -maxdepth 3` for manifests, excluding `node_modules/`, `.venv/`, `vendor/`,
   `target/`, `dist/`, `.git/`. Read-only — inference must never install anything,
   run the app's own tooling, or edit a file (the property that makes it safe to
   re-run on a dirty tree).
3. **Language → package manager → framework**, strictly in that order. Each layer's
   signal overrides nothing the previous layer said; it narrows the decision further.
4. **Backing services from client libraries**, never from assumption — a service in
   the generated compose file must trace back to a specific import or dependency line.
5. **Generate, then verify by running commands** (see "Verify" below). Only after
   that do you spend the (small) question budget on what's left unresolved.

### Step 1 — Read before asking: a lockfile is an answer, not a question

Three layers of signal, each answering a different question. None of them justify
asking the user — every framework/PaaS scaffolder examined (Nixpacks, Cloud Native
Buildpacks, fly launch, docker init) infers all three purely from files on disk.

**Language** (root manifest, strongest signal — never infer by counting file
extensions; a repo with a root `go.mod` and 400 `.py` helper scripts is a Go service):
`package.json` → Node · `pyproject.toml`/`requirements.txt`/`Pipfile` → Python ·
`go.mod` → Go · `Cargo.toml` → Rust · `pom.xml`/`build.gradle` → JVM ·
`*.csproj` → .NET · `composer.json` → PHP · `Gemfile` → Ruby.

**Package manager** (the committed lockfile — this alone picks among *seven* distinct
Python install commands and four Node ones; verified against Nixpacks' own
`src/providers/python.rs`/`node/mod.rs`, Apache-2.0, and the vendor Docker guides for
each): `package-lock.json`→`npm ci` · `yarn.lock`+no `.yarnrc.yml`→`yarn install
--frozen-lockfile` · `yarn.lock`+`.yarnrc.yml` (Berry)→`yarn install --immutable`
(`--frozen-lockfile` doesn't exist in Berry) · `pnpm-lock.yaml`→`pnpm install
--frozen-lockfile` (cache target `/pnpm/store` on the official `pnpm` image, else
resolve with `pnpm store path` — never hardcode `/root/...` on a nonroot base) ·
`bun.lock(b)`→`bun install --frozen-lockfile` · `uv.lock`→`uv sync --locked` ·
`poetry.lock`→`poetry install --no-root` · `Pipfile.lock`→`pipenv install --deploy` ·
`requirements.txt`→`pip install -r requirements.txt`. The `packageManager` field in
`package.json` wins over the lockfile when both exist. **Always the frozen/locked
form** — never the resolving one — because CI needs it to fail loudly when the
manifest and lock disagree, which is the whole point (verified: `npm install` silently
re-resolves; `npm ci` doesn't).

**Framework** (decides whether the image serves HTTP at all, the *production* command,
the artifact path, and the runtime base — verified against each framework's own
deployment docs, all fetched 2026-09-03): Next.js with `output: 'standalone'` in
`next.config` → copy `.next/standalone` + `.next/static` + `public` (all three, or the
app ships unstyled), `node server.js`, port 3000 · a Vite/CRA/plain-SPA frontend
(react/vue/svelte/preact/lit/solid/qwik *without* a server adapter) → build then serve
from `nginx:alpine`/Caddy with `try_files $uri $uri/ /index.html;` (omit this and every
deep link 404s on refresh) · Django → `gunicorn <proj>.wsgi:application --bind
0.0.0.0:8000` (or a uvicorn worker if `asgi.py` exists) — **never** `manage.py
runserver`; `collectstatic` runs at *build* time, `migrate` is a separate one-shot,
never inside `CMD` · FastAPI → `fastapi run app/main.py --port 8000` in **exec form**
(shell form breaks graceful shutdown and lifespan events — fastapi.tiangolo.com's own
deployment guide states this) · Flask → `gunicorn 'app:app' --bind 0.0.0.0:8000`,
never `flask run` · Go with no cgo import → `CGO_ENABLED=0`, static binary, a
`distroless/static` or `scratch` runtime (cgo present → `CGO_ENABLED=1` and a glibc
base; `scratch` is impossible there and fails at container start with a misleading
"no such file or directory").

**Backing services from the dependency list, not from guessing** (the single most
transferable idea from `fly launch`'s own scanner source,
`scanner/django.go`/`python.go`, read directly 2026-09-03): `psycopg`/`pg`/
`django.db.backends.postgresql` → a Postgres service, plus a `migrate`/release
one-shot · `redis`/`ioredis` → a Redis service · `celery`/`sidekiq`/`bull` → a
**second compose service reusing the same image with a different `command:`**, plus a
mandatory broker (a worker with no broker crash-loops on startup). No signal, no
service — inventing "redis because it's a web app" produces a stack nobody trusts;
missing a signal that *is* there (no broker for a detected Celery app) is the more
common and more confusing failure.

### Step 2 — The one mechanism that stops dev from leaking into prod

This is the highest-leverage fact in the whole phase, and it is almost never stated
explicitly anywhere: **Compose merge overwrites maps but *concatenates* lists**
(`volumes`, `ports`, `environment` — docs.docker.com/reference/compose-file/merge/,
verified 2026-09). A dev bind mount declared in a base file is **not removed** by a
production override unless that override redeclares the same `target` — it is
*added to*, not replaced. This is why "one compose file with a `dev`-vs-`prod`
condition baked in" is the wrong shape, and why the base file must always be the
**least-privileged** one:

- [ ] One multi-stage Dockerfile: `base` → `deps` (full install, dev tooling
      included) → `dev` (FROM deps; watcher command; the *only* stage that may
      contain nodemon/watchfiles/air/cargo-watch) → `builder` (compile/bundle) →
      `prod` (FROM a minimal runtime; only the artifact + production deps; non-root;
      the real server command). **The source `COPY` goes in the leaf stages only** —
      never in a stage another stage builds `FROM`, or every source edit re-runs
      whatever the children install (`dev-speed.md`, Phase 1; the audit script
      flags it).
- [ ] `compose.yaml` describes the **production shape**: `build: {target: prod}` (or,
      once an image is published, `image:` with **no `build:` key at all** — see
      below), no bind mount, no published dev port.
- [ ] `compose.override.yml` (auto-merged for local `docker compose up`, and which CI
      and production simply never pass) flips `build.target: dev`, adds the bind
      mount or a `develop.watch` block (Compose 2.22+; don't use both a `watch` rule
      and a bind mount on the same path — the mount shadows the synced files, a
      documented failure), and publishes the port.
- [ ] Never `profiles: [prod]` / `profiles: [dev]` directly — `profiles` controls
      whether a service exists at all, not its *shape*; that's what `build.target` and
      the override file are for.
- [ ] **The production compose file must contain `image:` and must *not* contain
      `build:`.** This one line is both the cleanest expression of 12-factor
      build-once-promote (12factor.net/build-release-run) and independently verified
      to matter: with both `image:` and `build:` present and the tag missing from the
      registry, `docker compose up` silently **builds locally** and tags the result
      with the promoted tag — a missing-artifact deploy turns into an undetected
      local build from whatever source tree the deploy host happens to have. With
      `image:` only, it fails closed (`Error not found`) — the behavior you actually
      want. Write it as `image: ${IMAGE_REF:?IMAGE_REF is required}` so
      `docker compose config` also fails loudly if the ref is missing, instead of
      silently substituting an empty string (both behaviors verified 2026-09-03).
      And never stack the dev file on top for a prod deploy (`-f compose.yaml -f
      compose.prod.yml`) — merge can't *remove* the inherited `build:` key; deploy
      `compose.prod.yml` standalone.
- [ ] One exception worth a question, not an assumption: Vite/Next.js/CRA inline
      `VITE_*`/`NEXT_PUBLIC_*`/`REACT_APP_*` into the JS bundle at **build** time
      (confirmed on the frameworks' own docs — nextjs.org, vite.dev,
      create-react-app.dev). Promoting one image across environments freezes those
      values at whatever the build environment had. Check with `grep` whether the
      code calls a same-origin relative path (`/api/...`) first — if so there's
      nothing to ask. If not, this is the one place in the whole phase worth spending
      a question on, because the failure (production silently calling the staging
      API) is expensive and easy to ship.

### Step 3 — Simple vs. complex: triage by signal count, not by vibe

| Tier | Signal | Output |
|---|---|---|
| **Simple** | One root manifest, zero backing-service signals, zero workspace file | `Dockerfile` + `.dockerignore` only — a compose file here is noise |
| **Moderate** | One app manifest + at least one backing-service signal | `Dockerfile` + `compose.yaml` with the app, each inferred service, named volumes, healthchecks, `depends_on: {condition: service_healthy}` |
| **Complex / monorepo** | A workspace file (`pnpm-workspace.yaml`, `turbo.json`, `nx.json`, `go.work`, Cargo `[workspace]`) or more than one root manifest of *different* languages | See below |

**Monorepo build-context mechanics** — where naive generators break: the build
**context** must be the workspace root (where the lockfile lives), while
`dockerfile:` points into the package — `build: {context: ., dockerfile:
apps/api/Dockerfile}`. A context scoped to the package directory can't see the root
lockfile and silently installs a different dependency tree than local dev. Because
the context is the root, the root `.dockerignore` decides everything — exclude every
`**/node_modules`, `**/.venv`, `**/target`, or the context upload becomes gigabytes
and busts cache on every unrelated edit. Use the ecosystem's own prune tool so
changing package A doesn't invalidate package B's layer: `turbo prune <pkg>
--docker`, `pnpm deploy --filter=<pkg> --prod`. Drive N images with `docker buildx
bake` (one file, shared/inherited config, parallel — GA since Docker Desktop 4.38,
and as of Compose v5.0.0 (2025-12-02) `docker compose build` delegates to Bake
internally by default) rather than N independent `docker build` invocations.

### Step 4 — Ask sparingly, and make every question closed

Zero-question scaffolding is achievable and is what the strongest tools already do
(Nixpacks, Cloud Native Buildpacks, Gordon) — but zero questions only stays *safe*
paired with a visible, reviewable plan. Adapt GitHub Spec Kit's `/clarify` protocol
(github.com/github/spec-kit, `templates/commands/clarify.md`, verified against the
shipped template 2026-09-03) to this domain:

- [ ] **A low, hard cap** — at most 2, and usually 0-1, for a Docker-scaffolding
      task (Spec Kit's own cap is 5, for the much larger surface of an entire feature
      spec; this domain has far fewer genuinely unresolvable decisions).
- [ ] **Priority = impact × irreversibility, not confidence.** The taxonomy above
      already resolves language, package manager, framework, port, and base image
      with high confidence — none of those clear the bar.
- [ ] **Closed, multiple-choice, one option marked Recommended** — never an open
      "what would you like?" `AskUserQuestion` (Claude Code's own mechanism) has no
      native `recommended` field, so the recommendation must be carried
      *positionally* (first option) **and** stated in its description.
- [ ] **Questions asked in one call are answered simultaneously** — they cannot
      depend on each other's answers. Don't batch a question whose relevance hinges
      on another question's outcome; ask it in a follow-up turn instead.
- [ ] **If every option leads to the same next step, it isn't a question** — drop it.

**The short list of questions that actually clear the bar** for this domain:

1. *Target environments* — "Just local dev, or dev + a production-ready image?"
   (Recommended: infer from context — if the user said "for production"/"to
   deploy"/mentioned a host, skip the question and build both; if they said
   "quickly test locally", build dev only.)
2. *Build-time-baked frontend env vars* — only when a bundler is detected **and**
   `grep` doesn't already resolve it (see Step 2's exception).
3. *A credential the build genuinely needs* and cannot be found anywhere in the repo
   (a private registry token, a build-time API key) — Repo2Run's own failure
   analysis (420 real repos) found this was the *only* class of failure that
   couldn't be resolved by the agent itself: 1.7% of failures, vs. 89.8% that were
   simply resource-bound (timeouts).

**Never ask** (a file already answers all of these): language, package manager,
runtime version (`.nvmrc`/`.python-version`/`go.mod`'s `go` directive/
`rust-toolchain.toml`), port, whether to use multi-stage, whether to add a
`.dockerignore`, whether to add a cache mount, whether to run as non-root, which
backing services to add (the dependency list already said).

### Step 5 — Brownfield: an existing artifact is data to reconcile with, never an obstacle

`docker init`'s brownfield policy — a single destructive "overwrite everything,
unrecoverable" prompt — is the explicit anti-model (docs.docker.com/reference/cli/
docker/init/, verified). Gordon's is only marginally better ("every file modification
is shown before it runs" — no stated preserve/extend/replace rule at all). The
correct policy, synthesized from Dev Containers' "reference and layer, never rewrite"
pattern and Nixpacks' "explicit artifact always wins":

- [ ] Run the static validators (Step 6) against the **unmodified** existing files
      first — the output becomes the evidence for a diff, not a rewrite.
- [ ] Classify: **correct** (matches inferred signals, modern syntax, multi-stage,
      non-root, pinned) → leave it, say so · **incomplete** (right idea, missing
      `.dockerignore`/healthcheck/non-root/cache mounts) → propose additive edits ·
      **outdated** (obsolete `version:` key, `MAINTAINER`, unpinned `FROM node:latest`,
      dev server in `CMD`, a secret via `ARG`) → propose a diff, one rationale line
      per hunk, cite the specific rule · **wrong-shape** (single stage shipping a
      full SDK, or the Dockerfile builds a different framework than what's actually
      in the repo) → propose a replacement, keep the original as `Dockerfile.bak`,
      require explicit confirmation before overwriting.
- [ ] Signals already **inside** the existing artifact outrank freshly-inferred
      ones — an existing `EXPOSE`, non-root `UID`, volume path, or service name
      encodes production knowledge the repo doesn't state anywhere else. Preserve
      verbatim unless it's the actual defect.
- [ ] **The sharpest brownfield trap, easy to miss**: appending a production stage
      to the *end* of an existing Dockerfile silently changes the default build
      target, because a bare `docker build .` always builds the *last* stage — a
      silent wrong-artifact ship, not a loud failure. Same for renaming an existing
      stage that CI already references by `target:`.
- [ ] Never delete an existing `.dockerignore` or `.hadolint.yaml`; merge into it. A
      committed rule-skip was a deliberate human decision — surface disagreement as a
      question, don't silently remove it.

### Step 6 — Verify, don't ask more

Every one of these is sub-second-to-seconds, mutates nothing on a static check, and
turns "I think this is right" into "here is the passing output." An agent that can
run these has no reason to ask the user to eyeball the result.

- [ ] `python3 ${CLAUDE_SKILL_DIR}/scripts/audit_dockerfile.py <Dockerfile...>` — the
      text-only pass first: it is the one check here that sees instruction *order*
      (an install behind a source `COPY`, locally or through a parent stage).

- [ ] `docker build --check .` (or `docker compose build --check` when a compose
      file with `build:` keys exists — it resolves each service's context/target/args
      exactly as Compose will, and is the *only* one of the two that catches a
      `build.target` naming a stage that doesn't exist; `docker compose config`
      alone returns exit 0 on a nonexistent build context *or* a nonexistent target —
      verified, don't rely on it as a build-wiring check). Exits non-zero on a plain
      violation already — `error=true` is not required for the CLI flag (only for the
      in-file `# check=error=true` durable-enforcement form).
- [ ] **Checks are target-scoped — verify every target you generate, not just one.**
      Verified directly: `docker build --check --target dev` on a Dockerfile whose
      `prod` stage contained a hardcoded secret and a shell-form `CMD` reported *zero*
      warnings. Checking the dev stage proves nothing about prod. Enumerate stages
      first with `docker build --call=targets .`.
- [ ] `docker compose config -q` per overlay combination that will actually be used
      (base, dev, prod) — and read the *merged* prod output specifically for a
      surviving `volumes:`/`ports:`/`target:` line, since list-concatenation (Step 2)
      is exactly what a naive override fails to catch.
- [ ] `docker compose up --wait --wait-timeout <n>` then `docker compose ps` — proves
      healthchecks and startup ordering actually converge, not just that they were
      written. **`docker compose up --wait --exit-code-from <svc>` is an invalid flag
      combination** (`--wait` implies detached; `--exit-code-from` implies
      `--abort-on-container-exit`, incompatible with `-d` — verified, contradicts
      several widely-repeated blog examples). The two forms that actually work: `up
      --wait <deps>` followed by `run --rm <tests>`, or `up --exit-code-from <svc>
      --abort-on-container-exit` alone.
- [ ] `docker history --no-trunc <img> | grep -iE 'secret|token|password|_KEY'` — and
      don't trust a clean `docker build --check` alone as proof: `SecretsUsedInArgOrEnv`
      has a verified blind spot for a **global** `ARG` declared *before* the first
      `FROM` (it fires correctly on an `ARG`/`ENV` inside a stage, but not there).
- [ ] `docker image inspect <img> --format '{{.Config.User}} {{.Config.Cmd}}
      {{.Size}}'` — confirms non-root, the real (non-dev-server) command in exec
      form, and gives a size baseline.

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
| Whether `docker login dhi.io` is required in every environment to pull Docker Hardened Images, even though DHI became free/Apache-2.0 on 2025-12-17 | Verified true in at least one anonymous-pull test; not confirmed as universal across all registry configurations |
| Exact Compose version that introduced the `include:` top-level element and `compose up --wait` | Landed in the Compose v2.x line (`include` ~v2.20.0, 2023-07); not independently re-verified against release notes for this pass |
| Docker Scout free-tier repository/image-size limits | Sourced from pricing-aggregator sites, not Docker's own current pricing page — vendor limits drift, re-check before citing a number |
| `daemon.json` GC key name: `defaultReservedSpace` vs `defaultKeepStorage` | Docker's own pages disagree (dockerd reference vs the GC guide, checked 2026-10-28). `defaultReservedSpace` verified accepted on Engine 29.9.2; `defaultKeepStorage` not tested (needs a daemon restart) |
| `minFreeSpace` / `maxUsedSpace` as a hard disk guard in `daemon.json` GC policies | Shown in the dockerd reference's policy example; not applied or tested on a real host |
| Whether corepack (`corepack enable pnpm`/`yarn`) remains bundled-by-default in the newest 2026 Node major | Community-reported churn around unbundling; verify with `corepack --version` in the chosen base image rather than assuming |

## How to keep this file honest

This ecosystem moves fast enough that "current" has a shelf life — the CDI
default flip (NVIDIA Container Toolkit 1.18, Docker Engine 28.3) is a
concrete example of a fact that was correct, then wrong, within about one
release cycle, and neither Docker's nor NVIDIA's user-facing docs had fully
caught up with their own toolkit's default change at time of writing.

Before asserting a Docker/BuildKit/NVIDIA-toolkit fact you're not sure is
still current: run a research pass (a web-search agent, or your own
research tooling if available) against official sources —
`docs.docker.com`, `docs.nvidia.com`, `catalog.ngc.nvidia.com`, the OWASP
Docker Security Cheat Sheet, and the tool's own repo/release notes — rather
than asserting from memory. Prefer official vendor docs over blog posts.
When you can't verify something, write "unverified" explicitly (see the
table above) rather than asserting it — an honest gap is more useful to the
next reader than a confident guess that turns out stale.

## Worked example

A case study, not a template — the numbers belong to that machine and
project. One GPU/ML image set (ComfyUI on CUDA 13 + PyTorch + a
source-compiled SageAttention extension, plus a Python/FastAPI/Celery
backend/worker), worked through this playbook in one session:

| Phase | What broke / what was applied | Result |
|---|---|---|
| dev-speed Phase 4 (pin refs) | Unpinned `pip install torch` in a CUDA-extension builder stage; upstream index moved a minor version; new torch required a newer C++ standard than the extension's build script hard-coded | Pinned exact version, identically, across both build stages |
| dev-speed Phase 4 (pin refs) | `git clone --depth 1 && checkout <sha>` on 4 pinned custom-node repos; one had already drifted past its pin | Switched to `fetch --depth 1 origin <sha> && checkout FETCH_HEAD` for all 4 |
| dev-speed Phase 1 (layer order) | `COPY backend/ ./` sat before the dependency install in 4 images; any source edit invalidated a ~20-minute install | Moved dependency install before the source copy, with a stub package directory |
| dev-speed Phase 3 (`.dockerignore`) | `.mypy_cache` (119 MB) had no ignore entry; baked into 4 images, 94% of build context transferred every build | Added `.mypy_cache`/`.ruff_cache`/`*.egg-info` to `.dockerignore` |
| dev-speed Phase 2 (cache mounts) | `PIP_NO_CACHE_DIR=1` + `--no-cache-dir` on every image; no apt cache mount; a 554 MB torch wheel downloaded twice per build | Removed both pip-cache-disabling settings, added pip+apt cache mounts across 4 Dockerfiles |
| dev-speed Phase 5 (GC) | No `builder.gc` section in `daemon.json`; default ~10 GB reservation was almost certainly evicting the expensive layers between builds | Set `defaultReservedSpace: "80GB"` (that machine's budget, derived from its layers and disk; not a recommendation) |
| dev-speed Phase 7 (ninja) | SageAttention's C++/CUDA extension compiled without `ninja`, falling back to distutils' slow serial backend | Added `pip install ninja` to the builder stage |
| dev-speed Phase 6 (package set) | Noted but not applied yet: `cuda-toolkit-13-2` (3.3 GB) vs `cuda-minimal-build-13-2` (~194 MB) for a compile-only stage | Left for a follow-up change — needs a real compile validation before swapping |

Net measured effect: a cold `docker compose build` (9 images) went from a
build that failed outright (unpinned torch + C++20 mismatch) to **3110s**
once fixed cold, to **18s** warm on the very next build — the 170× gap
between cold and warm is what Phases 1, 2, 3, and 5 bought, on top of the
correctness fixes from Phase 4.
