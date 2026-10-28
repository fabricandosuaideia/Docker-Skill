#!/usr/bin/env python3
"""Check that the facts this repository states in more than one place still agree.

Maintainer tool; not installed with the skill. Standard library only.

Run it after editing SKILL.md, a reference file, a script or an installer.
`tools/bump-version.sh` and `tools/tag-release.sh` run it as their gate.

What is checked, and why each one exists:

  skill     SKILL.md frontmatter and size against Claude Code's skill limits
            (description <= 1,536 chars, SKILL.md < 500 lines).
  release   the version in SKILL.md has the newest CHANGELOG entry, entries are
            in descending order, and every git tag matches the SKILL.md it points at.
  payload   what the installers copy is exactly what is in the repo. Adding a
            script and forgetting one installer ships a skill whose own map
            links to a file that was never installed.
  docs      every shipped file is named in both READMEs and in SKILL.md's map.
  links     relative links in SKILL.md resolve.
  syntax    scripts compile, installers parse.

Exit status is the number of failed checks (0 = clean).

Usage:  python3 tools/check-consistency.py [--root DIR]
"""

from __future__ import annotations

import argparse
import py_compile
import re
import subprocess
import sys
import tempfile
from pathlib import Path

SEMVER = r"(\d+)\.(\d+)\.(\d+)"
NOT_SHIPPED_MD = {"SKILL.md", "README.md", "README.pt-BR.md", "CHANGELOG.md", "CONTRIBUTING.md"}
DESCRIPTION_CAP = 1536
SKILL_LINE_CAP = 500


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.checks = 0

    def check(self, ok: bool, label: str, detail: str = "") -> None:
        self.checks += 1
        if not ok:
            self.failures.append(f"{label}: {detail}" if detail else label)


def frontmatter(text: str) -> dict[str, str]:
    """Flat read of the SKILL.md frontmatter: top-level keys and 2-space nested ones."""
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    out: dict[str, str] = {}
    for line in m.group(1).splitlines():
        kv = re.match(r"\s*([A-Za-z_-]+):\s*(.*)$", line)
        if kv:
            out[kv.group(1)] = kv.group(2).strip().strip('"')
    return out


def semver_key(v: str) -> tuple[int, int, int]:
    a, b, c = (int(x) for x in v.split("."))
    return a, b, c


def changelog_versions(text: str) -> list[tuple[str, str]]:
    """(version, date) for every '## X.Y.Z — YYYY-MM-DD' heading, in file order."""
    pattern = r"^## (\d+\.\d+\.\d+)\s+[—-]\s+(\d{4}-\d{2}-\d{2})\s*$"
    return re.findall(pattern, text, re.M)


def installer_list(text: str, pattern: str) -> set[str]:
    m = re.search(pattern, text, re.M)
    return set(re.findall(r"[\w./-]+", m.group(1))) if m else set()


def git(root: Path, *args: str) -> str | None:
    try:
        r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def run(root: Path) -> Report:
    rep = Report()
    skill_path = root / "SKILL.md"
    skill = skill_path.read_text(encoding="utf-8")
    fm = frontmatter(skill)

    # --- skill -------------------------------------------------------------
    rep.check(skill.startswith("---\n"), "skill: frontmatter must start on line 1")
    rep.check(fm.get("name") == "docker-image-playbook", "skill: name", f"got {fm.get('name')!r}")
    desc = fm.get("description", "")
    rep.check(0 < len(desc) <= DESCRIPTION_CAP, "skill: description length",
              f"{len(desc)} chars (cap {DESCRIPTION_CAP}, and it should not be empty)")
    lines = skill.count("\n") + 1
    rep.check(lines < SKILL_LINE_CAP, "skill: SKILL.md length", f"{lines} lines (cap {SKILL_LINE_CAP})")
    version = fm.get("version", "")
    rep.check(bool(re.fullmatch(SEMVER, version)), "skill: metadata.version is MAJOR.MINOR.PATCH", repr(version))

    # --- release -----------------------------------------------------------
    cl_path = root / "CHANGELOG.md"
    rep.check(cl_path.is_file(), "release: CHANGELOG.md exists")
    entries = changelog_versions(cl_path.read_text(encoding="utf-8")) if cl_path.is_file() else []
    versions = [v for v, _ in entries]
    rep.check(bool(versions), "release: CHANGELOG has at least one '## X.Y.Z — date' entry")
    if versions:
        rep.check(versions[0] == version, "release: newest CHANGELOG entry matches SKILL.md",
                  f"CHANGELOG top is {versions[0]}, SKILL.md says {version}")
        rep.check(versions == sorted(versions, key=semver_key, reverse=True) and len(set(versions)) == len(versions),
                  "release: CHANGELOG entries are unique and newest-first", ", ".join(versions))
    tags_out = git(root, "tag", "--list", "v*")
    if tags_out is not None:
        for tag in sorted(tags_out.split(), key=lambda t: semver_key(t[1:]) if re.fullmatch(rf"v{SEMVER}", t) else (0, 0, 0)):
            if not re.fullmatch(rf"v{SEMVER}", tag):
                rep.check(False, "release: tag name", f"{tag!r} is not vMAJOR.MINOR.PATCH")
                continue
            tagged = git(root, "show", f"{tag}:SKILL.md")
            tagged_v = frontmatter(tagged).get("version") if tagged else None
            rep.check(tagged_v == tag[1:], f"release: {tag} points at a SKILL.md declaring it",
                      f"that commit declares {tagged_v!r}")
            rep.check(tag[1:] in versions, f"release: {tag} has a CHANGELOG entry")

    # --- payload -----------------------------------------------------------
    shipped_md = {p.name for p in root.glob("*.md")} - NOT_SHIPPED_MD
    scripts_dir = root / "scripts"
    shipped_scripts = {p.name for p in scripts_dir.iterdir() if p.is_file()} if scripts_dir.is_dir() else set()
    sh = (root / "install.sh").read_text(encoding="utf-8")
    ps = (root / "install.ps1").read_text(encoding="utf-8")
    inst = {
        "install.sh": (installer_list(sh, r"^REQUIRED_FILES=\(([^)]*)\)"),
                       installer_list(sh, r"^REQUIRED_SCRIPTS=\(([^)]*)\)")),
        "install.ps1": (installer_list(ps, r"^\$RequiredFiles\s*=\s*@\(([^)]*)\)"),
                        installer_list(ps, r"^\$RequiredScripts\s*=\s*@\(([^)]*)\)")),
    }
    for name, (files, scripts) in inst.items():
        rep.check(files == shipped_md, f"payload: {name} file list matches the repo",
                  f"installer has {sorted(files)}, repo has {sorted(shipped_md)}")
        rep.check(scripts == shipped_scripts, f"payload: {name} script list matches scripts/",
                  f"installer has {sorted(scripts)}, repo has {sorted(shipped_scripts)}")

    # --- docs --------------------------------------------------------------
    docs = {n: (root / n).read_text(encoding="utf-8") for n in ("README.md", "README.pt-BR.md", "SKILL.md")}
    for item in sorted(shipped_md) + [f"scripts/{s}" for s in sorted(shipped_scripts)]:
        for doc, text in docs.items():
            rep.check(item in text, f"docs: {doc} mentions {item}")

    # --- links -------------------------------------------------------------
    for target in sorted(set(re.findall(r"\]\(([^)#\s]+)\)", skill))):
        if not re.match(r"[a-z]+:", target):
            rep.check((root / target).exists(), "links: SKILL.md link resolves", target)

    # --- syntax ------------------------------------------------------------
    for py in sorted(list(scripts_dir.glob("*.py")) + list((root / "tools").glob("*.py"))):
        try:
            with tempfile.TemporaryDirectory() as td:
                py_compile.compile(str(py), cfile=str(Path(td) / "x.pyc"), doraise=True)
            rep.check(True, f"syntax: {py.name}")
        except py_compile.PyCompileError as e:
            rep.check(False, f"syntax: {py.name}", str(e).splitlines()[-1])
    for sh_file in [root / "install.sh", *sorted((root / "tools").glob("*.sh"))]:
        r = subprocess.run(["bash", "-n", str(sh_file)], capture_output=True, text=True)
        rep.check(r.returncode == 0, f"syntax: {sh_file.name}", r.stderr.strip())
    return rep


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent))
    root = Path(ap.parse_args(argv).root).resolve()
    rep = run(root)
    if rep.failures:
        print(f"check-consistency: {len(rep.failures)} of {rep.checks} checks FAILED\n")
        for f in rep.failures:
            print(f"  x {f}")
        return len(rep.failures)
    print(f"check-consistency: {rep.checks} checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
