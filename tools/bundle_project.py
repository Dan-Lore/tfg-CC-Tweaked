#!/usr/bin/env python3
"""Bundle a CC: Tweaked project entry into one Lua file (package.preload + entry).

Usage:
  python tools/bundle_project.py ae2_feed
  python tools/bundle_project.py crystals
  python tools/bundle_project.py power
  python tools/bundle_project.py distill
  python tools/bundle_project.py ae_stats sampler
  python tools/bundle_project.py ae_stats display
  python tools/bundle_project.py ae_stats graphview
  python tools/bundle_project.py craft craft_ui
  python tools/bundle_project.py craft greenhouse_clean
  python tools/bundle_project.py craft wheat_grain
  python tools/bundle_project.py craft pizza_maintain

Resolves require("name") from <project>/ then shared/. Writes dist/<entry>.lua.
COPY_CFG copies a single .cfg next to the bundle.
COPY_CFG_BY_ENTRY copies <entry>.cfg for multi-entry projects.
MERGE_CFG merges several source .cfg files into dist/<entry>.cfg
(e.g. craft pizza_maintain → pizza_maintain.lua + pizza_maintain.cfg).
Projects in EMBED_CFG bake <project>/*.cfg into the bundle as cfg_embed.
"""

from __future__ import annotations

import argparse
import re
import shutil
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
    "craft": ("storage", "food"),
    "greenhouse_clean": ("greenhouse", "food"),
    "craft_io": ("food",),
    "craft_stock": ("food",),
    "craft_grow": ("food",),
    "pizza_maintain": ("food",),
    "wheat_grain": ("food",),
}

CRAFT_CFG_HINT = (
    "-- Also copy the matching .cfg next to this file "
    "(same basename; sections [storage] and [recipes])."
)
AE2_FEED_CFG_HINT = (
    "-- Also copy ae2_feed.cfg next to this file on the computer."
)
CRYSTALS_CFG_HINT = (
    "-- Also copy crystals.cfg next to this file on the computer."
)
POWER_CFG_HINT = (
    "-- Also copy power.cfg next to this file on the computer."
)
DISTILL_CFG_HINT = (
    "-- Also copy distill.cfg next to this file on the computer."
)
AE_STATS_CFG_HINT = (
    "-- Also copy the matching .cfg next to this file "
    "(sampler.cfg / display.cfg / graphview.cfg; "
    "display+graphview also need labels.cfg)."
)

# Projects that embed <project>/<name>.cfg as package.preload["cfg_embed"].
EMBED_CFG: dict[str, str] = {}

# Copy <project>/<name>.cfg next to the bundle in dist/.
COPY_CFG: dict[str, str] = {
    "crystals": "crystals.cfg",
    "ae2_feed": "ae2_feed.cfg",
    "power": "power.cfg",
    "distill": "distill.cfg",
}

# project -> entry -> cfg filename (copied to dist/<cfg>).
COPY_CFG_BY_ENTRY: dict[str, dict[str, str]] = {
    "ae_stats": {
        "sampler": "sampler.cfg",
        "display": "display.cfg",
        "graphview": "graphview.cfg",
    },
}

# Extra files copied alongside an entry bundle (e.g. labels.cfg).
EXTRA_COPY_BY_ENTRY: dict[str, dict[str, tuple[str, ...]]] = {
    "ae_stats": {
        "display": ("labels.cfg",),
        "graphview": ("labels.cfg",),
    },
}

# Merge several source cfgs into one sectioned dist file named like the entry.
# project -> (src_cfg, ...)  → dist/<entry>.cfg with [stem] sections.
MERGE_CFG: dict[str, tuple[str, ...]] = {
    "craft": ("storage.cfg", "recipes.cfg"),
}


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


def lua_long_string(text: str) -> str:
    """Wrap text in a Lua long bracket string that cannot appear inside it."""
    eq = 0
    while True:
        open_b = "[" + ("=" * eq) + "["
        close_b = "]" + ("=" * eq) + "]"
        if open_b not in text and close_b not in text:
            return open_b + text + close_b
        eq += 1


def wrap_cfg_embed(cfg_text: str) -> str:
    body = cfg_text.replace("\r\n", "\n").replace("\r", "\n")
    if not body.endswith("\n"):
        body += "\n"
    parts: list[str] = []
    parts.append("-- >>> EDIT CONFIG (crystals.cfg syntax) <<<\n")
    parts.append(f"local EMBEDDED_CFG = {lua_long_string(body)}\n\n")
    parts.append('package.preload["cfg_embed"] = function()\n')
    parts.append("    return EMBEDDED_CFG\n")
    parts.append("end\n\n")
    return "".join(parts)


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
    embed_cfg_path: Path | None = None,
) -> str:
    parts: list[str] = []
    parts.append(f"-- Bundled from {project}/{entry}.lua — do not edit by hand; rebuild with tools/bundle_project.py\n")
    if project == "craft":
        parts.append(CRAFT_CFG_HINT + "\n")
    elif project == "ae2_feed":
        parts.append(AE2_FEED_CFG_HINT + "\n")
    elif project == "crystals":
        parts.append(CRYSTALS_CFG_HINT + "\n")
    elif project == "power":
        parts.append(POWER_CFG_HINT + "\n")
    elif project == "distill":
        parts.append(DISTILL_CFG_HINT + "\n")
    elif project == "ae_stats":
        parts.append(AE_STATS_CFG_HINT + "\n")
    parts.append("-- Generated package.preload modules + entrypoint.\n\n")

    if embed_cfg_path is not None and embed_cfg_path.is_file():
        parts.append(wrap_cfg_embed(read_text(embed_cfg_path)))

    for name, path in modules.items():
        src = read_text(path)
        parts.append(f"-- module: {name} ({path.relative_to(REPO_ROOT).as_posix()})\n")
        parts.append(wrap_preload(name, src, mark_config=False))
        parts.append("\n")

    entry_body = strip_package_path(entry_src)
    parts.append(f"-- entry: {project}/{entry}.lua\n")
    parts.append(entry_body.rstrip() + "\n")
    return "".join(parts)


def write_merged_cfg(
    project_dir: Path,
    out_path: Path,
    sources: tuple[str, ...],
    paired_lua: str,
) -> None:
    parts: list[str] = []
    parts.append(
        f"# Config for {paired_lua} (keep the same basename on the computer).\n"
        "# Sections match source files in the repo. Edit either section in-game.\n\n"
    )
    for src_name in sources:
        src_path = project_dir / src_name
        if not src_path.is_file():
            raise SystemExit(f"merge cfg source missing: {src_path}")
        section = Path(src_name).stem
        body = read_text(src_path).replace("\r\n", "\n").replace("\r", "\n").rstrip()
        parts.append(f"[{section}]\n")
        parts.append(body)
        parts.append("\n\n")
    out_path.write_text("".join(parts), encoding="utf-8", newline="\n")


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

    embed_cfg_path = None
    cfg_name = EMBED_CFG.get(project)
    if cfg_name:
        candidate = project_dir / cfg_name
        if candidate.is_file():
            embed_cfg_path = candidate

    bundle = build_bundle(project, entry, modules, entry_src, embed_cfg_path)

    if project == "ae2_feed" and entry == "main":
        out_name = "ae2_feed"
    elif project == "crystals" and entry == "main":
        out_name = "crystals"
    elif project == "power" and entry == "main":
        out_name = "power"
    elif project == "distill" and entry == "main":
        out_name = "distill"
    else:
        out_name = entry
    out_dir = REPO_ROOT / "dist"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"{out_name}.lua"
    out_path.write_text(bundle, encoding="utf-8", newline="\n")

    mod_list = ", ".join(modules.keys()) or "(none)"
    print(f"Wrote {out_path.relative_to(REPO_ROOT).as_posix()}")
    print(f"  modules: {mod_list}")
    if embed_cfg_path is not None:
        print(f"  embedded config: {embed_cfg_path.relative_to(REPO_ROOT).as_posix()}")

    sources = MERGE_CFG.get(project)
    if sources:
        dst_cfg = out_dir / f"{out_name}.cfg"
        write_merged_cfg(project_dir, dst_cfg, sources, f"{out_name}.lua")
        print(
            f"  merged config: {dst_cfg.relative_to(REPO_ROOT).as_posix()} "
            f"<- {', '.join(sources)}"
        )
    else:
        entry_map = COPY_CFG_BY_ENTRY.get(project) or {}
        copy_name = entry_map.get(entry) or COPY_CFG.get(project)
        if copy_name:
            src_cfg = project_dir / copy_name
            if src_cfg.is_file():
                dst_cfg = out_dir / copy_name
                shutil.copyfile(src_cfg, dst_cfg)
                print(f"  copied config: {dst_cfg.relative_to(REPO_ROOT).as_posix()}")
        extra = (EXTRA_COPY_BY_ENTRY.get(project) or {}).get(entry) or ()
        for extra_name in extra:
            src_extra = project_dir / extra_name
            if src_extra.is_file():
                dst_extra = out_dir / extra_name
                shutil.copyfile(src_extra, dst_extra)
                print(f"  copied extra: {dst_extra.relative_to(REPO_ROOT).as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
