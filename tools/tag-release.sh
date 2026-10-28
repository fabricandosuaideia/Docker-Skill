#!/usr/bin/env bash
#
# tag-release.sh -- tag the current commit with the version SKILL.md declares, or refuse.
#
# The tag name is not an argument: it is read from SKILL.md, so a tag can never name a
# version the commit does not declare. It refuses unless ALL of these hold:
#
#   - the branch is main
#   - the working tree is clean (what is tagged is exactly what is on disk)
#   - CHANGELOG.md's newest entry is this version
#   - tools/check-consistency.py passes
#   - the tag does not exist yet (a published version is never moved)
#
# The annotated tag's message is the CHANGELOG entry for the version. It creates the tag
# locally and NEVER pushes: publishing is a separate, deliberate step it only prints.
#
# Usage:  tools/tag-release.sh
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
SEMVER='[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*'

die() { printf 'tag-release: %s\n' "$1" >&2; exit "${2:-1}"; }

case "${1:-}" in
  -h|--help) sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac
[ "$#" -eq 0 ] || die "takes no arguments: the version comes from SKILL.md" 2

git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $ROOT"

FM_END="$(grep -n -m 2 '^---[[:space:]]*$' SKILL.md | sed -n '2s/:.*//p')"
VERSION="$(sed -n "1,${FM_END}p" SKILL.md | grep -m 1 "^[[:space:]]*version:" | grep -o "$SEMVER" | sed -n '1p' || true)"
[ -n "$VERSION" ] || die "no version found in the SKILL.md frontmatter"
TAG="v${VERSION}"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "on '$BRANCH', not main. Releases are tagged from main."
[ -z "$(git status --porcelain)" ] || die "the working tree is not clean; commit or stash first:
$(git status --short)"

TOP="$(grep -m 1 -o "^## ${SEMVER}" CHANGELOG.md | grep -o "$SEMVER" || true)"
[ "$TOP" = "$VERSION" ] || die "CHANGELOG.md's newest entry is '${TOP:-<none>}' but SKILL.md declares $VERSION."

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "$TAG already exists (at $(git rev-parse --short "$TAG^{commit}")). A released version is never re-tagged; bump to a new one."

echo "Running the consistency check..."
python3 tools/check-consistency.py --root "$ROOT" || die "the consistency check failed; nothing was tagged."

# Message: a subject line, then the CHANGELOG section for this version (up to the next '## ').
NOTES="$(awk -v v="$VERSION" '
  $0 ~ "^## " v "([[:space:]]|$)" { on=1; next }
  on && /^## / { exit }
  on { print }' CHANGELOG.md | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
MSG="docker-image-playbook ${TAG}

${NOTES}"

# --cleanup=verbatim: the default strips lines starting with "#", which would eat the
# "### Added" / "### Fixed" headings of the CHANGELOG section.
git tag -a --cleanup=verbatim "$TAG" -m "$MSG"
printf 'Tagged %s at %s (local only).\n\n' "$TAG" "$(git rev-parse --short HEAD)"
printf 'To publish it:\n  git push origin main %s\n' "$TAG"
