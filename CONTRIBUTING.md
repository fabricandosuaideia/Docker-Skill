# Contributing

## What a version number means here

The version is `metadata.version` in `SKILL.md`; both installers read it from there. This is a skill,
not a library, so "breaking" means breaking for the people who installed it or for Claude's use of it.

| Bump | When |
|---|---|
| **MAJOR** | The skill is renamed or restructured so an existing install or a reference to it stops working: a renamed skill, a removed file or script, a changed install path. |
| **MINOR** | New capability: a new phase, reference file, script, audit check or installer option, or a new trigger in `description`. |
| **PATCH** | Corrections and rewording: a fixed claim, a fixed false positive, examples made more general, release tooling. |

## Releasing

Releases are cut from `main`, and each step refuses rather than guesses:

1. Write the `## X.Y.Z — YYYY-MM-DD` entry at the top of [`CHANGELOG.md`](CHANGELOG.md).
2. `tools/bump-version.sh X.Y.Z` — sets the version in `SKILL.md`. It refuses a version that is not
   strictly greater, or one with no newest CHANGELOG entry, and runs the consistency check; if that
   fails it puts `SKILL.md` back.
3. Review `git diff`, then commit.
4. `tools/tag-release.sh` — creates the annotated tag `vX.Y.Z` from the version in `SKILL.md`, with the
   CHANGELOG entry as its message. It refuses unless you are on `main` with a clean tree, the
   CHANGELOG matches, the check passes, and the tag does not exist. It never pushes.
5. Publish when you decide to: `git push origin main vX.Y.Z`.

A published tag is never moved. If a release is wrong, fix it in a new version.

## The consistency check

`python3 tools/check-consistency.py` verifies the facts this repository states in more than one
place. Run it after any edit to `SKILL.md`, a reference file, a script or an installer. It checks:

- `SKILL.md` against Claude Code's skill limits (`description` ≤ 1,536 characters, < 500 lines).
- The newest CHANGELOG entry equals the `SKILL.md` version, and every git tag points at a commit that
  declares that version and has a CHANGELOG entry.
- Both installers copy exactly the reference files in the repo root and the files in `scripts/`.
- Every shipped file is named in `README.md`, `README.pt-BR.md` and the map in `SKILL.md`.
- The links in `SKILL.md` resolve, and the scripts and installers parse.

### Adding a file to the installed skill

A new reference `.md` in the root, or a new file in `scripts/`, has to be added in four places, and
the check fails until it is: the file lists in `install.sh` and `install.ps1`, both READMEs, and the
map in `SKILL.md`. Files in `tools/` are maintainer tools and are never installed.
