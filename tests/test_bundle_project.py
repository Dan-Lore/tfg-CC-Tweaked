#!/usr/bin/env python3
"""Pytest for tools/bundle_project.py."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "tools"))


def load_bundler():
    path = REPO / "tools" / "bundle_project.py"
    spec = importlib.util.spec_from_file_location("bundle_project", path)
    mod = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture(scope="module")
def bundler():
    return load_bundler()


def test_topo_modules_resolves_shared(bundler, tmp_path):
    # Use real craft_ui entry graph lightly via collect on ae2_feed main
    entry = "main"
    src = (REPO / "ae2_feed" / "main.lua").read_text(encoding="utf-8")
    modules = bundler.topo_modules(
        entry, src, REPO / "ae2_feed", REPO / "shared"
    )
    assert "config" in modules
    assert "discover" in modules
    assert "move" in modules
    assert "transfer" in modules  # via move


def test_bundle_power_writes_lua_and_cfg(bundler, tmp_path, monkeypatch):
    # Run bundler.main into real dist/ (repo) — assert artifacts
    dist = REPO / "dist"
    rc = bundler.main(["power"])
    assert rc == 0
    assert (dist / "power.lua").is_file()
    assert (dist / "power.cfg").is_file()
    text = (dist / "power.lua").read_text(encoding="utf-8")
    assert 'package.preload["config"]' in text
    assert 'package.preload["gas_turbine"]' in text
    assert "Bundled from power/main.lua" in text


def test_bundle_craft_merges_cfg(bundler):
    rc = bundler.main(["craft", "pizza_maintain"])
    assert rc == 0
    cfg = (REPO / "dist" / "pizza_maintain.cfg").read_text(encoding="utf-8")
    assert "[storage]" in cfg
    assert "[recipes]" in cfg
    assert "main |" in cfg or "main|" in cfg.replace(" ", "")
    lua = (REPO / "dist" / "pizza_maintain.lua").read_text(encoding="utf-8")
    assert 'package.preload["craft"]' in lua or "craft.request" in lua


def test_bundle_crystals_copies_cfg(bundler):
    rc = bundler.main(["crystals"])
    assert rc == 0
    assert (REPO / "dist" / "crystals.lua").is_file()
    assert (REPO / "dist" / "crystals.cfg").is_file()


def test_circular_require_detected(bundler, tmp_path):
    proj = tmp_path / "circ"
    proj.mkdir()
    (proj / "main.lua").write_text('require("a")\n', encoding="utf-8")
    (proj / "a.lua").write_text('require("b")\nreturn {}\n', encoding="utf-8")
    (proj / "b.lua").write_text('require("a")\nreturn {}\n', encoding="utf-8")
    shared = tmp_path / "shared"
    shared.mkdir()
    with pytest.raises(RuntimeError, match="circular"):
        bundler.topo_modules(
            "main",
            (proj / "main.lua").read_text(encoding="utf-8"),
            proj,
            shared,
        )


def test_check_requires_all_entries():
    import subprocess

    proc = subprocess.run(
        [sys.executable, str(REPO / "tools" / "check_requires.py")],
        cwd=str(REPO),
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert "All entry requires" in proc.stdout
