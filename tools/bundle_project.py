#!/usr/bin/env python3
"""Bundle a CC: Tweaked project entry into one Lua file (package.preload + entry).

Usage:
  python tools/bundle_project.py ae2_feed
  python tools/bundle_project.py craft craft_ui
  python tools/bundle_project.py craft greenhouse_clean
  python tools/bundle_project.py craft wheat_grain

Resolves require("name") from <project>/ then shared/. Writes dist/<entry>.lua
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import OrderedDict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
REQUIRE_RE = re.compile(r"""require\s*\(\s*['"]([A-Za-z0-9_./-]+)['"]\s*\)""")
PACKAGE_PATH_RE = re.compile(
    r"^package\.path\s*=\s*package\.path(?:\s*\n\s*\.\.[^\n]*)*\s*(?:\n|$)",
    re.MULTILINE,
)

# Lazy requires that static scan of the entry may miss (nested in functions).
EXTRA_REQUIRES: dict[str, tuple[str, ...]] = {
    "craft": ("storage",),
    "greenhouse_clean": ("greenhouse",),
}

CRAFT_CFG_HINT = (
    "-- Also copy craft/recipes.cfg and craft/storage.cfg next to this file on the computer."
)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_package_path(src: str) -> str:
    return PACKAGE_PATH_RE.sub("", src, count=1).lstrip("\n")


def find_module(name: str, project_dir: Path, shared_dir: Path) -> Path | None:
    for base in (project_dir, shared_dir):
        candidate = base / f"{name}.lua"
        if candidate.is_file():
            return candidate
    return None


def collect_requires(src: str) -> list[str]:
    return REQUIRE_RE.findall(src)


def topo_modules(
    entry_name: str,
    entry_src: str,
    project_dir: Path,
    shared_dir: Path,
) -> OrderedDict[str, Path]:
    """Return dependency modules (not including the entry) in load order."""
    ordered: OrderedDict[str, Path] = OrderedDict()
    visiting: set[str] = set()

    def visit(name: str, from_src: str | None = None) -> None:
        if name == entry_name or name in ordered:
            return
        if name in visiting:
            raise RuntimeError(f"circular require involving {name!r}")
        path = find_module(name, project_dir, shared_dir)
        if path is None:
            raise FileNotFoundError(
                f"module {name!r} not found in {project_dir.name}/ or shared/"
            )
        visiting.add(name)
        src = from_src if from_src is not None else read_text(path)
        for dep in collect_requires(src):
            visit(dep)
        for dep in EXTRA_REQUIRES.get(name, ()):
            visit(dep)
        visiting.remove(name)
        ordered[name] = path

    for dep in collect_requires(entry_src):
        visit(dep)
    for dep in EXTRA_REQUIRES.get(entry_name, ()):
        visit(dep)

    return ordered


def wrap_preload(name: str, src: str, mark_config: bool) -> str:
    parts: list[str] = [f'package.preload["{name}"] = function(...)\n']
    if mark_config and name == "config":
        parts.append("-- >>> EDIT CONFIG HERE (e.g. N) <<<\n")
    parts.append(src.rstrip() + "\n")
    parts.append("end\n")
    return "".join(parts)


def build_bundle(
    project: str,
    entry: str,
    modules: OrderedDict[str, Path],
    entry_src: str,
) -> str:
    parts: list[str] = []
    parts.append(f"-- Bundled from {project}/{entry}.lua — do not edit by hand; rebuild with tools/bundle_project.py\n")
    if project == "craft":
        parts.append(CRAFT_CFG_HINT + "\n")
    parts.append("-- Generated package.preload modules + entrypoint.\n\n")

    for name, path in modules.items():
        src = read_text(path)
        parts.append(f"-- module: {name} ({path.relative_to(REPO_ROOT).as_posix()})\n")
        parts.append(wrap_preload(name, src, mark_config=(project == "ae2_feed")))
        parts.append("\n")

    entry_body = strip_package_path(entry_src)
    parts.append(f"-- entry: {project}/{entry}.lua\n")
    parts.append(entry_body.rstrip() + "\n")
    return "".join(parts)


def resolve_entry(project: str, entry_arg: str | None) -> tuple[str, Path]:
    project_dir = REPO_ROOT / project
    if not project_dir.is_dir():
        raise SystemExit(f"project directory not found: {project_dir}")

    if entry_arg:
        entry = entry_arg
    elif (project_dir / "main.lua").is_file():
        entry = "main"
    else:
        raise SystemExit(
            f"no entry given and {project}/main.lua missing; "
            f"usage: bundle_project.py {project} <entry>"
        )

    entry_path = project_dir / f"{entry}.lua"
    if not entry_path.is_file():
        raise SystemExit(f"entry not found: {entry_path}")
    return entry, entry_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", help="project folder name (ae2_feed, craft, ...)")
    parser.add_argument(
        "entry",
        nargs="?",
        default=None,
        help="entry module name without .lua (default: main)",
    )
    args = parser.parse_args(argv)

    project = args.project
    entry, entry_path = resolve_entry(project, args.entry)
    project_dir = REPO_ROOT / project
    shared_dir = REPO_ROOT / "shared"

    entry_src = read_text(entry_path)
    modules = topo_modules(entry, entry_src, project_dir, shared_dir)
    bundle = build_bundle(project, entry, modules, entry_src)

    out_name = "ae2_feed" if project == "ae2_feed" and entry == "main" else entry
    out_dir = REPO_ROOT / "dist"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{out_name}.lua"
    out_path.write_text(bundle, encoding="utf-8", newline="\n")

    mod_list = ", ".join(modules.keys()) or "(none)"
    print(f"Wrote {out_path.relative_to(REPO_ROOT).as_posix()}")
    print(f"  modules: {mod_list}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
