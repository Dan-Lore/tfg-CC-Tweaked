#!/usr/bin/env python3
"""Verify each project entry resolves require() only from its dir + shared/."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

ENTRIES: list[tuple[str, str]] = [
    ("ae2_feed", "main"),
    ("crystals", "main"),
    ("power", "main"),
    ("distill", "main"),
    ("ae_stats", "sampler"),
    ("ae_stats", "display"),
    ("ae_stats", "graphview"),
    ("craft", "craft_ui"),
    ("craft", "greenhouse_clean"),
    ("craft", "wheat_grain"),
    ("craft", "pizza_maintain"),
]


def load_bundler():
    path = REPO_ROOT / "tools" / "bundle_project.py"
    spec = importlib.util.spec_from_file_location("bundle_project", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    bundler = load_bundler()
    shared = REPO_ROOT / "shared"
    failed = 0
    for project, entry in ENTRIES:
        project_dir = REPO_ROOT / project
        entry_path = project_dir / f"{entry}.lua"
        if not entry_path.is_file():
            print(f"MISSING entry: {entry_path}")
            failed += 1
            continue
        try:
            modules = bundler.topo_modules(
                entry,
                bundler.read_text(entry_path),
                project_dir,
                shared,
            )
        except Exception as exc:  # noqa: BLE001
            print(f"FAIL {project}/{entry}: {exc}")
            failed += 1
            continue
        for name, path in modules.items():
            rel = path.resolve()
            try:
                rel.relative_to(project_dir.resolve())
                in_proj = True
            except ValueError:
                in_proj = False
            try:
                rel.relative_to(shared.resolve())
                in_shared = True
            except ValueError:
                in_shared = False
            if not (in_proj or in_shared):
                print(f"FAIL {project}/{entry}: module {name} outside project/shared: {path}")
                failed += 1
        print(f"OK {project}/{entry} ({len(modules)} modules)")
    if failed:
        print(f"{failed} check(s) failed")
        return 1
    print("All entry requires resolve within project + shared")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
