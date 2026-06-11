#  SECTION 1 — CONFIG
# ============================================================

cfg_init() {
    mkdir -m 700 -p "$ZMENU_CONFIG_DIR"
    [[ -f "$ZMENU_CONFIG_FILE" ]] && return
    cat > "$ZMENU_CONFIG_FILE" << 'EOF'
# Z-Menu Configuration
# Edit directly or via zmenu → Settings → Edit Config

# Directory scanned for projects
ZMENU_PROJECTS_DIR="${HOME}/projects"

# LLM-Gateway source/build directory (only needed if you run llm-gateway locally)
LLM_GATEWAY_DIR="${HOME}/projects/llm-gateway"

# Lemonade and Hermes binaries (defaults usually work if they are on $PATH)
ZMENU_LEMONADE_BIN="lemond"
ZMENU_HERMES_BIN="hermes"

# Preferred model for AI sessions (leave empty to auto-select)
ZMENU_AI_MODEL=""

# Context window size for AI sessions
# Recommended: 8192 (fast) | 16384 (balanced) | 32768 (long docs)
ZMENU_AI_CONTEXT_LENGTH=8192

# AI backend: auto | opencode | ollama
# auto = best available (Ollama → OpenCode)
ZMENU_AI_BACKEND="auto"

# Editor for in-menu editing
ZMENU_PREFERRED_EDITOR="${VISUAL:-${EDITOR:-nano}}"

# GPU gfx ID override — use if rocminfo reports the wrong ID for your GPU
# Strix Halo (Radeon 8060S): rocminfo reports gfx1100, real die is gfx1151
# Set this to force the correct ID:  ZMENU_GPU_GFX_OVERRIDE=gfx1151
ZMENU_GPU_GFX_OVERRIDE=""

# Machine label shown in AI system prompts and wiki (defaults to hostname if empty)
ZMENU_MACHINE_LABEL=""

# ── Background Watch Mode ──────────────────────────────────
# Run: zmenu --watch   (checks every ZMENU_WATCH_INTERVAL seconds)
ZMENU_WATCH_INTERVAL=30
ZMENU_ALERT_GPU_TEMP=85
ZMENU_ALERT_RAM_PERCENT=90
ZMENU_ALERT_SWAP_MB=500
ZMENU_ALERT_LOAD_MULTIPLIER=2

# ── Dashboard Sparklines ───────────────────────────────────
# Number of historical data points to show (default: 30 ≈ 15 min at 30s intervals)
ZMENU_SPARKLINE_POINTS=30
EOF
    chmod 600 "$ZMENU_CONFIG_FILE" 2>/dev/null || true
    echo -e "  ${BGRN}✓${NC}  Config created: ${ZMENU_CONFIG_FILE}"
}

cfg_load() {
    cfg_init
    # Security: verify config file ownership and permissions before sourcing
    local _mode _owner
    _mode=$(stat -c '%a' "$ZMENU_CONFIG_FILE" 2>/dev/null || echo "")
    _owner=$(stat -c '%u' "$ZMENU_CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$_owner" && "$_owner" != "$(id -u)" ]]; then
        echo -e "  ${FAIL}  Config file is not owned by you. Aborting." >&2
        return 1
    fi
    if [[ -n "$_mode" && "$_mode" != "600" && "${ZMENU_CONFIG_PERMISSIVE:-0}" != "1" ]]; then
        echo -e "  ${FAIL}  Config file permissions ($_mode) are too permissive." >&2
        echo -e "         Run: chmod 600 ${ZMENU_CONFIG_FILE}" >&2
        echo -e "         Or override: ZMENU_CONFIG_PERMISSIVE=1 zmenu" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$ZMENU_CONFIG_FILE"
    # Propagate config overrides to runtime variables
}

cfg_edit() {
    _run_editor "$ZMENU_CONFIG_FILE"
    cfg_load
}

# Run the user's preferred editor safely, allowing paths with spaces.
# Usage: _run_editor [file1] [file2] ...
_run_editor() {
    local -a editor=()
    IFS=' ' read -r -a editor <<< "$ZMENU_PREFERRED_EDITOR"
    "${editor[@]}" "$@"
}

# Safely set or append a key=value in the zmenu config file.
# Escapes sed metacharacters so arbitrary values (e.g. model names with /)
# cannot corrupt the config.
_cfg_set() {
    local key="$1" value="$2"
    local cfg="$ZMENU_CONFIG_FILE"
    # Escape backslash, ampersand, and pipe for safe sed replacement
    local safe_value
    safe_value=$(printf '%s' "$value" | sed 's/[&\\|]/\\&/g')
    if grep -q "^${key}=" "$cfg" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${safe_value}\"|" "$cfg"
    else
        printf '%s="%s"\n' "$key" "$value" >> "$cfg"
    fi
}

