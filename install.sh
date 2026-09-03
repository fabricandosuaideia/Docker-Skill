#!/usr/bin/env bash
# install.sh -- install docker-image-playbook into a Claude Code skills
# directory (macOS/Linux/WSL). For Windows PowerShell, use install.ps1.
#
# No git clone needed -- this downloads the skill straight from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/fabricandosuaideia/Docker-Skill/main/install.sh | bash
#
# With flags (note the `-s --`, required when piping into bash):
#   curl -fsSL .../install.sh | bash -s -- --project
#   curl -fsSL .../install.sh | bash -s -- --force
#   curl -fsSL .../install.sh | bash -s -- --uninstall
#
# Installs SKILL.md + dev-speed.md + production-hardening.md + scripts/ into
# ~/.claude/skills/docker-image-playbook (default) or
# ./.claude/skills/docker-image-playbook with --project.
#
# Run from inside a clone of this repo, it installs the local copy instead
# of downloading -- so editing a file and re-running `./install.sh --force`
# picks up the edit, no network involved. Piped via curl, it always
# downloads (there is no local copy to read). Needs curl + tar only in the
# download path.
#
# Safe to re-run: without --force it refuses to overwrite an existing
# install rather than silently clobbering local edits.
set -euo pipefail

REPO="fabricandosuaideia/Docker-Skill"
BRANCH="${DOCKER_SKILL_BRANCH:-main}"
SKILL_NAME="docker-image-playbook"
SCOPE="global"
FORCE=0
UNINSTALL=0

# The skill is these files and nothing else. Used to validate a download (or
# a local clone) before anything on disk is touched.
REQUIRED_FILES=(dev-speed.md production-hardening.md)
REQUIRED_SCRIPTS=(audit_dockerfile.py)

print_status()  { echo "-> $1"; }
print_success() { echo "OK $1"; }
print_error()   { echo "ERROR $1" >&2; }

show_help() {
  cat <<EOF
Usage: install.sh [OPTIONS]

Install the docker-image-playbook Claude Code skill.

Options:
  --project, --local   Install to ./.claude/skills/${SKILL_NAME}
  --global              Install to ~/.claude/skills/${SKILL_NAME} (default)
  --force, -f           Overwrite an existing install without prompting
  --uninstall           Remove the installed skill (no download needed)
  -h, --help            Show this help message

Examples:
  curl -fsSL <url>/install.sh | bash
  curl -fsSL <url>/install.sh | bash -s -- --project
  curl -fsSL <url>/install.sh | bash -s -- --force
  ./install.sh --project --force   (from a local clone)

When piping into bash, flags MUST come after \`-s --\`; \`| bash --project\`
is parsed by bash itself and fails.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --project|--local) SCOPE="project" ;;
    --global) SCOPE="global" ;;
    --force|-f) FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) show_help; exit 0 ;;
    *)
      print_error "Unknown option: $arg"
      show_help >&2
      exit 1
      ;;
  esac
done

if [ "$SCOPE" = "project" ]; then
  TARGET_ROOT="$(pwd)/.claude/skills"
else
  TARGET_ROOT="${HOME}/.claude/skills"
fi
TARGET="${TARGET_ROOT}/${SKILL_NAME}"

if [ "$UNINSTALL" = "1" ]; then
  if [ -d "$TARGET" ]; then
    rm -rf "$TARGET"
    echo "Removed ${TARGET}"
  else
    echo "Not installed at ${TARGET}"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Read the version out of a SKILL.md frontmatter, which carries it as an
# indented, QUOTED scalar:
#
#     metadata:
#       version: "1.0.0"
#
# so the quotes have to come off. Pure bash -- no grep/sed/awk, hence no new
# dependency and no pipeline to interact with `set -o pipefail`. A SKILL.md
# predating the field (or an unreadable one) yields "unknown" instead of
# aborting the run: under `set -e` a non-matching extractor that returns
# non-zero would kill the install, and a missing version is not a reason to
# refuse to install.
# ---------------------------------------------------------------------------
skill_version() {
  local file="$1" line version="" in_frontmatter="false"
  [ -r "$file" ] || { echo "unknown"; return 0; }
  # `|| [ -n "$line" ]` so a final line without a trailing newline is still
  # seen; `${line%$'\r'}` so a CRLF checkout does not smuggle a \r into the
  # version string and make every comparison differ.
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "$line" = "---" ]; then
      if [ "$in_frontmatter" = "true" ]; then break; fi
      in_frontmatter="true"
      continue
    fi
    if [ "$in_frontmatter" = "true" ] && [[ "$line" =~ ^[[:space:]]*version:[[:space:]]*\"?([^\"[:space:]]+) ]]; then
      version="${BASH_REMATCH[1]}"
      break
    fi
  done < "$file"
  echo "${version:-unknown}"
}

# ---------------------------------------------------------------------------
# Local-clone fast path: only reachable when this file is actually being
# executed from disk (`./install.sh`, `bash install.sh`) with the rest of
# the repo sitting next to it. Piped via `curl | bash`, ${BASH_SOURCE[0]} is
# unset (verified empirically: piping a script into bash gives it no source
# path at all) so this is skipped and the download path below always runs --
# there is no ambiguity about which copy wins.
# ---------------------------------------------------------------------------
LOCAL_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  CANDIDATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "${CANDIDATE_DIR}/SKILL.md" ] && [ -f "${CANDIDATE_DIR}/dev-speed.md" ] \
     && [ -f "${CANDIDATE_DIR}/production-hardening.md" ] \
     && [ -f "${CANDIDATE_DIR}/scripts/audit_dockerfile.py" ]; then
    LOCAL_DIR="$CANDIDATE_DIR"
  fi
fi

# ---------------------------------------------------------------------------
# Overwrite guard. Runs before the download so a `curl | bash` that's about
# to fail this check doesn't spend time fetching a tarball first.
#
# Read from the terminal, never stdin: under `curl | bash` the script body IS
# stdin, so a bare `read` swallows the next line of the script instead of
# user input. With no tty (CI, nested pipe) we refuse rather than guess, so
# the failure is visible instead of masquerading as a user cancellation.
# ---------------------------------------------------------------------------
if [ -d "$TARGET" ] && [ "$FORCE" != "1" ]; then
  echo "An existing install was found at: $TARGET"
  if { exec 3< /dev/tty; } 2>/dev/null; then
    read -r -p "Overwrite it? (y/N) " REPLY <&3 || REPLY=""
    exec 3<&-
    case "$REPLY" in
      [Yy]) ;;
      *) echo "Installation cancelled."; exit 0 ;;
    esac
  else
    print_error "Non-interactive shell and $TARGET already exists."
    echo "Re-run with --force to overwrite:" >&2
    echo "  curl -fsSL <url>/install.sh | bash -s -- --force" >&2
    exit 1
  fi
fi

TMP_DIR=""
STAGE="${TARGET}.tmp.$$"
cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; rm -rf "$STAGE"; }
trap cleanup EXIT

if [ -n "$LOCAL_DIR" ]; then
  print_status "Installing from local clone at ${LOCAL_DIR}..."
  SRC_DIR="$LOCAL_DIR"
else
  for bin in curl tar; do
    command -v "$bin" >/dev/null 2>&1 || { print_error "'$bin' is required but not on PATH."; exit 1; }
  done

  TMP_DIR="$(mktemp -d)"
  print_status "Downloading ${SKILL_NAME} (${BRANCH})..."
  TARBALL_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
  if ! curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/skill.tar.gz"; then
    print_error "Failed to download ${TARBALL_URL}"
    echo "If the repository or branch is unreachable, install by hand from a clone:" >&2
    echo "  git clone https://github.com/${REPO}.git && cd Docker-Skill && ./install.sh" >&2
    exit 1
  fi

  tar -xzf "$TMP_DIR/skill.tar.gz" -C "$TMP_DIR"

  # Glob, not `find ... -print -quit`: avoids depending on a find flag whose
  # BSD (macOS) vs. GNU (Linux) behavior might differ, and needs no pipeline
  # to interact with `set -o pipefail`. A GitHub branch tarball always
  # extracts to exactly one top-level `<repo>-<branch>` directory.
  SRC_DIR=""
  for d in "$TMP_DIR"/Docker-Skill-*/; do
    [ -d "$d" ] && SRC_DIR="${d%/}"
    break
  done
fi

# Validate the payload BEFORE touching the destination. A partial download
# that yielded SKILL.md but not dev-speed.md/production-hardening.md would
# install a skill whose own navigation table links to missing files --
# silent capability loss.
[ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/SKILL.md" ] || { print_error "Source has no SKILL.md -- aborting."; exit 1; }
for f in "${REQUIRED_FILES[@]}"; do
  [ -f "$SRC_DIR/$f" ] || { print_error "Source is missing $f -- aborting."; exit 1; }
done
[ -d "$SRC_DIR/scripts" ] || { print_error "Source has no scripts/ -- aborting."; exit 1; }
for s in "${REQUIRED_SCRIPTS[@]}"; do
  [ -f "$SRC_DIR/scripts/$s" ] || { print_error "Source is missing scripts/$s -- aborting."; exit 1; }
done

# Announce which version is going in, and which one it displaces. This is the
# only moment in the flow where the incoming version and the one already on
# disk are both available -- say it out loud, or a user sitting on an old
# install has no way to tell.
NEW_VERSION="$(skill_version "$SRC_DIR/SKILL.md")"
if [ -d "$TARGET" ]; then
  OLD_VERSION="$(skill_version "$TARGET/SKILL.md")"
  if [ "$OLD_VERSION" = "$NEW_VERSION" ]; then
    print_status "already at ${NEW_VERSION} -- reinstalling"
  else
    print_status "installing ${NEW_VERSION} (replacing ${OLD_VERSION})"
  fi
else
  print_status "installing ${NEW_VERSION}"
fi

# Stage into a sibling, then swap. The destination is never left half-written.
print_status "Installing to ${TARGET}..."
rm -rf "$STAGE"
mkdir -p "$STAGE/scripts"
cp "$SRC_DIR/SKILL.md" "$STAGE/"
for f in "${REQUIRED_FILES[@]}"; do
  cp "$SRC_DIR/$f" "$STAGE/"
done
for s in "${REQUIRED_SCRIPTS[@]}"; do
  cp "$SRC_DIR/scripts/$s" "$STAGE/scripts/"
done
chmod +x "$STAGE/scripts/"*.py 2>/dev/null || true

mkdir -p "$TARGET_ROOT"
rm -rf "$TARGET"
mv "$STAGE" "$TARGET"

if [ "$NEW_VERSION" = "unknown" ]; then
  print_success "${SKILL_NAME} (version unknown) installed at ${TARGET}"
else
  print_success "${SKILL_NAME} v${NEW_VERSION} installed at ${TARGET}"
fi
echo ""
echo "Installed:"
echo "  SKILL.md"
for f in "${REQUIRED_FILES[@]}"; do echo "  $f"; done
for s in "${REQUIRED_SCRIPTS[@]}"; do echo "  scripts/$s"; done
echo ""
if [ "$SCOPE" = "project" ]; then
  echo "This may be a new top-level skills directory for this session --"
  echo "restart Claude Code (or start a new session) in this project to load it."
else
  echo "If a Claude Code session is already running, it picks up changes under"
  echo "~/.claude/skills/ live. Otherwise it's ready the next time you start one."
fi
echo ""
echo "Run the audit script yourself with:"
echo "  python3 ${TARGET}/scripts/audit_dockerfile.py Dockerfile"
