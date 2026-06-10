# zmenu TODO

## Done — v5.12.0 KILL MODE Refactor

- [x] **KILL MODE as option #1** — task manager for killing runaway processes fast
  - Top CPU consumers (numbered, `Nk` = SIGTERM, `NK` = SIGKILL, `Ni` = info)
  - Top RAM consumers (same pattern)
  - Process groups (kill entire Lemonade, Hermes, Docker, Zed groups)
  - Unknown / suspicious processes (risk-tiered, all killable)
  - Kill by PID (enter any process ID)
- [x] **Fix dead ends** — `_show_process_groups` is now interactive with kill actions
- [x] **Consistent navigation** — every screen supports `[Enter]=back`, `[r]=refresh`, `[q]=quit`
- [x] **Dashboard warnings** — when memory/load is critical, dashboard shouts `→ Use KILL MODE (option 1)`
- [x] **Main menu redesign** — KILL MODE #1, Docker & Services surfaced directly at #3
- [x] **Docs sync** — README, DEVELOPMENT.md, and version all updated to 5.12.0

## Open — Next Up

### Navigation Consistency Audit
- [x] Audit all submenu loops for consistent `[Enter]=back / [r]=refresh / [q]=quit` handling
- [x] Fix AI_BACKEND_ACTIVE conditionals hiding footer hints (Back/Export) in 11 locations
- [x] Add `q) Quit zmenu` to all submenus missing it
- [x] Automated navigation validation added to `./build.sh` — catches dead ends, missing back options, and footer bugs on every build
- [ ] Some menus still use `sleep 1` on invalid input — replace with `sleep 0.5` everywhere for snappier feel

### Kill Mode Enhancements
- [ ] Add a "quick kill" hotkey from the dashboard (press `k` to jump straight to KILL MODE)
- [ ] Add kill actions to `_scan_unknowns` when called from System Scan (not just from KILL MODE)
- [ ] Add signal choice in process info screen (show `kill -l` options, not just TERM/KILL)
- [ ] Add CPU% threshold filter in KILL MODE (e.g. "only show processes using >10% CPU")

### Build & Repo Hygiene
- [ ] Decide: should `zmenu.sh` remain tracked in git, or be treated as a build artifact?
  - Pro tracked: it's the distributable file users copy to `/usr/local/bin`
  - Pro ignored: it's auto-generated, leads to merge conflicts
- [ ] Add a `make install` target or simple install script
- [ ] Add pre-commit hook that runs `./build.sh` and `bash -n zmenu.sh`

### UX Polish
- [ ] Add a "last action" summary to the dashboard (e.g. "Last: killed python3 pid 12345")
- [ ] Colour-code the KILL MODE menu header more aggressively so it's unmistakable when stressed
- [ ] Add a "panic button" — single keypress that SIGKILLs the top CPU consumer immediately
- [ ] Evaluate whether Security & Privacy and Maintenance should be merged or reordered

### Bugs
- [ ] `--run` mode fails because `clear` returns non-zero in non-TTY environments (triggered by `set -e`)
- [ ] `_scan_unknowns` in System Scan is read-only — add a kill prompt at the end
