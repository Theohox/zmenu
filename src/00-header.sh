#!/usr/bin/env bash
# ============================================================
#  Z-MENU  v5.12.0
#  Local Sovereign Dashboard
#
#  INSTALL:   ./build.sh && sudo cp zmenu.sh /usr/local/bin/zmenu
#  RUN:       zmenu
#  HEADLESS:  zmenu --run <function_name>
#
#  v5.12.0 — KILL MODE refactor:
#    • Dashboard home screen with green/yellow/red status at a glance
#    • Find Problems module — full bottleneck sweep with plain English fixes
#    • Export from most screens (press E → ~/zmenu-report.md)
#    • 8 menu sections grouped by what affects what
#    • Portable — auto-detect hardware, no hardcoded values
#    • Back buttons + Ask AI on every screen (when AI backend is available)
#
#  Architecture:
#    1. Config       — ~/.zmenu/config (sourced, user-editable)
#    2. Discovery    — runs once at startup, populates all state
#    3. Chrome       — header, pause, confirm, status dashboard
#    4. Context/AI   — context generator + AI launcher
#    5. Export       — E) on any screen saves markdown report
#    6. Modules      — 8 sections, each self-contained
#    7. Main Menu    — top-level loop
#    8. Entrypoint   — bootstrap, CLI args
# ============================================================

set -euo pipefail

# ── Version ────────────────────────────────────────────────
readonly ZMENU_VERSION="5.12.0"
readonly ZMENU_SELF="$(realpath "${BASH_SOURCE[0]}")"
readonly ZMENU_INSTALL_PATH="/usr/local/bin/zmenu"

# ── Config directory & defaults ────────────────────────────
ZMENU_CONFIG_DIR="${HOME}/.zmenu"
ZMENU_CONFIG_FILE="${ZMENU_CONFIG_DIR}/config"
ZMENU_WIKI_DIR="${ZMENU_CONFIG_DIR}/wiki"
ZMENU_CONTEXT_FILE="/tmp/zmenu-context.md"
ZMENU_ERROR_LOG="/tmp/zmenu-errors.log"
ZMENU_REPORT_FILE="${HOME}/zmenu-report.md"

# Default config values — overridden by config file
ZMENU_PROJECTS_DIR="${HOME}/projects"
ZMENU_AI_MODEL=""          # empty = auto-select best available
ZMENU_AI_CONTEXT_LENGTH=8192
ZMENU_PREFERRED_EDITOR="${VISUAL:-${EDITOR:-nano}}"
ZMENU_HEADLESS="${ZMENU_HEADLESS:-0}"

# ── Colours ────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; WHT='\033[0;37m'
BRED='\033[1;31m'; BGRN='\033[1;32m'; BYEL='\033[1;33m'
BBLU='\033[1;34m'; BCYN='\033[1;36m'; BWHT='\033[1;37m'
BBLK='\033[1;30m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

OK="${BGRN}●${NC}"       # running / healthy / ready
FAIL="${BRED}●${NC}"     # error / down / critical
WARN="${BYEL}●${NC}"     # attention / degraded / unexpected
IDLE="${BBLK}○${NC}"     # stopped / installed-not-running / intentionally off

# ── Error trap ─────────────────────────────────────────────
_on_err() { echo "[$(date '+%H:%M:%S')] ERR line $1: $BASH_COMMAND" >> "$ZMENU_ERROR_LOG"; }

# ============================================================
