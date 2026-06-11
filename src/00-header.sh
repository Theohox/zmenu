#!/usr/bin/env bash
# shellcheck disable=SC2034
# ============================================================
#  Z-MENU  v5.14.2
#  Local Sovereign Dashboard
#
#  INSTALL:   ./build.sh && sudo cp zmenu.sh /usr/local/bin/zmenu
#  RUN:       zmenu
#  HEADLESS:  zmenu --run <function_name>
#  WATCH:     zmenu --watch   (background monitoring)
#
#  v5.13.1 — Quality audit + sparklines:
#    • Fixed _history_load_trend: replaced fragile awk+getline+date with Python
#    • Fixed _history_trend_str: replaced bc dependency with pure bash math
#    • Fixed _watch_mode: lightweight probes instead of heavy full discover()
#    • Fixed _build_context_json: env-var pass (no shell escaping issues)
#    • Removed false [?]=help promise from submenu_footer
#    • ASCII sparklines on dashboard (GPU temp, RAM, load)
#    • Configurable sparkline point count: ZMENU_SPARKLINE_POINTS
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
readonly ZMENU_VERSION="5.14.2"
ZMENU_SELF="$(realpath "${BASH_SOURCE[0]}")"
readonly ZMENU_SELF
readonly ZMENU_INSTALL_PATH="/usr/local/bin/zmenu"

# ── Config directory & defaults ────────────────────────────
ZMENU_CONFIG_DIR="${HOME}/.zmenu"
ZMENU_CONFIG_FILE="${ZMENU_CONFIG_DIR}/config"
ZMENU_WIKI_DIR="${ZMENU_CONFIG_DIR}/wiki"
ZMENU_HISTORY_DIR="${ZMENU_CONFIG_DIR}/history"
ZMENU_TMP_DIR="${ZMENU_CONFIG_DIR}/tmp"
ZMENU_SESSION_LOG="${ZMENU_HISTORY_DIR}/commands.jsonl"
ZMENU_CONTEXT_FILE="${ZMENU_TMP_DIR}/zmenu-context.md"
ZMENU_ERROR_LOG="${ZMENU_TMP_DIR}/zmenu-errors.log"
ZMENU_REPORT_FILE="${HOME}/zmenu-report.md"

# Ensure private temp directory exists before any sensitive files are created
mkdir -p "$ZMENU_TMP_DIR" 2>/dev/null && chmod 700 "$ZMENU_TMP_DIR" 2>/dev/null || true

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
_on_err() {
    local _safe_cmd
    _safe_cmd=$(echo "$BASH_COMMAND" | sed 's/\(token\|key\|password\|secret\|api_key\|auth\)=[^[:space:]]*/\1=***/gi')
    echo "[$(date '+%H:%M:%S')] ERR line $1: $_safe_cmd" >> "$ZMENU_ERROR_LOG"
}
trap '_on_err $LINENO' ERR

# ── Cleanup on exit ────────────────────────────────────────
_zmenu_cleanup() {
    rm -f "${ZMENU_TMP_DIR}/zmenu-chat-*.json" "${ZMENU_TMP_DIR}/zmenu-session-*.md" \
          "${ZMENU_TMP_DIR}/zmenu-ai-apply.txt" "${ZMENU_TMP_DIR}/zmenu-bp.txt" 2>/dev/null || true
}
trap _zmenu_cleanup EXIT

# Ensure error log has restrictive permissions
mkdir -p "$ZMENU_TMP_DIR" 2>/dev/null && chmod 700 "$ZMENU_TMP_DIR" 2>/dev/null || true
touch "$ZMENU_ERROR_LOG" 2>/dev/null && chmod 600 "$ZMENU_ERROR_LOG" 2>/dev/null || true

# ============================================================
