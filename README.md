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
| `SKILL.md` | Navigation, the one lesson that matters most (measure before you optimize), a fast checklist, and a worked example. Loads first. |
| `dev-speed.md` | Build speed: layer ordering, BuildKit cache mounts (and the two ways to silently defeat them), `.dockerignore` hygiene beyond the obvious, pinning upstream refs correctly, GC sizing, right-sized package installs, `ninja` for native/CUDA extension builds. |
| `production-hardening.md` | Shipping: non-root users (and the GPU-specific gotchas under them), multi-stage builds, CUDA base-image tiers, secrets (`--mount=type=secret`, never `ARG`/`ENV`), digest pinning, vulnerability scanning, SBOM/provenance, `HEALTHCHECK`, image size, GPU exposure (CDI vs. the legacy runtime), read-only rootfs, lockfiles, multi-platform builds. |
| `scripts/audit_dockerfile.py` | A mechanical, dependency-free pass over one or more Dockerfiles for the checklist's grep-able subset: contradictory cache-mount flags, fragile shallow-clone pins, secret-shaped `ARG`/`ENV` names, floating/undigested tags, missing `USER`/`HEALTHCHECK`. Advisory, not a substitute for Trivy/Grype/Docker Scout. |

GPU/ML (CUDA, PyTorch) images get their own callouts throughout — this
started as the playbook for one project's CUDA 13 + PyTorch + a
source-compiled extension image, but every general Docker/BuildKit rule in
it applies to any language or stack.

## Install

Clone and run the installer for your platform. Both support a global
install (every Claude Code session on the machine) or a project install
(this repo only), and refuse to overwrite an existing install unless you
pass the force flag.

**macOS / Linux / WSL:**

```sh
git clone https://github.com/fabricandosuaideia/Docker-Skill.git
cd Docker-Skill
./install.sh              # global:  ~/.claude/skills/docker-image-playbook
# ./install.sh --project  # project: ./.claude/skills/docker-image-playbook
```

**Windows (PowerShell):**

```powershell
git clone https://github.com/fabricandosuaideia/Docker-Skill.git
cd Docker-Skill
./install.ps1              # global:  $HOME/.claude/skills/docker-image-playbook
# ./install.ps1 -Project   # project: ./.claude/skills/docker-image-playbook
```

Re-running either script refuses to overwrite an existing install — pass
`--force` (`-Force` on Windows) to update. Pass `--uninstall` (`-Uninstall`)
to remove it.

If a Claude Code session is already running, it picks up a global install
under `~/.claude/skills/` live, no restart needed, as long as that directory
already existed when the session started. A brand-new project-level
`.claude/skills/` needs a session restart to be watched.

**Platform coverage:** `install.sh` uses only POSIX/bash-3.2-compatible
constructs (arrays, `${BASH_SOURCE[0]}`, `cp -R`, a `sed` substitution
without GNU-only interval syntax) specifically so it runs unmodified on
macOS's stock BSD toolchain, not just Linux — but it's only been
execute-tested on Linux/WSL2 so far. `install.ps1` has had no PowerShell
runtime available to execute-test at all, only a structural review. If you
run either on a platform it hasn't been verified on, please open an issue
either way — success or failure both help.

## Using it

Claude Code loads the skill automatically when it's relevant (editing a
Dockerfile, a build failing or feeling slow, shipping a container) — nothing
to invoke by hand. To run the audit script yourself:

```sh
python3 ~/.claude/skills/docker-image-playbook/scripts/audit_dockerfile.py Dockerfile
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
