Fallback deploy pack: all bundled dist/*.lua + matching .cfg from the post-refactor tree (merged to main).

## Contents
- craft: craft_ui, pizza_maintain, wheat_grain, greenhouse_clean
- power, distill, crystals, ae2_feed
- ae_stats: sampler, display, graphview (+ labels.cfg)

## Verify before release
- python tools/run_tests.py (8 Lua suites)
- python -m pytest tests/
- python tools/check_requires.py
- Full tools/bundle_project.py rebuild of all entries

Copy each .lua + matching .cfg onto the in-game computer (same basename).
