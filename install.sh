#!/usr/bin/env bash
# install.sh -- install docker-image-playbook into a Claude Code skills
# directory (macOS/Linux/WSL). For Windows PowerShell, use install.ps1.
#
# Usage:
#   ./install.sh               # global install:  ~/.claude/skills/docker-image-playbook
#   ./install.sh --project     # project install:  ./.claude/skills/docker-image-playbook
#   ./install.sh --force       # overwrite an existing install
#   ./install.sh --uninstall   # remove the installed skill
#   ./install.sh --project --force --uninstall  # flags compose
#
# Safe to re-run: without --force it refuses to overwrite an existing
# install rather than silently clobbering local edits.
set -euo pipefail

SKILL_NAME="docker-image-playbook"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES=(SKILL.md dev-speed.md production-hardening.md scripts)

SCOPE="global"
FORCE=0
UNINSTALL=0

usage() {
  # `sed 's/^# *//'` (not `\{0,1\}`) deliberately -- macOS ships BSD sed,
  # not GNU sed, and this simpler form needs no interval-expression support
  # from either.
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# *//'
}

for arg in "$@"; do
  case "$arg" in
    --project|--local) SCOPE="project" ;;
    --global) SCOPE="global" ;;
    --force|-f) FORCE=1 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $arg" >&2
      usage >&2
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

for f in "${FILES[@]}"; do
  if [ ! -e "${SCRIPT_DIR}/${f}" ]; then
    echo "error: ${SCRIPT_DIR}/${f} not found -- run this script from a full clone of the repo" >&2
    exit 1
  fi
done

if [ -d "$TARGET" ] && [ "$FORCE" != "1" ]; then
  echo "error: ${TARGET} already exists. Re-run with --force to overwrite." >&2
  exit 1
fi

mkdir -p "$TARGET_ROOT"
rm -rf "$TARGET"
mkdir -p "$TARGET"
for f in "${FILES[@]}"; do
  cp -R "${SCRIPT_DIR}/${f}" "${TARGET}/${f}"
done
chmod +x "${TARGET}/scripts/"*.py 2>/dev/null || true

echo "Installed ${SKILL_NAME} -> ${TARGET}"
if [ "$SCOPE" = "project" ]; then
  echo "This may be a new top-level skills directory for this session --"
  echo "restart Claude Code (or start a new session) in this project to load it."
else
  echo "If a Claude Code session is already running, it picks up changes under"
  echo "~/.claude/skills/ live. Otherwise it's ready the next time you start one."
fi
