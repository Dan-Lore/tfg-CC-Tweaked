#!/usr/bin/env python3
"""Verify each project entry resolves require() only from its dir + projects/shared."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def load_bundler():
    path = REPO_ROOT / "tools" / "bundle_project.py"
    spec = importlib.util.spec_from_file_location("bundle_project", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def main() -> int:
    bundler = load_bundler()
    shared = bundler.SHARED_DIR
    failed = 0
    projects = bundler.list_projects()
    if not projects:
        print(f"No projects under {bundler.PROJECTS_ROOT}")
        return 1

    for project in projects:
        project_dir = bundler.PROJECTS_ROOT / project
        try:
            entries = bundler.discover_entries(project)
        except SystemExit as exc:
            print(f"FAIL {project}: {exc}")
            failed += 1
            continue
        for ent in entries:
            try:
                modules = bundler.topo_modules(
                    ent.module,
                    bundler.read_text(ent.path),
                    project_dir,
                    shared,
                )
            except Exception as exc:  # noqa: BLE001
                print(f"FAIL {project}/{ent.module}: {exc}")
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
                    print(
                        f"FAIL {project}/{ent.module}: "
                        f"module {name} outside project/shared: {path}"
                    )
                    failed += 1
            print(f"OK {project}/{ent.module} ({len(modules)} modules)")
    if failed:
        print(f"{failed} check(s) failed")
        return 1
    print("All entry requires resolve within project + shared")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
