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
