#!/usr/bin/env python3
"""Bundle a CC: Tweaked project entry into one Lua file (package.preload + entry).

Layout conventions (under projects/):

  Single-entry project:
    projects/<name>/main.lua
    projects/<name>/<name>.cfg          # optional → dist/<name>.cfg

  Multi-entry project:
    projects/<name>/entries/<entry>.lua
    projects/<name>/<entry>.cfg         # optional → dist/<entry>.cfg
    projects/<name>/cfg/*.cfg           # optional fragments → merged dist/<entry>.cfg
    other root *.cfg referenced in the entry source are copied alongside

  Shared modules: projects/shared/

Usage:
  python tools/bundle_project.py ae2_feed
  python tools/bundle_project.py ae_stats display
  python tools/bundle_project.py craft craft_ui
  python tools/bundle_project.py --all
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from collections import OrderedDict, namedtuple
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROJECTS_ROOT = REPO_ROOT / "projects"
SHARED_DIR = PROJECTS_ROOT / "shared"

REQUIRE_RE = re.compile(r"""require\s*\(\s*['"]([A-Za-z0-9_./-]+)['"]\s*\)""")
PACKAGE_PATH_RE = re.compile(
    r"^package\.path\s*=\s*package\.path(?:\s*\n\s*\.\.[^\n]*)*\s*(?:\n|$)",
    re.MULTILINE,
)

# module = require/topo name; dist_name = dist/<dist_name>.lua; path = entry file
Entry = namedtuple("Entry", ("module", "dist_name", "path"))


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_package_path(src: str) -> str:
    return PACKAGE_PATH_RE.sub("", src, count=1).lstrip("\n")


def list_projects() -> list[str]:
    if not PROJECTS_ROOT.is_dir():
        return []
    names: list[str] = []
    for path in sorted(PROJECTS_ROOT.iterdir()):
        if path.is_dir() and path.name != "shared" and not path.name.startswith("."):
            names.append(path.name)
    return names


def discover_entries(project: str) -> list[Entry]:
    project_dir = PROJECTS_ROOT / project
    if not project_dir.is_dir():
        raise SystemExit(f"project directory not found: {project_dir}")

    entries_dir = project_dir / "entries"
    if entries_dir.is_dir():
        found = sorted(entries_dir.glob("*.lua"))
        if not found:
            raise SystemExit(f"no entries/*.lua in {entries_dir}")
        return [
            Entry(module=p.stem, dist_name=p.stem, path=p) for p in found
        ]

    main_path = project_dir / "main.lua"
    if main_path.is_file():
        return [Entry(module="main", dist_name=project, path=main_path)]

    raise SystemExit(
        f"{project}: need main.lua or entries/*.lua under {project_dir}"
    )


def resolve_entry(project: str, entry_arg: str | None) -> Entry:
    entries = discover_entries(project)
    if entry_arg:
        for ent in entries:
            if ent.module == entry_arg or ent.dist_name == entry_arg:
                return ent
        names = ", ".join(e.module for e in entries)
        raise SystemExit(
            f"entry {entry_arg!r} not found in {project}; available: {names}"
        )
    if len(entries) == 1:
        return entries[0]
    names = ", ".join(e.module for e in entries)
    raise SystemExit(
        f"multiple entries in {project}; pass one of: {names}"
    )


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
        visiting.remove(name)
        ordered[name] = path

    for dep in collect_requires(entry_src):
        visit(dep)

    return ordered


def wrap_preload(name: str, src: str) -> str:
    parts: list[str] = [f'package.preload["{name}"] = function(...)\n']
    parts.append(src.rstrip() + "\n")
    parts.append("end\n")
    return "".join(parts)


def cfg_hint(copied: list[str]) -> str:
    if not copied:
        return ""
    if len(copied) == 1:
        return f"-- Also copy {copied[0]} next to this file on the computer.\n"
    joined = ", ".join(copied)
    return f"-- Also copy these next to this file on the computer: {joined}.\n"


def build_bundle(
    project: str,
    entry: Entry,
    modules: OrderedDict[str, Path],
    entry_src: str,
    copied_cfg: list[str],
) -> str:
    parts: list[str] = []
    rel_entry = entry.path.relative_to(REPO_ROOT).as_posix()
    parts.append(
        f"-- Bundled from {rel_entry} — do not edit by hand; "
        f"rebuild with tools/bundle_project.py\n"
    )
    hint = cfg_hint(copied_cfg)
    if hint:
        parts.append(hint)
    parts.append("-- Generated package.preload modules + entrypoint.\n\n")

    for name, path in modules.items():
        src = read_text(path)
        parts.append(f"-- module: {name} ({path.relative_to(REPO_ROOT).as_posix()})\n")
        parts.append(wrap_preload(name, src))
        parts.append("\n")

    entry_body = strip_package_path(entry_src)
    parts.append(f"-- entry: {rel_entry}\n")
    parts.append(entry_body.rstrip() + "\n")
    return "".join(parts)


def write_merged_cfg(
    out_path: Path,
    sources: list[Path],
    paired_lua: str,
) -> None:
    parts: list[str] = []
    parts.append(
        f"# Config for {paired_lua} (keep the same basename on the computer).\n"
        "# Sections match source files in the repo. Edit either section in-game.\n\n"
    )
    for src_path in sources:
        section = src_path.stem
        body = read_text(src_path).replace("\r\n", "\n").replace("\r", "\n").rstrip()
        parts.append(f"[{section}]\n")
        parts.append(body)
        parts.append("\n\n")
    out_path.write_text("".join(parts), encoding="utf-8", newline="\n")


def fragment_cfgs(project_dir: Path) -> list[Path]:
    cfg_dir = project_dir / "cfg"
    if not cfg_dir.is_dir():
        return []
    return sorted(p for p in cfg_dir.glob("*.cfg") if p.is_file())


def entry_names_set(project: str) -> set[str]:
    return {e.dist_name for e in discover_entries(project)}


def deploy_cfgs(
    project: str,
    entry: Entry,
    entry_src: str,
    out_dir: Path,
) -> list[str]:
    """Copy/merge cfg files into dist/. Returns basenames written."""
    project_dir = PROJECTS_ROOT / project
    written: list[str] = []
    fragments = fragment_cfgs(project_dir)

    if fragments:
        dst = out_dir / f"{entry.dist_name}.cfg"
        write_merged_cfg(dst, fragments, f"{entry.dist_name}.lua")
        written.append(dst.name)
        print(
            f"  merged config: {dst.relative_to(REPO_ROOT).as_posix()} "
            f"<- {', '.join(p.name for p in fragments)}"
        )
    else:
        stem_cfg = project_dir / f"{entry.dist_name}.cfg"
        if stem_cfg.is_file():
            dst = out_dir / stem_cfg.name
            shutil.copyfile(stem_cfg, dst)
            written.append(dst.name)
            print(f"  copied config: {dst.relative_to(REPO_ROOT).as_posix()}")

    names = entry_names_set(project)
    for cfg_path in sorted(project_dir.glob("*.cfg")):
        if cfg_path.stem in names:
            continue
        if cfg_path.name in written:
            continue
        if cfg_path.name not in entry_src:
            continue
        dst = out_dir / cfg_path.name
        shutil.copyfile(cfg_path, dst)
        if cfg_path.name not in written:
            written.append(cfg_path.name)
        print(f"  copied extra: {dst.relative_to(REPO_ROOT).as_posix()}")

    return written


def bundle_one(project: str, entry: Entry) -> Path:
    project_dir = PROJECTS_ROOT / project
    entry_src = read_text(entry.path)
    modules = topo_modules(entry.module, entry_src, project_dir, SHARED_DIR)

    out_dir = REPO_ROOT / "dist"
    out_dir.mkdir(parents=True, exist_ok=True)

    copied = deploy_cfgs(project, entry, entry_src, out_dir)
    bundle = build_bundle(project, entry, modules, entry_src, copied)

    out_path = out_dir / f"{entry.dist_name}.lua"
    out_path.write_text(bundle, encoding="utf-8", newline="\n")

    mod_list = ", ".join(modules.keys()) or "(none)"
    print(f"Wrote {out_path.relative_to(REPO_ROOT).as_posix()}")
    print(f"  modules: {mod_list}")
    return out_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "project",
        nargs="?",
        help="project folder under projects/ (ae2_feed, craft, …)",
    )
    parser.add_argument(
        "entry",
        nargs="?",
        default=None,
        help="entry module (required when project has entries/)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="bundle every entry of every project",
    )
    args = parser.parse_args(argv)

    if args.all:
        if args.project or args.entry:
            raise SystemExit("--all does not take project/entry arguments")
        projects = list_projects()
        if not projects:
            raise SystemExit(f"no projects under {PROJECTS_ROOT}")
        for project in projects:
            for ent in discover_entries(project):
                print(f"=== {project}/{ent.module} ===")
                bundle_one(project, ent)
        return 0

    if not args.project:
        parser.error("project name required (or pass --all)")

    entry = resolve_entry(args.project, args.entry)
    bundle_one(args.project, entry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
