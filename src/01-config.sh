#  SECTION 1 — CONFIG
# ============================================================

cfg_init() {
    mkdir -p "$ZMENU_CONFIG_DIR"
    [[ -f "$ZMENU_CONFIG_FILE" ]] && return
    cat > "$ZMENU_CONFIG_FILE" << 'EOF'
# Z-Menu Configuration
# Edit directly or via zmenu → Settings → Edit Config

# Directory scanned for projects
ZMENU_PROJECTS_DIR="${HOME}/projects"

# Preferred model for AI sessions (leave empty to auto-select)
ZMENU_AI_MODEL=""

# Context window size for AI sessions
# Recommended: 8192 (fast) | 16384 (balanced) | 32768 (long docs)
ZMENU_AI_CONTEXT_LENGTH=8192

# AI backend: auto | zenny | opencode | ollama
# auto = best available (Zenny-Core → Ollama)
ZMENU_AI_BACKEND="auto"

# Zenny-Core model to use for inline chat (registry key — use list from AI Backend picker)
# Leave empty to auto-select smallest available model
ZMENU_ZENNY_CHAT_MODEL=""

# Editor for in-menu editing
ZMENU_PREFERRED_EDITOR="${VISUAL:-${EDITOR:-nano}}"

# Zenny-Core binary path — set to wherever you built/installed zenny-core
# Default: ${HOME}/.local/bin/zenny-core
# Build: cargo build --release --features vulkan  (in the zenny-core repo)
ZMENU_ZENNY_BINARY="${HOME}/.local/bin/zenny-core"

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
EOF
    echo -e "  ${BGRN}✓${NC}  Config created: ${ZMENU_CONFIG_FILE}"
}

cfg_load() {
    cfg_init
    # Security: verify config file ownership and permissions before sourcing
    local _mode _owner
    _mode=$(stat -c '%a' "$ZMENU_CONFIG_FILE" 2>/dev/null || echo "")
    _owner=$(stat -c '%u' "$ZMENU_CONFIG_FILE" 2>/dev/null || echo "")
    if [[ -n "$_mode" && "$_mode" != "600" && "$_mode" != "644" && "$_mode" != "640" ]]; then
        echo -e "  ${WARN}  Config file permissions ($_mode) are too permissive. Run: chmod 600 $ZMENU_CONFIG_FILE"
    fi
    if [[ -n "$_owner" && "$_owner" != "$(id -u)" ]]; then
        echo -e "  ${FAIL}  Config file is not owned by you. Aborting."
        return 1
    fi
    # shellcheck source=/dev/null
    source "$ZMENU_CONFIG_FILE"
    # Propagate config overrides to runtime variables
    if [[ -n "${ZMENU_ZENNY_BINARY:-}" ]]; then ZENNY_BINARY="$ZMENU_ZENNY_BINARY"; fi
}

cfg_edit() {
    ${ZMENU_PREFERRED_EDITOR} "$ZMENU_CONFIG_FILE"
    cfg_load
}

