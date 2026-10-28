#!/usr/bin/env python3
"""Where did the BuildKit cache go? Group `docker buildx du` records by layer.

`docker system df` says the build cache is big; it does not say why. This
script reads `docker buildx du --format json` (one JSON record per cache
entry, read-only -- it prunes nothing), groups the records by what created
them, and ranks the groups by total bytes. A group with a high count AND a
high size is the signature of a layer that is being re-created on every
build instead of being reused: a whole-tree `COPY . .` whose average size
shows it is carrying more than source code, or an install layer sitting
behind a `COPY` that changes on every edit (dev-speed.md, Phases 1 and 3).
It reports evidence, not a verdict: a repeated instruction can also be
several projects sharing the same boilerplate line.

Usage:
    python3 cache_report.py                 # query the default builder
    python3 cache_report.py --builder NAME  # query another builder
    python3 cache_report.py --top 20        # show more groups (default 12)
    python3 cache_report.py --input FILE    # read saved NDJSON instead of
                                            # running docker (use - for stdin)

Sizes are in decimal units (the unit buildx prints), so they won't match
`docker system df` to the byte. The stage counters in a description
("[stage-1 6/6]") differ between Dockerfiles, so two projects building the
same instruction land in separate groups -- that is deliberate, it keeps the
blame per Dockerfile.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field

UNITS = {"B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
         "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "TIB": 1024**4}

# BuildKit keys a layer on (instruction, parent chain). The same instruction
# showing up N times therefore means N different parent chains -- something
# upstream of it changed N times (or N projects share the boilerplate).
REPEAT_THRESHOLD = 5
# A source tree is megabytes. A whole-tree COPY averaging more than this is
# carrying something that isn't source (node_modules, .next, .venv, data).
BLOATED_COPY_AVG = 50e6
# Don't nag about groups too small to matter.
MIN_FLAG_BYTES = 100e6

WHOLE_TREE_COPY = re.compile(r"\b(COPY|ADD)\s+(--\S+\s+)*(\./?|\*|\.\s+\S+)(\s|$)")
INSTALL_LAYER = re.compile(
    r"apt-get\s+(update|install)|\bapk\s+add|\bpip3?\s+install|\buv\s+(sync|pip)"
    r"|\bnpm\s+(ci|install|i)\b|\byarn\s+install|\bpnpm\s+(install|i)\b"
    r"|\bpoetry\s+install|\bgo\s+mod\s+download|\bbundle\s+install"
    r"|\bcomposer\s+install|nodesource|npm\s+install\s+-g"
)


def parse_size(text: str) -> float:
    m = re.fullmatch(r"\s*([\d.]+)\s*([A-Za-z]+)\s*", text or "")
    if not m:
        return 0.0
    return float(m.group(1)) * UNITS.get(m.group(2).upper(), 0)


@dataclass
class Group:
    description: str
    count: int = 0
    total: float = 0.0
    shared: int = 0
    kinds: set[str] = field(default_factory=set)

    @property
    def average(self) -> float:
        return self.total / self.count if self.count else 0.0


def load_records(args: argparse.Namespace) -> list[dict]:
    if args.input:
        try:
            raw = sys.stdin.read() if args.input == "-" else open(args.input, encoding="utf-8").read()
        except OSError as e:
            sys.exit(f"error: cannot read {args.input}: {e.strerror}")
    else:
        cmd = ["docker", "buildx", "du", "--format", "json"]
        if args.builder:
            cmd += ["--builder", args.builder]
        try:
            raw = subprocess.run(cmd, check=True, capture_output=True, text=True,
                                 timeout=args.timeout).stdout
        except FileNotFoundError:
            sys.exit("error: docker not found on PATH")
        except subprocess.TimeoutExpired:
            sys.exit(f"error: `docker buildx du` did not finish in {args.timeout}s "
                     "(a very large cache is slow to enumerate) -- raise --timeout")
        except subprocess.CalledProcessError as e:
            sys.exit(f"error: {' '.join(cmd)} failed: {e.stderr.strip() or e}")
    records = []
    for line in raw.splitlines():
        line = line.strip()
        if line.startswith("{"):
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return records


def group_records(records: list[dict]) -> dict[str, Group]:
    groups: dict[str, Group] = {}
    for r in records:
        desc = " ".join((r.get("Description") or "(no description)").split())[:110]
        g = groups.setdefault(desc, Group(desc))
        g.count += 1
        g.total += parse_size(r.get("Size", ""))
        g.shared += bool(r.get("Shared"))
        if r.get("Type"):
            g.kinds.add(r["Type"])
    return groups


def advice(g: Group) -> str | None:
    if g.count < REPEAT_THRESHOLD or g.total < MIN_FLAG_BYTES:
        return None
    if WHOLE_TREE_COPY.search(g.description):
        if g.average < BLOATED_COPY_AVG:
            return None  # many small source copies is just normal edit churn
        return ("whole-tree COPY averaging %s per record -- source code is megabytes, "
                "so the context is carrying something else (node_modules, .next, "
                ".venv, data, a tool cache). Check the `transferring context:` size "
                "in `docker build --progress=plain`; dev-speed.md, Phase 3"
                % fmt(g.average).strip())
    if INSTALL_LAYER.search(g.description):
        return ("same install instruction under %d different parent chains: it was "
                "re-run because something before it changed (typically a source COPY, "
                "possibly in a parent stage), or %d projects share the same line -- "
                "tell them apart by Dockerfile; dev-speed.md, Phase 1" % (g.count, g.count))
    return None


def fmt(n: float) -> str:
    return f"{n / 1e9:7.2f} GB" if n >= 1e8 else f"{n / 1e6:7.1f} MB"


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--top", type=int, default=12)
    ap.add_argument("--builder")
    ap.add_argument("--input", help="saved `docker buildx du --format json` output, or - for stdin")
    ap.add_argument("--timeout", type=int, default=300)
    args = ap.parse_args(argv)

    records = load_records(args)
    if not records:
        print("no cache records found (empty cache, or unexpected output format).")
        return 0

    groups = group_records(records)
    total = sum(g.total for g in groups.values())
    shared = sum(parse_size(r.get("Size", "")) for r in records if r.get("Shared"))
    print(f"{len(records)} cache records, {total / 1e9:.2f} GB total "
          f"({shared / 1e9:.2f} GB shared with images, {(total - shared) / 1e9:.2f} GB private)\n")
    print(f"{'total':>10}  {'count':>5}  {'avg':>10}  description")
    ranked = sorted(groups.values(), key=lambda g: -g.total)
    for g in ranked[: args.top]:
        print(f"{fmt(g.total)}  {g.count:>5}  {fmt(g.average)}  {g.description}")

    flagged = [(g, a) for g in ranked if (a := advice(g))]
    if flagged:
        print("\nRepeated layers worth a look:")
        for g, a in flagged[: args.top]:
            print(f"  - {fmt(g.total).strip()} in {g.count} records: {g.description[:60]}\n    {a}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
