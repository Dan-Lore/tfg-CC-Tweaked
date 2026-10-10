#!/usr/bin/env python3
"""Run Lua unit tests (tests/test_*.lua) with system lua + CC stubs."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TESTS_DIR = REPO_ROOT / "tests"


def find_lua() -> str:
    for name in ("lua", "lua5.4", "lua5.2", "lua5.3"):
        try:
            subprocess.run(
                [name, "-v"],
                check=True,
                capture_output=True,
            )
            return name
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    raise SystemExit(
        "lua not found in PATH (need lua 5.2/5.4). Install lua5.4 and retry."
    )


def main() -> int:
    lua = find_lua()
    tests = sorted(TESTS_DIR.glob("test_*.lua"))
    if not tests:
        print("No tests/test_*.lua found", file=sys.stderr)
        return 1

    failed = 0
    for path in tests:
        print(f"\n--- {path.relative_to(REPO_ROOT)} ---")
        proc = subprocess.run(
            [lua, str(path)],
            cwd=str(REPO_ROOT),
            text=True,
        )
        if proc.returncode != 0:
            failed += 1
            print(f"FAILED ({proc.returncode}): {path.name}")

    print()
    if failed:
        print(f"{failed}/{len(tests)} test files failed")
        return 1
    print(f"All {len(tests)} Lua test files passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
