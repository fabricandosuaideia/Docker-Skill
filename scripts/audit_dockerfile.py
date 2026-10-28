#!/usr/bin/env python3
"""Mechanical audit for a Dockerfile against docker-image-playbook's checklist.

Checks only the subset of the playbook that is genuinely a grep-able fact
about the text of the Dockerfile (a contradiction between two lines, a
fragile pin pattern, a tag with no digest, the order of two instructions in
the same stage or across stages). It does not check anything that requires
running the build, inspecting the produced image, or knowing the runtime
environment — those stay in production-hardening.md / dev-speed.md as
things a person decides, not something this script can decide for them.

Usage:
    python3 audit_dockerfile.py [path/to/Dockerfile ...]

With no arguments, audits ./Dockerfile if present. Exit code is the number
of WARN-level findings (0 = clean), so it can be used as a CI gate if wanted
-- but treat it as advisory, not a substitute for Trivy/Grype/Docker Scout
(see production-hardening.md, "Vulnerability scanning").
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path

SECRET_WORDS = {"TOKEN", "SECRET", "KEY", "PASSWORD", "PASSWD", "CREDENTIAL", "APIKEY"}

# An instruction that downloads and installs: the expensive, stable kind of
# layer that must not sit behind a COPY of the source tree.
INSTALL_RE = re.compile(
    r"apt-get\s+install\b|\bapk\s+add\b|\bpip3?\s+install\b"
    r"|\buv\s+(?:sync|pip\s+install)\b|\bnpm\s+(?:ci|install|i)\b"
    r"|\byarn\s+install\b|\bpnpm\s+(?:install|i)\b|\bbun\s+install\b"
    r"|\bpoetry\s+install\b|\bpipenv\s+install\b|\bgo\s+mod\s+download\b"
    r"|\bbundle\s+install\b|\bcomposer\s+install\b|nodesource"
)


def looks_like_secret_name(name: str) -> bool:
    """True if NAME, split on non-alphanumeric boundaries, contains a
    secret-shaped word. Word-splitting (not a \\b regex) is required because
    \\b treats '_' as a word character, so \\bTOKEN\\b never matches inside
    HF_TOKEN -- confirmed by this script's own test suite catching it.
    """
    parts = re.split(r"[^A-Za-z0-9]+", name.upper())
    return any(p in SECRET_WORDS for p in parts if p)


@dataclass
class Finding:
    line: int
    severity: str  # "WARN" or "INFO"
    check_id: str
    message: str


def join_continuations(lines: list[str]) -> list[tuple[int, str]]:
    """Join backslash-continued lines into logical lines.

    Returns (starting_line_number, joined_text) pairs so findings can still
    point at a real line in the file.
    """
    joined: list[tuple[int, str]] = []
    buf: list[str] = []
    start = 0
    for i, raw in enumerate(lines, start=1):
        stripped = raw.rstrip("\n")
        if not buf:
            start = i
        if stripped.rstrip().endswith("\\"):
            buf.append(stripped.rstrip()[:-1])
            continue
        buf.append(stripped)
        joined.append((start, "\n".join(buf)))
        buf = []
    if buf:
        joined.append((start, "\n".join(buf)))
    return joined


@dataclass
class Stage:
    name: str
    parent: str
    line: int
    source_copy_line: int = 0   # first COPY/ADD of a source tree from the context
    has_install: bool = False   # an install RUN already seen in this stage
    inherits_source_from: str = ""  # nearest ancestor stage that copies source
    inherits_line: int = 0
    parent_is_stage: bool = False  # FROM <earlier stage>, not an image


def source_copy_kind(block: str) -> str:
    """"" if BLOCK isn't a COPY/ADD from the build context of a source tree;
    "context" for the whole context (`.`, `./`, `*`); "dir" for a directory
    (trailing slash). Deliberately narrow: a manifest (`COPY go.mod ./`) is the
    *good* half of the dependency/source split and must not be flagged, and a
    bare directory name without a slash can't be told from a file by text.
    """
    m = re.match(r"\s*(COPY|ADD)\s+(.*)", block, re.IGNORECASE | re.DOTALL)
    if not m:
        return ""
    tokens = m.group(2).split()
    if any(t.lower().startswith("--from=") for t in tokens):
        return ""
    args = [t for t in tokens if not t.startswith("--") and not t.startswith("<<")]
    if len(args) < 2:
        return ""
    kind = ""
    for src in args[:-1]:
        if src in (".", "./", "./*", "*"):
            return "context"
        if src.endswith("/"):
            kind = "dir"
    return kind


def audit(text: str, dockerignore_present: bool | None = None) -> list[Finding]:
    """dockerignore_present: None = unknown (text-only audit), skips that check."""
    findings: list[Finding] = []
    raw_lines = text.split("\n")
    logical = join_continuations(raw_lines)

    has_pip_no_cache_env = bool(
        re.search(r"^\s*ENV\b.*PIP_NO_CACHE_DIR\s*=\s*1", text, re.MULTILINE)
    )
    has_healthcheck = bool(re.search(r"^\s*HEALTHCHECK\b", text, re.MULTILINE))
    has_user = bool(re.search(r"^\s*USER\b", text, re.MULTILINE))

    stages: dict[str, Stage] = {}
    current: Stage | None = None
    first_context_copy = 0

    for lineno, block in logical:
        stripped = block.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # --- stage tracking: COPY-before-install, and source COPY in a parent ---
        fm = re.match(r"FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+AS\s+(\S+))?", stripped, re.IGNORECASE)
        if fm:
            parent = fm.group(1)
            name = (fm.group(2) or f"#{len(stages)}").lower()
            current = Stage(name=name, parent=parent, line=lineno)
            anc = stages.get(parent.lower())
            if anc:
                if anc.source_copy_line:
                    current.inherits_source_from, current.inherits_line = anc.name, anc.source_copy_line
                else:
                    current.inherits_source_from, current.inherits_line = anc.inherits_source_from, anc.inherits_line
            current.parent_is_stage = anc is not None
            stages[name] = current
        elif current is not None:
            kind = source_copy_kind(stripped)
            if kind and not current.source_copy_line:
                current.source_copy_line = lineno
            if kind == "context" and not first_context_copy:
                first_context_copy = lineno
            if re.match(r"RUN\b", stripped, re.IGNORECASE) and INSTALL_RE.search(stripped):
                if "--no-deps" not in stripped:
                    if current.source_copy_line and not current.has_install:
                        findings.append(Finding(
                            lineno, "WARN", "copy-before-install",
                            f"Dependency install in stage {current.name!r} comes after the "
                            f"source COPY on line {current.source_copy_line}: every source "
                            "edit invalidates the COPY and re-runs this install. Copy only "
                            "the manifest/lockfile first, install, then COPY the source "
                            "(dev-speed.md, Phase 1).",
                        ))
                    elif current.inherits_source_from:
                        findings.append(Finding(
                            lineno, "WARN", "install-after-parent-copy",
                            f"Stage {current.name!r} builds FROM a stage that already COPYs "
                            f"the source tree (stage {current.inherits_source_from!r}, line "
                            f"{current.inherits_line}), so any source edit re-runs this "
                            "install. Move it into a stage the source-copying stage derives "
                            "from, and COPY the source last in each leaf stage "
                            "(dev-speed.md, Phase 1, 'Multi-stage').",
                        ))
                current.has_install = True

        # FROM <image>[:tag] -- no tag, or explicit :latest
        m = re.match(r"FROM\s+(?:--platform=\S+\s+)?(\S+)", stripped)
        if m:
            ref = m.group(1)
            # `FROM <earlier stage>` names a stage, not an image: no tag exists.
            if "@sha256:" not in ref and not (current and current.parent_is_stage):
                image = ref.split(" ")[0]
                if ":" not in image.split("/")[-1]:
                    findings.append(Finding(
                        lineno, "WARN", "from-no-tag",
                        f"FROM has no tag (implicitly :latest): {image!r}. "
                        "Pin at least a version tag; pin @sha256:... for a "
                        "reproducible/production build.",
                    ))
                elif image.rsplit(":", 1)[-1] == "latest":
                    findings.append(Finding(
                        lineno, "WARN", "from-latest",
                        f"FROM uses the floating :latest tag: {image!r}. "
                        "Pin a version, and a digest for production "
                        "(see production-hardening.md, 'Pin base images').",
                    ))
                else:
                    findings.append(Finding(
                        lineno, "INFO", "from-no-digest",
                        f"FROM is tag-pinned but not digest-pinned: {image!r}. "
                        "Fine for dev; consider @sha256:... before shipping, "
                        "especially for a CUDA base (see production-hardening.md).",
                    ))

        # ARG/ENV with a secret-shaped name
        for m in re.finditer(r"^\s*(ARG|ENV)\s+([A-Za-z_][A-Za-z0-9_]*)", block, re.MULTILINE):
            directive, name = m.group(1), m.group(2)
            if looks_like_secret_name(name):
                findings.append(Finding(
                    lineno, "WARN", "secret-in-arg-env",
                    f"{directive} {name} looks like a secret. ARG/ENV values "
                    "persist in `docker history` and in max-mode provenance "
                    "attestations even after being unset later. Use "
                    "`RUN --mount=type=secret,id=...` instead "
                    "(production-hardening.md, 'Secrets').",
                ))

        # pip install --no-cache-dir alongside a pip cache mount in the same RUN
        if "RUN" in block and re.search(r"pip\s+install", block):
            has_cache_mount = "target=/root/.cache/pip" in block or "target=/root/.cache/uv" in block
            has_no_cache_flag = "--no-cache-dir" in block
            if has_cache_mount and has_no_cache_flag:
                findings.append(Finding(
                    lineno, "WARN", "pip-cache-contradiction",
                    "This RUN mounts a pip cache AND passes --no-cache-dir -- "
                    "the flag stops pip from ever populating the cache, so the "
                    "mount persists nothing (dev-speed.md, Phase 2).",
                ))
            elif has_no_cache_flag and has_pip_no_cache_env:
                findings.append(Finding(
                    lineno, "INFO", "pip-no-cache-dir-set",
                    "pip install uses --no-cache-dir and PIP_NO_CACHE_DIR=1 is "
                    "set elsewhere in this file. Fine if you deliberately don't "
                    "use a pip cache mount; otherwise remove both "
                    "(dev-speed.md, Phase 2).",
                ))

        # apt-get install without --no-install-recommends
        if re.search(r"apt-get\s+install\b", block) and "--no-install-recommends" not in block:
            findings.append(Finding(
                lineno, "WARN", "apt-no-recommends",
                "apt-get install without --no-install-recommends pulls "
                "transitive suggested packages you probably don't want "
                "(dev-speed.md, Phase 6).",
            ))

        # apt cache mount + rm -rf of the same path in one RUN (self-defeating)
        has_apt_cache_mount = "target=/var/lib/apt" in block or "target=/var/cache/apt" in block
        if has_apt_cache_mount and re.search(r"rm\s+-rf\s+/var/lib/apt/lists", block):
            findings.append(Finding(
                lineno, "WARN", "apt-cache-rm-contradiction",
                "This RUN both mounts an apt cache and rm -rf's "
                "/var/lib/apt/lists -- the rm deletes what the mount is "
                "supposed to persist between builds. Pick one "
                "(dev-speed.md, Phase 2).",
            ))
        if has_apt_cache_mount and "docker-clean" not in block:
            findings.append(Finding(
                lineno, "INFO", "apt-cache-mount-docker-clean",
                "This RUN mounts an apt cache but doesn't remove "
                "/etc/apt/apt.conf.d/docker-clean. Debian/Ubuntu base images "
                "ship that file and it deletes downloaded .debs immediately, "
                "which can leave the cache mount empty -- verify your base "
                "image actually needs this removed (dev-speed.md, Phase 2).",
            ))

        # git clone --depth 1 ... && ... checkout <sha> (fragile pin)
        if re.search(r"git\s+clone\s+(?:--depth\s+1|--depth=1)", block) and re.search(
            r"git\s+checkout\s+[0-9a-fA-F]{7,40}\b", block
        ):
            findings.append(Finding(
                lineno, "WARN", "fragile-shallow-clone-pin",
                "`git clone --depth 1` + `git checkout <sha>` only works "
                "while <sha> is still the branch tip -- it breaks the moment "
                "upstream pushes past it. Use `git fetch --depth 1 origin "
                "<sha> && git checkout FETCH_HEAD` instead "
                "(dev-speed.md, Phase 4).",
            ))

    if first_context_copy and dockerignore_present is False:
        findings.append(Finding(
            first_context_copy, "INFO", "no-dockerignore",
            "This file COPYs the whole build context but no .dockerignore was "
            "found next to it, in its parent, or in the current directory "
            "(also checked: <Dockerfile>.dockerignore). Everything in the "
            "context -- node_modules, .git, tool caches -- is uploaded and "
            "can end up in a layer (dev-speed.md, Phase 3).",
        ))
    if not has_healthcheck:
        findings.append(Finding(
            0, "INFO", "no-healthcheck",
            "No HEALTHCHECK found in this file. Fine for a dev image; add one "
            "before shipping (production-hardening.md, 'HEALTHCHECK') -- and "
            "if this is a GPU/ML service, make sure it never triggers "
            "inference.",
        ))
    if not has_user:
        findings.append(Finding(
            0, "INFO", "no-user",
            "No USER found in this file -- the container runs as root. Fine "
            "for local dev; add a non-root USER before shipping "
            "(production-hardening.md, 'Non-root user').",
        ))

    return findings


def find_dockerignore(path: Path) -> bool:
    """Where BuildKit would look, given the Dockerfile's location. The real
    context is set by the build command (or compose), which we can't see, so
    probe the likely ones: per-Dockerfile, its directory, its parent, cwd."""
    path = path.resolve()
    candidates = [
        path.with_name(path.name + ".dockerignore"),
        path.parent / ".dockerignore",
        path.parent.parent / ".dockerignore",
        Path.cwd() / ".dockerignore",
    ]
    return any(c.is_file() for c in candidates)


def main(argv: list[str]) -> int:
    paths = [Path(p) for p in argv] or [Path("Dockerfile")]
    total_warn = 0
    for path in paths:
        if not path.is_file():
            print(f"skip: {path} not found", file=sys.stderr)
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        findings = audit(text, find_dockerignore(path))
        print(f"\n== {path} ==")
        if not findings:
            print("  clean -- no mechanically-checkable issues found")
            continue
        for f in sorted(findings, key=lambda f: (f.line, f.severity)):
            where = f"line {f.line}" if f.line else "file-level"
            print(f"  [{f.severity}] {where} ({f.check_id}): {f.message}")
        total_warn += sum(1 for f in findings if f.severity == "WARN")

    print(f"\n{total_warn} WARN-level finding(s). This is a heuristic pass over "
          "the text only -- it proves nothing about the built image. See "
          "production-hardening.md 'Vulnerability scanning' for a real scanner.")
    return total_warn


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
