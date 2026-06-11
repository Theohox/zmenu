# zmenu v5.14.1

**Feedback-driven improvements: universal query, safer GPU detection, richer history, and CI hardening.**

## Universal query

- New `zmenu --query <term>` flag searches the wiki, command history, and recent metrics in one shot.
- Prints a concise markdown summary for piping to an AI or a pager.

## Time-series history & diagnostics

- Metrics history now records GPU temperature, GPU utilization, and load average alongside RAM.
- New `_history_zoom()` helper for retrieving recent metric windows.
- Added `_disc_collect()` dispatcher so future metrics plugins can feed the history pipeline uniformly.

## Safety / configuration

- Added `ZMENU_GFX_AUTO_CORRECT` config (default `false`).
  - `gfx1100` is no longer silently remapped to `gfx1151`.
  - Users must opt in to auto-correction.

## QA / hygiene

- Fixed all `shellcheck -S warning` findings in the source tree.
- Fixed `set -e` abort in `_query_universal()` when `grep -c` finds zero matches.
- Fixed the bats `no runtime eval` test so source comments containing the word `eval` are not flagged.

---

# zmenu v5.14.0

**Lemonade & Hermes become first-class AI Engine citizens.**

## New actions

- **Lemonade** (`AI Engine → 1`)
  - Start `lemond` in the background
  - List downloaded models
  - Unload the current model
  - View backend recipes

- **Hermes** (`AI Engine → 2`)
  - Start the messaging gateway (`hermes gateway run`)
  - Launch the CLI/TUI (`hermes --tui`)
  - Launch the Desktop Electron app (`hermes-desktop`)

- Both sub-menus now have `C) ✦ Ask AI` support.

## Improvements

- Hermes discovery now correctly detects:
  - `hermes` CLI (the old `hermes_cli` name no longer exists)
  - `hermes gateway` processes
  - `hermes-desktop` wrapper / `Hermes` Electron binary
- AI Engine `C) Ask AI` context now includes live Lemonade and Hermes status.
- Added `ZMENU_LEMONADE_BIN` and `ZMENU_HERMES_BIN` config overrides.
- Process-group and KILL MODE Hermes kill patterns updated for the new binary names.

## QA / hygiene

- `zmenu.sh` build artifact is git-ignored; releases ship via CI artifact.
- `TODO.md` is git-ignored as an internal planning file.
