#!/usr/bin/env bash
# ============================================================
#  Z-MENU  v3.0.0
#  Local Sovereign Dashboard — HP ZBook Ultra / AMD Ryzen AI
#
#  INSTALL:   chmod +x zmenu.sh && sudo cp zmenu.sh /usr/local/bin/zmenu
#  RUN:       zmenu
#  HEADLESS:  zmenu --run <function_name>
#
#  Architecture:
#    1. Config  — ~/.zmenu/config (sourced, user-editable)
#    2. Discover — runs once at startup, populates all state
#    3. Modules — self-contained, follow standard pattern
#    4. AI  — any section can launch a local AI session with live context
# ============================================================

set -euo pipefail

# ── Version ────────────────────────────────────────────────
readonly ZMENU_VERSION="3.4.1"
readonly ZMENU_SELF="$(realpath "${BASH_SOURCE[0]}")"
readonly ZMENU_INSTALL_PATH="/usr/local/bin/zmenu"

# ── Config directory & defaults ────────────────────────────
ZMENU_CONFIG_DIR="${HOME}/.zmenu"
ZMENU_CONFIG_FILE="${ZMENU_CONFIG_DIR}/config"
ZMENU_CONTEXT_FILE="/tmp/zmenu-context.md"
ZMENU_ERROR_LOG="/tmp/zmenu-errors.log"

# Default config values — overridden by config file
ZMENU_PROJECTS_DIR="${HOME}/projects"
ZMENU_AI_MODEL=""          # empty = auto-select best available
ZMENU_PREFERRED_EDITOR="${VISUAL:-${EDITOR:-nano}}"
ZMENU_HEADLESS="${ZMENU_HEADLESS:-0}"

# ── Colours ────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; WHT='\033[0;37m'
BRED='\033[1;31m'; BGRN='\033[1;32m'; BYEL='\033[1;33m'
BBLU='\033[1;34m'; BCYN='\033[1;36m'; BWHT='\033[1;37m'
BBLK='\033[1;30m'; DIM='\033[2m'; BOLD='\033[1m'; NC='\033[0m'

OK="${BGRN}●${NC}"
FAIL="${BRED}●${NC}"
WARN="${BYEL}●${NC}"
IDLE="${BBLK}●${NC}"

# ── Error trap ─────────────────────────────────────────────
trap '_on_err $LINENO' ERR
_on_err() { echo "[$(date '+%H:%M:%S')] ERR line $1: $BASH_COMMAND" >> "$ZMENU_ERROR_LOG"; }

# ============================================================
#  SECTION 1 — CONFIG
# ============================================================

cfg_init() {
    mkdir -p "$ZMENU_CONFIG_DIR"
    [[ -f "$ZMENU_CONFIG_FILE" ]] && return

    cat > "$ZMENU_CONFIG_FILE" << 'EOF'
# Z-Menu Configuration
# Edit directly or via zmenu → Manage Z-Menu → Edit Config
# All paths support ~ expansion. All values are bash variables.

# Directory scanned for projects
ZMENU_PROJECTS_DIR="${HOME}/projects"

# Preferred model for AI sessions (leave empty to auto-select)
# Auto-select picks the first Ollama model with 'tools' capability
ZMENU_AI_MODEL=""

# Editor for in-menu editing
ZMENU_PREFERRED_EDITOR="${VISUAL:-${EDITOR:-nano}}"
EOF
    echo -e "  ${BGRN}✓${NC}  Config created: ${ZMENU_CONFIG_FILE}"
}

cfg_load() {
    cfg_init
    # shellcheck source=/dev/null
    source "$ZMENU_CONFIG_FILE"
}

cfg_edit() {
    ${ZMENU_PREFERRED_EDITOR} "$ZMENU_CONFIG_FILE"
    cfg_load
}

# ============================================================
#  SECTION 2 — DISCOVERY ENGINE
#  Runs once at startup. Populates D_* (discovered) variables.
#  Never assumes — always probes.
# ============================================================

# Discovered state — all empty until discover() runs
D_OLLAMA_URL=""
D_OLLAMA_RUNNING=false
D_OLLAMA_ACTIVE_MODEL=""
D_OLLAMA_MODELS=()          # all available models
D_OLLAMA_TOOL_MODELS=()     # models with tool-calling support

D_LMS_URL=""
D_LMS_RUNNING=false
D_LMS_MODELS=()

D_AI_BIN=""
D_AI_VER=""
D_AI_RUNNING=false

D_DOCKER_RUNNING=false
D_CONTAINERS=()             # name:status pairs

D_GPU_DRIVER=""             # rocm | amdgpu-sysfs | none
D_GPU_GFX=""                # e.g. gfx1151
D_GPU_TEMP=""
D_GPU_USE=""

D_NPU_DRIVER=""             # amdxdna | none
D_NPU_DEVICE=""

D_SERVICES=()               # discovered systemd AI/infra services
D_OPEN_PORTS=()             # port:process pairs

discover() {
    _disc_ollama
    _disc_lms
    _disc_ai_tool
    _disc_docker
    _disc_gpu
    _disc_npu
    _disc_services
    _disc_ports
    _sel_ai_model
}

# ── Ollama ─────────────────────────────────────────────────
_disc_ollama() {
    # Scan common ports for an Ollama-compatible API
    local candidates=(11434 11435 11436)
    for port in "${candidates[@]}"; do
        local url="http://localhost:${port}"
        if curl -sf --max-time 1 "${url}/api/tags" >/dev/null 2>&1; then
            D_OLLAMA_URL="$url"
            D_OLLAMA_RUNNING=true
            break
        fi
    done
    [[ "$D_OLLAMA_RUNNING" == false ]] && return

    # Active model
    local ps
    ps=$(curl -sf --max-time 2 "${D_OLLAMA_URL}/api/ps" 2>/dev/null || echo "")
    D_OLLAMA_ACTIVE_MODEL=$(echo "$ps" \
        | grep -o '"name":"[^"]*"' | head -1 \
        | sed 's/"name":"//;s/"//' || echo "")

    # All models
    local tags
    tags=$(curl -sf --max-time 3 "${D_OLLAMA_URL}/api/tags" 2>/dev/null || echo "")
    while IFS= read -r name; do
        [[ -n "$name" ]] && D_OLLAMA_MODELS+=("$name")
    done < <(echo "$tags" | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"//')

    # Tool-capable models
    for m in "${D_OLLAMA_MODELS[@]}"; do
        if ollama show "$m" 2>/dev/null | grep -qi "tools"; then
            D_OLLAMA_TOOL_MODELS+=("$m")
        fi
    done
}

# ── LM Studio ──────────────────────────────────────────────
_disc_lms() {
    local candidates=(1234 1235 8080)
    for port in "${candidates[@]}"; do
        local url="http://localhost:${port}"
        if curl -sf --max-time 1 "${url}/v1/models" >/dev/null 2>&1; then
            D_LMS_URL="$url"
            D_LMS_RUNNING=true
            break
        fi
    done
    [[ "$D_LMS_RUNNING" == false ]] && return

    local resp
    resp=$(curl -sf --max-time 3 "${D_LMS_URL}/v1/models" 2>/dev/null || echo "")
    while IFS= read -r id; do
        [[ -n "$id" ]] && D_LMS_MODELS+=("$id")
    done < <(echo "$resp" | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
}

# ── Local AI tool (Ollama) ─────────────────────────────────
_disc_ai_tool() {
    D_AI_BIN=$(command -v ollama 2>/dev/null || echo "")
    [[ -z "$D_AI_BIN" ]] && return
    D_AI_RUNNING=true
    D_AI_VER=$(ollama --version 2>/dev/null \
        | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || echo "?")
}

# ── Docker ─────────────────────────────────────────────────
_disc_docker() {
    export DOCKER_HOST="${DOCKER_HOST:-unix:///run/docker.sock}"
    docker info >/dev/null 2>&1 || return
    D_DOCKER_RUNNING=true
    while IFS= read -r line; do
        [[ -n "$line" ]] && D_CONTAINERS+=("$line")
    done < <(docker ps --format "{{.Names}}:{{.Status}}" 2>/dev/null || true)
}

# ── GPU ────────────────────────────────────────────────────
_disc_gpu() {
    if command -v rocm-smi >/dev/null 2>&1; then
        D_GPU_DRIVER="rocm"
        D_GPU_GFX=$(rocminfo 2>/dev/null \
            | grep -i "gfx" | head -1 | grep -o 'gfx[0-9a-f]*' || echo "unknown")
        D_GPU_TEMP=$(rocm-smi --showtemp 2>/dev/null \
            | awk '/GPU\[0\]/{print $NF}' | head -1 || echo "?")
        D_GPU_USE=$(rocm-smi --showuse 2>/dev/null \
            | awk '/GPU\[0\]/{print $NF}' | head -1 || echo "?")
        return
    fi
    # Fallback: sysfs
    for d in /sys/class/hwmon/hwmon*; do
        local n; n=$(cat "$d/name" 2>/dev/null || echo "")
        if [[ "$n" == *amdgpu* ]]; then
            D_GPU_DRIVER="amdgpu-sysfs"
            local tf; tf=$(ls "$d"/temp*_input 2>/dev/null | head -1)
            [[ -f "$tf" ]] && D_GPU_TEMP=$(awk '{printf "%.0f", $1/1000}' "$tf")
            return
        fi
    done
}

# ── NPU ────────────────────────────────────────────────────
_disc_npu() {
    for mod in amdxdna ryzen_ai npu amd_ipu; do
        if lsmod 2>/dev/null | grep -qi "$mod"; then
            D_NPU_DRIVER="$mod"
            D_NPU_DEVICE=$(ls /dev/accel* 2>/dev/null | head -1 || echo "no-device")
            return
        fi
    done
}

# ── Systemd services of interest ───────────────────────────
_disc_services() {
    local units
    units=$(systemctl list-units --type=service --state=active \
        --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' || true)
    local keywords=("ollama" "docker" "n8n" "lmstudio" "rocm" "amd" "containerd")
    for svc in $units; do
        for kw in "${keywords[@]}"; do
            if [[ "$svc" == *"$kw"* ]]; then
                D_SERVICES+=("$svc")
                break
            fi
        done
    done
}

# ── Listening ports ────────────────────────────────────────
_disc_ports() {
    while IFS= read -r line; do
        [[ -n "$line" ]] && D_OPEN_PORTS+=("$line")
    done < <(ss -tlnp 2>/dev/null \
        | awk 'NR>1 {match($4, /[0-9]+$/, a); if(a[0]!="") print a[0]":"$6}' \
        | sort -t: -k1 -n || true)
}

# ── Select best Ollama model ───────────────────────────────
_sel_ai_model() {
    # Use config override if set
    if [[ -n "$ZMENU_AI_MODEL" ]]; then
        # Validate it exists
        for m in "${D_OLLAMA_MODELS[@]}"; do
            [[ "$m" == "$ZMENU_AI_MODEL" ]] && return
        done
    fi

    # Prefer tool-capable models
    if [[ ${#D_OLLAMA_TOOL_MODELS[@]} -gt 0 ]]; then
        ZMENU_AI_MODEL="${D_OLLAMA_TOOL_MODELS[0]}"
        return
    fi

    # Fall back to any available model
    if [[ ${#D_OLLAMA_MODELS[@]} -gt 0 ]]; then
        ZMENU_AI_MODEL="${D_OLLAMA_MODELS[0]}"
        return
    fi

    ZMENU_AI_MODEL="no-models-found"
}

# ── GFX version normaliser ─────────────────────────────────
# Converts between compact (1151) and dotted (11.5.1) forms
# so comparisons work regardless of which form the user set.
_gfx_normalise() {
    local v="$1"
    # Remove dots to get compact form: 11.5.1 → 1151, 1151 → 1151
    echo "${v//./}"
}

_gfx_match() {
    # Returns 0 (true) if two GFX version strings refer to the same version
    [[ "$(_gfx_normalise "$1")" == "$(_gfx_normalise "$2")" ]]
}

# ── GFX version display ───────────────────────────────────
# Shows both forms for clarity: "1151 (11.5.1)"
_gfx_dotted() {
    local v="${1//./}"
    # Convert compact to dotted: 1151 → 11.5.1, 1100 → 11.0.0
    if [[ ${#v} -eq 4 ]]; then
        echo "${v:0:2}.${v:2:1}.${v:3:1}"
    elif [[ ${#v} -eq 3 ]]; then
        echo "${v:0:1}.${v:1:1}.${v:2:1}"
    else
        echo "$v"
    fi
}

# ============================================================
#  SECTION 3 — CONTEXT GENERATOR
#  Produces /tmp/zmenu-context.md for local AI sessions
# ============================================================

context_generate() {
    {
        echo "# Z-Menu Live System Context"
        echo "> Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        echo "## Machine"
        echo '```'
        # CPU model
        grep -m1 'model name' /proc/cpuinfo 2>/dev/null \
            | sed 's/model name\s*:\s*/CPU: /' || echo "CPU: unknown"
        # RAM
        free -h | awk '/^Mem/{printf "RAM: %s total, %s used, %s free\n",$2,$3,$7}'
        # Disk
        df -h / | awk 'NR==2{printf "Disk: %s used / %s total (%s full, %s free)\n",$3,$2,$5,$4}'
        # Load
        awk '{printf "Load: %s %s %s\n",$1,$2,$3}' /proc/loadavg
        # Uptime
        uptime -p 2>/dev/null || true
        echo '```'
        echo ""

        echo "## AI Inference Stack"
        echo '```'
        if [[ "$D_OLLAMA_RUNNING" == true ]]; then
            echo "Ollama: RUNNING at ${D_OLLAMA_URL}"
            echo "Active model: ${D_OLLAMA_ACTIVE_MODEL:-none loaded}"
            echo "Available models:"
            for m in "${D_OLLAMA_MODELS[@]}"; do echo "  - $m"; done
            echo "Tool-capable models:"
            if [[ ${#D_OLLAMA_TOOL_MODELS[@]} -gt 0 ]]; then
                for m in "${D_OLLAMA_TOOL_MODELS[@]}"; do echo "  - $m"; done
            else
                echo "  - none detected"
            fi
        else
            echo "Ollama: STOPPED"
        fi
        echo ""
        if [[ "$D_LMS_RUNNING" == true ]]; then
            echo "LM Studio: RUNNING at ${D_LMS_URL}"
            for m in "${D_LMS_MODELS[@]}"; do echo "  - $m"; done
        else
            echo "LM Studio: STOPPED (fine — Ollama handles inference)"
        fi
        echo ""
        if [[ "$D_AI_RUNNING" == true ]]; then
            echo "Local AI tool: INSTALLED v${D_AI_VER}"
            echo "Selected model for sessions: ${ZMENU_AI_MODEL}"
        else
            echo "Local AI tool: not found"
        fi
        echo '```'
        echo ""

        echo "## GPU"
        echo '```'
        echo "Driver: ${D_GPU_DRIVER:-none}"
        echo "GFX: ${D_GPU_GFX:-unknown}"
        [[ -n "$D_GPU_TEMP" ]] && echo "Temp: ${D_GPU_TEMP}°C"
        [[ -n "$D_GPU_USE" ]] && echo "Utilisation: ${D_GPU_USE}%"
        if [[ "$D_GPU_DRIVER" == "rocm" ]]; then
            rocm-smi --showmeminfo vram 2>/dev/null | grep -E "Used|Total" | head -4 || true
        fi
        echo '```'
        echo ""

        echo "## NPU"
        echo '```'
        echo "Driver: ${D_NPU_DRIVER:-none}"
        echo "Device: ${D_NPU_DEVICE:-not found}"
        echo '```'
        echo ""

        echo "## Docker"
        echo '```'
        if [[ "$D_DOCKER_RUNNING" == true ]]; then
            echo "Status: RUNNING"
            echo "Containers:"
            docker ps --format "  {{.Names}}: {{.Status}} ({{.Ports}})" 2>/dev/null || true
        else
            echo "Status: STOPPED"
        fi
        echo '```'
        echo ""

        echo "## Open Ports"
        echo '```'
        ss -tlnp 2>/dev/null | grep LISTEN | \
            awk '{print $4, $6}' | sed 's/^/  /' || echo "  none"
        echo '```'
        echo ""

        echo "## Projects"
        echo '```'
        if [[ -d "$ZMENU_PROJECTS_DIR" ]]; then
            while IFS= read -r -d '' p; do
                local pn; pn=$(basename "$p")
                local flags=""
                [[ -f "${p}/AI.md" ]] && flags+="[AI.md]" || flags+="[no AI.md]"
                [[ -f "${p}/.config/ai/settings.json" ]] && flags+="[secured]"
                if [[ -d "${p}/.git" ]]; then
                    local br; br=$(git -C "$p" branch --show-current 2>/dev/null || echo "?")
                    flags+="[git:${br}]"
                fi
                echo "  ${pn}  ${flags}"
            done < <(find "$ZMENU_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 \
                | sort -z 2>/dev/null || true)
        else
            echo "  ${ZMENU_PROJECTS_DIR} not found"
        fi
        echo '```'
        echo ""

        echo "## Systemd Services (AI/Infra)"
        echo '```'
        for s in "${D_SERVICES[@]}"; do
            local st; st=$(systemctl is-active "$s" 2>/dev/null || echo "unknown")
            echo "  ${s}: ${st}"
        done
        echo '```'
        echo ""

        echo "## Recent Errors"
        echo '```'
        if [[ -f "$ZMENU_ERROR_LOG" ]]; then
            tail -10 "$ZMENU_ERROR_LOG"
        else
            echo "none"
        fi
        echo '```'

    } > "$ZMENU_CONTEXT_FILE" 2>/dev/null
}

# ============================================================
#  SECTION 4 — LOCAL AI LAUNCHER
#  Opens Open WebUI in browser with context pre-loaded as a
#  system prompt via the Ollama API. Zero telemetry. 100% local.
# ============================================================

OWUI_PORT="${OWUI_PORT:-3000}"
OWUI_URL="http://localhost:${OWUI_PORT}"

owui_check() {
    if [[ "$D_OLLAMA_RUNNING" == false ]]; then
        echo -e "  ${FAIL}  Ollama not running"
        echo "  Start: sudo systemctl start ollama"
        return 1
    fi
    if ! curl -sf "${OWUI_URL}" >/dev/null 2>&1; then
        echo -e "  ${WARN}  Open WebUI not running on ${OWUI_URL}"
        echo ""
        echo "  Start it with:"
        echo "  docker run -d --name open-webui --restart unless-stopped \\"
        echo "    -p 127.0.0.1:3000:8080 \\"
        echo "    --add-host=host.docker.internal:host-gateway \\"
        echo "    -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \\"
        echo "    -v open-webui:/app/backend/data \\"
        echo "    ghcr.io/open-webui/open-webui:main"
        return 1
    fi
    return 0
}

_build_context_prompt() {
    # $1 = role prompt
    local role_prompt="${1:-}"
    local context=""

    # Live system snapshot
    context_generate
    context="$(cat "$ZMENU_CONTEXT_FILE" 2>/dev/null)"

    # Append all skill files
    local skill_dir="${HOME}/.config/ai/skills"
    if [[ -d "$skill_dir" ]]; then
        for sf in "${skill_dir}"/*.md; do
            if [[ -f "$sf" ]]; then
                context+="\n\n---\n# Skill: $(basename "$sf" .md)\n"
                context+="$(cat "$sf")"
            fi
        done
    fi

    if [[ -n "$role_prompt" ]]; then
        context+="\n\n---\n${role_prompt}"
    fi

    printf '%s' "$context"
}

# Send context to Ollama as a primed conversation, then open Open WebUI
# Usage: cc_launch "Title" "role prompt" "/optional/working/dir"
cc_launch() {
    local title="${1:-Local AI}"
    local prompt="${2:-}"
    local workdir="${3:-$HOME}"

    echo "  Generating live system context..."
    context_generate
    echo -e "  ${OK}  Context ready → ${ZMENU_CONTEXT_FILE}"

    # Build full context including skills
    local full_context
    full_context="$(_build_context_prompt "$prompt")"

    # Write a combined context file that Open WebUI session can reference
    local session_file="/tmp/zmenu-session-$(date +%s).md"
    printf '%s' "$full_context" > "$session_file"
    echo -e "  ${OK}  Session context → ${session_file}"

    # Prime Ollama with the context via API (no telemetry — direct local API call)
    echo "  Priming model with context..."
    curl -sf "${D_OLLAMA_URL}/api/chat"         -H "Content-Type: application/json"         -d "{
            "model": "${ZMENU_AI_MODEL}",
            "messages": [{
                "role": "system",
                "content": $(printf '%s' "$full_context" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")
            }],
            "stream": false
        }" >/dev/null 2>&1 && echo -e "  ${OK}  Model primed" || echo -e "  ${WARN}  Could not prime model (will still open UI)"

    echo ""
    echo -e "  ${BCYN}${title}${NC}"
    echo "  Model: ${ZMENU_AI_MODEL}"
    echo "  Context includes: system snapshot + $(ls "${HOME}/.config/ai/skills/"*.md 2>/dev/null | wc -l) skill file(s)"
    echo ""

    if owui_check 2>/dev/null; then
        # Open WebUI in browser
        if command -v xdg-open >/dev/null 2>&1; then
            xdg-open "${OWUI_URL}" &>/dev/null &
            echo -e "  ${OK}  Open WebUI launched → ${OWUI_URL}"
            echo ""
            echo -e "  ${DIM}  Context file for reference: ${session_file}${NC}"
            echo -e "  ${DIM}  Paste its contents into the chat if you want full context injected.${NC}"
        fi
    else
        echo ""
        echo -e "  ${BYEL}  Open WebUI not running. Starting fallback terminal session...${NC}"
        echo ""
        # Fallback: print context to terminal and open ollama directly
        echo -e "  ${DIM}  Context saved to: ${session_file}${NC}"
        echo -e "  ${DIM}  Run: ollama run ${ZMENU_AI_MODEL}${NC}"
        echo -e "  ${DIM}  Then paste context from: ${session_file}${NC}"
    fi
}

# ============================================================
#  SECTION 5 — CHROME: header, pause, confirm, status_bar
# ============================================================

header() {
    clear
    printf '\033[1;34m'
    echo "  ┌─────────────────────────────────────────────────────────┐"
    printf "  │  ▲  Z-MENU  v%-6s  ·  LOCAL SOVEREIGN                │\n" "$ZMENU_VERSION"
    echo "  └─────────────────────────────────────────────────────────┘"
    printf '\033[0m\n'
}

pause() {
    [[ "$ZMENU_HEADLESS" -eq 1 ]] && { echo "  [headless: done]"; return; }
    echo ""; read -rp "  $(printf '%b' "${DIM}[ENTER to return]${NC}") " _
}

confirm() {
    local prompt="$1"
    read -rp "  ${prompt} (y/N): " _c
    [[ "$_c" =~ ^[Yy]$ ]]
}

status_bar() {
    # ── AI Stack ─────────────────────────────────────────
    local _olla _olla_info _lms _cc _cc_info
    if [[ "$D_OLLAMA_RUNNING" == true ]]; then
        _olla=$OK
        _olla_info="${D_OLLAMA_ACTIVE_MODEL:-no model loaded}"
    else
        _olla=$FAIL; _olla_info="stopped"
    fi
    if [[ "$D_LMS_RUNNING" == true ]]; then
        _lms=$OK
    else
        _lms=$IDLE
    fi
    if [[ "$D_AI_RUNNING" == true ]]; then
        _cc=$OK; _cc_info="v${D_AI_VER}  model: ${BCYN}${ZMENU_AI_MODEL}${NC}"
    else
        _cc=$FAIL; _cc_info="not installed"
    fi

    # ── GPU ───────────────────────────────────────────────
    local _gpu _gpu_info
    case "$D_GPU_DRIVER" in
        rocm)      _gpu=$OK;   _gpu_info="${D_GPU_GFX}  ${D_GPU_TEMP}°C  ${D_GPU_USE}% utilisation" ;;
        amdgpu-sysfs) _gpu=$WARN; _gpu_info="${D_GPU_GFX}  ${D_GPU_TEMP}°C  (rocm-smi not in PATH)" ;;
        *)         _gpu=$IDLE; _gpu_info="not detected" ;;
    esac

    # ── NPU ───────────────────────────────────────────────
    local _npu _npu_info
    if [[ -n "$D_NPU_DRIVER" && "$D_NPU_DEVICE" != "not found" ]]; then
        _npu=$OK; _npu_info="${D_NPU_DRIVER}  ${D_NPU_DEVICE}"
    elif [[ -n "$D_NPU_DRIVER" ]]; then
        _npu=$WARN; _npu_info="${D_NPU_DRIVER} loaded, no device node"
    else
        _npu=$IDLE; _npu_info="no NPU driver"
    fi

    # ── Docker / containers ───────────────────────────────
    local _dock _dock_info
    if [[ "$D_DOCKER_RUNNING" == true ]]; then
        _dock=$OK; _dock_info="${#D_CONTAINERS[@]} container(s) running"
    else
        _dock=$FAIL; _dock_info="stopped"
    fi

    # ── System metrics ────────────────────────────────────
    local cpu_pct mem_used mem_total mem_pct disk_pct load1 load5 load15
    cpu_pct=$(top -bn1 2>/dev/null | awk '/^%Cpu/{print $2}' || echo "?")
    read -r mem_total mem_used < <(free -m | awk '/^Mem/{print $2,$3}')
    mem_pct=$(awk "BEGIN{printf \"%.0f\", ${mem_used}/${mem_total}*100}" 2>/dev/null || echo "?")
    disk_pct=$(df -h / | awk 'NR==2{print $5}')
    read -r load1 load5 load15 < <(awk '{print $1,$2,$3}' /proc/loadavg)

    # ── Render ───────────────────────────────────────────
    echo -e "  ${BOLD}${BBLU}┄ STATUS ───────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${BOLD}AI Stack${NC}"
    echo -e "    Ollama      ${_olla}   ${_olla_info}"
    echo -e "    LM Studio   ${_lms}   $([ "$D_LMS_RUNNING" == true ] && echo "${D_LMS_URL}" || echo "${DIM}off (fine — Ollama handles inference)${NC}")"
    echo -e "    Local AI  ${_cc}   ${_cc_info}"
    echo ""
    echo -e "  ${BOLD}Hardware${NC}"
    echo -e "    GPU   ${_gpu}   ${DIM}${_gpu_info}${NC}"
    echo -e "    NPU   ${_npu}   ${DIM}${_npu_info}${NC}"
    echo -e "    Docker ${_dock}  ${DIM}${_dock_info}${NC}"
    echo ""
    echo -e "  ${BOLD}System${NC}"
    echo -e "    CPU ${CYN}${cpu_pct}%${NC}   RAM ${CYN}${mem_used}/${mem_total}MB (${mem_pct}%)${NC}   Disk ${CYN}${disk_pct}${NC}   Load ${CYN}${load1} ${load5} ${load15}${NC}"
    echo -e "    ${DIM}$(date '+%a %d %b %Y  %H:%M:%S')${NC}"
    echo ""
    echo -e "  ${DIM}● green=healthy  ● red=needs attention  ● yellow=warning  ○ grey=idle/off${NC}"
    echo ""
}

# ============================================================
#  SECTION 6 — MODULES
#  Pattern for every module:
#    mod_NAME() { while true; do header; ...; read choice; case...; done; }
#  Every module has an "ask AI" option.
# ============================================================

# ── 1: System Health ───────────────────────────────────────
mod_system_health() {
    while true; do
        header
        echo -e "${BCYN}┄ SYSTEM HEALTH ────────────────────────────────────────${NC}"
        echo ""
        echo "   a)  Full resource audit     (CPU · RAM · Disk · Swap)"
        echo "   b)  Live process monitor    (htop / top)"
        echo "   c)  Thermal dashboard       (CPU · GPU · battery)"
        echo "   d)  Hardware profile        (CPU · RAM · PCIe · NVMe)"
        echo "   e)  Power & battery         (TDP · profiles · uptime)"
        echo ""
        echo "   C)  ✦ Ask AI about this system"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _sys_resources; pause ;;
            b) htop 2>/dev/null || top ;;
            c) _sys_thermal; pause ;;
            d) _sys_hardware; pause ;;
            e) _sys_power; pause ;;
            C) cc_launch "System Health Expert" \
                "You are a system health expert. Review the context and:
1. Flag any RAM, CPU, swap, or disk concerns
2. Check if GPU utilisation looks right
3. Note any services that look unhealthy
Be specific and actionable."; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_sys_resources() {
    header
    echo -e "${BCYN}┄ CPU${NC}"
    lscpu | grep -E "Model name|Core|Thread|MHz|cache" | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ MEMORY${NC}"
    free -h | sed 's/^/  /'
    local sw_total sw_used
    read -r sw_total sw_used < <(free -m | awk '/^Swap/{print $2,$3}')
    if [[ "$sw_total" -gt 0 ]]; then
        local pct; pct=$(awk "BEGIN{printf \"%.0f\", ${sw_used}/${sw_total}*100}")
        [[ "$pct" -gt 60 ]] \
            && echo -e "  ${BYEL}⚠  Swap ${pct}% full${NC}" \
            || echo -e "  ${BGRN}✓  Swap healthy: ${pct}%${NC}"
    fi
    echo ""
    echo -e "${BCYN}┄ DISK${NC}"
    df -hT | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ TOP PROCESSES BY CPU${NC}"
    ps -eo pid,user:12,cmd:35,%cpu,%mem --sort=-%cpu | head -11 | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ TOP PROCESSES BY RAM${NC}"
    ps -eo pid,user:12,cmd:35,%cpu,%mem --sort=-%mem | head -11 | sed 's/^/  /'
}

_sys_thermal() {
    header
    echo -e "${BCYN}┄ THERMAL SENSORS${NC}"
    if command -v sensors >/dev/null 2>&1; then
        sensors 2>/dev/null | sed 's/^/  /'
    else
        echo -e "  ${BYEL}lm-sensors not installed: sudo apt install lm-sensors${NC}"
    fi
    echo ""
    echo -e "${BCYN}┄ GPU THERMAL (sysfs)${NC}"
    for d in /sys/class/hwmon/hwmon*; do
        local name; name=$(cat "$d/name" 2>/dev/null || echo "")
        if [[ "$name" == *amdgpu* || "$name" == *amd* ]]; then
            echo "  ${name}:"
            for f in "$d"/temp*_input; do
                [[ -f "$f" ]] && awk '{printf "    %.1f °C\n", $1/1000}' "$f"
            done
        fi
    done
    echo ""
    echo -e "${BCYN}┄ BATTERY${NC}"
    local bat; bat=$(find /sys/class/power_supply -name "BAT*" 2>/dev/null | head -1)
    if [[ -n "$bat" ]]; then
        echo "  Status:   $(cat "${bat}/status" 2>/dev/null || echo "N/A")"
        echo "  Capacity: $(cat "${bat}/capacity" 2>/dev/null || echo "N/A")%"
    else
        echo "  No battery found"
    fi
}

_sys_hardware() {
    header
    echo -e "${BCYN}┄ CPU${NC}"
    lscpu | grep -E "Model name|Architecture|Core|Thread|Socket|cache|Vendor" | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ MEMORY MODULES${NC}"
    if command -v dmidecode >/dev/null 2>&1; then
        sudo dmidecode --type 17 2>/dev/null \
            | grep -E "Size|Speed|Type:|Manufacturer|Part|Locator|Configured" \
            | grep -v "No Module" | sed 's/^/  /'
    else
        echo "  sudo apt install dmidecode"
    fi
    echo ""
    echo -e "${BCYN}┄ STORAGE${NC}"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ PCIe DEVICES${NC}"
    lspci 2>/dev/null | grep -iE "VGA|3D|Display|NVMe|USB|Audio|Network|Wireless" | sed 's/^/  /'
}

_sys_power() {
    header
    echo -e "${BCYN}┄ POWER PROFILE${NC}"
    if command -v powerprofilesctl >/dev/null 2>&1; then
        echo "  Active: $(powerprofilesctl get 2>/dev/null)"
        echo ""
        powerprofilesctl list 2>/dev/null | sed 's/^/  /'
    else
        echo "  sudo apt install power-profiles-daemon"
    fi
    echo ""
    echo -e "${BCYN}┄ CPU FREQUENCY${NC}"
    cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null \
        | awk '{printf "  Core %-3d  %5.0f MHz\n", NR-1, $1/1000}' | head -24
    echo ""
    echo -e "${BCYN}┄ UPTIME${NC}"
    uptime -p | sed 's/^/  /'
}

# ── 2: AI Stack ────────────────────────────────────────────
mod_ai_stack() {
    while true; do
        header
        echo -e "${BCYN}┄ AI STACK ─────────────────────────────────────────────${NC}"
        echo ""

        # Ollama quick status
        local olla_label
        $D_OLLAMA_RUNNING \
            && olla_label="${OK} ${D_OLLAMA_URL}  model: ${BCYN}${D_OLLAMA_ACTIVE_MODEL:-none}${NC}" \
            || olla_label="${FAIL} stopped"
        echo -e "  Ollama      ${olla_label}"

        local lms_label
        $D_LMS_RUNNING \
            && lms_label="${OK} ${D_LMS_URL}" \
            || lms_label="${IDLE} off (fine)"
        echo -e "  LM Studio   ${lms_label}"

        local cc_label
        $D_AI_RUNNING \
            && cc_label="${OK} v${D_AI_VER}  active model: ${BCYN}${ZMENU_AI_MODEL}${NC}" \
            || cc_label="${FAIL} not installed"
        echo -e "  Local AI  ${cc_label}"
        echo ""

        echo "   a)  Ollama details        (models · active · GPU)"
        echo "   b)  Test inference        (send ping to active model)"
        echo "   c)  Switch active model   (choose from discovered list)"
        echo "   d)  LM Studio details     (models on disk · start/stop)"
        echo "   e)  AI session   (general session)"
        echo ""
        echo "   C)  ✦ Ask AI to diagnose the AI stack"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _ai_ollama; pause ;;
            b) _ai_test_inference; pause ;;
            c) _ai_switch_model ;;
            d) _ai_lms; pause ;;
            e) cc_launch "AI Stack Assistant" \
                "You are an expert on this local AI stack. Review the context and tell me the current state of all AI services, what's working, what could be improved."; pause ;;
            C) cc_launch "AI Stack Diagnostics" \
                "Diagnose the AI stack. Check: Ollama health, model capabilities (which have tool-calling), GPU utilisation, LM Studio status. List any issues and fixes."; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_ai_ollama() {
    header
    echo -e "${BCYN}┄ OLLAMA STATUS${NC}"
    if [[ "$D_OLLAMA_RUNNING" == false ]]; then
        echo -e "  ${FAIL}  Ollama not running"
        echo "  Start: sudo systemctl start ollama"
        return
    fi
    echo -e "  ${OK}  Running at ${D_OLLAMA_URL}"
    echo ""
    echo -e "${BCYN}┄ ACTIVE MODEL${NC}"
    if [[ -n "$D_OLLAMA_ACTIVE_MODEL" ]]; then
        echo -e "  ${OK}  ${D_OLLAMA_ACTIVE_MODEL}"
    else
        echo -e "  ${IDLE}  No model loaded (will load on first request)"
    fi
    echo ""
    echo -e "${BCYN}┄ ALL MODELS${NC}"
    printf "  %-30s  %-10s  %s\n" "NAME" "SIZE" "TOOLS"
    echo "  ──────────────────────────────────────────────────"
    for m in "${D_OLLAMA_MODELS[@]}"; do
        local sz; sz=$(ollama list 2>/dev/null | awk -v n="$m" '$1==n{print $3,$4}')
        local tools="no"
        for tm in "${D_OLLAMA_TOOL_MODELS[@]}"; do [[ "$tm" == "$m" ]] && tools="${BGRN}yes${NC}"; done
        printf "  %-30s  %-10s  %b\n" "$m" "$sz" "$tools"
    done
    echo ""
    echo -e "${BCYN}┄ GPU${NC}"
    if [[ "$D_GPU_DRIVER" == "rocm" ]]; then
        rocm-smi 2>/dev/null | grep -v "^=\|^$" | head -8 | sed 's/^/  /'
    else
        echo "  GPU driver: ${D_GPU_DRIVER:-none}"
        [[ -n "$D_GPU_TEMP" ]] && echo "  Temp: ${D_GPU_TEMP}°C"
    fi
}

_ai_test_inference() {
    header
    echo -e "${BCYN}┄ INFERENCE TEST${NC}"
    if [[ -z "$ZMENU_AI_MODEL" || "$ZMENU_AI_MODEL" == "no-models-found" ]]; then
        echo -e "  ${FAIL}  No model available"
        return
    fi
    echo "  Sending test prompt to: ${ZMENU_AI_MODEL}"
    echo "  (GPU utilisation should spike during inference)"
    echo ""
    local response
    response=$(HSA_OVERRIDE_GFX_VERSION="${D_GPU_GFX#gfx}" \
        ollama run "$ZMENU_AI_MODEL" "Reply with exactly one word: ONLINE" 2>&1)
    if echo "$response" | grep -qi "online"; then
        echo -e "  ${OK}  Model responded: ${response}"
        echo -e "  ${OK}  ROCm GPU inference confirmed"
    else
        echo -e "  ${WARN}  Response: ${response}"
    fi
}

_ai_switch_model() {
    header
    echo -e "${BCYN}┄ SWITCH ACTIVE MODEL${NC}"
    echo ""
    if [[ ${#D_OLLAMA_MODELS[@]} -eq 0 ]]; then
        echo -e "  ${FAIL}  No models available"
        pause; return
    fi
    local i=1
    for m in "${D_OLLAMA_MODELS[@]}"; do
        local tools=""
        for tm in "${D_OLLAMA_TOOL_MODELS[@]}"; do
            [[ "$tm" == "$m" ]] && tools=" ${BGRN}[tools]${NC}"
        done
        [[ "$m" == "$ZMENU_AI_MODEL" ]] \
            && echo -e "   ${i})  ${BOLD}${m}${NC}${tools} ${DIM}← current${NC}" \
            || echo -e "   ${i})  ${m}${tools}"
        ((i++))
    done
    echo ""
    read -rp "  Select number: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#D_OLLAMA_MODELS[@]} ]]; then
        ZMENU_AI_MODEL="${D_OLLAMA_MODELS[$((n-1))]}"
        # Persist to config
        if grep -q "ZMENU_AI_MODEL" "$ZMENU_CONFIG_FILE"; then
            sed -i "s|^ZMENU_AI_MODEL=.*|ZMENU_AI_MODEL=\"${ZMENU_AI_MODEL}\"|" \
                "$ZMENU_CONFIG_FILE"
        else
            echo "ZMENU_AI_MODEL=\"${ZMENU_AI_MODEL}\"" >> "$ZMENU_CONFIG_FILE"
        fi
        echo -e "  ${OK}  Active model set to: ${ZMENU_AI_MODEL}"
    fi
    pause
}

_ai_lms() {
    header
    echo -e "${BCYN}┄ LM STUDIO${NC}"
    if [[ "$D_LMS_RUNNING" == true ]]; then
        echo -e "  ${OK}  Running at ${D_LMS_URL}"
        echo -e "  ${BYEL}ℹ  Ollama handles inference — you can stop LM Studio${NC}"
        echo ""
        echo "  Models visible:"
        for m in "${D_LMS_MODELS[@]}"; do echo "  · $m"; done
    else
        echo -e "  ${IDLE}  Stopped — this is fine"
        echo "  Start to browse/download models: lms server start"
        echo "  Or open the LM Studio GUI app"
    fi
    echo ""
    echo -e "${BCYN}┄ GGUF FILES ON DISK${NC}"
    local lms_dir="${HOME}/.lmstudio/models"
    if [[ -d "$lms_dir" ]]; then
        find "$lms_dir" -name "*.gguf" 2>/dev/null | while read -r f; do
            printf "  %-50s  %s\n" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)"
        done
    else
        echo "  ${lms_dir} not found"
    fi
}

# ── 3: Docker & Services ───────────────────────────────────
mod_docker() {
    while true; do
        header
        echo -e "${BCYN}┄ DOCKER & SERVICES ────────────────────────────────────${NC}"
        echo ""
        if [[ "$D_DOCKER_RUNNING" == true ]]; then
            echo -e "  ${OK}  Docker running  (${DOCKER_HOST})"
            echo ""
            docker ps --format "  {{.Names}}: {{.Status}} · {{.Ports}}" 2>/dev/null \
                || echo "  no containers"
        else
            echo -e "  ${FAIL}  Docker not running"
        fi
        echo ""
        echo "   a)  Container list         (status · resources)"
        echo "   b)  Container logs         (select container)"
        echo "   c)  System prune           (clean stopped/unused)"
        echo "   d)  Start a service        (n8n · SearXNG · Crawl4AI)"
        echo "   e)  Stop a container"
        echo "   f)  Restart a container"
        echo ""
        echo "   C)  ✦ Ask AI about containers"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _docker_list; pause ;;
            b) _docker_logs ;;
            c) _docker_prune ;;
            d) _docker_start ;;
            e) _docker_stop ;;
            f) _docker_restart ;;
            C) cc_launch "Docker Expert" \
                "Review the container state in the context. Identify any unhealthy containers, resource issues, or misconfigurations."; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_docker_list() {
    header
    echo -e "${BCYN}┄ RUNNING CONTAINERS${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null \
        | sed 's/^/  /' || echo "  None"
    echo ""
    echo -e "${BCYN}┄ RESOURCE USAGE${NC}"
    docker stats --no-stream --format \
        "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null \
        | sed 's/^/  /' || echo "  None"
    echo ""
    echo -e "${BCYN}┄ IMAGES${NC}"
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null \
        | sed 's/^/  /' | head -20
}

_docker_logs() {
    header
    echo -e "${BCYN}┄ CONTAINER LOGS${NC}"
    echo ""
    if [[ ${#D_CONTAINERS[@]} -eq 0 ]]; then
        echo "  No running containers"; pause; return
    fi
    local i=1
    for c in "${D_CONTAINERS[@]}"; do
        echo "   ${i})  ${c%%:*}"
        ((i++))
    done
    echo ""
    read -rp "  Select container: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -le ${#D_CONTAINERS[@]} ]]; then
        local name="${D_CONTAINERS[$((n-1))]%%:*}"
        header
        echo -e "${BCYN}┄ LOGS: ${name}${NC}"
        docker logs --tail 50 --timestamps "$name" 2>&1 | sed 's/^/  /'
    fi
    pause
}

_docker_prune() {
    header
    echo -e "${BRED}┄ DOCKER PRUNE${NC}"
    docker system df 2>/dev/null | sed 's/^/  /'
    echo ""
    if confirm "Prune stopped containers, unused networks, dangling images?"; then
        docker system prune -f 2>/dev/null | sed 's/^/  /'
        echo -e "  ${OK}  Done"
    fi
    pause
}

_docker_start() {
    header
    echo -e "${BCYN}┄ START SERVICES${NC}"
    echo ""
    echo "   1)  n8n          (workflow automation · :5678)"
    echo "   2)  SearXNG      (private web search · :8080)"
    echo "   3)  Crawl4AI     (web scraping · :11235)"
    echo ""
    read -rp "  Select: " n
    local name url image vol port
    case $n in
        1) name=n8n;      port=5678;  image=n8nio/n8n;               vol="-v n8n_data:/home/node/.n8n" ;;
        2) name=searxng;  port=8080;  image=searxng/searxng;          vol="" ;;
        3) name=crawl4ai; port=11235; image=unclecode/crawl4ai:latest; vol="" ;;
        4) name=open-webui; port=3000; image=ghcr.io/open-webui/open-webui:main
           docker run -d --name open-webui --restart unless-stopped \
               -p 127.0.0.1:3000:8080 \
               --add-host=host.docker.internal:host-gateway \
               -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
               -v open-webui:/app/backend/data \
               ghcr.io/open-webui/open-webui:main 2>/dev/null \
               && echo -e "  ${OK}  Open WebUI started → http://localhost:3000" \
               || echo -e "  ${WARN}  Already running or image missing"
           pause; continue ;;
        *) echo -e "${RED}  Invalid.${NC}"; sleep 1; return ;;
    esac
    echo ""
    # shellcheck disable=SC2086
    docker run -d --name "$name" --restart unless-stopped \
        -p "127.0.0.1:${port}:${port}" $vol "$image" 2>/dev/null \
        && echo -e "  ${OK}  ${name} started on 127.0.0.1:${port}" \
        || echo -e "  ${WARN}  Already running or image missing"
    pause
}

# ── 4: Security & Network ──────────────────────────────────
mod_security() {
    while true; do
        header
        echo -e "${BCYN}┄ SECURITY & NETWORK ───────────────────────────────────${NC}"
        echo ""
        echo "   a)  Open ports audit       (all listening services)"
        echo "   b)  Firewall status        (UFW + DOCKER-USER chain)"
        echo "   c)  Failed login audit     (top IPs · recent events)"
        echo "   d)  Sudo/auth events       (last 48h)"
        echo "   e)  Rootkit quick check    (rkhunter · chkrootkit)"
        echo "   f)  Outbound connections   (non-loopback)"
        echo ""
        echo -e "   ${BCYN}┄ Privacy & Telemetry${NC}"
        echo "   g)  Live traffic monitor   (nethogs — see what phones home)"
        echo "   h)  Telemetry status       (check all opt-out vars)"
        echo "   i)  Browser privacy        (Chromium + Firefox)"
        echo "   j)  Tailscale              (status · stop · disable)"
        echo "   k)  Service audit          (Ollama · Docker · snap · apt)"
        echo "   l)  Apply privacy lockdown (guided or one-shot)"
        echo ""
        echo "   C)  ✦ Ask AI to audit security & privacy posture"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _sec_ports; pause ;;
            b) _sec_firewall; pause ;;
            c) _sec_failed_logins; pause ;;
            d) _sec_sudo; pause ;;
            e) _sec_rootkit; pause ;;
            f) _sec_outbound; pause ;;
            g) _priv_traffic ;;
            h) _priv_telemetry_status; pause ;;
            i) _priv_browser ;;
            j) _priv_tailscale ;;
            k) _priv_service_audit; pause ;;
            l) _priv_lockdown ;;
            C) cc_launch "Security & Privacy Auditor" \
                "Perform a full security and privacy audit from the context. Check: open ports, UFW rules, DOCKER-USER chain, anomalous outbound connections, telemetry opt-out variables, and any services phoning home. Be specific about risks and fixes."; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_sec_ports() {
    header
    echo -e "${BCYN}┄ LISTENING PORTS${NC}"
    ss -tlunp 2>/dev/null | sed 's/^/  /'
}

_sec_firewall() {
    header
    echo -e "${BCYN}┄ UFW${NC}"
    sudo ufw status verbose 2>/dev/null | sed 's/^/  /' \
        || echo "  ufw not installed"
    echo ""
    echo -e "${BCYN}┄ DOCKER-USER CHAIN${NC}"
    local rules; rules=$(sudo iptables -L DOCKER-USER --line-numbers -n 2>/dev/null)
    if echo "$rules" | grep -q "DROP"; then
        echo -e "  ${OK}  DOCKER-USER active — UFW bypass protected"
    else
        echo -e "  ${FAIL}  DOCKER-USER missing — containers may bypass UFW"
    fi
    echo "$rules" | sed 's/^/  /'
}

_sec_failed_logins() {
    header
    echo -e "${BCYN}┄ FAILED LOGINS${NC}"
    local logfile=""
    for f in /var/log/auth.log /var/log/secure; do
        [[ -f "$f" ]] && logfile="$f" && break
    done
    if [[ -n "$logfile" ]]; then
        echo "  Source: $logfile"
        echo ""
        echo "  Top offending IPs:"
        sudo grep -i "failed\|invalid\|authentication failure" "$logfile" 2>/dev/null \
            | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
            | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
        echo ""
        echo "  Last 20 events:"
        sudo grep -i "failed\|invalid\|authentication failure" "$logfile" 2>/dev/null \
            | tail -20 | sed 's/^/    /'
    else
        sudo journalctl -u ssh --since "7 days ago" 2>/dev/null \
            | grep -i "fail\|invalid" | tail -20 | sed 's/^/  /'
    fi
}

_sec_sudo() {
    header
    echo -e "${BCYN}┄ SUDO / AUTH EVENTS (last 48h)${NC}"
    sudo journalctl _COMM=sudo --since "48 hours ago" 2>/dev/null \
        | tail -40 | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ LAST LOGINS${NC}"
    last -n 15 2>/dev/null | sed 's/^/  /'
}

_sec_rootkit() {
    header
    echo -e "${BCYN}┄ ROOTKIT SCAN${NC}"
    if command -v rkhunter >/dev/null 2>&1; then
        sudo rkhunter --check --skip-keypress --report-warnings-only 2>&1 | sed 's/^/  /'
    else
        echo "  rkhunter not installed: sudo apt install rkhunter"
    fi
    echo ""
    if command -v chkrootkit >/dev/null 2>&1; then
        sudo chkrootkit 2>&1 | grep -v "not found\|not tested" | sed 's/^/  /' | head -40
    else
        echo "  chkrootkit not installed: sudo apt install chkrootkit"
    fi
    echo ""
    echo -e "${BCYN}┄ UNUSUAL SUID BINARIES${NC}"
    sudo find / -perm /4000 2>/dev/null \
        | grep -vE "^/usr/bin|^/usr/sbin|^/bin|^/sbin|^/usr/lib|^/snap" \
        | head -20 | sed 's/^/    /' \
        || echo "  None outside standard paths"
}

_sec_outbound() {
    header
    echo -e "${BCYN}┄ OUTBOUND CONNECTIONS (non-loopback)${NC}"
    ss -tnp 2>/dev/null \
        | awk 'NR>1 && $5 !~ /127\.|::1|\*/' \
        | sed 's/^/  /' | head -30
}


# ── Privacy & Telemetry functions ──────────────────────────

_priv_traffic() {
    header
    echo -e "${BCYN}┄ LIVE TRAFFIC MONITOR${NC}"
    echo ""
    if ! command -v nethogs >/dev/null 2>&1; then
        echo -e "  ${WARN}  nethogs not installed"
        echo ""
        if confirm "Install nethogs now?"; then
            sudo apt install nethogs -y
        else
            pause; return
        fi
    fi
    echo "  Launching nethogs — press q to quit..."
    sleep 1
    sudo nethogs 2>/dev/null || echo -e "  ${FAIL}  nethogs failed to start"
    pause
}

_priv_telemetry_status() {
    header
    echo -e "${BCYN}┄ TELEMETRY OPT-OUT STATUS${NC}"
    echo ""
    local all_ok=true
    local vars=(
        "DO_NOT_TRACK:1"
        "TELEMETRY_DISABLED:1"
        "DISABLE_TELEMETRY:1"
        "DOTNET_CLI_TELEMETRY_OPTOUT:1"
        "NEXT_TELEMETRY_DISABLED:1"
        "HOMEBREW_NO_ANALYTICS:1"
        "SAM_CLI_TELEMETRY:0"
        "SCARF_ANALYTICS:false"
    )
    for entry in "${vars[@]}"; do
        local var="${entry%%:*}"
        local expected="${entry##*:}"
        local current; current=$(printenv "$var" 2>/dev/null || echo "NOT SET")
        if [[ "$current" == "$expected" ]]; then
            echo -e "  ${OK}  ${var}=${current}"
        else
            echo -e "  ${FAIL}  ${var}=${current}  ${DIM}(should be ${expected})${NC}"
            all_ok=false
        fi
    done
    echo ""
    if [[ "$all_ok" == false ]]; then
        echo -e "  ${WARN}  Some variables missing. Run option l) to apply lockdown."
    else
        echo -e "  ${OK}  All telemetry opt-out variables set"
    fi
}

_priv_browser() {
    while true; do
        header
        echo -e "${BCYN}┄ BROWSER PRIVACY${NC}"
        echo ""
        echo "   a)  Chromium — apply privacy flags"
        echo "   b)  Chromium — check current flags"
        echo "   c)  Firefox  — disable telemetry"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _priv_chromium_apply; pause ;;
            b) _priv_chromium_check; pause ;;
            c) _priv_firefox; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_priv_chromium_apply() {
    header
    echo -e "${BCYN}┄ CHROMIUM PRIVACY FLAGS${NC}"
    echo ""
    local flags_file="${HOME}/.config/chromium-flags.conf"
    cat > "$flags_file" << 'FLAGSEOF'
--disable-background-networking
--disable-client-side-phishing-detection
--disable-sync
--disable-translate
--no-first-run
--disable-metrics-reporting
--disable-crash-reporter
--disable-features=ChromeWhatsNewUI
FLAGSEOF
    echo -e "  ${OK}  Privacy flags written to: ${flags_file}"
    echo ""
    echo "  Flags applied:"
    cat "$flags_file" | sed 's/^/    /'
    echo ""
    echo -e "  ${DIM}  Restart Chromium for changes to take effect${NC}"
    echo ""
    echo -e "  ${BCYN}  Also do manually in Chromium settings:${NC}"
    echo "  Settings → Privacy → uncheck 'Help improve Chromium'"
    echo "  Settings → Privacy → uncheck 'Send usage statistics'"
    echo "  Settings → Sync   → turn off sync entirely"
}

_priv_chromium_check() {
    header
    echo -e "${BCYN}┄ CHROMIUM FLAGS CHECK${NC}"
    echo ""
    local flags_file="${HOME}/.config/chromium-flags.conf"
    if [[ -f "$flags_file" ]]; then
        echo -e "  ${OK}  Flags file exists: ${flags_file}"
        echo ""
        cat "$flags_file" | sed 's/^/    /'
    else
        echo -e "  ${WARN}  No flags file found at ${flags_file}"
        echo "  Run option a) to create it"
    fi
    echo ""
    echo -e "  ${BCYN}┄ Running Chromium processes${NC}"
    ps aux | grep -i chromium | grep -v grep | sed 's/^/  /' | head -5
}

_priv_firefox() {
    header
    echo -e "${BCYN}┄ FIREFOX TELEMETRY${NC}"
    echo ""
    local prefs
    prefs=$(find "${HOME}/.mozilla/firefox" -name "prefs.js" 2>/dev/null | head -1)
    if [[ -z "$prefs" ]]; then
        echo -e "  ${WARN}  Firefox profile not found — is Firefox installed?"
        pause; return
    fi
    echo "  Profile: $prefs"
    echo ""
    # Check current state
    local settings=(
        "toolkit.telemetry.enabled"
        "toolkit.telemetry.unified"
        "datareporting.healthreport.uploadEnabled"
        "app.shield.optoutstudies.enabled"
    )
    for s in "${settings[@]}"; do
        if grep -q "$s" "$prefs" 2>/dev/null; then
            local val; val=$(grep "$s" "$prefs" | grep -o 'true\|false')
            if [[ "$val" == "false" ]]; then
                echo -e "  ${OK}  ${s} = false"
            else
                echo -e "  ${WARN}  ${s} = ${val}  (should be false)"
            fi
        else
            echo -e "  ${IDLE}  ${s} = not set (using default)"
        fi
    done
    echo ""
    if confirm "Apply telemetry opt-out to Firefox prefs.js?"; then
        # Close Firefox first warning
        echo -e "  ${BYEL}  Note: Firefox must be closed for changes to take effect${NC}"
        echo ""
        local tmpfile; tmpfile=$(mktemp)
        grep -v "toolkit.telemetry\|datareporting\|app.shield" "$prefs" > "$tmpfile"
        cat >> "$tmpfile" << 'FFEOF'
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
FFEOF
        cp "$prefs" "${prefs}.bak"
        mv "$tmpfile" "$prefs"
        echo -e "  ${OK}  Applied. Backup saved to ${prefs}.bak"
    fi
}

_priv_tailscale() {
    header
    echo -e "${BCYN}┄ TAILSCALE${NC}"
    echo ""
    if ! command -v tailscale >/dev/null 2>&1; then
        echo -e "  ${IDLE}  Tailscale not installed"
        pause; return
    fi
    local ts_status; ts_status=$(tailscale status 2>/dev/null || echo "not running")
    local ts_active; ts_active=$(systemctl is-active tailscaled 2>/dev/null)
    local ts_enabled; ts_enabled=$(systemctl is-enabled tailscaled 2>/dev/null)
    echo -e "  Service:  ${ts_active}"
    echo -e "  Autostart: ${ts_enabled}"
    echo ""
    echo "$ts_status" | sed 's/^/  /' | head -10
    echo ""
    echo "   a)  Stop Tailscale now"
    echo "   b)  Disable autostart  (won't start on boot)"
    echo "   c)  Stop + disable     (both)"
    echo "   d)  Start Tailscale"
    echo "   r)  Return"
    echo ""
    read -rp "  Selection: " ch
    case $ch in
        a) sudo systemctl stop tailscaled && echo -e "  ${OK}  Stopped" || echo -e "  ${FAIL}  Failed"; pause ;;
        b) sudo systemctl disable tailscaled && echo -e "  ${OK}  Disabled autostart" || echo -e "  ${FAIL}  Failed"; pause ;;
        c) sudo systemctl stop tailscaled && sudo systemctl disable tailscaled \
               && echo -e "  ${OK}  Stopped and disabled" || echo -e "  ${FAIL}  Failed"; pause ;;
        d) sudo systemctl start tailscaled && echo -e "  ${OK}  Started" || echo -e "  ${FAIL}  Failed"; pause ;;
    esac
}

_priv_service_audit() {
    header
    echo -e "${BCYN}┄ SERVICE PHONE-HOME AUDIT${NC}"
    echo ""

    # Ollama
    echo -e "${BCYN}  Ollama${NC}"
    local ollama_override="/etc/systemd/system/ollama.service.d/override.conf"
    if [[ -f "$ollama_override" ]] && grep -q "DO_NOT_TRACK" "$ollama_override"; then
        echo -e "  ${OK}  Telemetry override present"
    else
        echo -e "  ${WARN}  No telemetry override — run option l) to apply"
    fi
    echo ""

    # Docker
    echo -e "${BCYN}  Docker${NC}"
    if [[ -f "/etc/docker/daemon.json" ]]; then
        echo -e "  ${OK}  daemon.json present:"
        cat /etc/docker/daemon.json | sed 's/^/    /'
    else
        echo -e "  ${IDLE}  No daemon.json — using defaults"
    fi
    echo ""

    # Snap
    echo -e "${BCYN}  Snap${NC}"
    local snap_metrics; snap_metrics=$(snap get system metrics.enable 2>/dev/null || echo "unknown")
    if [[ "$snap_metrics" == "false" ]]; then
        echo -e "  ${OK}  Snap metrics disabled"
    else
        echo -e "  ${WARN}  Snap metrics: ${snap_metrics}"
        echo "  Disable: sudo snap set system metrics.enable=false"
    fi
    echo ""

    # APT
    echo -e "${BCYN}  APT${NC}"
    if [[ -f "/etc/apt/apt.conf.d/20packagekit" ]]; then
        echo -e "  ${IDLE}  PackageKit present (background update checks)"
    else
        echo -e "  ${OK}  No PackageKit background checker"
    fi
    echo ""

    # Outbound right now
    echo -e "${BCYN}  Current outbound connections${NC}"
    ss -tnp 2>/dev/null | awk 'NR>1 && $5 !~ /127\.|::1|\*/' | sed 's/^/  /' | head -15
    [[ -z "$(ss -tnp 2>/dev/null | awk 'NR>1 && $5 !~ /127\.|::1|\*/')" ]] && \
        echo -e "  ${OK}  No external connections detected"
}

_priv_lockdown() {
    header
    echo -e "${BCYN}┄ PRIVACY LOCKDOWN${NC}"
    echo ""
    echo "  Choose how to proceed:"
    echo ""
    echo "   a)  Guided  — step through each item with confirm prompts"
    echo "   b)  One-shot — apply everything automatically"
    echo "   r)  Return"
    echo ""
    read -rp "  Selection: " ch
    case $ch in
        a) _priv_lockdown_guided ;;
        b) _priv_lockdown_oneshot ;;
    esac
}

_priv_lockdown_guided() {
    header
    echo -e "${BCYN}┄ GUIDED PRIVACY LOCKDOWN${NC}"
    echo ""

    # Step 1 — env vars
    echo -e "${BOLD}  Step 1: Telemetry opt-out environment variables${NC}"
    echo ""
    if confirm "Add telemetry opt-out vars to ~/.bashrc?"; then
        _priv_apply_env_vars
        echo -e "  ${OK}  Done"
    else
        echo -e "  ${DIM}  Skipped${NC}"
    fi
    echo ""

    # Step 2 — Ollama override
    echo -e "${BOLD}  Step 2: Ollama systemd telemetry override${NC}"
    echo ""
    if confirm "Create Ollama telemetry override?"; then
        _priv_apply_ollama_override
        echo -e "  ${OK}  Done"
    else
        echo -e "  ${DIM}  Skipped${NC}"
    fi
    echo ""

    # Step 3 — Snap
    echo -e "${BOLD}  Step 3: Disable Snap metrics${NC}"
    echo ""
    if confirm "Disable Snap usage metrics?"; then
        sudo snap set system metrics.enable=false 2>/dev/null \
            && echo -e "  ${OK}  Done" || echo -e "  ${WARN}  Failed (snap may not be installed)"
    else
        echo -e "  ${DIM}  Skipped${NC}"
    fi
    echo ""

    # Step 4 — Tailscale
    echo -e "${BOLD}  Step 4: Tailscale${NC}"
    echo ""
    if command -v tailscale >/dev/null 2>&1; then
        if confirm "Stop and disable Tailscale autostart?"; then
            sudo systemctl stop tailscaled 2>/dev/null
            sudo systemctl disable tailscaled 2>/dev/null
            echo -e "  ${OK}  Done"
        else
            echo -e "  ${DIM}  Skipped${NC}"
        fi
    else
        echo -e "  ${IDLE}  Tailscale not installed — skipping"
    fi
    echo ""

    # Step 5 — Chromium
    echo -e "${BOLD}  Step 5: Chromium privacy flags${NC}"
    echo ""
    if confirm "Apply Chromium privacy flags?"; then
        _priv_chromium_apply
    else
        echo -e "  ${DIM}  Skipped${NC}"
    fi
    echo ""

    echo -e "  ${OK}  Guided lockdown complete"
    echo -e "  ${DIM}  Run: source ~/.bashrc to activate env vars${NC}"
    pause
}

_priv_lockdown_oneshot() {
    header
    echo -e "${BCYN}┄ ONE-SHOT PRIVACY LOCKDOWN${NC}"
    echo ""
    echo -e "  ${BYEL}  This will apply ALL privacy settings automatically.${NC}"
    echo ""
    if ! confirm "Apply everything now?"; then
        return
    fi
    echo ""

    echo "  [1/5] Telemetry env vars..."
    _priv_apply_env_vars && echo -e "  ${OK}  Done" || echo -e "  ${WARN}  Partial"

    echo "  [2/5] Ollama override..."
    _priv_apply_ollama_override && echo -e "  ${OK}  Done" || echo -e "  ${WARN}  Failed"

    echo "  [3/5] Snap metrics..."
    sudo snap set system metrics.enable=false 2>/dev/null \
        && echo -e "  ${OK}  Done" || echo -e "  ${IDLE}  Snap not found"

    echo "  [4/5] Tailscale..."
    if command -v tailscale >/dev/null 2>&1; then
        sudo systemctl stop tailscaled 2>/dev/null
        sudo systemctl disable tailscaled 2>/dev/null
        echo -e "  ${OK}  Stopped and disabled"
    else
        echo -e "  ${IDLE}  Not installed"
    fi

    echo "  [5/5] Chromium flags..."
    _priv_chromium_apply >/dev/null 2>&1 && echo -e "  ${OK}  Done"

    echo ""
    echo -e "  ${OK}  One-shot lockdown complete"
    echo -e "  ${DIM}  Run: source ~/.bashrc  to activate env vars${NC}"
    echo -e "  ${DIM}  Restart Chromium for browser flags to take effect${NC}"
    pause
}

_priv_apply_env_vars() {
    # Remove existing block if present, then append fresh
    if grep -q "DO_NOT_TRACK" ~/.bashrc; then
        sed -i '/DO_NOT_TRACK/d' ~/.bashrc
        sed -i '/TELEMETRY_DISABLED/d' ~/.bashrc
        sed -i '/DISABLE_TELEMETRY/d' ~/.bashrc
        sed -i '/DOTNET_CLI_TELEMETRY/d' ~/.bashrc
        sed -i '/NEXT_TELEMETRY/d' ~/.bashrc
        sed -i '/GATSBY_TELEMETRY/d' ~/.bashrc
        sed -i '/NUXT_TELEMETRY/d' ~/.bashrc
        sed -i '/ASTRO_TELEMETRY/d' ~/.bashrc
        sed -i '/HOMEBREW_NO_ANALYTICS/d' ~/.bashrc
        sed -i '/SAM_CLI_TELEMETRY/d' ~/.bashrc
        sed -i '/SCARF_ANALYTICS/d' ~/.bashrc
        sed -i '/Privacy.*Zero Telemetry/d' ~/.bashrc
    fi
    printf '\n# Privacy / Zero Telemetry\n' >> ~/.bashrc
    printf 'export DO_NOT_TRACK=1\n' >> ~/.bashrc
    printf 'export TELEMETRY_DISABLED=1\n' >> ~/.bashrc
    printf 'export DISABLE_TELEMETRY=1\n' >> ~/.bashrc
    printf 'export DOTNET_CLI_TELEMETRY_OPTOUT=1\n' >> ~/.bashrc
    printf 'export NEXT_TELEMETRY_DISABLED=1\n' >> ~/.bashrc
    printf 'export GATSBY_TELEMETRY_DISABLED=1\n' >> ~/.bashrc
    printf 'export NUXT_TELEMETRY_DISABLED=1\n' >> ~/.bashrc
    printf 'export ASTRO_TELEMETRY_DISABLED=1\n' >> ~/.bashrc
    printf 'export HOMEBREW_NO_ANALYTICS=1\n' >> ~/.bashrc
    printf 'export SAM_CLI_TELEMETRY=0\n' >> ~/.bashrc
    printf 'export SCARF_ANALYTICS=false\n' >> ~/.bashrc
    source ~/.bashrc 2>/dev/null || true
}

_priv_apply_ollama_override() {
    sudo mkdir -p /etc/systemd/system/ollama.service.d
    sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null << 'OLEOF'
[Service]
Environment="DO_NOT_TRACK=1"
Environment="OLLAMA_NOPRUNE=1"
OLEOF
    sudo systemctl daemon-reload
    sudo systemctl restart ollama 2>/dev/null || true
}

# ── 5: Maintenance ─────────────────────────────────────────
mod_maintenance() {
    while true; do
        header
        echo -e "${BCYN}┄ MAINTENANCE ──────────────────────────────────────────${NC}"
        echo ""
        echo "   a)  System updates         (apt check · upgrade)"
        echo "   b)  Disk audit & cleanup   (breakdown · safe cleanup)"
        echo "   c)  SMART disk health      (NVMe health)"
        echo "   d)  Journal errors         (last 24h)"
        echo "   e)  Journal size trim      (vacuum to 200MB)"
        echo ""
        echo "   C)  ✦ Ask AI for a maintenance plan"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _maint_updates ;;
            b) _maint_disk ;;
            c) _maint_smart; pause ;;
            d) _maint_journal_errors; pause ;;
            e) _maint_journal_trim; pause ;;
            C) cc_launch "Maintenance Planner" \
                "Review the system context and create a prioritised maintenance plan. Focus on disk space, outdated packages, journal bloat, and any warnings."; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_maint_updates() {
    header
    echo -e "${BCYN}┄ APT UPDATES${NC}"
    sudo apt update -qq 2>&1 | sed 's/^/  /'
    echo ""
    local cnt; cnt=$(apt list --upgradable 2>/dev/null | grep -c "/" || echo 0)
    apt list --upgradable 2>/dev/null | grep -v "Listing" | sed 's/^/  /' | head -30
    echo ""
    if [[ "$cnt" -gt 0 ]]; then
        echo -e "  ${BYEL}${cnt} package(s) upgradable${NC}"
        if confirm "Run sudo apt upgrade now?"; then
            sudo apt upgrade -y 2>&1 | tail -20 | sed 's/^/  /'
        fi
    else
        echo -e "  ${OK}  System up to date"
    fi
    pause
}

_maint_disk() {
    while true; do
        header
        echo -e "${BCYN}┄ DISK AUDIT${NC}"
        echo ""
        # Sizes
        local disk_used disk_total disk_free disk_pct
        read -r disk_total disk_used disk_pct < <(df -BG / | \
            awk 'NR==2{gsub(/G/,"",$2); gsub(/G/,"",$3); gsub(/%/,"",$5); print $2,$3,$5}')
        disk_free=$((disk_total - disk_used))
        local bar_filled=$((disk_pct / 5)) bar_empty=$((20 - disk_pct / 5))
        local bar_col=$BGRN
        [[ "$disk_pct" -gt 60 ]] && bar_col=$BYEL
        [[ "$disk_pct" -gt 80 ]] && bar_col=$BRED
        printf "  %b" "${BOLD}  ${disk_used}GB used / ${disk_total}GB  (${disk_free}GB free · ${disk_pct}%%)${NC}\n"
        printf "  [%b" "$bar_col"
        printf '█%.0s' $(seq 1 $bar_filled)
        printf '%b' "${NC}"
        printf '░%.0s' $(seq 1 $bar_empty)
        printf "]  %d%%\n\n" "$disk_pct"

        # Breakdown
        local ai_lms ai_ollama
        ai_lms=$(du -sh "${HOME}/.lmstudio/models" 2>/dev/null | cut -f1 || echo "0")
        ai_ollama=$(du -sh "${HOME}/.ollama/models" 2>/dev/null | cut -f1 || echo "0")
        local apt_cache journal_sz
        apt_cache=$(du -sh /var/cache/apt 2>/dev/null | cut -f1 || echo "?")
        journal_sz=$(du -sh /var/log/journal 2>/dev/null | cut -f1 || echo "?")

        printf "  %-30s  %s\n" "LM Studio models:"  "$ai_lms"
        printf "  %-30s  %s\n" "Ollama models:"     "$ai_ollama"
        printf "  %-30s  %s\n" "APT cache:"         "$apt_cache"
        printf "  %-30s  %s\n" "Journal logs:"      "$journal_sz"
        echo ""

        echo "   a)  Clean APT cache"
        echo "   b)  Trim journal to 200MB"
        echo "   c)  Remove disabled snap revisions"
        echo "   d)  docker system prune"
        echo "   A)  Run all safe cleanups"
        echo "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) sudo apt clean && sudo apt autoremove -y 2>/dev/null | tail -5 | sed 's/^/  /'
               echo -e "  ${OK}  APT cleaned"; pause ;;
            b) sudo journalctl --vacuum-size=200M 2>/dev/null | sed 's/^/  /'
               echo -e "  ${OK}  Journal trimmed"; pause ;;
            c) snap list --all 2>/dev/null | awk '/disabled/{print $1,$3}' | \
                   while read -r sn rv; do sudo snap remove "$sn" --revision="$rv" 2>/dev/null; done
               echo -e "  ${OK}  Done"; pause ;;
            d) _docker_prune ;;
            A) sudo apt clean && sudo apt autoremove -y >/dev/null 2>&1
               sudo journalctl --vacuum-size=200M >/dev/null 2>&1
               snap list --all 2>/dev/null | awk '/disabled/{print $1,$3}' | \
                   while read -r sn rv; do sudo snap remove "$sn" --revision="$rv" 2>/dev/null; done
               echo -e "  ${OK}  All safe cleanups done"
               df -h / | awk 'NR==2{printf "  Disk now: %s used / %s (%s free)\n",$3,$2,$4}'
               pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_maint_smart() {
    header
    echo -e "${BCYN}┄ DISK SMART HEALTH${NC}"
    if ! command -v smartctl >/dev/null 2>&1; then
        echo "  sudo apt install smartmontools"; return
    fi
    for dev in $(lsblk -dno NAME | grep -Ev "loop|sr" | awk '{print "/dev/"$1}'); do
        echo -e "  ${BOLD}${dev}${NC}"
        sudo smartctl -H "$dev" 2>/dev/null \
            | grep -E "SMART overall|result|Model|Capacity|Temperature|Power_On|Reallocated" \
            | sed 's/^/    /'
        echo ""
    done
}

_maint_journal_errors() {
    header
    echo -e "${BCYN}┄ JOURNAL ERRORS (last 24h)${NC}"
    sudo journalctl -p err --since "24 hours ago" 2>/dev/null \
        | grep -v "^--" | tail -60 | sed 's/^/  /'
}

_maint_journal_trim() {
    header
    echo -e "${BCYN}┄ JOURNAL VACUUM${NC}"
    sudo journalctl --vacuum-size=200M 2>/dev/null | sed 's/^/  /'
    echo -e "  ${OK}  Done"
    pause
}

# ── 6: Projects ────────────────────────────────────────────
mod_projects() {
    while true; do
        header
        echo -e "${BCYN}┄ PROJECTS  (${ZMENU_PROJECTS_DIR}) ─────────────────────${NC}"
        echo ""

        local -a proj_paths=()
        if [[ -d "$ZMENU_PROJECTS_DIR" ]]; then
            while IFS= read -r -d '' p; do
                proj_paths+=("$p")
            done < <(find "$ZMENU_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d \
                -print0 | sort -z 2>/dev/null || true)
        fi

        local i=1
        for p in "${proj_paths[@]}"; do
            local pn; pn=$(basename "$p")
            local badges=""
            [[ -f "${p}/AI.md" ]] && badges+="${BGRN}[md]${NC}" || badges+="${DIM}[no md]${NC}"
            [[ -f "${p}/.config/ai/settings.json" ]] && badges+=" ${BGRN}[secured]${NC}"
            if [[ -d "${p}/.git" ]]; then
                local br; br=$(git -C "$p" branch --show-current 2>/dev/null || echo "?")
                local dirty=""
                git -C "$p" diff --quiet 2>/dev/null || dirty=" ${BYEL}*${NC}"
                badges+=" ${BCYN}[${br}${dirty}]${NC}"
            fi
            printf "   %d)  ${BOLD}%-20s${NC}  %b\n" "$i" "$pn" "$badges"
            ((i++))
        done

        echo ""
        echo "   n)  New project"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            n|N) _proj_new ;;
            r|R) break ;;
            *)
                if [[ "$ch" =~ ^[0-9]+$ ]] && [[ "$ch" -ge 1 ]] \
                    && [[ "$ch" -le ${#proj_paths[@]} ]]; then
                    _proj_open "${proj_paths[$((ch-1))]}"
                else
                    echo -e "${RED}  Invalid.${NC}"; sleep 1
                fi
                ;;
        esac
    done
}

_proj_open() {
    local path="$1"
    local name; name=$(basename "$path")
    while true; do
        header
        echo -e "${BCYN}┄ PROJECT: ${name}${NC}"
        echo ""
        [[ -d "${path}/.git" ]] && {
            echo -e "${BCYN}┄ GIT${NC}"
            git -C "$path" status --short 2>/dev/null | head -10 | sed 's/^/  /'
            echo ""
            git -C "$path" log --oneline -5 2>/dev/null | sed 's/^/  /'
            echo ""
        }
        [[ -f "${path}/AI.md" ]] \
            && echo -e "  ${OK}  AI.md present" \
            || echo -e "  ${WARN}  No AI.md"
        [[ -f "${path}/.config/ai/settings.json" ]] \
            && echo -e "  ${OK}  .config/ai/settings.json present" \
            || echo -e "  ${WARN}  No .config/ai/settings.json"
        echo ""
        echo "   a)  Open terminal here"
        echo "   b)  Launch AI session in this project"
        echo "   c)  Edit AI.md"
        echo "   d)  Edit .config/ai/settings.json"
        echo "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) if command -v gnome-terminal >/dev/null 2>&1; then
                gnome-terminal --working-directory="$path" &>/dev/null &
               else
                echo "  Run: cd ${path}"
               fi ;;
            b) cc_launch "Project: ${name}" \
                "You are working on the project at ${path}. Read AI.md if present. What would you like help with?" \
                "$path"; pause ;;
            c) ${ZMENU_PREFERRED_EDITOR} "${path}/AI.md" ;;
            d) mkdir -p "${path}/.config/ai"
               ${ZMENU_PREFERRED_EDITOR} "${path}/.config/ai/settings.json" ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_proj_new() {
    header
    echo -e "${BCYN}┄ NEW PROJECT${NC}"
    echo ""
    read -rp "  Project name: " raw
    [[ -z "$raw" ]] && return
    local name; name=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')
    local path="${ZMENU_PROJECTS_DIR}/${name}"
    if [[ -d "$path" ]]; then
        echo -e "  ${WARN}  Already exists: ${path}"; pause; return
    fi
    mkdir -p "${path}/.config/ai"
    cat > "${path}/AI.md" << EOF
# ${name}
> Created: $(date '+%B %Y')

## What to Build

## Stack
Ubuntu 24 · AMD Ryzen AI MAX+ PRO 395 · 128GB RAM
Ollama (${ZMENU_AI_MODEL}) · Docker · ROCm GPU
EOF
    cat > "${path}/.config/ai/settings.json" << 'EOF'
{
  "permissions": {
    "allow": ["Bash:*"],
    "deny": [
      "Bash:rm -rf /", "Bash:sudo rm -rf*",
      "Bash:cat ~/.ssh/*", "Edit:~/.ssh/*"
    ]
  }
}
EOF
    cd "$path" && git init -q && echo ".env" > .gitignore \
        && git add . -q && git commit -q -m "chore: init" && cd - >/dev/null
    echo -e "  ${OK}  Created: ${path}"
    sleep 1
    _proj_open "$path"
}

# ── 7: GPU & NPU ───────────────────────────────────────────
mod_hardware_ai() {
    while true; do
        header
        echo -e "${BCYN}┄ GPU & NPU ────────────────────────────────────────────${NC}"
        echo ""
        echo "   a)  GPU full status        (ROCm · VRAM · compute)"
        echo "   b)  NPU status             (XDNA driver · device)"
        echo "   c)  Check HSA env var      (needed for GPU inference)"
        echo ""
        echo "   C)  ✦ Ask AI about GPU/NPU setup"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _hw_gpu; pause ;;
            b) _hw_npu; pause ;;
            c) _hw_hsa; pause ;;
            C) cc_launch "GPU/NPU Expert" \
                "You are an AMD ROCm and XDNA NPU expert. Review the GPU/NPU status in the context. Check GFX version, HSA override, VRAM usage, and driver state. Identify any issues."; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_hw_gpu() {
    header
    echo -e "${BCYN}┄ GPU: ${D_GPU_GFX:-unknown}  driver: ${D_GPU_DRIVER:-none}${NC}"
    echo ""
    case "$D_GPU_DRIVER" in
        rocm)
            rocm-smi 2>/dev/null | grep -v "^=\|^$" | sed 's/^/  /'
            echo ""
            echo -e "${BCYN}┄ VRAM${NC}"
            rocm-smi --showmeminfo vram 2>/dev/null | sed 's/^/  /'
            echo ""
            echo -e "${BCYN}┄ COMPUTE DEVICES${NC}"
            rocminfo 2>/dev/null \
                | grep -E "Name|Marketing|Chip|Compute|Max Clock" \
                | head -20 | sed 's/^/  /'
            ;;
        amdgpu-sysfs)
            echo -e "  ${WARN}  rocm-smi not in PATH — add /opt/rocm/bin to PATH"
            echo ""
            for d in /sys/class/hwmon/hwmon*; do
                local n; n=$(cat "$d/name" 2>/dev/null || echo "")
                [[ "$n" != *amdgpu* ]] && continue
                echo "  Device: $n"
                for f in "$d"/temp*_input; do
                    [[ -f "$f" ]] && awk '{printf "  Temp: %.1f°C\n", $1/1000}' "$f"
                done
            done
            ;;
        *)
            echo -e "  ${FAIL}  No AMD GPU driver detected"
            ;;
    esac
    echo ""
    echo -e "${BCYN}┄ HSA_OVERRIDE_GFX_VERSION${NC}"
    local hsa="${HSA_OVERRIDE_GFX_VERSION:-NOT SET}"
    local gfx_compact="${D_GPU_GFX#gfx}"
    echo "  Current value: ${hsa}"
    if [[ "$hsa" == "NOT SET" ]]; then
        echo -e "  ${BYEL}Fix: export HSA_OVERRIDE_GFX_VERSION=$(_gfx_dotted "$gfx_compact")${NC}"
        echo "  Add to ~/.bashrc for permanence"
    elif _gfx_match "$hsa" "$gfx_compact"; then
        echo -e "  ${OK}  Set correctly (${hsa} ≡ gfx${gfx_compact})"
    else
        echo -e "  ${WARN}  Set to ${hsa} but GPU is gfx${gfx_compact}"
        echo -e "  ${BYEL}Fix: export HSA_OVERRIDE_GFX_VERSION=$(_gfx_dotted "$gfx_compact")${NC}"
    fi
}

_hw_npu() {
    header
    echo -e "${BCYN}┄ NPU / XDNA${NC}"
    echo ""
    echo "  Kernel modules:"
    for mod in amdxdna ryzen_ai npu amd_ipu; do
        if lsmod 2>/dev/null | grep -qi "$mod"; then
            echo -e "  ${OK}  ${mod}"
        fi
    done
    echo ""
    echo "  Device nodes:"
    ls /dev/accel* 2>/dev/null | sed 's/^/    /' || echo "    none at /dev/accel*"
    echo ""
    echo "  Recent dmesg (NPU/XDNA):"
    sudo dmesg 2>/dev/null | grep -iE "npu|xdna|ryzen.ai|ipu" | tail -8 | sed 's/^/    /'
}

_hw_hsa() {
    header
    echo -e "${BCYN}┄ HSA / ROCm ENVIRONMENT${NC}"
    echo ""
    local gfx_compact="${D_GPU_GFX#gfx}"
    local gfx_dotted; gfx_dotted=$(_gfx_dotted "$gfx_compact")
    local hsa_cur="${HSA_OVERRIDE_GFX_VERSION:-NOT SET}"

    echo "  GPU GFX detected:            ${D_GPU_GFX:-unknown}"
    echo "  Compact form:                ${gfx_compact}"
    echo "  Dotted form:                 ${gfx_dotted}"
    echo "  Current HSA_OVERRIDE:        ${hsa_cur}"
    echo ""
    if [[ "$hsa_cur" == "NOT SET" ]]; then
        echo -e "  ${FAIL}  HSA_OVERRIDE_GFX_VERSION not set"
        echo "  Run:  export HSA_OVERRIDE_GFX_VERSION=${gfx_dotted}"
        echo "  Permanent: echo 'export HSA_OVERRIDE_GFX_VERSION=${gfx_dotted}' >> ~/.bashrc"
    elif _gfx_match "$hsa_cur" "$gfx_compact"; then
        echo -e "  ${OK}  Matches detected GPU (${hsa_cur} ≡ gfx${gfx_compact}) — ROCm should work correctly"
    else
        echo -e "  ${WARN}  Set to ${hsa_cur} but detected GPU is gfx${gfx_compact} (${gfx_dotted})"
        echo "  Fix:  export HSA_OVERRIDE_GFX_VERSION=${gfx_dotted}"
    fi
}

# ── 8: Manage Z-Menu ───────────────────────────────────────
mod_manage() {
    while true; do
        header
        echo -e "${BCYN}┄ MANAGE Z-MENU ────────────────────────────────────────${NC}"
        echo ""
        echo "  Version:  ${ZMENU_VERSION}"
        echo "  Self:     ${ZMENU_SELF}"
        echo "  Install:  ${ZMENU_INSTALL_PATH}"
        echo "  Config:   ${ZMENU_CONFIG_FILE}"
        echo "  Model:    ${ZMENU_AI_MODEL}"
        echo ""
        local inst_ver
        inst_ver=$(grep '^ZMENU_VERSION=' "$ZMENU_INSTALL_PATH" 2>/dev/null \
            | cut -d'"' -f2 || echo "not installed")
        if [[ "$inst_ver" == "$ZMENU_VERSION" ]]; then
            echo -e "  Installed version: ${BGRN}✓ ${inst_ver} matches${NC}"
        else
            echo -e "  Installed version: ${BYEL}${inst_ver} (source is ${ZMENU_VERSION})${NC}"
        fi
        echo ""
        echo "   a)  Reinstall from this source"
        echo "   b)  Edit source"
        echo "   c)  Edit config"
        echo "   d)  Check/fix environment variables"
        echo "   e)  Re-run discovery"
        echo ""
        echo "   C)  ✦ Ask AI to improve Z-Menu"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _mgmt_reinstall; pause ;;
            b) set +e; ${ZMENU_PREFERRED_EDITOR} "$ZMENU_SELF"; set -e ;;
            c) cfg_edit ;;
            d) _mgmt_envcheck; pause ;;
            e) echo "  Re-running discovery..."; discover
               echo -e "  ${OK}  Done"; pause ;;
            C) cc_launch "Z-Menu Developer" \
                "You are the Z-Menu developer. Read the zmenu source at ${ZMENU_SELF} in addition to the context. The user wants to improve or extend Z-Menu. Follow the existing patterns: header, section loops, cc_launch for AI integration. Suggest improvements or write new modules."; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_mgmt_reinstall() {
    if [[ "$ZMENU_SELF" == "$ZMENU_INSTALL_PATH" ]]; then
        echo -e "  ${WARN}  Source and install path are the same — nothing to copy"
        return
    fi
    sudo cp "$ZMENU_SELF" "$ZMENU_INSTALL_PATH" && sudo chmod +x "$ZMENU_INSTALL_PATH" \
        && echo -e "  ${OK}  Installed to ${ZMENU_INSTALL_PATH}" \
        || echo -e "  ${FAIL}  Failed. Try: sudo cp ${ZMENU_SELF} ${ZMENU_INSTALL_PATH}"
}

_mgmt_envcheck() {
    header
    echo -e "${BCYN}┄ ENVIRONMENT VARIABLES${NC}"
    echo ""

    _env_check "HSA_OVERRIDE_GFX_VERSION" \
        "${D_GPU_GFX#gfx}" \
        "ROCm GPU version hint for inference"

    _env_check "DOCKER_HOST" \
        "unix:///run/docker.sock" \
        "Docker socket for CLI commands"
}

_env_check() {
    local var="$1" expected="$2" desc="$3"
    local cur="${!var:-NOT SET}"
    printf "\n  ${BOLD}%s${NC}\n" "$var"
    printf "  %s\n" "$desc"
    if [[ "$cur" == "NOT SET" ]]; then
        printf "  ${BRED}NOT SET${NC}  →  echo 'export %s=%s' >> ~/.bashrc\n" "$var" "$expected"
    elif [[ "$cur" == "$expected" ]]; then
        printf "  ${BGRN}✓  %s${NC}\n" "$cur"
    elif [[ "$var" == "HSA_OVERRIDE_GFX_VERSION" ]] && _gfx_match "$cur" "$expected"; then
        printf "  ${BGRN}✓  %s  (≡ %s)${NC}\n" "$cur" "$expected"
    else
        printf "  ${BYEL}%s  (expected: %s)${NC}\n" "$cur" "$expected"
    fi
}


# ── Docker stop / restart ───────────────────────────────────

_docker_pick_container() {
    # $1 = "running" or "all"
    local scope="${1:-running}"
    local -a ctrs=()
    local fmt
    if [[ "$scope" == "all" ]]; then
        fmt="docker ps -a --format {{.Names}}"
    else
        fmt="docker ps --format {{.Names}}"
    fi
    while IFS= read -r line; do ctrs+=("$line"); done < <($fmt 2>/dev/null)
    if [[ ${#ctrs[@]} -eq 0 ]]; then
        echo "  No containers found"; echo ""; echo "NONE"
        return
    fi
    local i=1
    for c in "${ctrs[@]}"; do
        local status; status=$(docker inspect --format "{{.State.Status}}" "$c" 2>/dev/null)
        echo "   ${i})  ${c}  (${status})"
        ((i++))
    done
    echo ""
    read -rp "  Select (or Enter to cancel): " n
    if [[ -z "$n" ]]; then echo "CANCEL"; return; fi
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#ctrs[@]} ]]; then
        echo "${ctrs[$((n-1))]}"
    else
        echo "INVALID"
    fi
}

_docker_stop() {
    header
    echo -e "${BCYN}┄ STOP CONTAINER${NC}"
    echo ""
    local name; name=$(_docker_pick_container "running" | tail -1)
    case "$name" in
        NONE|CANCEL|INVALID) pause; return ;;
    esac
    if confirm "Stop container: ${name}?"; then
        docker stop "$name" 2>/dev/null \
            && echo -e "  ${OK}  Stopped: ${name}" \
            || echo -e "  ${FAIL}  Failed"
    fi
    pause
}

_docker_restart() {
    header
    echo -e "${BCYN}┄ RESTART CONTAINER${NC}"
    echo ""
    local name; name=$(_docker_pick_container "all" | tail -1)
    case "$name" in
        NONE|CANCEL|INVALID) pause; return ;;
    esac
    docker restart "$name" 2>/dev/null \
        && echo -e "  ${OK}  Restarted: ${name}" \
        || echo -e "  ${FAIL}  Failed"
    pause
}

# ── 9: AI Inspector ────────────────────────────────────────

mod_ai_inspector() {
    while true; do
        header
        echo -e "${BCYN}┄ AI INSPECTOR ────────────────────────────────${NC}"
        echo ""
        # Quick summary
        local skill_count=0
        [[ -d "${HOME}/.config/ai/skills" ]] && skill_count=$(find "${HOME}/.config/ai/skills" -name "*.md" 2>/dev/null | wc -l)
        local mcp_count=0
        [[ -f "${HOME}/.config/ai/settings.json" ]] && \
            mcp_count=$(python3 -c "import json; d=json.load(open('${HOME}/.config/ai/settings.json')); print(len(d.get('mcpServers',{})))" 2>/dev/null || echo 0)
        local global_md="${WARN} missing${NC}"
        [[ -f "${HOME}/.config/ai/AI.md" ]] && global_md="${OK} present${NC}"
        local global_set="${WARN} missing${NC}"
        [[ -f "${HOME}/.config/ai/settings.json" ]] && global_set="${OK} present${NC}"
        echo -e "  Global AI.md:    ${global_md}"
        echo -e "  Global settings:     ${global_set}"
        echo -e "  Skills:              ${BGRN}${skill_count}${NC} file(s) in ~/.config/ai/skills/"
        echo -e "  MCP servers:         ${BGRN}${mcp_count}${NC} registered"
        echo ""
        echo "   a)  Global settings.json    (~/.config/ai/settings.json)"
        echo "   b)  Global AI.md           (~/.config/ai/AI.md)"
        echo "   c)  Skills viewer/editor    (~/.config/ai/skills/)"
        echo "   d)  MCP servers             (registered tool servers)"
        echo "   e)  Project inspector       (per-project settings & AI.md)"
        echo ""
        echo "   C)  ✦ Ask AI to audit your AI setup"
        echo "   r)  Return"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _cc_global_settings ;;
            b) _cc_global_md ;;
            c) _cc_skills ;;
            d) _cc_mcps ;;
            e) _cc_project_inspector ;;
            C) cc_launch "AI Auditor" \
                "Audit the AI configuration shown in the context. Check for: missing AI.md files, missing settings.json, MCP server misconfigurations, skills that could be added, and overly permissive or missing deny rules. Give a prioritised improvement list."; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_cc_global_settings() {
    header
    echo -e "${BCYN}┄ GLOBAL SETTINGS  (~/.config/ai/settings.json)${NC}"
    echo ""
    local f="${HOME}/.config/ai/settings.json"
    if [[ -f "$f" ]]; then
        echo -e "  ${OK}  File present"
        echo ""
        cat "$f" | sed 's/^/  /'
    else
        echo -e "  ${WARN}  Not found — using default settings (no restrictions)"
        echo ""
        echo "  Recommended: create with at minimum a deny list for destructive commands."
    fi
    echo ""
    echo "   e)  Edit    r)  Return"
    read -rp "  Selection: " ch
    [[ "$ch" =~ ^[eE]$ ]] && { mkdir -p "${HOME}/.config/ai"; ${ZMENU_PREFERRED_EDITOR} "$f"; }
}

_cc_global_md() {
    header
    echo -e "${BCYN}┄ GLOBAL AI.md  (~/.config/ai/AI.md)${NC}"
    echo ""
    local f="${HOME}/.config/ai/AI.md"
    if [[ -f "$f" ]]; then
        local lines; lines=$(wc -l < "$f")
        echo -e "  ${OK}  Present  (${lines} lines)"
        echo ""
        cat "$f" | sed 's/^/  /' | head -40
        [[ $lines -gt 40 ]] && echo "  ${DIM}... $((lines-40)) more lines${NC}"
    else
        echo -e "  ${WARN}  Not found"
        echo ""
        echo "  This file loads automatically in every AI session."
        echo "  Good for: your name, preferred languages, global rules."
    fi
    echo ""
    echo "   e)  Edit    r)  Return"
    read -rp "  Selection: " ch
    [[ "$ch" =~ ^[eE]$ ]] && { mkdir -p "${HOME}/.config/ai"; ${ZMENU_PREFERRED_EDITOR} "$f"; }
}

_cc_skills() {
    while true; do
        header
        echo -e "${BCYN}┄ SKILLS  (~/.config/ai/skills/)${NC}"
        echo ""
        local skills_dir="${HOME}/.config/ai/skills"
        local -a skill_files=()
        if [[ -d "$skills_dir" ]]; then
            while IFS= read -r -d '' f; do
                skill_files+=("$f")
            done < <(find "$skills_dir" -name "*.md" -print0 2>/dev/null | sort -z)
        fi
        if [[ ${#skill_files[@]} -eq 0 ]]; then
            echo -e "  ${IDLE}  No skills yet.  Skills are .md files that teach your AI specialist knowledge."
        else
            local i=1
            for f in "${skill_files[@]}"; do
                local name; name=$(basename "$f" .md)
                local lines; lines=$(wc -l < "$f")
                printf "   %d)  ${BOLD}%-28s${NC}  ${DIM}%d lines${NC}\n" "$i" "$name" "$lines"
                ((i++))
            done
        fi
        echo ""
        echo "   n)  New skill    r)  Return"
        echo ""
        read -rp "  Select skill to view/edit (or n/r): " ch
        case $ch in
            r|R) break ;;
            n|N) _cc_skill_new; continue ;;
            *)
                if [[ "$ch" =~ ^[0-9]+$ ]] && [[ "$ch" -ge 1 ]] && [[ "$ch" -le ${#skill_files[@]} ]]; then
                    local sf="${skill_files[$((ch-1))]}"
                    local sname; sname=$(basename "$sf" .md)
                    header
                    echo -e "${BCYN}┄ SKILL: ${sname}${NC}"
                    echo ""
                    cat "$sf" | sed 's/^/  /'
                    echo ""
                    echo "   e)  Edit    d)  Delete    r)  Return"
                    read -rp "  Selection: " act
                    case $act in
                        e|E) ${ZMENU_PREFERRED_EDITOR} "$sf" ;;
                        d|D) confirm "Delete skill: ${sname}?" && rm "$sf" && echo -e "  ${OK}  Deleted"; pause ;;
                    esac
                fi
                ;;
        esac
    done
}

_cc_skill_new() {
    header
    echo -e "${BCYN}┄ NEW SKILL${NC}"
    echo ""
    read -rp "  Skill name (e.g. docker, python, rocm): " name
    [[ -z "$name" ]] && return
    local f="${HOME}/.config/ai/skills/${name}.md"
    mkdir -p "${HOME}/.config/ai/skills"
    if [[ ! -f "$f" ]]; then
        printf "# %s\n\n## Purpose\nDescribe what this skill teaches your AI.\n\n## Rules\n- Rule 1\n\n## Examples\n" "$name" > "$f"
    fi
    ${ZMENU_PREFERRED_EDITOR} "$f"
}

_cc_mcps() {
    header
    echo -e "${BCYN}┄ MCP SERVERS${NC}"
    echo ""
    local settings="${HOME}/.config/ai/settings.json"
    if [[ ! -f "$settings" ]]; then
        echo -e "  ${WARN}  No ~/.config/ai/settings.json — no MCP servers registered"
        echo ""
        echo "   a)  Add MCP server    r)  Return"
        read -rp "  Selection: " ch
        [[ "$ch" =~ ^[aA]$ ]] && _cc_mcp_add
        return
    fi
    python3 - "$settings" << 'PYEOF'
import json, sys
f = sys.argv[1]
try:
    d = json.load(open(f))
    servers = d.get('mcpServers', {})
    if not servers:
        print("  No MCP servers registered yet.")
    else:
        print(f"  {len(servers)} registered server(s):\n")
        for name, cfg in servers.items():
            t = cfg.get('transport', cfg.get('type', '?'))
            u = cfg.get('url', cfg.get('command', ''))
            print(f"    {name}")
            print(f"      transport: {t}")
            print(f"      url:       {u}")
            print()
except Exception as e:
    print(f"  Error reading settings: {e}")
PYEOF
    echo ""
    echo "   a)  Add MCP server    e)  Edit settings.json    r)  Return"
    read -rp "  Selection: " ch
    case $ch in
        a|A) _cc_mcp_add ;;
        e|E) ${ZMENU_PREFERRED_EDITOR} "$settings" ;;
    esac
}

_cc_mcp_add() {
    header
    echo -e "${BCYN}┄ ADD MCP SERVER${NC}"
    echo ""
    echo "  ${DIM}Examples:${NC}"
    echo "  ${DIM}  crawl4ai  |  sse   |  http://localhost:11235/mcp/sse${NC}"
    echo "  ${DIM}  searxng   |  http  |  http://localhost:8080/mcp${NC}"
    echo ""
    read -rp "  Server name: " mcp_name
    [[ -z "$mcp_name" ]] && return
    read -rp "  URL: " mcp_url
    [[ -z "$mcp_url" ]] && return
    read -rp "  Transport [sse/http/stdio] (default: sse): " mcp_transport
    mcp_transport="${mcp_transport:-sse}"
    local settings="${HOME}/.config/ai/settings.json"
    python3 - "$settings" "$mcp_name" "$mcp_transport" "$mcp_url" << 'PYEOF'
import json, sys
f, name, transport, url = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    d = json.load(open(f))
except Exception:
    d = {}
d.setdefault("mcpServers", {})[name] = {"transport": transport, "url": url}
json.dump(d, open(f, "w"), indent=2)
print(f"  Added: {name}")
PYEOF
    pause
}

_cc_project_inspector() {
    header
    echo -e "${BCYN}┄ PROJECT AI INSPECTOR${NC}"
    echo ""
    echo -e "  ${DIM}[md]=AI.md  [set]=settings  [sk]=skills  [mcp]=MCP servers  [git]=branch${NC}"
    echo ""
    local -a proj_paths=()
    if [[ -d "$ZMENU_PROJECTS_DIR" ]]; then
        while IFS= read -r -d '' p; do
            proj_paths+=("$p")
        done < <(find "$ZMENU_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z 2>/dev/null || true)
    fi
    if [[ ${#proj_paths[@]} -eq 0 ]]; then
        echo "  No projects in ${ZMENU_PROJECTS_DIR}"; pause; return
    fi
    local i=1
    for p in "${proj_paths[@]}"; do
        local pn; pn=$(basename "$p")
        local badges=""
        # AI.md
        if [[ -f "${p}/AI.md" ]]; then
            local mdl; mdl=$(wc -l < "${p}/AI.md")
            badges+="${BGRN}[md:${mdl}L]${NC} "
        else
            badges+="${BRED}[no md]${NC} "
        fi
        # settings.json
        if [[ -f "${p}/.config/ai/settings.json" ]]; then
            local perms; perms=$(python3 -c "
import json
try:
    d=json.load(open('${p}/.config/ai/settings.json'))
    a=len(d.get('permissions',{}).get('allow',[]))
    dn=len(d.get('permissions',{}).get('deny',[]))
    print(f'+{a}/-{dn}')
except: print('ok')
" 2>/dev/null)
            badges+="${BGRN}[set:${perms}]${NC} "
        else
            badges+="${BYEL}[no set]${NC} "
        fi
        # Skills
        local sk=0
        [[ -d "${p}/.config/ai/skills" ]] && sk=$(find "${p}/.config/ai/skills" -name "*.md" 2>/dev/null | wc -l)
        [[ $sk -gt 0 ]] && badges+="${BCYN}[${sk}sk]${NC} "
        # MCPs
        if [[ -f "${p}/.config/ai/settings.json" ]]; then
            local mc; mc=$(python3 -c "
import json
try:
    d=json.load(open('${p}/.config/ai/settings.json'))
    print(len(d.get('mcpServers',{})))
except: print(0)
" 2>/dev/null)
            [[ "$mc" -gt 0 ]] && badges+="${BCYN}[${mc}mcp]${NC} "
        fi
        # Git
        if [[ -d "${p}/.git" ]]; then
            local br; br=$(git -C "$p" branch --show-current 2>/dev/null || echo "?")
            local dirty=""
            git -C "$p" diff --quiet 2>/dev/null || dirty="${BYEL}*${NC}"
            badges+="${DIM}[${br}${dirty}]${NC}"
        fi
        printf "   %d)  ${BOLD}%-22s${NC}  %b\n" "$i" "$pn" "$badges"
        ((i++))
    done
    echo ""
    echo "   r)  Return"
    echo ""
    read -rp "  Select project for detail view: " ch
    case $ch in
        r|R) return ;;
        *)
            if [[ "$ch" =~ ^[0-9]+$ ]] && [[ "$ch" -ge 1 ]] && [[ "$ch" -le ${#proj_paths[@]} ]]; then
                _cc_proj_detail "${proj_paths[$((ch-1))]}"
            fi
            ;;
    esac
}

_cc_proj_detail() {
    local path="$1"
    local name; name=$(basename "$path")
    header
    echo -e "${BCYN}┄ PROJECT: ${name}${NC}"
    echo ""
    # AI.md
    echo -e "${BOLD}  AI.md${NC}"
    if [[ -f "${path}/AI.md" ]]; then
        echo -e "  ${OK}  Present  ($(wc -l < "${path}/AI.md") lines)"
        echo ""
        head -25 "${path}/AI.md" | sed 's/^/    /'
        local t; t=$(wc -l < "${path}/AI.md")
        [[ $t -gt 25 ]] && echo "    ${DIM}... $((t-25)) more lines — press e to edit${NC}"
    else
        echo -e "  ${WARN}  Missing"
    fi
    echo ""
    # settings.json
    echo -e "${BOLD}  .config/ai/settings.json${NC}"
    if [[ -f "${path}/.config/ai/settings.json" ]]; then
        echo -e "  ${OK}  Present"
        echo ""
        cat "${path}/.config/ai/settings.json" | sed 's/^/    /'
    else
        echo -e "  ${WARN}  Missing — no project-specific permissions"
    fi
    echo ""
    # Skills
    echo -e "${BOLD}  Local Skills (.config/ai/skills/)${NC}"
    if [[ -d "${path}/.config/ai/skills" ]]; then
        local count; count=$(find "${path}/.config/ai/skills" -name "*.md" 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            find "${path}/.config/ai/skills" -name "*.md" 2>/dev/null | while read -r sf; do
                echo -e "    ${BGRN}●${NC}  $(basename "$sf" .md)  ${DIM}($(wc -l < "$sf") lines)${NC}"
            done
        else
            echo -e "  ${IDLE}  None"
        fi
    else
        echo -e "  ${IDLE}  None"
    fi
    echo ""
    # MCPs
    echo -e "${BOLD}  Local MCP Servers${NC}"
    if [[ -f "${path}/.config/ai/settings.json" ]]; then
        python3 - "${path}/.config/ai/settings.json" << 'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    servers = d.get('mcpServers', {})
    if servers:
        for n, c in servers.items():
            t = c.get('transport', c.get('type','?'))
            u = c.get('url', c.get('command',''))
            print(f"    {n}  ({t})  {u}")
    else:
        print("    None")
except:
    print("    (could not parse)")
PYEOF
    else
        echo -e "  ${IDLE}  None"
    fi
    echo ""
    echo "   e)  Edit AI.md    s)  Edit settings.json    r)  Return"
    read -rp "  Selection: " ch
    case $ch in
        e|E) ${ZMENU_PREFERRED_EDITOR} "${path}/AI.md" ;;
        s|S) mkdir -p "${path}/.config/ai"; ${ZMENU_PREFERRED_EDITOR} "${path}/.config/ai/settings.json" ;;
    esac
}

# ============================================================
#  SECTION 7 — MAIN MENU
# ============================================================

main_menu() {
    while true; do
        header
        status_bar
        echo -e "  ${BOLD}${BBLU}┄ MENU ─────────────────────────────────────────────────${NC}"
        echo ""
        echo "   1)  System Health          (CPU · RAM · thermal · hardware)"
        echo "   2)  AI Stack               (Ollama · LM Studio · Open WebUI)"
        echo "   3)  Docker & Services      (containers · logs · cleanup)"
        echo "   4)  Security & Network     (ports · firewall · logins)"
        echo "   5)  Maintenance            (updates · disk · SMART · journal)"
        echo "   6)  Projects               (open · create · AI sessions)"
        echo "   7)  GPU & NPU              (ROCm · VRAM · XDNA)"
        echo "   8)  Manage Z-Menu          (version · config · reinstall)"
        echo "   9)  AI Inspector  (settings · skills · MCPs · projects)"
        echo ""
        echo "   q)  Exit"
        echo ""
        read -rp "  $(printf '%b' "${BOLD}Selection:${NC} ")" choice
        case $choice in
            1) mod_system_health ;;
            2) mod_ai_stack ;;
            3) mod_docker ;;
            4) mod_security ;;
            5) mod_maintenance ;;
            6) mod_projects ;;
            7) mod_hardware_ai ;;
            8) mod_manage ;;
            9) mod_ai_inspector ;;
            q|Q) printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

# ============================================================
#  SECTION 8 — ENTRYPOINT
# ============================================================

_bootstrap() {
    cfg_load
    echo -e "${DIM}  Discovering system...${NC}"
    discover
    # Clear the "discovering" line
    printf '\033[1A\033[2K'
}

case "${1:-}" in
    --run|-r)
        if [[ -n "${2:-}" ]]; then
            export ZMENU_HEADLESS=1
            _bootstrap
            "$2"
            exit $?
        else
            printf '%bError: --run requires a function name%b\n' "$BRED" "$NC" >&2
            exit 1
        fi
        ;;
    --context)
        _bootstrap
        context_generate
        cat "$ZMENU_CONTEXT_FILE"
        exit 0
        ;;
    --help|-h)
        echo "Usage: zmenu [--run <function>] [--context] [--help]"
        echo "  --run <fn>    Execute a module function headlessly"
        echo "  --context     Dump live system context to stdout"
        exit 0
        ;;
    "")
        _bootstrap
        main_menu
        ;;
    *)
        printf '%bUnknown argument: %s%b\n' "$BRED" "$1" "$NC" >&2
        exit 1
        ;;
esac
