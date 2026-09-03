# Production hardening reference

Full detail behind `SKILL.md`'s production checklist. Load this file before
actually shipping a container, not for a quick sanity check — `scripts/audit_dockerfile.py`
catches the mechanically-checkable subset of this faster than reading prose.

**One shared root cause worth knowing before the individual items:** the
*classic* `docker` driver + `overlay2` storage cannot hold a multi-manifest
image (an "image index"). That single fact is the reason **three** separate
things fail or silently no-op on it: registry build-cache export
(`--cache-to type=registry`), SBOM/provenance attestations, and true
multi-platform images. All three work on the `docker-container` buildx
driver, or automatically once the daemon is on Docker Engine **29.0+** (which
defaults to the containerd image store). Verified 2026-09-03 against Docker's
own docs — `docs.docker.com/build/metadata/attestations/`,
`docs.docker.com/build/building/multi-platform/`.

## Non-root user

```dockerfile
RUN groupadd -r appuser && useradd --no-log-init -r -g appuser appuser
USER appuser
```

`--no-log-init` works around a documented Go `archive/tar` issue that can
cause disk exhaustion (Docker's own best-practices page, verified
2026-09-03). Compose equivalent: the `user:` service attribute. OWASP Docker
Security Cheat Sheet Rule #2.

**GPU-specific caveats (three genuinely different issues, don't conflate
them — verified against NVIDIA's own docs, 2026-09-03):**

1. **Ordinary CUDA compute as non-root generally works** — the NVIDIA
   Container Toolkit injects host group IDs into the container so device
   nodes are accessible. Its own known failure mode is a harmless `cannot
   find name for group ID` warning (those GIDs have no `/etc/group` entry
   inside the image).
2. **`nvidia-smi`/Nsight "Insufficient Permissions" (`ERR_NVGPUCTRPERM`) is a
   *profiling-counter* restriction, not a compute restriction** — a driver
   default (`NVreg_RestrictProfilingToAdminUsers=1`) dating to a 2018
   side-channel disclosure. It does not affect `torch.cuda` workloads. Don't
   "fix" it by running the container as root.
3. **`Failed to initialize NVML: Unknown Error`** is a different,
   cgroup-related bug: a host-level cgroup update (even a `systemctl
   daemon-reload` unrelated to your container) can silently strip GPU access
   from a running container when using the older hook-based runtime path.
   NVIDIA's documented mitigations: `{"exec-opts":
   ["native.cgroupdriver=cgroupfs"]}` in `daemon.json`, explicit `--device`
   flags, or CDI (see the GPU-exposure section below — CDI sidesteps this bug
   class entirely).

**A non-root ML container needs a writable `HOME`** for
`~/.cache/huggingface`, `~/.cache/torch`, `~/.triton` — point these at a
named volume `chown`'d to the container's UID, or the first model
load/download fails.

## Multi-stage: strip build tooling from the runtime image

```dockerfile
FROM <builder-base> AS builder
RUN <install compilers, build the artifact>

FROM <slim-runtime-base>
COPY --from=builder /app/artifact /app/artifact
```

You can also copy directly from a registry image without declaring it as a
build stage — e.g., the pattern Astral documents for installing `uv`:
`COPY --from=ghcr.io/astral-sh/uv:0.12.9 /uv /uvx /bin/` (pin the version;
they explicitly recommend against `:latest` here too).

`--target <stage-name>` stops the build early at any named stage — useful to
keep a "has the compiler" variant for local dev/debug while shipping a
stripped one to prod from the same Dockerfile.

## CUDA base image: pick the right tier per stage

NVIDIA's own NGC catalog page (verified 2026-09-03) defines three
`nvidia/cuda` tiers:

| Tag suffix | Contains | Use for |
|---|---|---|
| `-base` | CUDA runtime (`cudart`) only | Rare — only if you ship your own math libs |
| `-runtime` | `-base` + CUDA math libs + NCCL (a `-cudnn` variant also exists) | **Running** a pre-built CUDA app |
| `-devel` | `-runtime` + headers + build tools | **Compiling** — NVIDIA itself names this "particularly useful for multi-stage builds" |

Rule: **compile in `-devel`, run in `-runtime`.**

**GPU/ML-specific wrinkle:** a PyPI PyTorch wheel already bundles its own
CUDA runtime/cuDNN/cuBLAS as `nvidia-*` sub-wheels. For a pure-PyPI-PyTorch
image, `python:3.x-slim` + the pip CUDA wheels can be **smaller** than
`nvidia/cuda:*-runtime` + PyTorch, because you'd otherwise carry two copies of
the same libraries. Measure both before assuming the NVIDIA base is the
leaner choice. The GPU **driver** itself (`libcuda.so`) is never in any of
these images regardless — it's injected by the container runtime from the
host at container start.

## Secrets: never `ARG`/`ENV`, always `--mount=type=secret`

Docker states this without hedging (verified 2026-09-03): *"Build arguments
and environment variables are inappropriate for passing secrets to your
build, because they persist in the final image."* `ARG`/`ENV` values are
visible in `docker history` even after being unset in a later layer — and,
separately, **`--provenance=mode=max` also records build args**, so turning
on maximal supply-chain provenance for security reasons actually *widens*
this exact leak if you're still using `ARG` for secrets. Two leak surfaces,
not one.

```dockerfile
RUN --mount=type=secret,id=hf_token,env=HF_TOKEN \
    huggingface-cli download <gated-repo>
```
```sh
docker build --secret id=hf_token,env=HF_TOKEN .
```

Default mount path inside the build is `/run/secrets/<id>`; `env=` mounts it
straight into an environment variable instead of a file. For private git over
SSH, use `--ssh default` + `RUN --mount=type=ssh` rather than baking a
deploy key into a layer.

**The better ML-specific answer, when available: don't download
credential-gated weights at build time at all.** Fetch them at container
start into a named volume (the pattern used for model weights generally) —
this sidesteps the secret-in-build-context problem entirely rather than
mitigating it.

## Pin base images by digest — deliberately, not by accident

```dockerfile
FROM python:3.11-slim@sha256:9534e5a8e315485d4061ed659af0fd78a284c015f9b73661b41d6bab25604534
```

Docker's own best-practices page states both sides of this tradeoff
explicitly: digest-pinning guarantees the same image forever, even if the
publisher replaces the tag — but it "opts out of automated security fixes."
Their stated resolution is not "never pin," it's **pin, and automate the
bumps** (they name GitHub Dependabot's `docker` package ecosystem
specifically). Keep the human-readable tag alongside the digest so the pin
stays legible to a reader.

**Higher-value than usual for CUDA base images specifically**: an
`nvidia/cuda:<ver>-runtime-ubuntu22.04`-style tag gets rebuilt in place when
NVIDIA patches the underlying OS layer, and that rebuild can shift the exact
point-release of a CUDA library your own compiled extension's ABI depends on.
For a CUDA base with anything compiled against it, digest-pinning is the
difference between a reproducible build and a "worked last week, don't know
why it doesn't now."

## Vulnerability scanning

Three actively maintained options as of 2026-09-03 (OWASP Docker Security
Cheat Sheet Rule #9 names Clair/Grype/Trivy as the free tier, Docker
Scout/Snyk/Anchore/JFrog XRay/Qualys as commercial):

- **Trivy** (Aqua Security) — `trivy image <IMAGE>`. Useful gating flags:
  `--severity HIGH,CRITICAL`, `--exit-code 1` (fail CI on findings),
  `--ignore-unfixed` (don't fail on a CVE with no available fix — **see the
  GPU/ML caveat below, this flag is close to mandatory there**),
  `--exit-on-eol` (fail when the base OS itself is past end-of-life).
- **Grype** (Anchore, Apache-2.0) — `grype <image>`, or `grype sbom:<file>`
  piped from Syft. `--fail-on high` (exits 2) fails on `high` and `critical`
  both — the ladder is `negligible < low < medium < high < critical`.
- **Docker Scout** — pre-installed with Docker Desktop; standalone install
  for plain Engine. `docker scout cves`, `sbom`, `recommendations`,
  `quickview`. Runs local policy evaluation without sending data to Docker's
  service for most uses. *Unverified as of 2026-09-03: exact per-plan
  repository limits — not stated on any official Docker docs page I could
  open; treat third-party summaries of this as unconfirmed.*

**GPU/ML-specific caveat:** expect a large, mostly-unactionable finding count.
CUDA/PyTorch images are big Debian/Ubuntu bases carrying vendored C/C++ libs
on NVIDIA's own release cadence, not Debian's — many CVEs will have no fix
available yet. Gate on `--ignore-unfixed` (Trivy) or an equivalent, or the
pipeline is permanently red for reasons no one can act on. Separately, a
locally-compiled wheel (a wheel you built in a builder stage, not fetched
from an index) shows up in an SBOM as one opaque package — don't treat the
SBOM as a complete inventory of what's inside a CUDA image.

## SBOM / provenance attestations

`docker buildx build --sbom=true --provenance=mode=max .` attaches an in-toto
JSON SBOM and SLSA-style build provenance to the pushed image. **Provenance
at `mode=min` is on by default already** for anything pushed to a registry
(verified against Docker's own build-metadata docs, 2026-09-03) — you likely
already have some. `mode=max` adds full build-arg/environment detail, which
is exactly the leak surface named in the Secrets section above.

Requires the containerd image store or `docker-container` driver — see the
shared root cause noted at the top of this file.

## `HEALTHCHECK`

```dockerfile
HEALTHCHECK --interval=30s --timeout=30s --start-period=0s \
            --start-interval=5s --retries=3 \
  CMD curl -f http://localhost:8000/health || exit 1
```

Defaults shown are Dockerfile's own (verified 2026-09-03); only the *last*
`HEALTHCHECK` in a Dockerfile has effect. Compose exposes the identical
attribute (`healthcheck:` with the same fields), which is what
`depends_on: {condition: service_healthy}` reads. **Kubernetes does not read
this instruction at all** — it requires its own `livenessProbe`/
`readinessProbe`/`startupProbe` declared in the Pod spec; porting an image
whose only health signal is `HEALTHCHECK` to k8s ships with no probes unless
you add them separately.

**GPU/ML-specific caveats, both real production incidents in shape:**
- **Never make the healthcheck itself run inference.** It fires by default
  every 30 seconds, forever — a GPU inference call there allocates VRAM on
  every tick and can contend with, or OOM, the very service it's checking.
  Check a cheap endpoint the app already exposes that reports readiness state
  it tracks internally, not a live model call.
- **Give model-loading containers a long `--start-period`.** Weights loading
  from a volume can take minutes; a short default start period makes an
  orchestrator kill or mark-unhealthy a container that is simply still
  starting. `--start-interval` (default 5s) lets you poll fast *during* that
  grace window without polling fast forever afterward.

## Minimizing image size

Ranked by what's actually measured to matter, not by convention:

1. **Choose the smallest base that satisfies the requirement** and
   **multi-stage away build tooling** — both already covered above, and both
   move gigabytes.
2. **`--no-install-recommends` + list cleanup, matched to your caching
   strategy**:
   ```dockerfile
   RUN apt-get update && apt-get install -y --no-install-recommends \
       pkg-a pkg-b \
    && rm -rf /var/lib/apt/lists/*
   ```
   Official Debian/Ubuntu images already run `apt-get clean` automatically —
   an explicit `apt-get clean` is redundant. **But `rm -rf
   /var/lib/apt/lists/*` and an apt cache mount are mutually exclusive** — if
   you added the cache mount from `dev-speed.md` Phase 2, don't also `rm -rf`
   the same path in the same `RUN`, or you're deleting the cache you just
   built.
3. **Distroless (`gcr.io/distroless/*`), for non-GPU services only.**
   Actively maintained (verified against the repo's own `variables.bzl`,
   2026-09-03; `nonroot` UID is `65532`). Tiers: `static`, `base`,
   `base-nossl`, `cc`, plus language images including `python3-debian13`.
   **No official NVIDIA distroless CUDA image exists, and I found no primary
   source recommending distroless for a CUDA/PyTorch stack** — reasoning from
   verified facts rather than a citation: such a stack needs
   `libcudart`/`libcublas`/`libcudnn`/NCCL plus driver libs injected at
   runtime, and distroless gives you no package manager and no shell to
   diagnose the resulting `undefined symbol`/`cannot open shared object file`
   failures if something's missing — for a payoff of well under 1% of a
   multi-GB CUDA image's size. Good fit for a Go/Node sidecar in the same
   stack; poor fit for the GPU service itself.
4. **Doc/locale stripping (`dpkg` `path-exclude`)** — a real, widely-used
   pattern, but I found it **only in blog posts, not official Docker/Debian
   docs**, and the typical claimed saving is ~18 MB. Treat as noise on a
   multi-GB CUDA image; not worth the added complexity there.

## GPU exposure: what actually changed, and what didn't

**Not applicable on macOS, on any Mac hardware.** No Mac — Apple Silicon or
Intel — has an NVIDIA GPU, Docker Desktop for Mac runs containers in a Linux
VM with no GPU passthrough to NVIDIA hardware, and Apple Silicon's own GPU is
Metal-based, not CUDA. This entire section is a Linux/Windows(WSL2) concern.

**Headline, verified 2026-09-03 against Docker's and NVIDIA's own current
docs:** the underlying mechanism for exposing a GPU to a container changed —
**CDI (Container Device Interface) is now the default path** — but this is a
layer *below* your Compose file, and **your Compose YAML almost certainly
does not need to change.**

- **Docker Engine** enabled CDI by default since **28.3.0** (not
  experimental); disable via `daemon.json` `{"features": {"cdi": false}}` if
  you ever need to.
- **NVIDIA Container Toolkit ≥ 1.18.0** made its runtime default to a
  just-in-time-generated CDI spec instead of the legacy hook path. A systemd
  unit (`nvidia-cdi-refresh`) regenerates `/var/run/cdi/nvidia.yaml`
  automatically on install/upgrade/reboot. The legacy runtime mode still
  works but is marked deprecated.
- **Docker Compose's own official GPU how-to page still documents only**
  `deploy.resources.reservations.devices` — no mention of CDI, `gpus:`, or a
  required Compose change:
  ```yaml
  services:
    worker:
      deploy:
        resources:
          reservations:
            devices:
              - driver: nvidia
                count: all        # or device_ids: ["0","2"] — mutually exclusive with count
                capabilities: [gpu]   # required — omitting it is an error
  ```
  **Conclusion: this pattern is still correct and current. No migration
  needed at the Compose level.** What changed is invisible from here — on a
  toolkit ≥ 1.18 host, the same YAML is now satisfied via CDI under the hood,
  which is *why* it also happens to sidestep the cgroup-update NVML bug
  described in the non-root section above.
- A newer, shorter Compose-spec attribute exists — `gpus: all` (or a list) —
  shipped in Compose **v2.30.0**. It's real but less documented (present in
  the Compose services reference, absent from the GPU how-to page); the
  verbose `deploy.*` form remains the better-documented default choice.
- Runtime env vars worth knowing (NVIDIA's docker-specialized-configurations
  page): `NVIDIA_VISIBLE_DEVICES` (`all` / indices / UUIDs / `none`);
  `NVIDIA_DRIVER_CAPABILITIES` — **replaces the default set, does not add to
  it**; unset default is `utility,compute`, other values are `compat32`,
  `graphics`, `video`, `display`. `NVIDIA_REQUIRE_CUDA="cuda>=11.0
  driver>=450"` fails the container at start if the host driver is too old —
  a genuine fail-loud guard worth setting deliberately rather than
  discovering the mismatch as a runtime crash.
- GPUs are also usable **during a build** now:
  `docker buildx build --allow device` + `RUN --device=nvidia.com/gpu
  nvidia-smi -L`. Requires Docker v27+, Buildx v0.22+, and the Dockerfile
  frontend's labs channel (`v1.14.0-labs`, not stable syntax) — relevant if
  you ever want to compile-and-test a CUDA kernel inside the build itself.

## Read-only root filesystem

```yaml
services:
  api:
    read_only: true
    tmpfs:
      - /tmp
```

OWASP Rule #8. Real and current, but **this is the single hardest item on
this list to apply to a GPU/ML container, and the one most likely to break
minutes after startup rather than at startup.** A PyTorch/CUDA process writes
to more places than expected: `/tmp` generally, JIT/kernel compile caches
(Triton, `torch.compile`/Inductor), `torch.utils.cpp_extension`'s own build
directory, `~/.cache/huggingface`, font caches, CUDA's own JIT cache. The
failure mode: the container starts and looks fine, then dies on the first
`torch.compile` call or the first custom-kernel load.

**Don't guess the write paths — measure them.** Run once *without*
`read_only`, exercise every code path (including the first-ever compile,
which caches for next time), and audit what got written; run once *with* it
and collect the `EACCES` errors that name what you missed. Redirect JIT
caches to an explicit named volume rather than `tmpfs` where possible — a
`tmpfs` cache is wiped on every container restart, meaning every restart pays
full recompilation cost again (`torch.compile` recompilation can be minutes),
which a persistent volume avoids. (The specific PyTorch cache env var names —
e.g. `TRITON_CACHE_DIR`, `TORCHINDUCTOR_CACHE_DIR` — came from community
sources during this research, not pytorch.org directly; verify each against
current PyTorch docs before hard-coding them.)

## Lockfiles / reproducible installs

- **Python + `uv`** (current recommended tool per Astral's own Docker guide,
  verified 2026-09-03): `uv sync --locked` in the final stage asserts the
  lockfile is current rather than silently re-resolving; `--frozen` for
  intermediate stages. See `dev-speed.md` Phase 1 for the full pattern.
- **Python + plain pip**: `pip install --require-hashes -r requirements.txt`
  enforces a hash for every requirement *and* every transitive dependency,
  and requires every requirement be pinned (`==`, a URL, or a path) — this
  exists specifically to prevent "a new release surprises the hash check."
- **npm: `npm ci`, never `npm install`, in any Dockerfile.** Documented
  differences (npm CLI v11 docs, verified 2026-09-03): requires an existing
  lockfile; deletes any existing `node_modules` first; never writes to
  `package.json`/the lockfile; **errors instead of silently updating the
  lockfile** if `package.json` and the lockfile disagree. That last property
  is exactly the reproducibility guarantee a Docker build needs.

**GPU/ML-specific wrinkles:** a CUDA PyTorch install comes from
`--index-url https://download.pytorch.org/whl/cu128` (or similar), not
plain PyPI — a lockfile needs to record that index (`uv` supports this via
`[tool.uv.index]`/`[tool.uv.sources]`). And **a wheel you compiled yourself in
a builder stage has no upstream artifact to hash-pin** — its reproducibility
contract is the pinned source SHA (`dev-speed.md` Phase 4) plus pinned exact
library versions across the ABI boundary, which is complementary to a
lockfile, not a substitute for one. Avoid mixing installers (e.g., `uv` in
CI, bare `pip` in the Dockerfile) — two install paths is two chances to
silently drift, and for numerical ML code, drift can mean different output,
not just a crash.

## Multi-platform builds — usually skip, for a GPU image

`docker buildx build --platform linux/amd64,linux/arm64 .` works via QEMU
emulation (no Dockerfile changes, but Docker's own docs warn compute-heavy
steps like compilation can be dramatically slower under emulation), native
multi-node builders, or cross-compilation (language-dependent,
`BUILDPLATFORM`/`TARGETOS`/`TARGETARCH`).

**For a CUDA/PyTorch image, skip this.** NVIDIA's desktop/datacenter CUDA
stack and PyTorch's CUDA wheels are `linux/amd64`; an `arm64` GPU target
(Jetson-class, GH200-class) is a genuinely different platform with different
base images and driver assumptions — it would not be "the same image, another
arch," it would be a second port with its own validation burden. And
QEMU-emulating a multi-minute `nvcc`/C++ extension compile is precisely the
worst case Docker's own docs warn about. Two narrow exceptions: a non-GPU
sidecar in the same repo (a small Node/Go service) is cheap to build
multi-platform normally; and if developers on Apple Silicon need to pull your
image, they need either an amd64 emulation path or a separate CPU-only arm64
variant of the *non-GPU* services specifically — not the CUDA one.
