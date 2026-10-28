# Docker-Skill

A [Claude Code](https://code.claude.com) skill: cut Docker/BuildKit build
time and harden images for production. Load it whenever you're writing or
editing a `Dockerfile`/`docker-compose.yml`, when a build "feels slow," or
before shipping a container.

*(Leia em [português](README.pt-BR.md).)*

## Why this exists

A real build broke three ways in one session — a floating base-image
version, a `git clone --depth 1 && checkout <sha>` pin that only worked by
accident, a relative-path script that silently no-op'd — and, once fixed,
still took 52 minutes cold. Cleaning up cache hygiene alone (BuildKit cache
mounts, layer ordering, `.dockerignore`, GC sizing) dropped the next build to
**18 seconds**, no code changes. Every rule in this skill is either something
measured on a real build or a claim from an official source, tagged with when
it was checked — see `SKILL.md`'s "Explicitly unverified" table for what
*isn't* nailed down yet.

## What's inside

| File | Covers |
|---|---|
| `SKILL.md` | Navigation, scaffolding a Docker setup from zero (infer from the repo, ask sparingly, dev/prod separation, verify instead of asking), the one lesson that matters most for existing builds (measure before you optimize), a fast checklist, and a worked example. Loads first. |
| `scaffolding-from-zero.md` | Full depth behind the scaffolding phase: complete signal tables (every package manager, every framework covered), Compose merge/watch mechanics, monorepo/CI detail, the brownfield reconciliation algorithm, version floors. |
| `dev-speed.md` | Build speed: layer ordering, BuildKit cache mounts (and the two ways to silently defeat them), `.dockerignore` hygiene beyond the obvious, pinning upstream refs correctly, multi-stage `COPY` placement, shared-context `.dockerignore` (per-Dockerfile and allowlist forms), GC sizing and how to verify it took effect, right-sized package installs, `ninja` for native/CUDA extension builds. |
| `production-hardening.md` | Shipping: non-root users (and the GPU-specific gotchas under them), multi-stage builds, CUDA base-image tiers, secrets (`--mount=type=secret`, never `ARG`/`ENV`), digest pinning, vulnerability scanning, SBOM/provenance, `HEALTHCHECK`, image size, GPU exposure (CDI vs. the legacy runtime), read-only rootfs, lockfiles, multi-platform builds. |
| `scripts/audit_dockerfile.py` | A mechanical, dependency-free pass over one or more Dockerfiles for the checklist's grep-able subset: contradictory cache-mount flags, fragile shallow-clone pins, secret-shaped `ARG`/`ENV` names, floating/undigested tags, missing `USER`/`HEALTHCHECK`, and two instruction-order checks (an install behind a source `COPY`, in the same stage or a parent stage). Advisory, not a substitute for Trivy/Grype/Docker Scout. |
| `scripts/cache_report.py` | Read-only report on *why* the BuildKit cache is big: groups `docker buildx du` records by the instruction that created them and ranks them by bytes, flagging whole-tree `COPY` layers that carry more than source and install layers recreated under many parent chains. |

GPU/ML (CUDA, PyTorch) images get their own callouts throughout — this
started as the playbook for one project's CUDA 13 + PyTorch + a
source-compiled extension image, but every general Docker/BuildKit rule in
it applies to any language or stack.

## Install

No `git clone` needed — the installer downloads the skill straight from
GitHub. Both scripts support a global install (every Claude Code session on
the machine, the default) or a project install (this repo only, `--project`
/ `-Project`), and refuse to overwrite an existing install unless you pass
the force flag.

**macOS / Linux / WSL:**

```sh
curl -fsSL https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.sh | bash
```

Installs to `~/.claude/skills/docker-image-playbook`. With flags — note the
`-s --`, required when piping into bash:

```sh
curl -fsSL .../install.sh | bash -s -- --project   # ./.claude/skills/docker-image-playbook
curl -fsSL .../install.sh | bash -s -- --force      # overwrite an existing install
curl -fsSL .../install.sh | bash -s -- --uninstall  # remove it, no download needed
```

**Windows (PowerShell 5.1+, ships with Windows 10 and later):**

```powershell
irm https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.ps1 | iex
```

The piped form can't take parameters. For `-Project`, `-Force`, or
`-Uninstall`, download it first:

```powershell
irm https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.ps1 -OutFile install.ps1
./install.ps1 -Project -Force
```

`install.sh` also runs fine on Windows if you have Git Bash or WSL instead
of using `install.ps1`.

If a Claude Code session is already running, it picks up a global install
under `~/.claude/skills/` live, no restart needed, as long as that directory
already existed when the session started. A brand-new project-level
`.claude/skills/` needs a session restart to be watched.

**Working on the skill itself:** run either script from inside a clone of
this repo (`./install.sh`, not piped) and it installs your local working
copy instead of downloading — so editing a file and re-running
`./install.sh --force` picks up the edit with no network round-trip. That
local-copy detection only fires for a script executed from disk; piped in
via `curl | bash` / `irm | iex`, there is no local copy to read, so it
always downloads.

**Platform coverage:** `install.sh` uses only POSIX/bash-3.2-compatible
constructs (arrays, `${BASH_SOURCE[0]}`, `cp -R`, a `sed`-free `usage()`,
plain globs instead of `find -quit`) specifically so it runs unmodified on
macOS's stock BSD toolchain, not just Linux — every path (local install,
download install, `--force`, `--project`, `--uninstall`, the non-interactive
overwrite guard, a failed download) has been execute-tested, but so far only
on Linux/WSL2, not on real macOS. `install.ps1` has been execute-tested end
to end too, but under PowerShell 7 (`pwsh`) on Linux, not Windows PowerShell
5.1 on actual Windows — the two are close but not identical. If you run
either on a platform it hasn't been verified on yet, please open an issue
either way — success or failure both help.

## Using it

Claude Code loads the skill automatically when it's relevant (editing a
Dockerfile, a build failing or feeling slow, shipping a container) — nothing
to invoke by hand. To run the scripts yourself:

```sh
python3 ~/.claude/skills/docker-image-playbook/scripts/audit_dockerfile.py Dockerfile
python3 ~/.claude/skills/docker-image-playbook/scripts/cache_report.py   # why is the build cache big?
```

## Keeping it current

Docker/BuildKit/NVIDIA's container stack moves fast enough that a fact in
here can go stale within a release cycle — the skill documents one real
example (NVIDIA's GPU-exposure default changing under the hood between two
toolkit versions) that happened exactly this way. Corrections and additions
are welcome as issues or PRs, especially "this is now outdated, here's the
current official source."

## License

[MIT](LICENSE)
