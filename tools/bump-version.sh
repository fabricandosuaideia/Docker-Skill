#!/usr/bin/env bash
#
# bump-version.sh -- set the release version, or refuse.
#
# The version lives in one place, `metadata.version` in SKILL.md (both installers read it
# from there). What can drift is everything around it: a release with no CHANGELOG entry,
# or a number that goes backwards. This script makes both impossible to do by accident:
#
#   1. The new version must be bare MAJOR.MINOR.PATCH and strictly greater than the current.
#   2. CHANGELOG.md must already have a `## <new-version> -- <date>` entry, and it must be
#      the newest one. Write the entry first; the version follows the notes, not the reverse.
#   3. After writing SKILL.md it runs tools/check-consistency.py. If that fails, SKILL.md is
#      put back exactly as it was, so a failed bump leaves nothing half-done.
#
# It does not commit and it does not tag. Review `git diff`, commit, then run
# tools/tag-release.sh.
#
# Usage:  tools/bump-version.sh <new-version>
#         tools/bump-version.sh 1.3.0
#
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$ROOT/SKILL.md"
CHANGELOG="$ROOT/CHANGELOG.md"
SEMVER='[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*'

die() { printf 'bump-version: %s\n' "$1" >&2; exit "${2:-1}"; }

usage() {
  cat >&2 <<'EOF'
usage: tools/bump-version.sh <new-version>

Sets metadata.version in SKILL.md. <new-version> must be bare MAJOR.MINOR.PATCH, strictly
greater than the current one, and already be the newest entry in CHANGELOG.md.
Runs tools/check-consistency.py afterwards and restores SKILL.md if it fails.
EOF
  exit 2
}

case "${1:-}" in -h|--help) usage ;; esac
[ "$#" -eq 1 ] || usage
NEW="$1"
printf '%s\n' "$NEW" | grep -q "^${SEMVER}$" \
  || die "'$NEW' is not a bare MAJOR.MINOR.PATCH version (no leading 'v', no suffix)"

[ -f "$SKILL" ] || die "not found: $SKILL"
[ -f "$CHANGELOG" ] || die "not found: $CHANGELOG"

# The `version:` line inside the frontmatter (above the closing ---), never one in the prose.
FM_END="$(grep -n -m 2 '^---[[:space:]]*$' "$SKILL" | sed -n '2s/:.*//p')"
[ -n "$FM_END" ] || die "SKILL.md has no closing '---' for its frontmatter"
OFFSET="$(sed -n "1,${FM_END}p" "$SKILL" | grep -n -m 1 "^[[:space:]]*version:[[:space:]]*\"\{0,1\}${SEMVER}" | sed -n '1s/:.*//p' || true)"
[ -n "$OFFSET" ] || die "could not find a 'version: X.Y.Z' line in the SKILL.md frontmatter"
CURRENT="$(sed -n "${OFFSET}p" "$SKILL" | grep -o "$SEMVER" | sed -n '1p')"

version_gt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$1"; IFS=. read -r b1 b2 b3 <<< "$2"
  if [ "$((10#$a1))" -ne "$((10#$b1))" ]; then [ "$((10#$a1))" -gt "$((10#$b1))" ]; return; fi
  if [ "$((10#$a2))" -ne "$((10#$b2))" ]; then [ "$((10#$a2))" -gt "$((10#$b2))" ]; return; fi
  [ "$((10#$a3))" -gt "$((10#$b3))" ]
}
version_gt "$NEW" "$CURRENT" || die "$NEW is not greater than the current version $CURRENT"

# Newest CHANGELOG entry = the first '## X.Y.Z' heading.
TOP="$(grep -m 1 -o "^## ${SEMVER}" "$CHANGELOG" | grep -o "$SEMVER" || true)"
[ "$TOP" = "$NEW" ] || die "CHANGELOG.md's newest entry is '${TOP:-<none>}', not $NEW. Write the '## $NEW -- <date>' entry first." 1

BACKUP="$(mktemp)"
trap 'rm -f "$BACKUP"' EXIT
cat "$SKILL" > "$BACKUP"

TMP="${SKILL}.bump.$$"
sed "${OFFSET}s/${SEMVER}/${NEW}/" "$SKILL" > "$TMP"
cat "$TMP" > "$SKILL"      # through the existing file, so its mode and inode survive
rm -f "$TMP"

printf '%s -> %s\n\n  updated  %s (metadata.version, line %s)\n\n' "$CURRENT" "$NEW" "$SKILL" "$OFFSET"

command -v python3 >/dev/null 2>&1 || { cat "$BACKUP" > "$SKILL"; die "python3 not found; the consistency gate cannot run, so SKILL.md was restored."; }
echo "Running the consistency check..."
if ! python3 "$ROOT/tools/check-consistency.py" --root "$ROOT"; then
  cat "$BACKUP" > "$SKILL"
  die "the consistency check failed, so SKILL.md was restored to $CURRENT. Fix what it reported and run again."
fi

printf '\n%s\n%s\n' "Review with 'git diff', commit, then run tools/tag-release.sh." \
  "(Nothing was committed or tagged.)"
