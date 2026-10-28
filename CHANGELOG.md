# Changelog

Every released version of **docker-image-playbook**, newest first.

A release is one number, `metadata.version` in `SKILL.md`; both installers read it from there. It is
bumped only by `tools/bump-version.sh`, which refuses to run without an entry for that version in
this file, and tagged only by `tools/tag-release.sh`, which derives the tag name from `SKILL.md` so
the two cannot disagree. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for what each number means.

Versions 1.0.0 to 1.2.0 were tagged after the fact, on the commit that declared each one.

---

## 1.3.0 — 2026-10-28

Install a specific release instead of whatever `main` is today.

### Added
- `install.sh --version X.Y.Z` and `install.ps1 -Version X.Y.Z` (or `DOCKER_SKILL_VERSION`, which also
  works with the piped `irm | iex` form) download the git tag `vX.Y.Z`. The installer refuses to
  install if that tag's `SKILL.md` declares a different version, if the version is malformed, or if
  it is combined with a local clone (where it would silently install the wrong files). Needs 1.2.0
  or newer; older tags get an error that says so and how to install them from a checkout.

## 1.2.1 — 2026-10-28

Examples and structure made independent of any one project or machine; release tooling added.

### Changed
- `SKILL.md`: Phase 0 and the fast checklist now come before Phase -1, so they fall inside the first
  ~5k tokens Claude Code re-attaches after auto-compaction.
- `SKILL.md`: GPU/CUDA-only checklist items are marked as such; the worked example is framed as a
  case study (its numbers belong to that machine); `description` gained the "build cache / disk keeps
  growing" trigger.
- `dev-speed.md` Phase 5: the GC budget is sized per host (role, working set, disk headroom) instead
  of from a fixed number.
- Project-specific stage names and wording removed from examples.

### Added
- `CHANGELOG.md`, `CONTRIBUTING.md`, and the maintainer tools in `tools/` (`bump-version.sh`,
  `tag-release.sh`, `check-consistency.py`). They are not part of the installed skill.

## 1.2.0 — 2026-10-28

Build-cache diagnostics and stage-order checks.

### Added
- `scripts/cache_report.py`: read-only ranking of `docker buildx du` records by the instruction that
  created them.
- `scripts/audit_dockerfile.py`: `copy-before-install`, `install-after-parent-copy` (an install behind
  a source `COPY`, in the same stage or a parent stage) and `no-dockerignore`.
- `dev-speed.md`: source `COPY` belongs in leaf stages; cache mounts never reach the image; measuring
  the context and the `COPY` layer; per-Dockerfile and allowlist `.dockerignore`; proving the GC
  policy loaded with `docker buildx inspect`.

### Fixed
- `audit_dockerfile.py`: `from-no-tag` fired on `FROM <earlier stage>`.
- `dev-speed.md`: `defaultKeepStorage` was called "the old name"; Docker's own pages disagree, so it
  is now recorded as unverified.

## 1.1.0 — 2026-09-03

### Added
- Phase -1: scaffolding a Docker environment from zero (infer from the repo, verify by running, ask
  sparingly), with `scaffolding-from-zero.md` for the full signal tables, Compose merge/watch
  mechanics, monorepo/CI detail and the brownfield algorithm.

## 1.0.0 — 2026-09-03

First tagged version.

### Added
- `SKILL.md`, `dev-speed.md`, `production-hardening.md` and `scripts/audit_dockerfile.py`.
- Bash and PowerShell installers, including the `curl`/`irm` one-liner that needs no clone.
- English and Brazilian Portuguese READMEs.
