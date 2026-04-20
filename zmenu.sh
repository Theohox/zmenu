#!/usr/bin/env bash
# ============================================================
#  Z-MENU  v5.0.0
#  Local Sovereign Dashboard
#
#  INSTALL:   chmod +x zmenu.sh && sudo cp zmenu.sh /usr/local/bin/zmenu
#  RUN:       zmenu
#  HEADLESS:  zmenu --run <function_name>
#
#  v5.0.0 — Full rewrite:
#    • Dashboard home screen with green/yellow/red status at a glance
#    • Find Problems module — full bottleneck sweep with plain English fixes
#    • Export from any screen (press E → ~/zmenu-report.md)
#    • 8 menu sections grouped by what affects what
#    • Settings merged from old modules 8+9
#    • Portable — auto-detect hardware, no hardcoded values
#    • Back buttons + Ask AI on every screen
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
readonly ZMENU_VERSION="5.11.0"
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
EOF
    echo -e "  ${BGRN}✓${NC}  Config created: ${ZMENU_CONFIG_FILE}"
}

cfg_load() {
    cfg_init
    # shellcheck source=/dev/null
    source "$ZMENU_CONFIG_FILE"
    # Propagate config overrides to runtime variables
    [[ -n "${ZMENU_ZENNY_BINARY:-}" ]] && ZENNY_BINARY="$ZMENU_ZENNY_BINARY"
}

cfg_edit() {
    ${ZMENU_PREFERRED_EDITOR} "$ZMENU_CONFIG_FILE"
    cfg_load
}

# ============================================================
#  SECTION 2 — DISCOVERY ENGINE
#  Runs once at startup. Populates D_* variables.
#  Never assumes — always probes. Portable across Linux systems.
# ============================================================

# Discovered state — all empty until discover() runs
D_OLLAMA_URL=""
D_OLLAMA_RUNNING=false
D_OLLAMA_ACTIVE_MODEL=""
D_OLLAMA_MODELS=()
D_OLLAMA_TOOL_MODELS=()

D_LMS_URL=""
D_LMS_RUNNING=false
D_LMS_MODELS=()

D_ZENNY_RUNNING=false
D_ZENNY_SOCKET="/tmp/zenny-core.sock"
D_ZENNY_MODELS=()           # display_name strings (for UI)
D_ZENNY_KEYS=()             # registry keys (for inference requests)
D_ZENNY_PID=""

AI_BACKEND_ACTIVE=""        # resolved at runtime: zenny|opencode|ollama|none
AI_BACKEND_LABEL=""         # human-readable label for display

D_AI_BIN=""
D_AI_VER=""
D_AI_RUNNING=false

D_CLAUDE_BIN=""
D_CLAUDE_VER=""
D_CLAUDE_SESSION=false     # true when zmenu is running inside a Claude Code session

D_DOCKER_RUNNING=false
D_CONTAINERS=()

D_GPU_DRIVER=""             # rocm | amdgpu-sysfs | nvidia | none
D_GPU_GFX=""                # e.g. gfx1151
D_GPU_TEMP=""
D_GPU_USE=""
D_GPU_VRAM_USED=""
D_GPU_VRAM_TOTAL=""

D_NPU_DRIVER=""             # amdxdna | none
D_NPU_DEVICE=""

D_CPU_MODEL=""
D_CPU_CORES=""
D_CPU_GOVERNOR=""
D_MEM_TOTAL_MB=""
D_MEM_USED_MB=""
D_MEM_FREE_MB=""
D_SWAP_TOTAL_MB=""
D_SWAP_USED_MB=""

D_SERVICES=()
D_OPEN_PORTS=()

discover() {
    _disc_cpu
    _disc_memory
    _disc_ollama
    _disc_zenny
    _disc_lms
    _disc_ai_tool
    _disc_claude
    _disc_docker
    _disc_gpu
    _disc_npu
    _disc_services
    _disc_ports
    _sel_ai_backend
    ( _wiki_full_refresh ) 2>/dev/null || true
}

# ── CPU ────────────────────────────────────────────────────
_disc_cpu() {
    D_CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | sed 's/model name\s*:\s*//' || echo "unknown")
    D_CPU_CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "?")
    # Governor (first core)
    D_CPU_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
}

# ── Memory ─────────────────────────────────────────────────
_disc_memory() {
    read -r D_MEM_TOTAL_MB D_MEM_USED_MB D_MEM_FREE_MB < <(free -m | awk '/^Mem/{print $2,$3,$7}')
    read -r D_SWAP_TOTAL_MB D_SWAP_USED_MB < <(free -m | awk '/^Swap/{print $2,$3}')
}

# ── Ollama ─────────────────────────────────────────────────
_disc_ollama() {
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

    # Tool-capable models (skip if ollama binary not found)
    if command -v ollama >/dev/null 2>&1; then
        for m in "${D_OLLAMA_MODELS[@]}"; do
            if ollama show "$m" 2>/dev/null | grep -qi "tools"; then
                D_OLLAMA_TOOL_MODELS+=("$m")
            fi
        done
    fi
}

# ── Zenny-Core socket helper ───────────────────────────────
_zenny_send() {
    local msg="$1"
    # timeout 5 guards against hangs if socket exists but server is unresponsive
    timeout 5 python3 - <<PYEOF 2>/dev/null
import socket, sys
req = """${msg}""" + "\n"
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(4)
    s.connect("${D_ZENNY_SOCKET}")
    s.sendall(req.encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk: break
        buf += chunk
    s.close()
    print(buf.decode().strip())
except:
    sys.exit(1)
PYEOF
}

# ── Zenny-Core ─────────────────────────────────────────────
_disc_zenny() {
    D_ZENNY_RUNNING=false
    D_ZENNY_MODELS=()
    D_ZENNY_KEYS=()
    D_ZENNY_PID=""
    # Quick process check first — avoids blocking on a stale socket file
    D_ZENNY_PID=$(pgrep -x "$ZENNY_PROCESS" 2>/dev/null | head -1 || true)
    [[ -z "$D_ZENNY_PID" ]] && return
    [[ ! -S "$D_ZENNY_SOCKET" ]] && return
    local resp
    resp=$(_zenny_send '{"cmd":"list_models"}' 2>/dev/null) || return
    [[ -z "$resp" ]] && return
    D_ZENNY_RUNNING=true
    # Populate display names (UI) and registry keys (inference) in parallel
    while IFS='|' read -r disp key; do
        [[ -n "$disp" ]] && D_ZENNY_MODELS+=("$disp")
        [[ -n "$key"  ]] && D_ZENNY_KEYS+=("$key")
    done < <(echo "$resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    for m in d.get('models',[]):
        print(m.get('display_name','?') + '|' + m.get('name','?'))
except: pass
" 2>/dev/null || true)
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

# ── Local AI tool (Ollama binary) ──────────────────────────
_disc_ai_tool() {
    D_AI_BIN=$(command -v ollama 2>/dev/null || echo "")
    [[ -z "$D_AI_BIN" ]] && return
    D_AI_RUNNING=true
    D_AI_VER=$(ollama --version 2>/dev/null \
        | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1 || echo "?")
}

_disc_claude() {
    D_CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "")
    [[ -z "$D_CLAUDE_BIN" ]] && return
    D_CLAUDE_VER=$(claude --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]*' | head -1 || echo "?")
    # Detect if we're running inside an active Claude Code session
    # Claude Code sets CLAUDE_CODE_ENTRYPOINT or runs node processes with claude in path
    if [[ -n "${CLAUDE_CODE_ENTRYPOINT:-}" ]] || \
       pgrep -f "node.*\.nvm.*claude" >/dev/null 2>&1; then
        D_CLAUDE_SESSION=true
    fi
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

# ── GPU (portable: AMD ROCm → AMD sysfs → Nvidia → none) ──
_disc_gpu() {
    # Try ROCm (AMD)
    if command -v rocm-smi >/dev/null 2>&1; then
        D_GPU_DRIVER="rocm"
        local _raw_gfx; _raw_gfx=$(rocminfo 2>/dev/null \
            | grep -i "gfx" | head -1 | grep -o 'gfx[0-9a-f]*' || echo "unknown")
        # Config override takes priority; otherwise auto-fix Strix Halo: rocminfo reports
        # gfx1100 for this die family but the real ID is gfx1151. Set ZMENU_GPU_GFX_OVERRIDE
        # in ~/.zmenu/config if you need a different value.
        if [[ -n "${ZMENU_GPU_GFX_OVERRIDE:-}" ]]; then
            D_GPU_GFX="$ZMENU_GPU_GFX_OVERRIDE"
        elif [[ "$_raw_gfx" == "gfx1100" ]]; then
            D_GPU_GFX="gfx1151"  # Strix Halo: rocminfo bug — real die is gfx1151
        else
            D_GPU_GFX="$_raw_gfx"
        fi
        D_GPU_TEMP=$(rocm-smi --showtemp 2>/dev/null \
            | awk '/GPU\[0\]/{print $NF}' | head -1 || echo "?")
        D_GPU_USE=$(rocm-smi --showuse 2>/dev/null \
            | awk '/GPU\[0\]/{print $NF}' | head -1 || echo "?")
        # VRAM info
        local vram_out
        vram_out=$(rocm-smi --showmeminfo vram 2>/dev/null || true)
        D_GPU_VRAM_USED=$(echo "$vram_out" | awk '/Used/{gsub(/[^0-9]/,"",$NF); print $NF}' | head -1 || echo "")
        D_GPU_VRAM_TOTAL=$(echo "$vram_out" | awk '/Total/{gsub(/[^0-9]/,"",$NF); print $NF}' | head -1 || echo "")
        return
    fi
    # Try Nvidia
    if command -v nvidia-smi >/dev/null 2>&1; then
        D_GPU_DRIVER="nvidia"
        D_GPU_TEMP=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "?")
        D_GPU_USE=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1 || echo "?")
        D_GPU_GFX=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
        return
    fi
    # Fallback: AMD sysfs
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

# ── Systemd services ───────────────────────────────────────
_disc_services() {
    local units
    units=$(systemctl list-units --type=service --state=active \
        --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' || true)
    local keywords=("ollama" "docker" "n8n" "lmstudio" "rocm" "amd" "containerd" "open-webui" "zenny")
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
        | awk 'NR>1 {n=split($4,a,":"); p=a[n]; if(p~/^[0-9]+$/) print p":"$6}' \
        | sort -t: -k1 -n || true)
}

# ── Select backend and active model ───────────────────────
# ── Pick best Zenny model for inline chat ─────────────────
# Uses ZMENU_ZENNY_CHAT_MODEL if set and valid, otherwise prefers
# the smallest model (9B > 7B > flash > anything) over large ones.
_zenny_pick_chat_model() {
    # 1. User-configured preference
    if [[ -n "${ZMENU_ZENNY_CHAT_MODEL:-}" ]]; then
        for k in "${D_ZENNY_KEYS[@]}"; do
            [[ "$k" == "$ZMENU_ZENNY_CHAT_MODEL" ]] && { echo "$k"; return; }
        done
    fi
    # 2. Auto-pick: prefer keys that look like small/fast models
    local small_patterns=("9b" "7b" "8b" "flash" "mini" "tiny" "q4")
    for pat in "${small_patterns[@]}"; do
        for k in "${D_ZENNY_KEYS[@]}"; do
            local kl="${k,,}"   # lowercase
            [[ "$kl" == *"$pat"* ]] && { echo "$k"; return; }
        done
    done
    # 3. Fall back to first available
    echo "${D_ZENNY_KEYS[0]:-}"
}

# Sets AI_BACKEND_ACTIVE, AI_BACKEND_LABEL, ZMENU_AI_MODEL
_sel_ai_backend() {
    local want="${ZMENU_AI_BACKEND:-auto}"
    AI_BACKEND_ACTIVE="none"
    AI_BACKEND_LABEL="none"

    case "$want" in
        zenny)
            if [[ "$D_ZENNY_RUNNING" == true && ${#D_ZENNY_KEYS[@]} -gt 0 ]]; then
                AI_BACKEND_ACTIVE="zenny"
                AI_BACKEND_LABEL="Zenny-Core"
                ZMENU_AI_MODEL="$(_zenny_pick_chat_model)"
            fi ;;
        opencode)
            if _opencode_available; then
                AI_BACKEND_ACTIVE="opencode"
                AI_BACKEND_LABEL="OpenCode (TUI)"
                ZMENU_AI_MODEL="opencode"
            fi ;;
        ollama)
            if [[ "$D_OLLAMA_RUNNING" == true ]]; then
                AI_BACKEND_ACTIVE="ollama"
                AI_BACKEND_LABEL="Ollama (legacy)"
                ZMENU_AI_MODEL="${D_OLLAMA_MODELS[0]:-none}"
            fi ;;
        auto|*)
            # Priority: Zenny → Ollama → none
            if [[ "$D_ZENNY_RUNNING" == true && ${#D_ZENNY_KEYS[@]} -gt 0 ]]; then
                AI_BACKEND_ACTIVE="zenny"
                AI_BACKEND_LABEL="Zenny-Core (auto)"
                ZMENU_AI_MODEL="$(_zenny_pick_chat_model)"
            elif [[ "$D_OLLAMA_RUNNING" == true && ${#D_OLLAMA_MODELS[@]} -gt 0 ]]; then
                AI_BACKEND_ACTIVE="ollama"
                AI_BACKEND_LABEL="Ollama (auto)"
                ZMENU_AI_MODEL="${D_OLLAMA_MODELS[0]}"
            fi ;;
    esac
}

# Keep old name as alias for any external calls
_sel_ai_model() { _sel_ai_backend; }

# ============================================================
#  SECTION 3 — CONTEXT GENERATOR
# ============================================================

context_generate() {
    {
        echo "# Z-Menu Live System Context"
        echo "> Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""

        echo "## Machine"
        echo '```'
        echo "CPU: ${D_CPU_MODEL} (${D_CPU_CORES} threads)"
        echo "Governor: ${D_CPU_GOVERNOR}"
        free -h | awk '/^Mem/{printf "RAM: %s total, %s used, %s free\n",$2,$3,$7}'
        free -h | awk '/^Swap/{printf "Swap: %s total, %s used\n",$2,$3}'
        df -h / | awk 'NR==2{printf "Disk: %s used / %s total (%s full, %s free)\n",$3,$2,$5,$4}'
        awk '{printf "Load: %s %s %s\n",$1,$2,$3}' /proc/loadavg
        uptime -p 2>/dev/null || true
        echo '```'
        echo ""

        echo "## AI Inference Stack"
        echo '```'
        if [[ "$D_ZENNY_RUNNING" == true ]]; then
            echo "Zenny-Core: RUNNING (PID ${D_ZENNY_PID:-?})"
            echo "Socket: ${D_ZENNY_SOCKET}"
            echo "Models available:"
            local zenny_full
            zenny_full=$(_zenny_send '{"cmd":"list_models"}' 2>/dev/null || echo "")
            if [[ -n "$zenny_full" ]]; then
                echo "$zenny_full" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    for m in d.get('models',[]):
        dn=m.get('display_name','?')
        sz=m.get('size_bytes',0)/(1024**3)
        tags=','.join(m.get('tags',[])) or 'general'
        print(f'  - {dn}  ({sz:.1f}G, {tags})')
except: pass
" 2>/dev/null || for m in "${D_ZENNY_MODELS[@]}"; do echo "  - $m"; done
            else
                for m in "${D_ZENNY_MODELS[@]}"; do echo "  - $m"; done
            fi
        else
            echo "Zenny-Core: STOPPED"
        fi
        echo ""
        if [[ "$D_OLLAMA_RUNNING" == true ]]; then
            echo "Ollama: RUNNING at ${D_OLLAMA_URL}  (WARNING: should be disabled)"
        else
            echo "Ollama: STOPPED (disabled — use Zenny-Core)"
        fi
        echo ""
        if [[ "$D_LMS_RUNNING" == true ]]; then
            echo "LM Studio: RUNNING at ${D_LMS_URL} (download tool only)"
            for m in "${D_LMS_MODELS[@]}"; do echo "  - $m"; done
        else
            echo "LM Studio: not running (download tool — inference via Zenny-Core)"
        fi
        echo ""
        echo "Selected model: ${ZMENU_AI_MODEL}"
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
# ============================================================

OWUI_PORT="${OWUI_PORT:-3000}"
OWUI_URL="http://localhost:${OWUI_PORT}"

OPENCODE_BIN="${HOME}/.opencode/bin/opencode"
OPENCODE_PROCESS="opencode"
OPENCODE_CFG="${HOME}/.config/opencode"

ZENNY_BINARY="${HOME}/.local/bin/zenny-core"
ZENNY_PROCESS="zenny-core"
ZENNY_LOG="/tmp/zenny-core.log"

owui_check() {
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "open-webui"; then
        echo -e "  ${WARN}  Open WebUI container not running"
        return 1
    fi
    if ! curl -sf "${OWUI_URL}" >/dev/null 2>&1; then
        echo -e "  ${WARN}  Open WebUI not reachable on ${OWUI_URL}"
        return 1
    fi
    return 0
}

_opencode_available() {
    command -v opencode >/dev/null 2>&1 || [[ -x "${OPENCODE_BIN}" ]]
}

_opencode_cmd() {
    if command -v opencode >/dev/null 2>&1; then
        echo "opencode"
    elif [[ -x "${OPENCODE_BIN}" ]]; then
        echo "${OPENCODE_BIN}"
    else
        echo ""
    fi
}

_build_context_prompt() {
    local role_prompt="${1:-}"
    local context=""
    context_generate
    context="$(cat "$ZMENU_CONTEXT_FILE" 2>/dev/null)"
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

# _cc_write_rules — writes context into opencode's rules file for the session
# OpenCode auto-loads ~/.config/opencode/rules.md as persistent instructions
_cc_write_rules() {
    local context="$1"
    local rules_dir="${OPENCODE_CFG}"
    mkdir -p "$rules_dir"
    printf '%s' "$context" > "${rules_dir}/rules.md"
}

# ============================================================
#  AI BACKEND ADAPTERS
#  Each adapter takes (sys_prompt, hist_file) and prints response.
#  hist_file is a JSON array: [{"role":"user","content":"..."},...]
# ============================================================

_ai_call_zenny() {
    local sys_prompt="$1"
    local hist_file="$2"
    # Use registry key for inference (not display name)
    local model="${ZMENU_AI_MODEL:-}"
    [[ -z "$model" && ${#D_ZENNY_KEYS[@]} -gt 0 ]] && model="${D_ZENNY_KEYS[0]}"
    [[ -z "$model" ]] && { echo "[error: no Zenny model available — load one first]"; return 1; }
    timeout 180 python3 - <<PYEOF 2>/dev/null
import socket, json, sys

hist_file = "${hist_file}"
model     = "${model}"
# sys_prompt passed inline via heredoc expansion
sys_prompt = r"""${sys_prompt}"""

try:
    hist = json.load(open(hist_file))
except Exception:
    hist = []

# Zenny protocol: system + user only (no messages array)
# Flatten history into user field as a conversation transcript
current_msg = hist[-1]["content"] if hist and hist[-1]["role"] == "user" else ""
prior = [m for m in hist[:-1]] if len(hist) > 1 else []

if prior:
    lines = []
    for m in prior:
        role = "User" if m["role"] == "user" else "Assistant"
        lines.append(f"{role}: {m['content']}")
    user_field = "Prior conversation:\n" + "\n".join(lines) + "\n\nCurrent message: " + current_msg
else:
    user_field = current_msg

payload = json.dumps({
    "model": model,
    "system": sys_prompt,
    "user": user_field,
    "max_tokens": 2048,
    "temperature": 0.3,
    "stream": False
}) + "\n"

try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(175)
    s.connect("${D_ZENNY_SOCKET}")
    s.sendall(payload.encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(16384)
        if not chunk:
            break
        buf += chunk
    s.close()
    d = json.loads(buf.decode().strip())
    err = d.get("error")
    if err:
        if "space" in err.lower() or "context" in err.lower() or "kv" in err.lower():
            print(f"[Model context window too small: {err}. Try Settings → AI Backend → select a smaller model for chat]", end="")
        else:
            print(f"[error: {err}]", end="")
    else:
        import re
        content = d.get("content", "[no content field in response]")
        # Strip Qwen3 chain-of-thought — handle closed AND unclosed blocks
        # (unclosed = model hit max_tokens before finishing the think phase)
        content = re.sub(r'<think>.*?</think>', '', content, flags=re.DOTALL)
        content = re.sub(r'<think>.*$', '', content, flags=re.DOTALL)
        content = content.strip()
        if not content:
            content = "[model hit token limit during thinking — try a shorter prompt or switch to a faster model in Settings → AI Backend]"
        print(content, end="")
except Exception as e:
    print(f"[error: {e}]", end="")
PYEOF
}


_ai_call_ollama() {
    local sys_prompt="$1"
    local hist_file="$2"
    local _ctx="${ZMENU_AI_CONTEXT_LENGTH:-8192}"
    local _ictx=$(( _ctx < 16384 ? 16384 : _ctx ))
    [[ "$D_OLLAMA_RUNNING" != true ]] && { echo "[error: Ollama not running]"; return 1; }
    python3 -c "
import json,sys,urllib.request
hf,sp,url,model,ctx=sys.argv[1:]
h=json.load(open(hf))
msgs=[{'role':'system','content':sp}]+h
payload=json.dumps({'model':model,'messages':msgs,
    'options':{'num_ctx':int(ctx)},'stream':False}).encode()
req=urllib.request.Request(url+'/api/chat',data=payload,
    headers={'Content-Type':'application/json'})
try:
    with urllib.request.urlopen(req,timeout=180) as r:
        d=json.loads(r.read())
        print(d.get('message',{}).get('content',''),end='')
except Exception as e:
    print(f'[error: {e}]',end='')
" "$hist_file" "$sys_prompt" "${D_OLLAMA_URL}" "${ZMENU_AI_MODEL}" "${_ictx}" 2>/dev/null
}

# ── Router — dispatches to the active backend ─────────────
_ai_call() {
    local sys_prompt="$1"
    local hist_file="$2"
    case "${AI_BACKEND_ACTIVE:-none}" in
        zenny)    _ai_call_zenny  "$sys_prompt" "$hist_file" ;;
        ollama)   _ai_call_ollama "$sys_prompt" "$hist_file" ;;
        opencode)
            echo "[OpenCode is TUI-only — use AI Engine → AI Session for a full session]"
            ;;
        none|*)
            echo "[No AI backend available — go to Settings → AI Backend to configure one]"
            ;;
    esac
}

cc_launch() {
    # cc_launch "Title" "role prompt" ["/optional/workdir"] [--tui|--run]
    local title="${1:-Local AI}"
    local prompt="${2:-}"
    local workdir="${3:-$HOME}"
    local mode="${4:---tui}"   # --tui = interactive, --run = headless one-shot

    # Resolve workdir: if 3rd arg starts with -- it's the mode, not a dir
    if [[ "$workdir" == --* ]]; then
        mode="$workdir"
        workdir="$HOME"
    fi

    local oc_cmd
    oc_cmd="$(_opencode_cmd)"

    if [[ -z "$oc_cmd" ]]; then
        echo -e "  ${FAIL}  OpenCode not found at ${OPENCODE_BIN}"
        echo -e "  ${DIM}  Install: curl -fsSL https://opencode.ai/install | bash${NC}"
        return 1
    fi

    echo "  Generating live system context..."
    context_generate
    echo -e "  ${OK}  Context ready → ${ZMENU_CONTEXT_FILE}"

    local full_context
    full_context="$(_build_context_prompt "$prompt")"

    # Write context into opencode rules so it's injected automatically
    _cc_write_rules "$full_context"

    local session_file="/tmp/zmenu-session-$(date +%s).md"
    printf '%s' "$full_context" > "$session_file"
    echo -e "  ${OK}  Context injected → ${OPENCODE_CFG}/rules.md"
    echo ""
    echo -e "  ${BCYN}${title}${NC}"
    echo -e "  ${DIM}Model: ${ZMENU_AI_MODEL}  ·  workdir: ${workdir}${NC}"
    echo ""

    if [[ "$mode" == "--run" ]]; then
        # Non-interactive: run the role prompt as the message, stream output
        echo -e "  ${DIM}Running headless query...${NC}"
        echo ""
        (cd "$workdir" && "$oc_cmd" run "$prompt") 2>/dev/null || \
            echo -e "  ${WARN}  OpenCode returned non-zero — check model/config"
    else
        # Interactive TUI — hand off terminal to opencode
        echo -e "  ${DIM}Launching OpenCode TUI... (q or Ctrl+C to exit back to zmenu)${NC}"
        sleep 0.5
        (cd "$workdir" && "$oc_cmd") || true
        # Restore zmenu header after TUI exits
        echo ""
        echo -e "  ${OK}  OpenCode session ended — returning to zmenu"
    fi
}

# _cc_inline - Tier 1 inline chat assistant
# Header stays visible. Context built dynamically by calling _ctx_fn.
# Usage: _cc_inline "Section Title" _ctx_fn_name [_apply_fn_name]
#   _ctx_fn   — function that prints live section context to stdout
#   _apply_fn — function called with last AI response when user types "apply"
_cc_inline() {
    local section_title="${1:-Assistant}"
    local ctx_fn="${2:-}"
    local apply_fn="${3:-}"

    if [[ "${AI_BACKEND_ACTIVE:-none}" == "none" ]]; then
        echo -e "  ${FAIL}  No AI backend available"
        echo -e "  ${DIM}  Go to Settings → AI Backend to configure one${NC}"
        return 1
    fi
    if [[ "${AI_BACKEND_ACTIVE:-none}" == "opencode" ]]; then
        echo -e "  ${WARN}  AI backend is set to OpenCode, but Ask AI requires Zenny-Core."
        echo -e "  ${DIM}  Go to Settings → l) AI Backend and switch to 'zenny'.${NC}"
        sleep 2
        return 1
    fi

    # Build scoped context — prefer pre-built wiki (fast), fall back to live ctx_fn
    local scoped_context=""
    local _wiki_file; _wiki_file="$(_wiki_path "$section_title")"
    if [[ -f "$_wiki_file" ]]; then
        ( _wiki_fast_refresh ) 2>/dev/null || true
        scoped_context="$(cat "$_wiki_file")"
        if [[ -f "${ZMENU_WIKI_DIR}/changes.md" ]] && \
           [[ "$(wc -l < "${ZMENU_WIKI_DIR}/changes.md")" -gt 3 ]]; then
            scoped_context+="

## Recent Applied Changes
$(grep -A3 '^## ' "${ZMENU_WIKI_DIR}/changes.md" | tail -30)"
        fi
    elif [[ -n "$ctx_fn" ]] && declare -f "$ctx_fn" >/dev/null 2>&1; then
        scoped_context="$("$ctx_fn")"
    fi

    # Build full system prompt — hardware facts FIRST so they are never
    # truncated even with small context windows, then scoped context
    local _gpu_gfx="${D_GPU_GFX:-unknown}"
    local _gpu_temp="${D_GPU_TEMP:-?}"
    local _gpu_use="${D_GPU_USE:-?}"
    local _mem_total="${D_MEM_TOTAL_MB:-?}"
    local _mem_used="${D_MEM_USED_MB:-?}"
    local _npu_driver="${D_NPU_DRIVER:-unknown}"
    local _npu_device="${D_NPU_DEVICE:-unknown}"
    local _hsa="${HSA_OVERRIDE_GFX_VERSION:-not set}"
    local _machine="${ZMENU_MACHINE_LABEL:-$(hostname 2>/dev/null || echo 'this machine')}"
    local _os; _os=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}" || uname -sr)

    local sys_prompt
    sys_prompt="## MACHINE FACTS — read these first, do not contradict them
Machine:        ${_machine} — ${_os}
CPU:            ${D_CPU_MODEL:-unknown} (${D_CPU_CORES:-?} cores, x86_64)
RAM:            ${_mem_total} MB — unified pool (GPU+CPU share this)
GPU:            ${_gpu_gfx}  driver: ${D_GPU_DRIVER:-unknown}
GPU-volatile:   temp: ${_gpu_temp}°C  util: ${_gpu_use}%
NPU:            ${_npu_driver}  ${_npu_device}
AI backend:     ${AI_BACKEND_LABEL}  (model: ${ZMENU_AI_MODEL:-auto})
RAM used:       ${_mem_used} MB of ${_mem_total} MB

## Section: ${section_title}

${scoped_context}

---
## Your role
You are an expert assistant embedded in the zmenu sovereign dashboard
on this specific machine. The facts above are ground truth — never
contradict them or suggest alternatives already present.
Be concise and direct. Give exact copy-paste commands.
When the user types 'apply', the last suggestion has been run —
acknowledge it and advise what to check next.

## Rules for reading command output
- In 'ls -la' output, the number in column 2 of directory entries is the HARD LINK COUNT, not a file count. The file count is the number of non-. and non-.. lines shown.
- 'systemctl ... active exited' means a oneshot/forking service ran and completed — it does NOT mean the service is currently running a process. Always check 'is-active' of the specific instance (e.g. openvpn@<name>.service) not the umbrella.
- Do not re-interpret output that was already shown earlier in the conversation. If the user sends a blank message or just presses enter, ask what they want to do next rather than repeating prior output."

    local last_ai_response=""
    local hist_file; hist_file="/tmp/zmenu-chat-$(date +%s).json"
    printf '[]' > "$hist_file"

    _cc_inline_header "$section_title" "$scoped_context"
    echo -e "  ${DIM}Type your message  |  q=exit  |  apply=run last suggestion now${NC}"
    echo ""

    while true; do
        printf '%b  You: %b' "${BCYN}" "${NC}"
        local user_input=""
        IFS= read -r user_input || break

        [[ "$user_input" == "q" || "$user_input" == "quit" ]] && break
        [[ -z "$user_input" ]] && continue

        # Apply last suggestion immediately, no confirmation
        if [[ "$user_input" == "apply" || "$user_input" == "apply that" ]]; then
            echo ""
            if [[ -n "$apply_fn" ]] && declare -f "$apply_fn" >/dev/null 2>&1; then
                echo -e "  ${BCYN}✦ Applying...${NC}"
                "$apply_fn" "$last_ai_response"
                echo -e "  ${OK}  Applied."
            else
                echo -e "  ${WARN}  No auto-apply for this section — copy from above."
                printf '%s\n' "$last_ai_response" > /tmp/zmenu-ai-apply.txt
                echo -e "  ${DIM}  Also saved → /tmp/zmenu-ai-apply.txt${NC}"
            fi
            echo ""
            continue
        fi

        # Append user turn to history file
        python3 -c "
import json,sys
hf=sys.argv[1]; msg=sys.argv[2]
h=json.load(open(hf))
h.append({'role':'user','content':msg})
json.dump(h,open(hf,'w'))
" "$hist_file" "$user_input" 2>/dev/null

        echo ""
        echo -e "  ${DIM}Thinking... [${AI_BACKEND_LABEL}]${NC}"

        # Route to active backend
        local ai_response=""
        ai_response=$(_ai_call "$sys_prompt" "$hist_file")

        # Erase "Thinking..." line, print response
        printf '\033[1A\033[2K'
        printf '%b  ✦ AI:%b\n' "${BGRN}" "${NC}"
        printf '%s\n' "$ai_response" | fold -s -w 70 | sed 's/^/     /'
        echo ""

        last_ai_response="$ai_response"

        # Append AI turn to history file
        python3 -c "
import json,sys
hf=sys.argv[1]; msg=sys.argv[2]
h=json.load(open(hf))
h.append({'role':'assistant','content':msg})
json.dump(h,open(hf,'w'))
" "$hist_file" "$ai_response" 2>/dev/null
    done

    rm -f "$hist_file"
    echo ""
    echo -e "  ${DIM}Exiting assistant — returning to menu${NC}"
    sleep 0.3
}

# _cc_inline_header — persistent zmenu header + assistant context bar
_cc_inline_header() {
    local section_title="$1"
    local context_summary="$2"
    clear
    printf '\033[1;34m'
    echo "  ┌─────────────────────────────────────────────────────────┐"
    printf "  │  ▲  Z-MENU  v%-6s  ·  LOCAL SOVEREIGN                │\n" "$ZMENU_VERSION"
    echo "  └─────────────────────────────────────────────────────────┘"
    printf '\033[0m\n'
    echo -e "${BCYN}┄ ✦ AI ASSISTANT  ·  ${section_title}${NC}"
    echo ""
    if [[ -n "$context_summary" ]]; then
        # Show first 6 lines of live context as a readable summary
        echo -e "  ${DIM}Live context:${NC}"
        printf '%s\n' "$context_summary" | head -8 | sed 's/^/    /'
        echo ""
    fi
    echo -e "  ${DIM}Backend: ${AI_BACKEND_LABEL}  ·  model: ${ZMENU_AI_MODEL}  ·  q=exit  apply=run suggestion${NC}"
    echo -e "  ${DIM}────────────────────────────────────────────────────────${NC}"
    echo ""
}


# ============================================================
#  SECTION 4b — INLINE AI CONTEXT FUNCTIONS
#  Each _ctx_* function prints live section state to stdout.
#  Each _apply_* function parses AI response and applies changes.
# ============================================================

# ── Find Problems context ─────────────────────────────────
_ctx_find_problems() {
    printf "Section focus: full system bottleneck analysis\n\n"
    printf "CPU governor:    %s\n" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
    printf "CPU boost:       %s\n" "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo '?')"
    printf "AMD P-State:     %s\n" "$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo 'not found')"
    printf "Load average:    %s\n" "$(cat /proc/loadavg 2>/dev/null)"
    printf "RAM used:        %s / %s MB (%s%%)\n" "$D_MEM_USED_MB" "$D_MEM_TOTAL_MB" "$(( D_MEM_USED_MB * 100 / (D_MEM_TOTAL_MB+1) ))"
    printf "Swap used:       %s MB\n" "$D_SWAP_USED_MB"
    printf "vm.swappiness:   %s\n" "$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
    printf "inotify watches: %s\n" "$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo '?')"
    printf "THP:             %s\n" "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')"
    printf "GPU driver:      %s\n" "$D_GPU_DRIVER"
    printf "GPU temp:        %s°C  utilisation: %s%%\n" "${D_GPU_TEMP:-?}" "${D_GPU_USE:-?}"
    printf "Disk used:       %s\n" "$(df -h / 2>/dev/null | awk 'NR==2{print $5" of "$2}')"
    local sched; sched=$(lsblk -ndo NAME "$(findmnt -no SOURCE /)" 2>/dev/null)
    [[ -n "$sched" ]] && printf "I/O scheduler:   %s\n" "$(cat /sys/block/${sched}/queue/scheduler 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')"
    printf "Docker:          %s container(s)\n" "${#D_CONTAINERS[@]}"
    printf "Ollama:          %s  model: %s\n" "$(${D_OLLAMA_RUNNING} && echo 'running' || echo 'stopped')" "${D_OLLAMA_ACTIVE_MODEL:-none}"
}

# ── Generic apply engine ─────────────────────────────────
# Extracts commands from AI response and runs them.
# Allowlisted command prefixes — only these may be run via apply.
# Add new prefixes here rather than loosening the check elsewhere.
_APPLY_ALLOWED_PREFIXES=(
    sudo systemctl sysctl docker
    pkill kill killall
    apt apt-get snap
    mkdir rm cp mv chmod chown ln
    tee cat echo printf
    export unset
    python3 pip pip3
    curl wget
    powerprofilesctl cpupower
    journalctl dmesg
    git
    sed awk
)

# Extract and run AI-suggested commands safely.
# Priority: fenced code blocks (```...```) → bare allowlisted lines.
# Usage: _apply_generic "$ai_text" "Section Name"
_apply_generic() {
    local ai_text="$1"
    local section="${2:-General}"
    local cmds=""

    # Primary: extract all lines inside ``` fenced blocks
    cmds=$(printf '%s\n' "$ai_text" \
        | awk '/^```/{p=!p; next} p && /[^[:space:]]/{print}' \
        | grep -vE '^[[:space:]]*#' \
        | sed 's/^[[:space:]]*//')

    # Fallback: bare lines whose first word is in the allowlist
    if [[ -z "$cmds" ]]; then
        local prefix_pat
        prefix_pat=$(printf '%s|' "${_APPLY_ALLOWED_PREFIXES[@]}")
        prefix_pat="^[[:space:]]*(${prefix_pat%|}) "
        cmds=$(printf '%s\n' "$ai_text" \
            | grep -E "$prefix_pat" \
            | grep -vE '^[[:space:]]*#' \
            | sed 's/^[[:space:]]*//')
    fi

    if [[ -z "$cmds" ]]; then
        echo -e "  ${WARN}  No runnable commands found — copy from the response above."
        printf '%s\n' "$ai_text" > /tmp/zmenu-ai-apply.txt
        echo -e "  ${DIM}  Saved → /tmp/zmenu-ai-apply.txt${NC}"
        return 1
    fi

    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue

        # ── Safety checks — block commands that would kill zmenu,
        #    the shell, or cause duplicate daemon instances.
        local _blocked=false
        local _block_reason=""
        # Kill zmenu or the current shell
        if printf '%s' "$cmd" | grep -qE "(pkill|killall|kill)[[:space:]].*zmenu"; then
            _blocked=true; _block_reason="would kill zmenu itself"
        fi
        if printf '%s' "$cmd" | grep -qE "(pkill|killall)[[:space:]].*bash"; then
            _blocked=true; _block_reason="would kill the shell"
        fi
        # Directly launching Zenny-Core as a daemon (causes duplicate instances)
        if printf '%s' "$cmd" | grep -qE "${ZENNY_PROCESS}[[:space:]]*&|${ZENNY_PROCESS}[[:space:]]*\$"; then
            _blocked=true; _block_reason="would start a duplicate Zenny-Core — use AI Engine → Start"
        fi
        # Re-launching zmenu inside apply (infinite nesting)
        if printf '%s' "$cmd" | grep -qE "^[[:space:]]*(zmenu|${ZMENU_INSTALL_PATH})[[:space:]]*\$"; then
            _blocked=true; _block_reason="cannot re-launch zmenu from inside zmenu"
        fi
        # Destructive rm
        if printf '%s' "$cmd" | grep -qE "rm[[:space:]]+-[a-z]*r[a-z]*f[[:space:]]+/"; then
            _blocked=true; _block_reason="destructive recursive rm on root path"
        fi

        if $_blocked; then
            echo -e "  ${FAIL}  BLOCKED: ${cmd}"
            echo -e "  ${DIM}  Reason: ${_block_reason}${NC}"
            _wiki_log_change "$section" "$cmd" "BLOCKED — ${_block_reason}"
            continue
        fi

        echo -e "  ${DIM}Running: ${cmd}${NC}"
        if eval "$cmd" 2>/dev/null; then
            echo -e "  ${OK}  OK"
            _wiki_log_change "$section" "$cmd" "OK"
        else
            echo -e "  ${WARN}  Non-zero: ${cmd}"
            _wiki_log_change "$section" "$cmd" "FAIL"
        fi
    done <<< "$cmds"
}

# Section-specific wrappers (pass section name for wiki log)
_apply_find_problems()  { _apply_generic "$1" "Find Problems"; }
_apply_hardware()       { _apply_generic "$1" "Hardware"; }
_apply_apps_services()  { _apply_generic "$1" "Apps & Services"; }
_apply_maintenance()    { _apply_generic "$1" "Maintenance"; }
_apply_opencode() {
    local ai_text="$1"
    # If the AI response says to stop/kill opencode, use the verified stop function
    if printf '%s\n' "$ai_text" | grep -qiE 'pkill|kill|stop.*opencode|opencode.*stop'; then
        _opencode_stop
    else
        _apply_generic "$ai_text" "OpenCode"
    fi
}

# Stop OpenCode with SIGTERM, verify exit, escalate to SIGKILL if needed.
_opencode_stop() {
    if ! pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
        echo -e "  ${IDLE}  OpenCode is not running"
        return 0
    fi
    local pid; pid=$(pgrep -x "$OPENCODE_PROCESS" | head -1)
    echo "  Stopping OpenCode (PID ${pid})..."
    pkill -x "$OPENCODE_PROCESS" 2>/dev/null || true
    local i=0
    while pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1 && [[ $i -lt 10 ]]; do
        sleep 0.3; i=$((i + 1))
    done
    if pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
        echo -e "  ${WARN}  SIGTERM ignored — sending SIGKILL..."
        pkill -9 -x "$OPENCODE_PROCESS" 2>/dev/null || true
        sleep 0.5
    fi
    if pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
        echo -e "  ${FAIL}  OpenCode still running — check: pgrep $OPENCODE_PROCESS"
        _wiki_log_change "OpenCode" "pkill $OPENCODE_PROCESS" "FAIL — still running"
    else
        echo -e "  ${OK}  OpenCode stopped"
        _wiki_log_change "OpenCode" "pkill $OPENCODE_PROCESS" "OK"
    fi
}
_apply_ai_engine()      { _apply_generic "$1" "AI Engine"; }

# ── AI Engine context ─────────────────────────────────────
_ctx_ai_engine() {
    printf "Section focus: AI stack health and configuration\n\n"
    printf "Zenny-Core:      %s\n" "$(${D_ZENNY_RUNNING} && echo "running (PID ${D_ZENNY_PID:-?})  socket: ${D_ZENNY_SOCKET}" || echo 'stopped')"
    printf "Zenny models:    %s\n" "${#D_ZENNY_MODELS[@]}"
    for m in "${D_ZENNY_MODELS[@]}"; do printf "  - %s\n" "$m"; done
    if [[ "$D_ZENNY_RUNNING" == true ]]; then
        local stats_resp; stats_resp=$(_zenny_send '{"cmd":"stats"}' 2>/dev/null || echo "")
        if [[ -n "$stats_resp" ]]; then
            printf "Loaded models (tok/s):\n"
            echo "$stats_resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    for m in d.get('models',[]):
        print(f'  {m.get(\"name\",\"?\")}  {m.get(\"tok_s\",0):.0f} tok/s')
except: pass
" 2>/dev/null
        fi
    fi
    printf "\nGPU driver:      %s  (Vulkan backend)\n" "$D_GPU_DRIVER"
    printf "GPU:             %s\n" "${D_GPU_GFX:-?}"
    printf "Memory pool:     %s MB total (unified — GPU shares with RAM)\n" "$D_MEM_TOTAL_MB"
    printf "\nOllama:          %s\n" "$(${D_OLLAMA_RUNNING} && echo "RUNNING (WARNING: should be disabled)" || echo 'stopped (disabled)')"
    printf "\nOpenCode:        %s\n" "$(pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1 && echo "RUNNING (pid: $(pgrep -x "$OPENCODE_PROCESS" | head -1))" || (_opencode_available && echo "installed (not running)" || echo 'not installed'))"
    printf "Open WebUI:      %s\n" "$(curl -sf "${OWUI_URL}" >/dev/null 2>&1 && echo "running at ${OWUI_URL}" || echo 'not running')"
    printf "LM Studio:       %s\n" "$(${D_LMS_RUNNING} && echo "running at ${D_LMS_URL} (download only)" || echo 'off')"
}

# ── OpenCode context ──────────────────────────────────────
_ctx_opencode() {
    printf "Section focus: OpenCode coding agent configuration\n\n"
    local oc_cmd; oc_cmd="$(_opencode_cmd)"
    printf "OpenCode binary: %s\n" "${oc_cmd:-not installed}"
    printf "Version:         %s\n" "$([[ -n "$oc_cmd" ]] && "$oc_cmd" --version 2>/dev/null || echo 'N/A')"
    printf "\nopencode.json:\n"
    cat "${OPENCODE_CFG}/opencode.json" 2>/dev/null | sed 's/^/  /' || printf "  (not configured)\n"
    printf "\nrules.md (last zmenu context injection):\n"
    head -5 "${OPENCODE_CFG}/rules.md" 2>/dev/null | sed 's/^/  /' || printf "  (none)\n"
    printf "\nOllama models available for coding:\n"
    for m in "${D_OLLAMA_MODELS[@]}"; do
        printf "  %s\n" "$m"
    done
    printf "\nZed ACP config:\n"
    cat "${HOME}/.config/zed/settings.json" 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    srv=d.get('agent_servers',{})
    for k,v in srv.items(): print(f'  {k}: {v.get(\"command\",\"?\")}')
except: print('  (not configured)')
" 2>/dev/null
}

# ── Ollama Settings context ───────────────────────────────
_ctx_ollama_settings() {
    printf "Section focus: Ollama systemd environment and performance tuning\n\n"
    printf "Active model:    %s\n" "${D_OLLAMA_ACTIVE_MODEL:-none}"
    printf "Context window:  %s tokens (zmenu setting)\n" "$ZMENU_AI_CONTEXT_LENGTH"
    printf "Ollama version:  %s\n" "${D_AI_VER:-?}"
    printf "\nSystemd override (%s):\n" "/etc/systemd/system/ollama.service.d/override.conf"
    sudo cat /etc/systemd/system/ollama.service.d/override.conf 2>/dev/null | grep Environment | sed 's/^/  /' || printf "  (no overrides)\n"
    printf "\nLive env (what Ollama is actually running with):\n"
    sudo systemctl show ollama --property=Environment 2>/dev/null \
        | tr ' ' '\n' | grep '=' | grep -v '^$' | sed 's/^/  /' || printf "  (cannot read)\n"
    printf "\nMemory:\n"
    printf "  Total pool:    %s MB\n" "$D_MEM_TOTAL_MB"
    printf "  Currently used:%s MB (%s%%)\n" "$D_MEM_USED_MB" "$(( D_MEM_USED_MB * 100 / (D_MEM_TOTAL_MB+1) ))"
    if ${D_OLLAMA_RUNNING}; then
        local ps_json; ps_json=$(curl -sf "${D_OLLAMA_URL}/api/ps" 2>/dev/null || echo '{}')
        python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1])
    for m in d.get('models',[]):
        sz=m.get('size_vram',0)/(1024**3)
        print(f'  Model VRAM:    {sz:.1f} GB  ({m[\"name\"]})')
except: pass
" "$ps_json" 2>/dev/null
    fi
    printf "\nGPU: %s  %s°C  %s%% util\n" "$D_GPU_GFX" "${D_GPU_TEMP:-?}" "${D_GPU_USE:-?}"
}

_apply_ollama_settings() { _apply_generic "$1" "Ollama Settings"; }

# ── Apps & Services context ───────────────────────────────
_ctx_apps_services() {
    printf "Section focus: Docker containers and running services\n\n"
    printf "Docker:          %s\n" "$(${D_DOCKER_RUNNING} && echo 'running' || echo 'stopped')"
    if ${D_DOCKER_RUNNING}; then
        printf "\nContainers:\n"
        docker ps -a --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || printf "  (none)\n"
        printf "\nDocker disk usage:\n"
        docker system df 2>/dev/null | sed 's/^/  /' || true
    fi
    printf "\nOpen ports:\n"
    for p in "${D_OPEN_PORTS[@]}"; do printf "  %s\n" "$p"; done
    printf "\nKnown service ports:\n"
    printf "  11434 Ollama  3000 Open WebUI  5678 n8n  8080 SearXNG  11235 Crawl4AI\n"
    printf "\nSystemd AI services:\n"
    for s in "${D_SERVICES[@]}"; do
        printf "  %-25s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || echo '?')"
    done
}

# ── Hardware context ──────────────────────────────────────
_ctx_hardware() {
    printf "Section focus: GPU, NPU, thermals, and power profile\n\n"
    printf "GPU:             %s\n" "$D_GPU_GFX"
    printf "GPU driver:      %s\n" "$D_GPU_DRIVER"
    printf "GPU temp:        %s°C\n" "${D_GPU_TEMP:-?}"
    printf "GPU utilisation: %s%%\n" "${D_GPU_USE:-?}"
    printf "NPU driver:      %s\n" "${D_NPU_DRIVER:-none}"
    printf "NPU device:      %s\n" "${D_NPU_DEVICE:-not found}"
    printf "HSA GFX:         %s\n" "${HSA_OVERRIDE_GFX_VERSION:-not set}"
    printf "ROCr devices:    %s\n" "${ROCR_VISIBLE_DEVICES:-not set}"
    printf "\nThermals:\n"
    if command -v sensors >/dev/null 2>&1; then
        sensors 2>/dev/null | grep -E 'Tctl|Tdie|temp|°C' | head -8 | sed 's/^/  /'
    else
        printf "  sensors not installed\n"
    fi
    printf "\nPower profile:   %s\n" "$(powerprofilesctl get 2>/dev/null || cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo '?')"
    printf "CPU governor:    %s\n" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
    printf "CPU boost:       %s\n" "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo '?')"
    printf "AMD P-State:     %s\n" "$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo 'not found')"
    printf "\nCPU load:        %s\n" "$(cat /proc/loadavg 2>/dev/null)"
    printf "Throttle events: %s\n" "$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null || echo '0')"
}

# ── Security & Privacy context ────────────────────────────
_ctx_security() {
    printf "Section focus: security posture, firewall, ports, and privacy\n\n"

    printf "UFW status:\n"
    sudo -n ufw status 2>/dev/null | head -20 | sed 's/^/  /' || printf "  (no passwordless sudo for ufw)\n"

    printf "\nListening ports (pre-interpreted — these are the ONLY open ports):\n"
    ss -tlnp 2>/dev/null | awk '/LISTEN/{print "  "$4}' | head -20 || true

    printf "\nOutbound connections:\n"
    ss -tnp state established 2>/dev/null | awk 'NR>1{print "  "$4" → "$5}' | head -10 || true

    printf "\nFailed SSH logins (last 24h):\n"
    journalctl -u ssh --since "24h ago" 2>/dev/null | grep -c "Failed" | xargs printf "  %s failed attempts\n" || printf "  0\n"

    # ── VPN / tunnel inventory (pre-interpreted) ──────────────
    printf "\nVPN and tunnel tools (installed state — pre-interpreted):\n"
    for _pkg in openvpn wireguard-tools tailscale; do
        if dpkg -l "$_pkg" 2>/dev/null | grep -q '^ii'; then
            local _svc="${_pkg%.service}.service"
            local _enabled; _enabled=$(systemctl is-enabled "$_svc" 2>/dev/null || echo "not-a-unit")
            local _active;  _active=$(systemctl is-active  "$_svc" 2>/dev/null || echo "inactive")
            printf "  %-18s installed  service-enabled:%-12s service-active:%s\n" \
                "$_pkg" "$_enabled" "$_active"
        fi
    done
    # OpenVPN config directory — tell Zenny the actual file counts, not raw ls output
    if dpkg -l openvpn 2>/dev/null | grep -q '^ii'; then
        printf "\n  OpenVPN config detail:\n"
        local _oclient; _oclient=$(ls /etc/openvpn/client/ 2>/dev/null | grep -c '\.conf\|\.ovpn' || echo 0)
        local _oserver; _oserver=$(ls /etc/openvpn/server/ 2>/dev/null | grep -c '\.conf\|\.ovpn' || echo 0)
        printf "    /etc/openvpn/client/: %d .conf/.ovpn files\n" "$_oclient"
        printf "    /etc/openvpn/server/: %d .conf/.ovpn files\n" "$_oserver"
        # Active tunnel instances (openvpn@<name>.service)
        local _tunnels; _tunnels=$(systemctl list-units 'openvpn@*.service' --no-legend 2>/dev/null | grep -c 'active running' || echo 0)
        printf "    Active tunnel instances (openvpn@*.service running): %d\n" "$_tunnels"
        printf "    NOTE: 'openvpn.service active exited' is the Ubuntu umbrella service — normal when no tunnels are active\n"
    fi
    # Tailscale status
    if command -v tailscale >/dev/null 2>&1; then
        printf "\n  Tailscale:\n"
        tailscale status 2>/dev/null | head -5 | sed 's/^/    /' || printf "    (not connected)\n"
    fi

    # ── Non-standard enabled services ─────────────────────────
    printf "\nEnabled services (user-relevant, not core OS):\n"
    systemctl list-unit-files --type=service --state=enabled 2>/dev/null \
        | awk '$1 ~ /\.service$/{print $1}' \
        | grep -Ev '^(systemd|dbus|getty|multipathd|apport|cron|rsyslog|ufw|networkd|resolved|bluetooth|snapd|avahi|cups|gdm|colord|accounts|modem|polkit|wpa|thermald|kerneloops|whoopsie|apt-daily|fwupd|ubuntu-advantage)' \
        | sed 's/^/  /' | head -25 || true

    printf "\nTelemetry opt-outs:\n"
    for v in DO_NOT_TRACK TELEMETRY_DISABLED DOTNET_CLI_TELEMETRY_OPTOUT NEXT_TELEMETRY_DISABLED; do
        printf "  %-35s = %s\n" "$v" "${!v:-NOT SET}"
    done
}

_apply_security() { _apply_generic "$1" "Security"; }

# ── Settings context ──────────────────────────────────────
_ctx_settings() {
    printf "Section focus: zmenu configuration, version management, AI backend settings\n\n"
    printf "zmenu version:    %s\n" "${ZMENU_VERSION}"
    printf "Source:           %s\n" "${ZMENU_SELF}"
    printf "Install path:     %s\n" "${ZMENU_INSTALL_PATH}"
    printf "Config file:      %s\n" "${ZMENU_CONFIG_FILE}"
    printf "AI backend:       %s\n" "${AI_BACKEND_LABEL:-none}"
    printf "AI model:         %s\n" "${ZMENU_AI_MODEL:-auto}"
    printf "\nConfig contents:\n"
    cat "${ZMENU_CONFIG_FILE}" 2>/dev/null | sed 's/^/  /' || printf "  (no config file)\n"
    printf "\nEnvironment:\n"
    printf "  HSA_OVERRIDE_GFX_VERSION=%s\n" "${HSA_OVERRIDE_GFX_VERSION:-NOT SET}"
    printf "  ZENNY_GPU_LAYERS=%s\n"          "${ZENNY_GPU_LAYERS:-not set}"
    printf "\nSovereign wiki: %s files in %s\n" \
        "$(ls "${ZMENU_WIKI_DIR}"/*.md 2>/dev/null | wc -l)" "${ZMENU_WIKI_DIR}"
}
_apply_settings() { _apply_generic "$1" "Settings"; }

# ── Projects context ──────────────────────────────────────
_ctx_projects() {
    printf "Section focus: project directory management and AI session scaffolding\n\n"
    printf "Projects dir:  %s\n" "${ZMENU_PROJECTS_DIR}"
    local count=0
    if [[ -d "$ZMENU_PROJECTS_DIR" ]]; then
        count=$(find "$ZMENU_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    fi
    printf "Project count: %s\n\n" "$count"
    printf "Projects:\n"
    while IFS= read -r -d '' p; do
        local pn; pn=$(basename "$p")
        local badges=""
        [[ -f "${p}/AI.md" ]]                      && badges+=" [has AI.md]"
        [[ -d "${p}/.git" ]]                       && badges+=" [git]"
        [[ -f "${p}/.config/ai/settings.json" ]]   && badges+=" [settings.json]"
        printf "  %-24s%s\n" "$pn" "$badges"
    done < <(find "$ZMENU_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
    printf "\nAI backend: %s  model: %s\n" "${AI_BACKEND_LABEL:-none}" "${ZMENU_AI_MODEL:-auto}"
}
_apply_projects() { _apply_generic "$1" "Projects"; }

# ── Maintenance context ───────────────────────────────────
_ctx_maintenance() {
    printf "Section focus: system maintenance — updates, disk, journals, SMART\n\n"
    printf "Disk usage:\n"
    df -h / /home 2>/dev/null | sed 's/^/  /'
    printf "\nLargest consumers:\n"
    printf "  Ollama models:   %s\n" "$(du -sh "${HOME}/.ollama/models" 2>/dev/null | cut -f1 || echo '?')"
    printf "  LM Studio:       %s\n" "$(du -sh "${HOME}/.lmstudio/models" 2>/dev/null | cut -f1 || echo '?')"
    printf "  Docker:          %s\n" "$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo '?')"
    printf "  Journal:         %s\n" "$(du -sh /var/log/journal 2>/dev/null | cut -f1 || echo '?')"
    printf "  ~/.cache:        %s\n" "$(du -sh "${HOME}/.cache" 2>/dev/null | cut -f1 || echo '?')"
    printf "\nPackages:\n"
    printf "  Upgradeable:     %s\n" "$(apt list --upgradable 2>/dev/null | grep -c upgradable || echo '?')"
    printf "  Security updates:%s\n" "$(apt list --upgradable 2>/dev/null | grep -c security || echo '?')"
    printf "\nJournal errors (last 24h):\n"
    journalctl --since "24h ago" -p err 2>/dev/null | tail -5 | sed 's/^/  /' || printf "  (none)\n"
    printf "\nSMART status (NVMe):\n"
    sudo -n smartctl -H /dev/nvme0 2>/dev/null | grep -E 'result|PASSED|FAILED' | sed 's/^/  /' || printf "  (no passwordless sudo for smartctl)\n"
    printf "\nSwap:\n"
    printf "  Used: %s / %s MB\n" "$D_SWAP_USED_MB" "$D_SWAP_TOTAL_MB"
}

# ============================================================
#  SECTION 4c — SOVEREIGN WIKI
#  Pre-digested markdown knowledge base at ~/.zmenu/wiki/
#  Built at startup, fast-refreshed on each AI chat open.
#  Loaded as context instead of running shell commands live —
#  the AI gets structured facts+history, not raw command output.
# ============================================================

# Map section title → wiki file path
_wiki_path() {
    local s="${1,,}"
    case "$s" in
        hardware*)          printf '%s/hardware.md'      "$ZMENU_WIKI_DIR" ;;
        "apps & services"*) printf '%s/services.md'      "$ZMENU_WIKI_DIR" ;;
        "ai engine"*)       printf '%s/ai-stack.md'      "$ZMENU_WIKI_DIR" ;;
        opencode*)          printf '%s/opencode.md'      "$ZMENU_WIKI_DIR" ;;
        "ollama"*)          printf '%s/ai-stack.md'      "$ZMENU_WIKI_DIR" ;;
        "find problems"*)   printf '%s/find-problems.md' "$ZMENU_WIKI_DIR" ;;
        security*)          printf '%s/security.md'      "$ZMENU_WIKI_DIR" ;;
        maintenance*)       printf '%s/maintenance.md'   "$ZMENU_WIKI_DIR" ;;
        settings*)          printf '%s/settings.md'      "$ZMENU_WIKI_DIR" ;;
        projects*)          printf '%s/projects.md'      "$ZMENU_WIKI_DIR" ;;
        "system scan"*)     printf '%s/system-scan.md'   "$ZMENU_WIKI_DIR" ;;
        packages*)          printf '%s/packages.md'      "$ZMENU_WIKI_DIR" ;;
        *)                  printf '%s/general.md'       "$ZMENU_WIKI_DIR" ;;
    esac
}

# Fast refresh — re-runs lightweight discovery and patches volatile
# lines (temps, RAM, container state) into existing wiki files.
# ~50ms. Called at the start of every _cc_inline session.
_wiki_fast_refresh() {
    [[ ! -d "$ZMENU_WIKI_DIR" ]] && return
    _disc_memory 2>/dev/null
    _disc_gpu    2>/dev/null
    _disc_zenny  2>/dev/null
    _disc_docker 2>/dev/null
    local ts; ts="$(date '+%H:%M')"
    local hw="${ZMENU_WIKI_DIR}/hardware.md"
    if [[ -f "$hw" ]]; then
        sed -i "1s/ \[refreshed:.*\]$//" "$hw" 2>/dev/null
        sed -i "1s/$/ [refreshed: ${ts}]/" "$hw" 2>/dev/null
        sed -i "s|^GPU-volatile:.*|GPU-volatile: ${D_GPU_GFX:-?}  temp: ${D_GPU_TEMP:-?}°C  util: ${D_GPU_USE:-?}%|" "$hw" 2>/dev/null
        sed -i "s|^RAM-current:.*|RAM-current:  ${D_MEM_USED_MB:-?} MB used / ${D_MEM_TOTAL_MB:-?} MB|" "$hw" 2>/dev/null
    fi
}

# Full refresh — writes all wiki sections from scratch.
# Called at the end of discover() and via Settings → w)
_wiki_full_refresh() {
    mkdir -p "$ZMENU_WIKI_DIR"
    local ts; ts="$(date '+%Y-%m-%d %H:%M')"

    # ── hardware.md ─────────────────────────────────────────
    {
        printf "# Hardware — %s\n\n" "$ts"
        printf "Machine:     %s\n" "${ZMENU_MACHINE_LABEL:-$(hostname 2>/dev/null)}"
        printf "CPU:         %s (%s cores/threads)\n" "${D_CPU_MODEL:-unknown}" "${D_CPU_CORES:-?}"
        printf "GPU:         %s  driver: %s\n" "${D_GPU_GFX:-unknown}" "${D_GPU_DRIVER:-none}"
        printf "GPU-volatile: temp: %s°C  util: %s%%\n" "${D_GPU_TEMP:-?}" "${D_GPU_USE:-?}"
        printf "NPU:         %s  %s  (XDNA — not used for inference)\n" "${D_NPU_DRIVER:-amdxdna}" "${D_NPU_DEVICE:-accel0}"
        printf "RAM:         %s MB LPDDR5 @ 8000 MT/s — unified pool (GPU+CPU share)\n" "${D_MEM_TOTAL_MB:-131072}"
        printf "RAM-current: %s MB used / %s MB\n" "${D_MEM_USED_MB:-?}" "${D_MEM_TOTAL_MB:-?}"
        printf "Swap:        %s / %s MB\n\n" "${D_SWAP_USED_MB:-0}" "${D_SWAP_TOTAL_MB:-0}"
        printf "## Thermals & Power\n"
        if command -v sensors >/dev/null 2>&1; then
            sensors 2>/dev/null | grep -E 'Tctl|Tdie|edge|°C' | head -6 | sed 's/^/  /'
        else
            printf "  (sensors not installed)\n"
        fi
        printf "\nPower profile:   %s\n" "$(powerprofilesctl get 2>/dev/null || cat /sys/firmware/acpi/platform_profile 2>/dev/null || echo '?')"
        printf "CPU governor:    %s\n" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
        printf "CPU boost:       %s\n" "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo '?')"
        printf "AMD P-State:     %s\n" "$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo 'not found')"
        printf "Throttle events: %s\n" "$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null || echo '0')"
        printf "Load average:    %s\n" "$(cat /proc/loadavg 2>/dev/null)"
    } > "${ZMENU_WIKI_DIR}/hardware.md"

    # ── ai-stack.md ─────────────────────────────────────────
    {
        printf "# AI Stack — %s\n\n" "$ts"
        printf "## Primary: Zenny-Core\n"
        printf "Status:    %s\n" "$($D_ZENNY_RUNNING && echo "RUNNING  pid: ${D_ZENNY_PID:-?}  socket: ${D_ZENNY_SOCKET}" || echo 'stopped')"
        printf "Binary:    %s\n" "${ZENNY_BINARY}"
        printf "Models (%s available):\n" "${#D_ZENNY_MODELS[@]}"
        for i in "${!D_ZENNY_MODELS[@]}"; do
            printf "  [%s] display: %s\n" "$i" "${D_ZENNY_MODELS[$i]:-?}"
            printf "       key:     %s\n" "${D_ZENNY_KEYS[$i]:-?}"
        done
        printf "\nActive backend:  %s\n" "${AI_BACKEND_LABEL:-none}"
        printf "Active model:    %s\n\n" "${ZMENU_AI_MODEL:-auto}"
        printf "## GPU for Inference\n"
        printf "Device:  %s  driver: %s\n" "${D_GPU_GFX:-unknown}" "${D_GPU_DRIVER:-none}"
        printf "Backend: Vulkan  HSA_OVERRIDE_GFX_VERSION=%s\n" "${HSA_OVERRIDE_GFX_VERSION:-NOT SET — required!}"
        printf "\n## Other Tools\n"
        printf "OpenCode:    %s\n" "$(pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1 && echo "RUNNING (pid: $(pgrep -x "$OPENCODE_PROCESS" | head -1))" || (_opencode_available 2>/dev/null && echo 'installed (not running)' || echo 'not installed'))"
        printf "             OpenCode is a STANDALONE coding agent CLI — completely separate from Zenny-Core.\n"
        printf "             It does NOT wrap or use Zenny-Core. It has its own model config.\n"
        printf "             Process name: opencode   Stop it with: pkill opencode\n"
        printf "             zmenu's 'C) Ask AI' in the OpenCode section routes through Zenny-Core (NOT OpenCode).\n"
        printf "LM Studio:   %s  (download only, not inference)\n" "$($D_LMS_RUNNING && echo 'running' || echo 'off')"
        printf "Ollama:      %s  (disabled — replaced by Zenny-Core)\n" "$($D_OLLAMA_RUNNING && echo 'RUNNING (warning: should be stopped)' || echo 'stopped')"
        printf "Open WebUI:  %s\n" "$(curl -sf "${OWUI_URL:-http://localhost:3000}" >/dev/null 2>&1 && echo "running at ${OWUI_URL:-http://localhost:3000}" || echo 'not running')"
    } > "${ZMENU_WIKI_DIR}/ai-stack.md"

    # ── opencode.md ─────────────────────────────────────────
    {
        printf "# OpenCode — %s\n\n" "$ts"
        printf "## What OpenCode Is\n"
        printf "OpenCode is a standalone coding agent CLI built on the OpenCode protocol.\n"
        printf "It is a SEPARATE tool from Zenny-Core — they are INDEPENDENT processes.\n"
        printf "OpenCode does NOT wrap Zenny-Core and does NOT call Zenny-Core for inference.\n"
        printf "OpenCode has its own model config at ~/.config/opencode/opencode.json.\n\n"
        printf "## Process Management\n"
        printf "Process name:  opencode\n"
        printf "Check running: pgrep opencode\n"
        printf "Stop it:       pkill opencode\n"
        printf "Status:        %s\n\n" "$(pgrep opencode >/dev/null 2>&1 && echo "RUNNING (pid: $(pgrep opencode | head -1))" || echo 'not running')"
        printf "## Installation\n"
        local oc_cmd; oc_cmd="$(_opencode_cmd 2>/dev/null)"
        printf "Installed:  %s\n" "$(_opencode_available 2>/dev/null && echo 'yes' || echo 'no')"
        printf "Binary:     %s\n" "${oc_cmd:-not found}"
        if [[ -n "$oc_cmd" ]]; then
            printf "Version:    %s\n" "$("$oc_cmd" --version 2>/dev/null || echo '?')"
        fi
        printf "Install:    curl -fsSL https://opencode.ai/install | bash\n\n"
        printf "## Configuration\n"
        printf "Config dir:  ~/.config/opencode/\n"
        printf "Config file: ~/.config/opencode/opencode.json\n"
        printf "Rules file:  ~/.config/opencode/rules.md  (zmenu injects context here)\n\n"
        printf "## zmenu Integration\n"
        printf "zmenu 'AI Engine → 3) OpenCode' manages OpenCode configuration.\n"
        printf "zmenu 'AI Engine → 6) AI session' launches the OpenCode TUI.\n"
        printf "zmenu 'C) Ask AI' in OpenCode section routes through ZENNY-CORE (not OpenCode).\n"
        printf "The AI answering your questions IS Zenny-Core — OpenCode is just the subject matter.\n\n"
        printf "## Config Contents\n"
        if [[ -f "${OPENCODE_CFG}/opencode.json" ]]; then
            cat "${OPENCODE_CFG}/opencode.json" 2>/dev/null | head -30 | sed 's/^/  /'
        else
            printf "  (not configured)\n"
        fi
    } > "${ZMENU_WIKI_DIR}/opencode.md"

    # ── services.md ─────────────────────────────────────────
    {
        printf "# Services — %s\n\n" "$ts"
        printf "Docker:  %s\n" "$($D_DOCKER_RUNNING && echo 'running' || echo 'stopped')"
        if $D_DOCKER_RUNNING; then
            printf "\nContainers:\n"
            docker ps -a --format "  {{.Names}}  |  {{.Status}}  |  {{.Ports}}" 2>/dev/null || printf "  (none)\n"
            printf "\nDocker disk usage:\n"
            docker system df 2>/dev/null | sed 's/^/  /' || true
        fi
        printf "\nListening ports:\n"
        for p in "${D_OPEN_PORTS[@]}"; do printf "  %s\n" "$p"; done
        printf "\nKnown service ports:\n"
        printf "  11434=Ollama  3000=Open-WebUI  5678=n8n  8080=SearXNG  11235=Crawl4AI\n"
        printf "\nSystemd AI services:\n"
        for s in "${D_SERVICES[@]}"; do
            printf "  %-25s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null || echo '?')"
        done
    } > "${ZMENU_WIKI_DIR}/services.md"

    # ── security.md ─────────────────────────────────────────
    {
        printf "# Security — %s\n\n" "$ts"
        printf "UFW:\n"
        sudo -n ufw status 2>/dev/null | head -20 | sed 's/^/  /' || printf "  (no passwordless sudo for ufw)\n"
        printf "\nListening ports (only these ports are open):\n"
        ss -tlnp 2>/dev/null | awk '/LISTEN/{print "  "$4}' | head -20 || true
        printf "\nFailed SSH logins (last 24h):  "
        journalctl -u ssh --since "24h ago" 2>/dev/null | grep -c "Failed" || printf "0"
        printf "\nOutbound connections:\n"
        ss -tnp state established 2>/dev/null | awk 'NR>1{print "  "$4" → "$5}' | head -10 || true
        printf "\nVPN and tunnel tools:\n"
        for _p in openvpn wireguard-tools tailscale; do
            if dpkg -l "$_p" 2>/dev/null | grep -q '^ii'; then
                local _e; _e=$(systemctl is-enabled "${_p%.service}.service" 2>/dev/null || echo "not-a-unit")
                local _a; _a=$(systemctl is-active  "${_p%.service}.service" 2>/dev/null || echo "inactive")
                printf "  %-18s installed  enabled:%-12s active:%s\n" "$_p" "$_e" "$_a"
            fi
        done
        if dpkg -l openvpn 2>/dev/null | grep -q '^ii'; then
            printf "  OpenVPN config files:\n"
            local _c; _c=$(ls /etc/openvpn/client/ 2>/dev/null | grep -c '\.conf\|\.ovpn' || echo 0)
            local _s; _s=$(ls /etc/openvpn/server/ 2>/dev/null | grep -c '\.conf\|\.ovpn' || echo 0)
            printf "    client dir: %d .conf/.ovpn files\n" "$_c"
            printf "    server dir: %d .conf/.ovpn files\n" "$_s"
            local _t; _t=$(systemctl list-units 'openvpn@*.service' --no-legend 2>/dev/null | grep -c 'active running' || echo 0)
            printf "    active tunnel instances: %d\n" "$_t"
            printf "    NOTE: openvpn.service 'active exited' is the Ubuntu umbrella — normal with no tunnels configured\n"
        fi
        printf "\nEnabled services (user-relevant):\n"
        systemctl list-unit-files --type=service --state=enabled 2>/dev/null \
            | awk '$1 ~ /\.service$/{print "  "$1}' \
            | grep -Ev 'systemd|dbus|getty|multipathd|apport|cron|rsyslog|ufw|networkd|resolved|bluetooth|snapd|avahi|cups|gdm|colord|accounts|modem|polkit|wpa|thermald|kerneloops|whoopsie|apt-daily|fwupd|ubuntu-advantage' \
            | head -25 || true
        printf "\nTelemetry opt-outs:\n"
        for v in DO_NOT_TRACK TELEMETRY_DISABLED DOTNET_CLI_TELEMETRY_OPTOUT NEXT_TELEMETRY_DISABLED; do
            printf "  %-35s = %s\n" "$v" "${!v:-NOT SET}"
        done
    } > "${ZMENU_WIKI_DIR}/security.md"

    # ── maintenance.md ──────────────────────────────────────
    {
        printf "# Maintenance — %s\n\n" "$ts"
        printf "Disk:\n"
        df -h / /home 2>/dev/null | sed 's/^/  /'
        printf "\nStorage consumers:\n"
        printf "  LM Studio models: %s\n" "$(du -sh "${HOME}/.lmstudio/models" 2>/dev/null | cut -f1 || echo '?')"
        printf "  Ollama models:    %s\n" "$(du -sh "${HOME}/.ollama/models" 2>/dev/null | cut -f1 || echo '?')"
        printf "  Docker:           %s\n" "$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo '?')"
        printf "  Journal:          %s\n" "$(du -sh /var/log/journal 2>/dev/null | cut -f1 || echo '?')"
        printf "  ~/.cache:         %s\n" "$(du -sh "${HOME}/.cache" 2>/dev/null | cut -f1 || echo '?')"
        printf "\nPackages:\n"
        local _upg; _upg="$(apt list --upgradable 2>/dev/null)"
        printf "  Upgradeable: %s\n"  "$(printf '%s\n' "$_upg" | grep -c upgradable || echo '?')"
        printf "  Security:    %s\n"  "$(printf '%s\n' "$_upg" | grep -c security   || echo '?')"
        printf "\nJournal errors (last 24h):\n"
        journalctl --since "24h ago" -p err 2>/dev/null | tail -5 | sed 's/^/  /' || printf "  (none)\n"
        printf "\nSMART (NVMe):\n"
        sudo -n smartctl -H /dev/nvme0 2>/dev/null | grep -E 'result|PASSED|FAILED' | sed 's/^/  /' || printf "  (no passwordless sudo for smartctl)\n"
        printf "\nSwap: %s / %s MB\n" "${D_SWAP_USED_MB:-0}" "${D_SWAP_TOTAL_MB:-0}"
    } > "${ZMENU_WIKI_DIR}/maintenance.md"

    # ── find-problems.md ────────────────────────────────────
    {
        printf "# Find Problems — %s\n\n" "$ts"
        printf "CPU governor:    %s\n" "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo '?')"
        printf "CPU boost:       %s\n" "$(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null || echo '?')"
        printf "AMD P-State:     %s\n" "$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo 'not found')"
        printf "Load average:    %s\n" "$(cat /proc/loadavg 2>/dev/null)"
        printf "RAM used:        %s / %s MB\n" "${D_MEM_USED_MB:-?}" "${D_MEM_TOTAL_MB:-?}"
        printf "Swap used:       %s MB\n" "${D_SWAP_USED_MB:-0}"
        printf "vm.swappiness:   %s\n" "$(sysctl -n vm.swappiness 2>/dev/null || echo '?')"
        printf "inotify watches: %s\n" "$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo '?')"
        printf "THP:             %s\n" "$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -o '\[.*\]' | tr -d '[]')"
        printf "GPU:             %s  temp: %s°C  util: %s%%\n" "${D_GPU_GFX:-?}" "${D_GPU_TEMP:-?}" "${D_GPU_USE:-?}"
        printf "Disk (root):     %s\n" "$(df -h / 2>/dev/null | awk 'NR==2{print $5" of "$2}')"
    } > "${ZMENU_WIKI_DIR}/find-problems.md"

    # ── settings.md ─────────────────────────────────────────
    {
        printf "# Settings — %s\n\n" "$ts"
        printf "zmenu version:  %s\n" "${ZMENU_VERSION}"
        printf "Source:         %s\n" "${ZMENU_SELF}"
        printf "Install path:   %s\n" "${ZMENU_INSTALL_PATH}"
        printf "Config dir:     %s\n" "${ZMENU_CONFIG_DIR}"
        printf "Wiki dir:       %s\n" "${ZMENU_WIKI_DIR}"
        printf "AI backend:     %s\n" "${AI_BACKEND_LABEL:-none}"
        printf "AI model:       %s\n" "${ZMENU_AI_MODEL:-auto}"
        printf "Projects dir:   %s\n" "${ZMENU_PROJECTS_DIR}"
        printf "\nConfig file contents:\n"
        cat "${ZMENU_CONFIG_FILE}" 2>/dev/null | sed 's/^/  /' || printf "  (no config file)\n"
        printf "\nEnvironment:\n"
        printf "  HSA_OVERRIDE_GFX_VERSION=%s\n" "${HSA_OVERRIDE_GFX_VERSION:-NOT SET}"
        printf "  ZENNY_GPU_LAYERS=%s\n"          "${ZENNY_GPU_LAYERS:-not set}"
        printf "  ZENNY_VERBOSE=%s\n"             "${ZENNY_VERBOSE:-not set}"
    } > "${ZMENU_WIKI_DIR}/settings.md"

    # ── projects.md ─────────────────────────────────────────
    {
        printf "# Projects — %s\n\n" "$ts"
        printf "Projects dir: %s\n\n" "${ZMENU_PROJECTS_DIR}"
        if [[ -d "$ZMENU_PROJECTS_DIR" ]]; then
            printf "Projects:\n"
            while IFS= read -r -d '' p; do
                local pn; pn=$(basename "$p")
                local info=""
                [[ -f "${p}/AI.md" ]]                    && info+=" [AI.md]"
                [[ -d "${p}/.git" ]]                     && info+=" [git:$(git -C "$p" branch --show-current 2>/dev/null || echo '?')]"
                [[ -f "${p}/.config/ai/settings.json" ]] && info+=" [settings]"
                printf "  %-24s%s\n" "$pn" "$info"
            done < <(find "$ZMENU_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
        else
            printf "  (directory not found)\n"
        fi
    } > "${ZMENU_WIKI_DIR}/projects.md"

    # ── general.md — fallback for unrecognised sections ─────
    {
        printf "# General — %s\n\n" "$ts"
        printf "Machine:    %s\n" "${ZMENU_MACHINE_LABEL:-$(hostname 2>/dev/null)}"
        printf "AI engine:  %s\n" "${AI_BACKEND_LABEL:-none}"
        printf "GPU:        %s  driver: %s\n" "${D_GPU_GFX:-unknown}" "${D_GPU_DRIVER:-none}"
        printf "RAM:        %s MB unified\n" "${D_MEM_TOTAL_MB:-?}"
        printf "Backend:    %s  model: %s\n" "${AI_BACKEND_LABEL:-none}" "${ZMENU_AI_MODEL:-auto}"
        printf "\nZenny-Core: %s\n" "$($D_ZENNY_RUNNING && echo "RUNNING pid:${D_ZENNY_PID:-?}" || echo 'stopped')"
        printf "Wiki dir:   %s\n" "${ZMENU_WIKI_DIR}"
    } > "${ZMENU_WIKI_DIR}/general.md"

    # ── system-scan.md ──────────────────────────────────────
    {
        printf "# System Scan — %s\n\n" "$ts"
        printf "## App Registry Status\n"
        for rec in "${_SCAN_REGISTRY[@]}"; do
            local sname sinst sproc ssvc sport sconfig scat sdesc
            IFS='|' read -r sname sinst sproc ssvc sport sconfig scat sdesc <<< "$rec"
            local srunning="not installed"
            if [[ "$sinst" == docker:* ]]; then
                local scn="${sinst#docker:}"
                docker ps --filter "name=^${scn}$" --format "{{.Status}}" 2>/dev/null | grep -q "^Up" \
                    && srunning="RUNNING (docker)" || { docker ps -a --filter "name=^${scn}$" --format "{{.Status}}" 2>/dev/null | grep -q "." && srunning="stopped (docker)"; }
            elif [[ -n "$sproc" ]] && pgrep -x "$sproc" >/dev/null 2>&1; then
                srunning="RUNNING (pid: $(pgrep -x "$sproc" | head -1))"
            elif [[ -n "$sinst" ]]; then
                local sexp="${sinst/\~/$HOME}"
                { [[ -x "$sexp" ]] || command -v "$sinst" >/dev/null 2>&1; } && srunning="installed (not running)"
            fi
            printf "  %-18s %-12s  %s\n" "$sname" "$scat" "$srunning"
        done
        printf "\n## Listening Ports\n"
        ss -tlnp 2>/dev/null | grep LISTEN | awk '{print "  "$4"\t"$6}' | head -20
        printf "\n## Docker Containers\n"
        docker ps -a --format "  {{.Names}}: {{.Status}}  {{.Ports}}" 2>/dev/null || printf "  (docker not running)\n"
    } > "${ZMENU_WIKI_DIR}/system-scan.md"

    # ── packages.md ─────────────────────────────────────────
    {
        printf "# Packages — %s\n\n" "$ts"
        printf "## Snap (apps, base/core runtimes excluded)\n"
        snap list 2>/dev/null | awk 'NR>1 &&
            $1 !~ /^(bare|core|core[0-9]+|snapd|snapd-desktop-integration|gtk-common-themes|gnome-[0-9]|mesa-)/ \
            {printf "  %-26s %s\n", $1, $2}' || printf "  (snap not available)\n"
        printf "\n## User binaries (~/.local/bin)\n"
        ls -1 "${HOME}/.local/bin/" 2>/dev/null | sed 's/^/  /' || printf "  (none)\n"
        printf "\n## Cargo tools (~/.cargo/bin)\n"
        ls -1 "${HOME}/.cargo/bin/" 2>/dev/null | grep -v '\.d$' | sed 's/^/  /' || printf "  (none)\n"
        printf "\n## npm global\n"
        npm list -g --depth=0 2>/dev/null | tail -n +2 | sed 's/[├└─ ]*/  /' | head -15 || printf "  (none)\n"
        printf "\n## pip (user)\n"
        pip3 list --user 2>/dev/null | tail -n +3 | awk '{printf "  %-26s %s\n", $1, $2}' | head -20 || printf "  (none)\n"
        printf "\n## Snap disk usage\n"
        printf "  %s\n" "$(du -sh /var/lib/snapd/snaps 2>/dev/null | cut -f1 || echo '?')"
    } > "${ZMENU_WIKI_DIR}/packages.md"

    # ── changes.md — only create if it doesn't exist ────────
    [[ ! -f "${ZMENU_WIKI_DIR}/changes.md" ]] && \
        printf "# Changes — append-only audit log\n\nStarted: %s\n" "$ts" \
        > "${ZMENU_WIKI_DIR}/changes.md"
}

# Append one entry to changes.md after an apply action.
# Usage: _wiki_log_change "Section" "command ran" "OK|FAIL"
_wiki_log_change() {
    local section="$1" cmd="$2" result="${3:-OK}"
    mkdir -p "$ZMENU_WIKI_DIR"
    local log="${ZMENU_WIKI_DIR}/changes.md"
    [[ ! -f "$log" ]] && printf "# Changes — append-only audit log\n\n" > "$log"
    printf "\n## %s · %s\nApplied: %s\nResult:  %s\n" \
        "$(date '+%Y-%m-%d %H:%M')" "$section" "$cmd" "$result" >> "$log"
}

# Display wiki index + recent changes in terminal
_wiki_show() {
    header
    echo -e "${BCYN}┄ SOVEREIGN WIKI ────────────────────────────────────────${NC}"
    echo ""
    if [[ ! -d "$ZMENU_WIKI_DIR" ]] || [[ -z "$(ls -A "$ZMENU_WIKI_DIR" 2>/dev/null)" ]]; then
        echo -e "  ${WARN}  Wiki not initialised yet"
        echo -e "  ${DIM}  Run: Settings → e) Re-run discovery${NC}"
        return
    fi
    echo -e "  ${DIM}Location: ${ZMENU_WIKI_DIR}${NC}"
    echo ""
    echo -e "  ${BOLD}Sections:${NC}"
    for f in hardware ai-stack opencode services security maintenance find-problems projects settings system-scan packages general; do
        local fpath="${ZMENU_WIKI_DIR}/${f}.md"
        [[ ! -f "$fpath" ]] && continue
        local header_line; header_line="$(head -1 "$fpath")"
        local lines; lines="$(wc -l < "$fpath")"
        printf "  %-20s %s lines  —  %s\n" "${f}.md" "$lines" "${header_line#\# }"
    done
    echo ""
    echo -e "  ${BOLD}Recent changes:${NC}"
    if [[ -f "${ZMENU_WIKI_DIR}/changes.md" ]]; then
        local nchanges; nchanges=$(grep -c '^## ' "${ZMENU_WIKI_DIR}/changes.md" 2>/dev/null || echo 0)
        echo -e "  ${DIM}${nchanges} total applied actions${NC}"
        echo ""
        grep -A3 '^## ' "${ZMENU_WIKI_DIR}/changes.md" | tail -24 | sed 's/^/  /'
    else
        echo "  (none yet — use 'apply' after AI suggestions)"
    fi
}

# ============================================================
#  SECTION 5 — CHROME: header, pause, confirm, export, dashboard
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

# ── Export function — available from any screen ────────────
# Captures current terminal output context into a markdown file
export_report() {
    local section="${1:-General}"
    local extra_content="${2:-}"
    {
        echo "# Z-Menu Report"
        echo "> Section: ${section}"
        echo "> Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "> Version: ${ZMENU_VERSION}"
        echo ""

        echo "## System Overview"
        echo "- CPU: ${D_CPU_MODEL} (${D_CPU_CORES} threads, governor: ${D_CPU_GOVERNOR})"
        echo "- RAM: ${D_MEM_USED_MB}/${D_MEM_TOTAL_MB} MB used (${D_MEM_FREE_MB} MB free)"
        echo "- Swap: ${D_SWAP_USED_MB}/${D_SWAP_TOTAL_MB} MB"
        local disk_info; disk_info=$(df -h / | awk 'NR==2{printf "%s used / %s (%s free)",$3,$2,$4}')
        echo "- Disk: ${disk_info}"
        echo "- Load: $(awk '{print $1,$2,$3}' /proc/loadavg)"
        echo ""

        echo "## AI Stack"
        if [[ "$D_OLLAMA_RUNNING" == true ]]; then
            echo "- Ollama: RUNNING at ${D_OLLAMA_URL}"
            echo "- Active model: ${D_OLLAMA_ACTIVE_MODEL:-none}"
            echo "- Available: ${D_OLLAMA_MODELS[*]:-none}"
            echo "- Context window: ${ZMENU_AI_CONTEXT_LENGTH}"
        else
            echo "- Ollama: STOPPED"
        fi
        echo ""

        echo "## GPU"
        echo "- Driver: ${D_GPU_DRIVER:-none}"
        echo "- GFX: ${D_GPU_GFX:-unknown}"
        [[ -n "$D_GPU_TEMP" ]] && echo "- Temp: ${D_GPU_TEMP}°C"
        [[ -n "$D_GPU_USE" ]] && echo "- Utilisation: ${D_GPU_USE}%"
        echo ""

        echo "## Docker"
        if [[ "$D_DOCKER_RUNNING" == true ]]; then
            echo "- Status: RUNNING (${#D_CONTAINERS[@]} containers)"
            for c in "${D_CONTAINERS[@]}"; do echo "  - ${c}"; done
        else
            echo "- Status: STOPPED"
        fi
        echo ""

        if [[ -n "$extra_content" ]]; then
            echo "## ${section} Details"
            echo "$extra_content"
            echo ""
        fi

        echo "---"
        echo "*Report generated by zmenu v${ZMENU_VERSION}*"
    } > "$ZMENU_REPORT_FILE"
    echo -e "  ${OK}  Report saved to ${BOLD}${ZMENU_REPORT_FILE}${NC}"
}

# ── Dashboard status display ──────────────────────────────
# This is the home screen — shows everything at a glance
dashboard() {
    # ── Refresh live metrics ──
    _disc_memory

    # ── AI Engine ─────────────────────────────────────────
    local _zenny _zenny_info
    local _zenny_instances; _zenny_instances=$(pgrep -x "$ZENNY_PROCESS" 2>/dev/null | wc -l)
    if [[ "$D_ZENNY_RUNNING" == true ]]; then
        if [[ "$_zenny_instances" -gt 1 ]]; then
            _zenny=$WARN
            _zenny_info="${#D_ZENNY_MODELS[@]} model(s)  pid:${D_ZENNY_PID:-?}  ${BRED}⚠ ${_zenny_instances} instances running — stop and restart${NC}"
        else
            _zenny=$OK
            _zenny_info="${#D_ZENNY_MODELS[@]} model(s)  pid:${D_ZENNY_PID:-?}"
        fi
    else
        _zenny=$IDLE; _zenny_info="stopped"
    fi

    local _olla _olla_info
    if [[ "$D_OLLAMA_RUNNING" == true ]]; then
        _olla=$WARN; _olla_info="running (should be disabled)"
    else
        _olla=$IDLE; _olla_info="disabled"
    fi

    local _lms
    $D_LMS_RUNNING && _lms=$OK || _lms=$IDLE

    # ── Memory Pool ───────────────────────────────────────
    local mem_pct=0
    [[ "$D_MEM_TOTAL_MB" -gt 0 ]] && mem_pct=$((D_MEM_USED_MB * 100 / D_MEM_TOTAL_MB))
    local _mem
    if [[ $mem_pct -lt 70 ]]; then _mem=$OK
    elif [[ $mem_pct -lt 90 ]]; then _mem=$WARN
    else _mem=$FAIL; fi

    # Memory consumers (top 5 by RSS)
    local mem_consumers
    mem_consumers=$(ps aux --sort=-rss 2>/dev/null \
        | awk 'NR>1 && NR<=6{printf "      %-18s %5.0f MB\n", $11, $6/1024}' || true)

    # Zenny-Core loaded models / tok/s
    local zenny_loaded=""
    if [[ "$D_ZENNY_RUNNING" == true ]]; then
        local stats_resp
        stats_resp=$(_zenny_send '{"cmd":"stats"}' 2>/dev/null || echo "")
        if [[ -n "$stats_resp" ]]; then
            zenny_loaded=$(echo "$stats_resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    for m in d.get('models',[]):
        name=m.get('name','?')
        toks=m.get('tok_s',0)
        print(f'      Zenny: {name}  {toks:.0f} tok/s')
except: pass
" 2>/dev/null || true)
        fi
    fi

    # Swap
    local _swap
    if [[ "$D_SWAP_USED_MB" -gt 100 ]]; then _swap=$WARN
    elif [[ "$D_SWAP_USED_MB" -gt 0 ]]; then _swap=$OK
    else _swap=$IDLE; fi

    # ── GPU ───────────────────────────────────────────────
    local _gpu _gpu_info
    case "$D_GPU_DRIVER" in
        rocm)         _gpu=$OK;   _gpu_info="${D_GPU_GFX}  ${D_GPU_TEMP:-?}°C  ${D_GPU_USE:-?}%" ;;
        nvidia)       _gpu=$OK;   _gpu_info="${D_GPU_GFX}  ${D_GPU_TEMP:-?}°C  ${D_GPU_USE:-?}%" ;;
        amdgpu-sysfs) _gpu=$WARN; _gpu_info="sysfs only  ${D_GPU_TEMP:-?}°C  ${DIM}(rocm-smi not in PATH)${NC}" ;;
        *)            _gpu=$IDLE; _gpu_info="not detected" ;;
    esac

    # ── NPU ───────────────────────────────────────────────
    # NPU is always-on hardware — $OK when driver+device present (ready),
    # $IDLE only if driver missing (not usable)
    local _npu _npu_info
    if [[ -n "$D_NPU_DRIVER" && -n "$D_NPU_DEVICE" && "$D_NPU_DEVICE" != "no-device" ]]; then
        _npu=$OK; _npu_info="${D_NPU_DRIVER}  ${D_NPU_DEVICE}  ${DIM}(XDNA — available)${NC}"
    elif [[ -n "$D_NPU_DRIVER" ]]; then
        _npu=$WARN; _npu_info="${D_NPU_DRIVER} loaded, no device found"
    else
        _npu=$IDLE; _npu_info="driver not loaded"
    fi

    # ── Docker ────────────────────────────────────────────
    local _dock _dock_info
    if [[ "$D_DOCKER_RUNNING" == true ]]; then
        _dock=$OK; _dock_info="${#D_CONTAINERS[@]} container(s)"
    else
        _dock=$FAIL; _dock_info="stopped"
    fi

    # ── Disk ──────────────────────────────────────────────
    local disk_pct; disk_pct=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    local _disk
    if [[ "$disk_pct" -lt 70 ]]; then _disk=$OK
    elif [[ "$disk_pct" -lt 85 ]]; then _disk=$WARN
    else _disk=$FAIL; fi

    # ── Thermals ──────────────────────────────────────────
    local cpu_temp=""
    if command -v sensors >/dev/null 2>&1; then
        cpu_temp=$(sensors 2>/dev/null | awk '/Tctl|Tdie/{gsub(/[+°C]/,"",$2); print $2; exit}' || echo "")
    fi
    [[ -z "$cpu_temp" ]] && cpu_temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1 | awk '{printf "%.0f", $1/1000}' || echo "?")
    local _therm
    local therm_val="${cpu_temp:-0}"
    if [[ "$therm_val" =~ ^[0-9]+$ ]]; then
        if [[ $therm_val -lt 70 ]]; then _therm=$OK
        elif [[ $therm_val -lt 85 ]]; then _therm=$WARN
        else _therm=$FAIL; fi
    else
        _therm=$IDLE
    fi

    # ── Load ──────────────────────────────────────────────
    local load1; load1=$(awk '{print $1}' /proc/loadavg)
    local _load
    local load_int=${load1%.*}
    local core_count=${D_CPU_CORES:-4}
    if [[ $load_int -lt $core_count ]]; then _load=$OK
    elif [[ $load_int -lt $((core_count * 2)) ]]; then _load=$WARN
    else _load=$FAIL; fi

    # ── RENDER ────────────────────────────────────────────
    echo -e "  ${BOLD}${BBLU}┄ DASHBOARD ────────────────────────────────────────────${NC}"
    echo ""

    # AI Engine — CEO view: only show RUNNING tools + Claude session
    echo -e "  ${BOLD}AI Engine${NC}"
    local _ai_any=false
    # Zenny-Core (always show — it's the primary engine)
    echo -e "    Zenny-Core  ${_zenny}  ${_zenny_info}"
    _ai_any=true
    # Claude Code — show only when session is active
    if [[ "$D_CLAUDE_SESSION" == true ]]; then
        echo -e "    Claude Code ${OK}  session active  v${D_CLAUDE_VER}"
        _ai_any=true
    elif [[ -n "$D_CLAUDE_BIN" ]]; then
        echo -e "    Claude Code ${IDLE}  v${D_CLAUDE_VER}"
    fi
    # OpenCode — only if running
    if pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
        echo -e "    OpenCode    ${OK}  RUNNING  v$( "$(_opencode_cmd)" --version 2>/dev/null || echo '?' )"
        _ai_any=true
    fi
    # Ollama — only if running (warn — should be stopped)
    if [[ "$D_OLLAMA_RUNNING" == true ]]; then
        echo -e "    Ollama      ${WARN}  running — should be stopped (replaced by Zenny-Core)"
    fi
    # LM Studio — only if running
    if [[ "$D_LMS_RUNNING" == true ]]; then
        echo -e "    LM Studio   ${OK}  ${D_LMS_URL}"
    fi
    echo ""

    echo -e "  ${BOLD}Memory Pool${NC}    ${_mem}  ${D_MEM_USED_MB}/${D_MEM_TOTAL_MB} MB  (${mem_pct}%)"
    [[ -n "$zenny_loaded" ]] && echo -e "$zenny_loaded"
    echo -e "    ${_swap}  Swap: ${D_SWAP_USED_MB}/${D_SWAP_TOTAL_MB} MB"
    if [[ -n "$mem_consumers" ]]; then
        echo -e "    ${DIM}Top consumers:${NC}"
        echo -e "$mem_consumers"
    fi
    echo ""

    # Hardware — only show lines with actionable info
    echo -e "  ${BOLD}Hardware${NC}"
    echo -e "    GPU       ${_gpu}  ${_gpu_info}"
    echo -e "    NPU       ${_npu}  ${_npu_info}"
    # Thermals: only yellow/red lines get shown on CEO view; always show temp numbers
    echo -e "    Thermals  ${_therm}  CPU: ${cpu_temp:-?}°C  GPU: ${D_GPU_TEMP:-?}°C"
    echo -e "    Load      ${_load}  $(awk '{printf "%s %s %s",$1,$2,$3}' /proc/loadavg)  ${DIM}(${D_CPU_CORES} threads)${NC}"
    echo ""

    # Services — one-liner per service (detail lives in System Scan)
    echo -e "  ${BOLD}Services${NC}"
    echo -e "    Docker    ${_dock}  ${_dock_info}"
    echo -e "    Disk      ${_disk}  ${disk_pct}% used"
    echo ""

    # Wiki — one-liner status only
    local wiki_ts="" wiki_changes=0
    [[ -f "${ZMENU_WIKI_DIR}/hardware.md" ]] && \
        wiki_ts=$(head -1 "${ZMENU_WIKI_DIR}/hardware.md" | sed 's/# Hardware — //')
    [[ -f "${ZMENU_WIKI_DIR}/changes.md" ]] && \
        wiki_changes=$(grep -c '^## ' "${ZMENU_WIKI_DIR}/changes.md" 2>/dev/null || echo 0)
    if [[ -n "$wiki_ts" ]]; then
        echo -e "  ${DIM}Wiki: refreshed ${wiki_ts}  ·  ${wiki_changes} changes  ·  4=System Scan for full inventory${NC}"
    fi

    echo ""
    echo -e "  ${DIM}$(date '+%a %d %b %Y  %H:%M:%S')  ·  ●=active  ○=stopped  ●=warning  ●=error${NC}"
    echo ""
}

# ============================================================
#  SECTION 6 — MODULES
# ============================================================

# ──────────────────────────────────────────────────────────
#  MODULE 2: FIND PROBLEMS — Full bottleneck sweep
# ──────────────────────────────────────────────────────────

mod_find_problems() {
    while true; do
        header
        echo -e "${BCYN}┄ FIND PROBLEMS ────────────────────────────────────────${NC}"
        echo ""
        echo "  Scans your system for performance bottlenecks, misconfigurations,"
        echo "  and wasted resources. Every finding explained in plain English."
        echo ""
        echo "   a)  Run full bottleneck sweep"
        echo "   b)  CPU only      (governor, boost, pstate)"
        echo "   c)  Memory only   (pressure, swap, swappiness)"
        echo "   d)  GPU only      (Ollama GPU vs CPU check)"
        echo "   e)  Docker only   (overhead, limits, orphans)"
        echo "   f)  Storage only  (I/O scheduler, alignment)"
        echo "   g)  Thermals only (throttling check)"
        echo "   h)  Kernel tuning (vm.swappiness, fs.inotify, etc.)"
        echo ""
        echo "   E)  Export report"
        echo "   C)  ✦ Ask AI to diagnose problems"
        echo "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _bp_full_sweep; pause ;;
            b) _bp_cpu; pause ;;
            c) _bp_memory; pause ;;
            d) _bp_gpu; pause ;;
            e) _bp_docker; pause ;;
            f) _bp_storage; pause ;;
            g) _bp_thermals; pause ;;
            h) _bp_kernel; pause ;;
            E) _bp_full_sweep 2>&1 | tee /tmp/zmenu-bp.txt >/dev/null
               export_report "Find Problems" "$(cat /tmp/zmenu-bp.txt 2>/dev/null)"; pause ;;
            C) _cc_inline "Find Problems" _ctx_find_problems _apply_find_problems; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_bp_finding() {
    # $1 = severity (ok|warn|crit), $2 = title, $3 = explanation, $4 = fix command (optional)
    local sev="$1" title="$2" explain="$3" fix="${4:-}"
    case "$sev" in
        ok)   echo -e "  ${OK}  ${BOLD}${title}${NC}" ;;
        warn) echo -e "  ${WARN}  ${BOLD}${title}${NC}" ;;
        crit) echo -e "  ${FAIL}  ${BOLD}${title}${NC}" ;;
    esac
    echo -e "      ${DIM}${explain}${NC}"
    if [[ -n "$fix" ]]; then
        echo -e "      ${BCYN}Fix:${NC} ${fix}"
    fi
    echo ""
}

_bp_cpu() {
    header
    echo -e "${BCYN}┄ CPU BOTTLENECK CHECK${NC}"
    echo ""

    # Governor
    local gov; gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    if [[ "$gov" == "performance" ]]; then
        _bp_finding "ok" "CPU governor: ${gov}" "CPU is set to maximum performance."
    elif [[ "$gov" == "powersave" ]]; then
        _bp_finding "warn" "CPU governor: ${gov}" \
            "CPU is in power-saving mode — this throttles clock speed and slows AI inference." \
            "sudo cpupower frequency-set -g performance"
    elif [[ "$gov" == "schedutil" || "$gov" == "ondemand" ]]; then
        _bp_finding "ok" "CPU governor: ${gov}" "Dynamic governor — scales with demand. Fine for most workloads."
    else
        _bp_finding "warn" "CPU governor: ${gov}" "Unexpected governor. Check if this is intentional."
    fi

    # Boost
    local boost_file="/sys/devices/system/cpu/cpufreq/boost"
    if [[ -f "$boost_file" ]]; then
        local boost; boost=$(cat "$boost_file" 2>/dev/null)
        if [[ "$boost" == "1" ]]; then
            _bp_finding "ok" "CPU boost: enabled" "Turbo boost is on — maximum single-thread performance."
        else
            _bp_finding "warn" "CPU boost: disabled" \
                "Turbo boost is off — you're leaving performance on the table for AI workloads." \
                "echo 1 | sudo tee ${boost_file}"
        fi
    fi

    # AMD pstate driver
    local pstate_status
    pstate_status=$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null || echo "not found")
    if [[ "$pstate_status" == "active" ]]; then
        _bp_finding "ok" "AMD P-State: active" "Using the modern AMD P-State driver for best efficiency."
    elif [[ "$pstate_status" == "passive" ]]; then
        _bp_finding "warn" "AMD P-State: passive" \
            "P-State is in passive mode — active mode gives better power/perf scaling." \
            "echo active | sudo tee /sys/devices/system/cpu/amd_pstate/status"
    elif [[ "$pstate_status" != "not found" ]]; then
        _bp_finding "warn" "AMD P-State: ${pstate_status}" "Check if this is expected."
    fi

    # Load average vs cores
    local load1; load1=$(awk '{print $1}' /proc/loadavg)
    local load_int=${load1%.*}
    local cores=${D_CPU_CORES:-4}
    if [[ $load_int -gt $((cores * 2)) ]]; then
        _bp_finding "crit" "CPU overloaded: load ${load1} on ${cores} threads" \
            "System is heavily overloaded — processes are queuing for CPU time." \
            "Check: ps aux --sort=-%cpu | head -10"
    elif [[ $load_int -gt $cores ]]; then
        _bp_finding "warn" "CPU busy: load ${load1} on ${cores} threads" \
            "Load exceeds thread count — some queueing is happening."
    else
        _bp_finding "ok" "CPU load healthy: ${load1} on ${cores} threads" "Plenty of headroom."
    fi
}

_bp_memory() {
    header
    echo -e "${BCYN}┄ MEMORY BOTTLENECK CHECK${NC}"
    echo ""
    _disc_memory

    # RAM pressure
    local mem_pct=$((D_MEM_USED_MB * 100 / D_MEM_TOTAL_MB))
    if [[ $mem_pct -gt 90 ]]; then
        _bp_finding "crit" "RAM pressure: ${mem_pct}% used (${D_MEM_USED_MB}/${D_MEM_TOTAL_MB} MB)" \
            "System is nearly out of RAM. This causes swapping which destroys performance." \
            "Check who's using it: ps aux --sort=-rss | head -10"
    elif [[ $mem_pct -gt 75 ]]; then
        _bp_finding "warn" "RAM usage: ${mem_pct}% (${D_MEM_USED_MB}/${D_MEM_TOTAL_MB} MB)" \
            "Getting high — watch for swap activity."
    else
        _bp_finding "ok" "RAM healthy: ${mem_pct}% used (${D_MEM_USED_MB}/${D_MEM_TOTAL_MB} MB)" \
            "Plenty of free memory."
    fi

    # Swap
    if [[ "$D_SWAP_USED_MB" -gt 500 ]]; then
        _bp_finding "crit" "Swap in heavy use: ${D_SWAP_USED_MB} MB" \
            "System is actively swapping — this makes everything slow, especially AI inference." \
            "Free swap: sudo swapoff -a && sudo swapon -a  (warning: needs free RAM)"
    elif [[ "$D_SWAP_USED_MB" -gt 100 ]]; then
        _bp_finding "warn" "Swap in use: ${D_SWAP_USED_MB} MB" \
            "Some data has been swapped to disk. Not critical but watch it."
    else
        _bp_finding "ok" "Swap clean: ${D_SWAP_USED_MB} MB used" "No swap pressure."
    fi

    # Swappiness
    local swappiness; swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "?")
    if [[ "$swappiness" =~ ^[0-9]+$ ]]; then
        if [[ $swappiness -gt 30 ]]; then
            _bp_finding "warn" "vm.swappiness = ${swappiness} (high)" \
                "The kernel is too eager to swap. For AI workloads with lots of RAM, lower is better." \
                "sudo sysctl vm.swappiness=10  (add to /etc/sysctl.conf for permanence)"
        else
            _bp_finding "ok" "vm.swappiness = ${swappiness}" "Good — kernel won't swap aggressively."
        fi
    fi

    # Memory consumers
    echo -e "  ${BCYN}Top memory consumers:${NC}"
    ps aux --sort=-rss 2>/dev/null \
        | awk 'NR>1 && NR<=8{printf "    %-25s %6.0f MB  (%s%%)\n", $11, $6/1024, $4}' || true
    echo ""
}

_bp_gpu() {
    header
    echo -e "${BCYN}┄ GPU BOTTLENECK CHECK${NC}"
    echo ""

    if [[ "$D_GPU_DRIVER" == "none" || -z "$D_GPU_DRIVER" ]]; then
        _bp_finding "crit" "No GPU driver detected" \
            "AI inference will run on CPU only — this is 10x slower than GPU." \
            "Install ROCm (AMD) or CUDA (Nvidia) drivers"
        return
    fi

    if [[ "$D_GPU_DRIVER" == "amdgpu-sysfs" ]]; then
        _bp_finding "warn" "GPU detected but rocm-smi not in PATH" \
            "The GPU exists but ROCm tools aren't accessible. Ollama may fall back to CPU." \
            "export PATH=\$PATH:/opt/rocm/bin  (add to ~/.bashrc)"
    fi

    # Check if Ollama is using GPU or CPU
    if [[ "$D_OLLAMA_RUNNING" == true && -n "$D_OLLAMA_ACTIVE_MODEL" ]]; then
        local ps_json
        ps_json=$(curl -sf "${D_OLLAMA_URL}/api/ps" 2>/dev/null || echo "")
        if [[ -n "$ps_json" ]]; then
            local gpu_check
            gpu_check=$(echo "$ps_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for m in d.get('models', []):
        vram = m.get('size_vram', 0)
        total = m.get('size', 0)
        if total > 0:
            gpu_pct = (vram / total) * 100
            print(f'{gpu_pct:.0f}')
        else:
            print('0')
except: print('unknown')
" 2>/dev/null || echo "unknown")
            if [[ "$gpu_check" =~ ^[0-9]+$ ]]; then
                if [[ $gpu_check -gt 90 ]]; then
                    _bp_finding "ok" "Ollama: ${gpu_check}% on GPU" \
                        "Model is running on GPU — fast inference."
                elif [[ $gpu_check -gt 0 ]]; then
                    _bp_finding "warn" "Ollama: only ${gpu_check}% on GPU" \
                        "Part of the model is on CPU — this slows inference. Check if you have enough VRAM." \
                        "Try a smaller model or reduce context length"
                else
                    _bp_finding "crit" "Ollama is using CPU instead of GPU" \
                        "This makes inference 10x slower. The GPU driver may not be configured correctly." \
                        "Check: HSA_OVERRIDE_GFX_VERSION, ROCm install, or CUDA drivers"
                fi
            fi
        fi
    elif [[ "$D_OLLAMA_RUNNING" == true ]]; then
        _bp_finding "ok" "Ollama running, no model loaded" "Load a model to check GPU allocation."
    fi

    # HSA override check (AMD)
    if [[ "$D_GPU_DRIVER" == "rocm" ]]; then
        local hsa="${HSA_OVERRIDE_GFX_VERSION:-NOT SET}"
        if [[ "$hsa" == "NOT SET" ]]; then
            local gfx_num="${D_GPU_GFX#gfx}"
            local gfx_hint=""
            if [[ ${#gfx_num} -eq 4 ]]; then
                gfx_hint="${gfx_num:0:2}.${gfx_num:2:1}.${gfx_num:3:1}"
            else
                gfx_hint="${gfx_num}"
            fi
            _bp_finding "warn" "HSA_OVERRIDE_GFX_VERSION not set" \
                "ROCm may not recognize your GPU without this variable." \
                "export HSA_OVERRIDE_GFX_VERSION=${gfx_hint}  (add to ~/.bashrc)"
        else
            _bp_finding "ok" "HSA_OVERRIDE_GFX_VERSION=${hsa}" "ROCm GPU hint is set."
        fi
    fi
}

_bp_docker() {
    header
    echo -e "${BCYN}┄ DOCKER BOTTLENECK CHECK${NC}"
    echo ""

    if [[ "$D_DOCKER_RUNNING" != true ]]; then
        _bp_finding "ok" "Docker not running" "No container overhead."
        return
    fi

    # Container count
    local total; total=$(docker ps -q 2>/dev/null | wc -l)
    local all_total; all_total=$(docker ps -aq 2>/dev/null | wc -l)
    local stopped=$((all_total - total))
    if [[ $stopped -gt 5 ]]; then
        _bp_finding "warn" "${stopped} stopped containers" \
            "Stopped containers waste disk space." \
            "docker container prune -f"
    fi

    # Dangling images
    local dangling; dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
    if [[ $dangling -gt 0 ]]; then
        _bp_finding "warn" "${dangling} dangling image(s)" \
            "Orphaned image layers wasting disk space." \
            "docker image prune -f"
    fi

    # Container resource usage
    echo -e "  ${BCYN}Container resource usage:${NC}"
    docker stats --no-stream --format "    {{.Name}}: {{.CPUPerc}} CPU  {{.MemUsage}}" 2>/dev/null || echo "    Could not query"
    echo ""

    # Containers without memory limits
    local unlimited
    unlimited=$(docker ps --format '{{.Names}}' 2>/dev/null | while read -r name; do
        local mem_limit; mem_limit=$(docker inspect --format '{{.HostConfig.Memory}}' "$name" 2>/dev/null || echo "0")
        [[ "$mem_limit" == "0" ]] && echo "$name"
    done || true)
    if [[ -n "$unlimited" ]]; then
        _bp_finding "warn" "Containers without memory limits" \
            "These containers can use unlimited RAM: $(echo "$unlimited" | tr '\n' ', ')" \
            "Add --memory=2g to docker run commands"
    fi
}

_bp_storage() {
    header
    echo -e "${BCYN}┄ STORAGE BOTTLENECK CHECK${NC}"
    echo ""

    # Disk usage
    local disk_pct; disk_pct=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5}')
    if [[ $disk_pct -gt 90 ]]; then
        _bp_finding "crit" "Disk ${disk_pct}% full" \
            "Almost out of disk space — this can cause crashes and data loss." \
            "Run: zmenu → Maintenance → Disk audit"
    elif [[ $disk_pct -gt 75 ]]; then
        _bp_finding "warn" "Disk ${disk_pct}% used" "Getting full. Plan cleanup soon."
    else
        _bp_finding "ok" "Disk ${disk_pct}% used" "Healthy disk space."
    fi

    # I/O scheduler
    local root_dev; root_dev=$(lsblk -ndo NAME "$(findmnt -no SOURCE /)" 2>/dev/null || echo "")
    if [[ -n "$root_dev" ]]; then
        local sched_file="/sys/block/${root_dev}/queue/scheduler"
        if [[ -f "$sched_file" ]]; then
            local sched; sched=$(cat "$sched_file" 2>/dev/null)
            local active; active=$(echo "$sched" | grep -o '\[.*\]' | tr -d '[]')
            if [[ "$active" == "none" || "$active" == "mq-deadline" || "$active" == "kyber" ]]; then
                _bp_finding "ok" "I/O scheduler: ${active}" "Good choice for NVMe/SSD."
            elif [[ "$active" == "bfq" || "$active" == "cfq" ]]; then
                _bp_finding "warn" "I/O scheduler: ${active}" \
                    "This scheduler adds overhead on NVMe. Switch to 'none' or 'mq-deadline' for best throughput." \
                    "echo none | sudo tee ${sched_file}"
            fi
        fi
    fi

    # Large space consumers
    echo -e "  ${BCYN}Largest space consumers:${NC}"
    local ollama_sz; ollama_sz=$(du -sh "${HOME}/.ollama/models" 2>/dev/null | cut -f1 || echo "0")
    local lms_sz; lms_sz=$(du -sh "${HOME}/.lmstudio/models" 2>/dev/null | cut -f1 || echo "0")
    local docker_sz; docker_sz=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "0")
    local journal_sz; journal_sz=$(du -sh /var/log/journal 2>/dev/null | cut -f1 || echo "0")
    printf "    %-30s  %s\n" "Ollama models:" "$ollama_sz"
    printf "    %-30s  %s\n" "LM Studio models:" "$lms_sz"
    printf "    %-30s  %s\n" "Docker:" "$docker_sz"
    printf "    %-30s  %s\n" "Journal logs:" "$journal_sz"
    echo ""
}

_bp_thermals() {
    header
    echo -e "${BCYN}┄ THERMAL BOTTLENECK CHECK${NC}"
    echo ""

    # CPU temp
    local cpu_temp=""
    if command -v sensors >/dev/null 2>&1; then
        cpu_temp=$(sensors 2>/dev/null | awk '/Tctl|Tdie/{gsub(/[+°C]/,"",$2); print $2; exit}' || echo "")
    fi
    [[ -z "$cpu_temp" ]] && cpu_temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -1 | awk '{printf "%.0f", $1/1000}' || echo "?")

    if [[ "$cpu_temp" =~ ^[0-9]+$ ]]; then
        if [[ $cpu_temp -gt 95 ]]; then
            _bp_finding "crit" "CPU temperature: ${cpu_temp}°C — THROTTLING LIKELY" \
                "The CPU is dangerously hot and is almost certainly throttling to prevent damage." \
                "Check: cooling, ambient temp, or switch power profile: powerprofilesctl set balanced"
        elif [[ $cpu_temp -gt 80 ]]; then
            _bp_finding "warn" "CPU temperature: ${cpu_temp}°C — getting hot" \
                "High but within limits. Sustained heat may cause throttling during AI workloads."
        else
            _bp_finding "ok" "CPU temperature: ${cpu_temp}°C" "Cool and comfortable."
        fi
    fi

    # GPU temp
    if [[ -n "$D_GPU_TEMP" && "$D_GPU_TEMP" != "?" ]]; then
        local gt="${D_GPU_TEMP%%.*}"  # strip decimals
        if [[ "$gt" =~ ^[0-9]+$ ]]; then
            if [[ $gt -gt 95 ]]; then
                _bp_finding "crit" "GPU temperature: ${D_GPU_TEMP}°C — THROTTLING" \
                    "GPU is thermal throttling — inference will be significantly slower."
            elif [[ $gt -gt 80 ]]; then
                _bp_finding "warn" "GPU temperature: ${D_GPU_TEMP}°C" "Getting warm under load."
            else
                _bp_finding "ok" "GPU temperature: ${D_GPU_TEMP}°C" "Normal."
            fi
        fi
    fi

    # Throttle check (kernel)
    if [[ -f /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count ]]; then
        local throttle_count; throttle_count=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null || echo "0")
        if [[ "$throttle_count" -gt 0 ]]; then
            _bp_finding "warn" "CPU has throttled ${throttle_count} time(s) since boot" \
                "Thermal throttling has occurred. This reduces performance during heavy loads."
        fi
    fi
}

_bp_kernel() {
    header
    echo -e "${BCYN}┄ KERNEL TUNING CHECK${NC}"
    echo ""

    # vm.swappiness
    local swappiness; swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
    if [[ "$swappiness" =~ ^[0-9]+$ ]] && [[ $swappiness -gt 30 ]]; then
        _bp_finding "warn" "vm.swappiness = ${swappiness}" \
            "Too eager to swap. For systems with lots of RAM doing AI work, lower is better." \
            "sudo sysctl vm.swappiness=10"
    else
        _bp_finding "ok" "vm.swappiness = ${swappiness}" "Good."
    fi

    # vm.dirty_ratio
    local dirty; dirty=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "?")
    if [[ "$dirty" =~ ^[0-9]+$ ]] && [[ $dirty -gt 30 ]]; then
        _bp_finding "warn" "vm.dirty_ratio = ${dirty}" \
            "Large dirty page ratio can cause I/O stalls." \
            "sudo sysctl vm.dirty_ratio=10"
    else
        _bp_finding "ok" "vm.dirty_ratio = ${dirty}" "Fine."
    fi

    # fs.inotify.max_user_watches
    local inotify; inotify=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo "?")
    if [[ "$inotify" =~ ^[0-9]+$ ]] && [[ $inotify -lt 524288 ]]; then
        _bp_finding "warn" "fs.inotify.max_user_watches = ${inotify} (low)" \
            "Low inotify limit can cause 'no space left on device' errors in dev tools." \
            "echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf && sudo sysctl -p"
    else
        _bp_finding "ok" "fs.inotify.max_user_watches = ${inotify}" "Adequate."
    fi

    # Transparent Huge Pages
    local thp; thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "?")
    local thp_active; thp_active=$(echo "$thp" | grep -o '\[.*\]' | tr -d '[]')
    _bp_finding "ok" "Transparent Huge Pages: ${thp_active:-unknown}" "Current THP setting."
}

_bp_full_sweep() {
    header
    echo -e "${BCYN}┄ FULL BOTTLENECK SWEEP ─────────────────────────────────${NC}"
    echo ""
    echo -e "  ${DIM}Scanning CPU, memory, GPU, Docker, storage, thermals, kernel...${NC}"
    echo ""

    # Capture all findings
    _bp_cpu 2>&1 | grep -v "┄\|^$" | head -30
    _bp_memory 2>&1 | grep -v "┄\|^$" | head -30
    _bp_gpu 2>&1 | grep -v "┄\|^$" | head -30
    _bp_docker 2>&1 | grep -v "┄\|^$" | head -30
    _bp_storage 2>&1 | grep -v "┄\|^$" | head -30
    _bp_thermals 2>&1 | grep -v "┄\|^$" | head -20
    _bp_kernel 2>&1 | grep -v "┄\|^$" | head -20

    echo ""
    echo -e "  ${BCYN}Sweep complete.${NC} Press E on the menu to export this as a report."
}

# ──────────────────────────────────────────────────────────
#  MODULE 3: AI ENGINE (Ollama, models, OpenCode, LM Studio)
# ──────────────────────────────────────────────────────────

mod_ai_engine() {
    while true; do
        header
        echo -e "${BCYN}┄ AI ENGINE ────────────────────────────────────────────${NC}"
        echo ""

        # Zenny-Core status
        local zenny_label
        if [[ "$D_ZENNY_RUNNING" == true ]]; then
            zenny_label="${OK} ${#D_ZENNY_MODELS[@]} model(s)  pid:${D_ZENNY_PID:-?}"
        else
            zenny_label="${IDLE} stopped"
        fi
        echo -e "  Zenny-Core  ${zenny_label}"

        # OpenCode status — green only when actually running as a process
        local oc_label oc_ver
        oc_ver=$(_opencode_available && "$(_opencode_cmd)" --version 2>/dev/null | tr -d '\n' || echo "")
        if pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
            oc_label="${OK} RUNNING  v${oc_ver}  →  ${OPENCODE_BIN}"
        elif _opencode_available; then
            oc_label="${IDLE} installed (not running)  v${oc_ver}"
        else
            oc_label="${IDLE} not installed"
        fi
        echo -e "  OpenCode    ${oc_label}"

        # LM Studio status
        local lms_label
        $D_LMS_RUNNING && lms_label="${OK} ${D_LMS_URL}" || lms_label="${IDLE} off"
        echo -e "  LM Studio   ${lms_label}"

        # Ollama status (legacy)
        local olla_label
        if $D_OLLAMA_RUNNING; then
            olla_label="${WARN} ${D_OLLAMA_URL}  (should be disabled)"
        else
            olla_label="${IDLE} disabled"
        fi
        echo -e "  Ollama      ${olla_label}"
        echo ""

        echo "   1)  Zenny-Core             (model load · unload · benchmark · stats)"
        echo "   2)  Ollama                 (legacy — start · stop · settings)"
        echo "   3)  OpenCode              (coding agent · Zed · ACP)"
        echo "   4)  LM Studio             (model downloader)"
        echo ""
        echo "   5)  Switch model"
        echo "   6)  AI session             (OpenCode TUI with system context)"
        echo ""
        echo "   E)  Export report"
        echo "   C)  ✦ Ask AI to diagnose the AI stack"
        echo "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _ai_sub_zenny ;;
            2) _ai_sub_ollama ;;
            3) _ai_sub_opencode ;;
            4) _ai_sub_lms ;;
            5) _ai_switch_model ;;
            6) cc_launch "AI Stack Assistant" \
                "You are an expert on this local AI stack. Review the context and tell me the current state of all AI services, what's working, what could be improved." "$HOME" "--tui" ;;
            E) export_report "AI Engine"; pause ;;
            C) _cc_inline "AI Engine" _ctx_ai_engine _apply_ai_engine; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

# ── Zenny-Core context function ───────────────────────────
_ctx_zenny() {
    printf "Section focus: Zenny-Core inference engine status\n\n"
    printf "Socket:          %s\n" "$D_ZENNY_SOCKET"
    printf "Running:         %s\n" "$(${D_ZENNY_RUNNING} && echo "yes (PID ${D_ZENNY_PID:-?})" || echo 'no')"
    printf "Models loaded:   %s\n" "${#D_ZENNY_MODELS[@]}"
    for m in "${D_ZENNY_MODELS[@]}"; do printf "  - %s\n" "$m"; done
    if [[ "$D_ZENNY_RUNNING" == true ]]; then
        printf "\nStats:\n"
        local stats_resp
        stats_resp=$(_zenny_send '{"cmd":"stats"}' 2>/dev/null || echo "")
        [[ -n "$stats_resp" ]] && echo "$stats_resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    for m in d.get('models',[]):
        print(f'  {m.get(\"name\",\"?\")}  {m.get(\"tok_s\",0):.0f} tok/s')
except: pass
" 2>/dev/null || printf "  (no stats)\n"
    fi
    printf "\nGPU:             %s  Vulkan backend\n" "${D_GPU_GFX:-?}"
    printf "Model dir:       %s\n" "${HOME}/.lmstudio/models/"
}

# ── Zenny-Core sub-menu ────────────────────────────────────
_ai_sub_zenny() {
    while true; do
        header
        echo -e "${BCYN}┄ ZENNY-CORE ───────────────────────────────────────────${NC}"
        echo ""

        if [[ "$D_ZENNY_RUNNING" == true ]]; then
            echo -e "  Status:  ${OK} running  (PID ${D_ZENNY_PID:-?})"
            echo -e "  Socket:  ${DIM}${D_ZENNY_SOCKET}${NC}"
            echo -e "  Models:  ${#D_ZENNY_MODELS[@]} available"
            for m in "${D_ZENNY_MODELS[@]}"; do echo "    · $m"; done
        else
            echo -e "  Status:  ${IDLE} stopped"
            echo -e "  Socket:  ${DIM}${D_ZENNY_SOCKET}${NC}"
        fi
        echo ""
        echo -e "  ${DIM}Binary: ${ZENNY_BINARY}${NC}"
        echo -e "  ${DIM}Models: ~/.lmstudio/models/${NC}"
        _zenny_systemd_status
        echo ""

        echo "   a)  List models            (registry with sizes)"
        echo "   b)  Load model             (pre-warm into GPU memory)"
        echo "   c)  Unload model           (free GPU memory)"
        echo "   d)  Stats                  (tok/s per loaded model)"
        echo "   e)  Benchmark              (run benchmark on a model)"
        echo "   f)  Rescan                 (re-scan ~/.lmstudio/models/)"
        echo "   g)  Start Zenny-Core       (launch process)"
        echo -e "   h)  ${BRED}Stop Zenny-Core${NC}        (kill process)"
        echo "   i)  Install as systemd service  (auto-start on boot)"
        echo ""
        echo "   C)  ✦ Ask AI    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _zenny_list_models; pause ;;
            b) _zenny_load_model; pause ;;
            c) _zenny_unload_model; pause ;;
            d) _zenny_stats; pause ;;
            e) _zenny_benchmark; pause ;;
            f) _zenny_rescan; pause ;;
            g) _zenny_start; pause ;;
            h) _zenny_stop; pause ;;
            i) _zenny_systemd_install; pause ;;
            C) _cc_inline "AI Engine" _ctx_ai_engine _apply_ai_engine ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_zenny_list_models() {
    header
    echo -e "${BCYN}┄ ZENNY-CORE — LIST MODELS${NC}"
    echo ""
    if [[ "$D_ZENNY_RUNNING" != true ]]; then
        echo -e "  ${FAIL}  Zenny-Core not running"; return
    fi
    local resp
    resp=$(_zenny_send '{"cmd":"list_models"}' 2>/dev/null) || { echo -e "  ${FAIL}  No response from socket"; return; }
    echo "$resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    models=d.get('models',[])
    if not models: print('  No models in registry'); sys.exit()
    print(f'  {\"NAME\":<40} {\"SIZE\":>8}  TAGS')
    print(f'  {\"-\"*40} {\"-\"*8}  ----')
    for m in models:
        dn=m.get('display_name','?')
        sz=m.get('size_bytes',0)/(1024**3)
        tags=','.join(m.get('tags',[])) or 'general'
        print(f'  {dn:<40} {sz:>6.1f}G  {tags}')
except Exception as e:
    print(f'  Error: {e}')
" 2>/dev/null || echo "  (parse error)"
}

_zenny_load_model() {
    header
    echo -e "${BCYN}┄ ZENNY-CORE — LOAD MODEL${NC}"
    echo ""
    if [[ "$D_ZENNY_RUNNING" != true ]]; then
        echo -e "  ${FAIL}  Zenny-Core not running"; return
    fi
    if [[ ${#D_ZENNY_MODELS[@]} -eq 0 ]]; then
        echo -e "  ${FAIL}  No models in registry — run Rescan first"; return
    fi
    local i=1
    for m in "${D_ZENNY_MODELS[@]}"; do
        printf "   %d)  %s\n" "$i" "$m"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Select number: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#D_ZENNY_MODELS[@]} ]]; then
        local model="${D_ZENNY_MODELS[$((n-1))]}"
        echo "  Loading ${model}..."
        local resp
        resp=$(_zenny_send "{\"cmd\":\"load_model\",\"name\":\"${model}\"}" 2>/dev/null)
        echo "$resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    if d.get('error'): print(f'  Error: {d[\"error\"]}')
    else: print('  Loaded OK')
except: print('  Done')
" 2>/dev/null || echo -e "  ${WARN}  No response"
    fi
}

_zenny_unload_model() {
    header
    echo -e "${BCYN}┄ ZENNY-CORE — UNLOAD MODEL${NC}"
    echo ""
    if [[ "$D_ZENNY_RUNNING" != true ]]; then
        echo -e "  ${FAIL}  Zenny-Core not running"; return
    fi
    if [[ ${#D_ZENNY_MODELS[@]} -eq 0 ]]; then
        echo -e "  ${IDLE}  No models in registry"; return
    fi
    local i=1
    for m in "${D_ZENNY_MODELS[@]}"; do
        printf "   %d)  %s\n" "$i" "$m"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Select number: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#D_ZENNY_MODELS[@]} ]]; then
        local model="${D_ZENNY_MODELS[$((n-1))]}"
        echo "  Unloading ${model}..."
        local resp
        resp=$(_zenny_send "{\"cmd\":\"unload_model\",\"name\":\"${model}\"}" 2>/dev/null)
        echo "$resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    if d.get('error'): print(f'  Error: {d[\"error\"]}')
    else: print('  Unloaded OK — GPU memory freed')
except: print('  Done')
" 2>/dev/null || echo -e "  ${WARN}  No response"
    fi
}

_zenny_stats() {
    header
    echo -e "${BCYN}┄ ZENNY-CORE — STATS${NC}"
    echo ""
    if [[ "$D_ZENNY_RUNNING" != true ]]; then
        echo -e "  ${FAIL}  Zenny-Core not running"; return
    fi
    local resp
    resp=$(_zenny_send '{"cmd":"stats"}' 2>/dev/null) || { echo -e "  ${FAIL}  No response"; return; }
    echo "$resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    models=d.get('models',[])
    if not models: print('  No models currently loaded')
    else:
        print(f'  {\"MODEL\":<40} {\"TOK/S\":>8}')
        print(f'  {\"-\"*40} {\"-\"*8}')
        for m in models:
            print(f'  {m.get(\"name\",\"?\"):<40} {m.get(\"tok_s\",0):>7.0f}')
except Exception as e:
    print(f'  {d}')
" 2>/dev/null || echo "  (parse error)"
}

_zenny_benchmark() {
    header
    echo -e "${BCYN}┄ ZENNY-CORE — BENCHMARK${NC}"
    echo ""
    if [[ "$D_ZENNY_RUNNING" != true ]]; then
        echo -e "  ${FAIL}  Zenny-Core not running"; return
    fi
    if [[ ${#D_ZENNY_MODELS[@]} -eq 0 ]]; then
        echo -e "  ${FAIL}  No models in registry"; return
    fi
    local i=1
    for m in "${D_ZENNY_MODELS[@]}"; do
        printf "   %d)  %s\n" "$i" "$m"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Select number: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#D_ZENNY_MODELS[@]} ]]; then
        local model="${D_ZENNY_MODELS[$((n-1))]}"
        echo "  Benchmarking ${model} (this may take a moment)..."
        local resp
        resp=$(_zenny_send "{\"cmd\":\"benchmark\",\"name\":\"${model}\"}" 2>/dev/null)
        echo "$resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    if d.get('error'): print(f'  Error: {d[\"error\"]}')
    else:
        print(f'  tok/s: {d.get(\"tok_s\",\"?\"):.1f}' if isinstance(d.get('tok_s'),float) else f'  Result: {d}')
except: print(f'  Raw: {resp}')
" 2>/dev/null || echo -e "  ${WARN}  No response"
    fi
}

_zenny_rescan() {
    header
    echo -e "${BCYN}┄ ZENNY-CORE — RESCAN${NC}"
    echo ""
    if [[ "$D_ZENNY_RUNNING" != true ]]; then
        echo -e "  ${FAIL}  Zenny-Core not running"; return
    fi
    echo "  Rescanning ~/.lmstudio/models/ ..."
    local resp
    resp=$(_zenny_send '{"cmd":"rescan"}' 2>/dev/null) || { echo -e "  ${FAIL}  No response"; return; }
    echo "$resp" | python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    if d.get('error'): print(f'  Error: {d[\"error\"]}')
    else: print(f'  Rescan complete — {len(d.get(\"models\",[]))} model(s) found')
except: print('  Done')
" 2>/dev/null || echo -e "  ${OK}  Rescan sent"
    _disc_zenny
    echo -e "  ${OK}  Registry updated: ${#D_ZENNY_MODELS[@]} model(s)"
}

_zenny_start() {
    header
    echo -e "${BCYN}┄ START ZENNY-CORE${NC}"
    echo ""
    # Always do a live check — never rely on cached D_ZENNY_RUNNING here
    _disc_zenny 2>/dev/null
    if [[ "$D_ZENNY_RUNNING" == true ]]; then
        echo -e "  ${OK}  Zenny-Core already running (PID ${D_ZENNY_PID:-?})"; return
    fi
    # Extra guard: pgrep in case _disc_zenny missed it
    if pgrep -x "$ZENNY_PROCESS" >/dev/null 2>&1; then
        echo -e "  ${WARN}  ${ZENNY_PROCESS} process found but socket not ready — check logs"
        echo -e "  ${DIM}  tail ${ZENNY_LOG}${NC}"; return
    fi
    if [[ ! -x "$ZENNY_BINARY" ]]; then
        echo -e "  ${FAIL}  Binary not found: ${ZENNY_BINARY}"; return
    fi
    echo "  Starting Zenny-Core..."
    RUST_LOG=zenny_core=info "$ZENNY_BINARY" &>"$ZENNY_LOG" &
    sleep 2
    _disc_zenny
    if [[ "$D_ZENNY_RUNNING" == true ]]; then
        echo -e "  ${OK}  Zenny-Core started (PID ${D_ZENNY_PID:-?})"
        echo -e "  ${DIM}  Logs: ${ZENNY_LOG}${NC}"
    else
        echo -e "  ${FAIL}  Failed to start — check: tail ${ZENNY_LOG}"
    fi
}

_zenny_stop() {
    header
    echo -e "${BCYN}┄ STOP ZENNY-CORE${NC}"
    echo ""
    if [[ "$D_ZENNY_RUNNING" == false ]]; then
        echo -e "  ${IDLE}  Zenny-Core is not running"; return
    fi
    echo "  Stopping Zenny-Core (PID ${D_ZENNY_PID:-?})..."
    if [[ -n "$D_ZENNY_PID" ]]; then
        kill "$D_ZENNY_PID" 2>/dev/null && echo -e "  ${OK}  Stopped" \
            || echo -e "  ${FAIL}  Could not kill PID ${D_ZENNY_PID}"
    else
        pkill -x "$ZENNY_PROCESS" 2>/dev/null && echo -e "  ${OK}  Stopped" \
            || echo -e "  ${FAIL}  Could not find process"
    fi
    D_ZENNY_RUNNING=false
    D_ZENNY_PID=""
    D_ZENNY_MODELS=()
}

# ── Zenny-Core systemd service management ─────────────────
_ZENNY_SERVICE="zenny-core"
_ZENNY_SERVICE_FILE="/etc/systemd/system/${_ZENNY_SERVICE}.service"

_zenny_systemd_install() {
    header
    echo -e "${BCYN}┄ INSTALL ZENNY-CORE SYSTEMD SERVICE${NC}"
    echo ""
    if [[ ! -x "$ZENNY_BINARY" ]]; then
        echo -e "  ${FAIL}  Binary not found: ${ZENNY_BINARY}"
        echo -e "  ${DIM}  Build: cargo build --release --features vulkan, then set ZMENU_ZENNY_BINARY in ~/.zmenu/config${NC}"
        return
    fi
    if systemctl is-active --quiet "$_ZENNY_SERVICE" 2>/dev/null; then
        echo -e "  ${OK}  Service already installed and active"
        systemctl status "$_ZENNY_SERVICE" --no-pager -l 2>/dev/null | head -10 | sed 's/^/  /'
        return
    fi
    echo "  Creating ${_ZENNY_SERVICE_FILE}..."
    sudo tee "$_ZENNY_SERVICE_FILE" > /dev/null << SVCEOF
[Unit]
Description=Zenny-Core local AI inference engine
After=network.target

[Service]
Type=simple
User=${USER}
ExecStart=${ZENNY_BINARY}
Restart=on-failure
RestartSec=5
StandardOutput=append:${ZENNY_LOG}
StandardError=append:${ZENNY_LOG}
Environment=RUST_LOG=zenny_core=info

[Install]
WantedBy=default.target
SVCEOF
    sudo systemctl daemon-reload
    sudo systemctl enable "$_ZENNY_SERVICE"
    sudo systemctl start  "$_ZENNY_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$_ZENNY_SERVICE" 2>/dev/null; then
        echo -e "  ${OK}  Service installed, enabled, and started"
        echo -e "  ${DIM}  Logs: journalctl -u ${_ZENNY_SERVICE} -f${NC}"
    else
        echo -e "  ${FAIL}  Service failed to start — check: journalctl -u ${_ZENNY_SERVICE}"
    fi
}

_zenny_systemd_status() {
    if ! [[ -f "$_ZENNY_SERVICE_FILE" ]]; then
        echo -e "  ${IDLE}  Systemd service not installed  ${DIM}(use AI Engine → Install as service)${NC}"
        return
    fi
    local state; state=$(systemctl is-active "$_ZENNY_SERVICE" 2>/dev/null || echo "unknown")
    local enabled; enabled=$(systemctl is-enabled "$_ZENNY_SERVICE" 2>/dev/null || echo "unknown")
    echo -e "  Systemd:  ${state}  (enabled: ${enabled})"
}

# ── OpenCode sub-menu ─────────────────────────────────────
_ai_sub_opencode() {
    while true; do
        header
        echo -e "${BCYN}┄ OPENCODE ─────────────────────────────────────────────${NC}"
        echo ""

        local oc_cmd oc_ver
        oc_cmd="$(_opencode_cmd)"
        if [[ -n "$oc_cmd" ]]; then
            oc_ver=$("$oc_cmd" --version 2>/dev/null || echo "?")
            echo -e "  Status:   ${OK} installed   v${oc_ver}"
            echo -e "  Binary:   ${DIM}${oc_cmd}${NC}"
        else
            echo -e "  Status:   ${FAIL} not installed"
            echo -e "  Install:  ${DIM}curl -fsSL https://opencode.ai/install | bash${NC}"
        fi
        echo ""
        echo -e "  ${DIM}Config:   ${OPENCODE_CFG}/opencode.json${NC}"
        echo -e "  ${DIM}Rules:    ${OPENCODE_CFG}/rules.md  (zmenu context)${NC}"
        echo -e "  ${DIM}ACP:      Zed → agent panel → + → OpenCode${NC}"
        echo ""

        local cfg="${OPENCODE_CFG}/opencode.json"
        if [[ -f "$cfg" ]]; then
            echo -e "  ${OK}  opencode.json present"
            python3 -c "
import json
try:
    d = json.load(open('${cfg}'))
    for p, v in d.get('provider', {}).items():
        models = list(v.get('models', {}).keys())
        print(f'  Provider: {p}  ({len(models)} model(s): {\", \".join(models[:4])})')
except: pass
" 2>/dev/null || true
        else
            echo -e "  ${WARN}  No opencode.json — run option 3 to configure"
        fi
        echo ""

        local oc_running="not running"
        pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1 && oc_running="RUNNING (pid: $(pgrep -x "$OPENCODE_PROCESS" | head -1))"
        echo -e "  Process:  ${DIM}${oc_running}${NC}"
        echo ""
        echo "   1)  Launch OpenCode TUI      (interactive session)"
        echo "   2)  Launch in projects dir"
        echo "   3)  Configure Ollama provider  (auto-detect models)"
        echo "   4)  Edit opencode.json"
        echo "   5)  Upgrade OpenCode"
        echo "   6)  Open in Zed via ACP"
        echo "   s)  Stop OpenCode             (pkill with verify)"
        echo ""
        echo "   C)  ✦ Ask AI    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1)
                if [[ -n "$oc_cmd" ]]; then
                    echo -e "  ${DIM}Launching OpenCode TUI... (exit to return to zmenu)${NC}"
                    sleep 0.3
                    (cd "$HOME" && "$oc_cmd") || true
                else
                    echo -e "  ${FAIL}  OpenCode not installed"
                fi
                pause ;;
            2)
                cc_launch "OpenCode — Project Session" \
                    "You are a coding assistant. Review the project context and help with development tasks." \
                    "${ZMENU_PROJECTS_DIR}" "--tui" ;;
            3) _oc_configure_ollama; pause ;;
            4)
                mkdir -p "${OPENCODE_CFG}"
                ${ZMENU_PREFERRED_EDITOR} "${OPENCODE_CFG}/opencode.json"
                pause ;;
            5)
                if [[ -n "$oc_cmd" ]]; then
                    "$oc_cmd" upgrade && echo -e "  ${OK}  Upgraded" \
                        || echo -e "  ${FAIL}  Upgrade failed"
                else
                    echo -e "  ${FAIL}  OpenCode not installed"
                fi
                pause ;;
            6)
                if command -v zed >/dev/null 2>&1; then
                    zed . &>/dev/null &
                    echo -e "  ${OK}  Zed launched — open Agent Panel and select OpenCode"
                else
                    echo -e "  ${WARN}  zed not in PATH"
                fi
                pause ;;
            s|S) _opencode_stop; pause ;;
            C) _cc_inline "OpenCode" _ctx_opencode _apply_opencode; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_oc_configure_ollama() {
    header
    echo -e "${BCYN}┄ CONFIGURE OPENCODE → OLLAMA${NC}"
    echo ""
    echo "  Writing opencode.json with your current Ollama models..."
    echo ""

    mkdir -p "${OPENCODE_CFG}"

    local models_json=""
    for m in "${D_OLLAMA_MODELS[@]}"; do
        local display="${m%%:*}"
        models_json+="        \"${m}\": { \"name\": \"${display}\" },\n"
    done
    # strip trailing comma
    models_json="${models_json%,\\n}"

    cat > "${OPENCODE_CFG}/opencode.json" << OCEOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
$(printf '%b' "$models_json")
      }
    }
  }
}
OCEOF

    echo -e "  ${OK}  Written: ${OPENCODE_CFG}/opencode.json"
    echo ""
    echo "  Models registered:"
    for m in "${D_OLLAMA_MODELS[@]}"; do
        echo "    • ${m}"
    done
    echo ""
    echo -e "  ${DIM}Launch OpenCode and use /models to select one${NC}"
}

# ── Ollama sub-menu ────────────────────────────────────────
_ai_sub_ollama() {
    while true; do
        header
        echo -e "${BCYN}┄ OLLAMA ───────────────────────────────────────────────${NC}"
        echo -e "  ${WARN}  ${DIM}Legacy backend — replaced by Zenny-Core (Vulkan). Settings preserved for reference.${NC}"
        echo ""

        if [[ "$D_OLLAMA_RUNNING" == true ]]; then
            echo -e "  Status:  ${OK} running at ${D_OLLAMA_URL}   v${D_AI_VER:-?}"
            if [[ -n "$D_OLLAMA_ACTIVE_MODEL" ]]; then
                local vram_info=""
                local ps_json
                ps_json=$(curl -sf "${D_OLLAMA_URL}/api/ps" 2>/dev/null || true)
                if [[ -n "$ps_json" ]]; then
                    vram_info=$(echo "$ps_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for m in d.get('models', []):
        sz = m.get('size_vram', 0) / (1024**3)
        print(f'({sz:.1f} GB VRAM)')
except: pass
" 2>/dev/null || true)
                fi
                echo -e "  Active:  ${BCYN}${D_OLLAMA_ACTIVE_MODEL}${NC}  ${vram_info}"
            else
                echo -e "  Active:  ${IDLE} no model loaded"
            fi
            echo "  Context: ${ZMENU_AI_CONTEXT_LENGTH} tokens"

            # ── Live env snapshot (key vars only) ─────────────
            local _fa _kv _ka _mp _np _hsa
            _fa=$(sudo systemctl show ollama --property=Environment 2>/dev/null \
                | grep -o 'OLLAMA_FLASH_ATTENTION=[^ ]*' | cut -d= -f2 || echo "?")
            _kv=$(sudo systemctl show ollama --property=Environment 2>/dev/null \
                | grep -o 'OLLAMA_KV_CACHE_TYPE=[^ ]*' | cut -d= -f2 || echo "?")
            _ka=$(sudo systemctl show ollama --property=Environment 2>/dev/null \
                | grep -o 'OLLAMA_KEEP_ALIVE=[^ ]*' | cut -d= -f2 || echo "?")
            _mp=$(sudo systemctl show ollama --property=Environment 2>/dev/null \
                | grep -o 'OLLAMA_MAX_LOADED_MODELS=[^ ]*' | cut -d= -f2 || echo "?")
            _np=$(sudo systemctl show ollama --property=Environment 2>/dev/null \
                | grep -o 'OLLAMA_NUM_PARALLEL=[^ ]*' | cut -d= -f2 || echo "?")
            _hsa=$(sudo systemctl show ollama --property=Environment 2>/dev/null \
                | grep -o 'HSA_OVERRIDE_GFX_VERSION=[^ ]*' | cut -d= -f2 || echo "?")
            echo ""
            echo -e "  ${DIM}Flash Attn: ${_fa:-–}  KV Cache: ${_kv:-–}  Keep Alive: ${_ka:-–}  Max Models: ${_mp:-–}  Parallel: ${_np:-–}  HSA: ${_hsa:-–}${NC}"
        else
            echo -e "  Status:  ${FAIL} stopped"
        fi
        echo ""

        if [[ ${#D_OLLAMA_MODELS[@]} -gt 0 ]]; then
            echo -e "  ${DIM}NAME                            SIZE        TOOLS${NC}"
            echo -e "  ${DIM}──────────────────────────────────────────────────${NC}"
            for m in "${D_OLLAMA_MODELS[@]}"; do
                local sz; sz=$(ollama list 2>/dev/null | awk -v n="$m" '$1==n{print $3,$4}')
                local tools="no"
                for tm in "${D_OLLAMA_TOOL_MODELS[@]}"; do [[ "$tm" == "$m" ]] && tools="${BGRN}yes${NC}"; done
                local marker=""
                [[ "$m" == "$ZMENU_AI_MODEL" ]] && marker=" ${DIM}← active${NC}"
                printf "  %-30s  %-10s  %b%b\n" "$m" "$sz" "$tools" "$marker"
            done
            echo ""
        fi

        echo "   1)  Switch model"
        echo "   2)  Context window"
        echo -e "   3)  ${BRED}Stop Ollama${NC}"
        echo "   4)  Start Ollama"
        echo "   5)  Unload model            (free VRAM, keep running)"
        echo "   6)  Settings                (systemd override)"
        echo ""
        echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _ai_switch_model ;;
            2) _ai_set_context_length ;;
            3) _ai_stop_ollama; pause ;;
            4) _ai_start_ollama; pause ;;
            5) _ai_unload_model; pause ;;
            6) _ai_ollama_settings ;;
            E) export_report "Ollama"; pause ;;
            C) _cc_inline "Ollama Settings" _ctx_ollama_settings _apply_ollama_settings; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

# ── Helper: read a single env var from the active systemd unit ──
_ollama_get_env() {
    # Usage: _ollama_get_env VARNAME
    sudo systemctl show ollama --property=Environment 2>/dev/null \
        | grep -o "${1}=[^ ]*" | cut -d= -f2 || echo "–"
}

# ── Helper: read a single env var from override.conf (set value) ──
_ollama_get_override() {
    local key="$1"
    local override_dir="/etc/systemd/system/ollama.service.d"
    grep -rh "Environment=\"${key}=" "${override_dir}"/*.conf 2>/dev/null \
        | sed "s/.*${key}=\([^\"]*\)\".*/\1/" | head -1 || echo "–"
}

_ai_ollama_settings() {
    while true; do
        header
        echo -e "${BCYN}┄ OLLAMA SETTINGS ──────────────────────────────────────${NC}"
        echo ""
        local override_dir="/etc/systemd/system/ollama.service.d"
        echo -e "  ${DIM}Source: ${override_dir}/override.conf${NC}"
        echo ""

        # Read all relevant vars from override file
        local v_host v_flash v_kv v_ka v_maxm v_npar v_mq v_hsa v_rocr v_dnt v_noprune v_debug v_origins
        v_host=$(_ollama_get_override "OLLAMA_HOST")
        v_flash=$(_ollama_get_override "OLLAMA_FLASH_ATTENTION")
        v_kv=$(_ollama_get_override "OLLAMA_KV_CACHE_TYPE")
        v_ka=$(_ollama_get_override "OLLAMA_KEEP_ALIVE")
        v_maxm=$(_ollama_get_override "OLLAMA_MAX_LOADED_MODELS")
        v_npar=$(_ollama_get_override "OLLAMA_NUM_PARALLEL")
        v_mq=$(_ollama_get_override "OLLAMA_MAX_QUEUE")
        v_hsa=$(_ollama_get_override "HSA_OVERRIDE_GFX_VERSION")
        v_rocr=$(_ollama_get_override "ROCR_VISIBLE_DEVICES")
        v_dnt=$(_ollama_get_override "DO_NOT_TRACK")
        v_noprune=$(_ollama_get_override "OLLAMA_NOPRUNE")
        v_debug=$(_ollama_get_override "OLLAMA_DEBUG")
        v_origins=$(_ollama_get_override "OLLAMA_ORIGINS")

        # Display — two columns: variable | current value | description
        echo -e "  ${BOLD}── Network ──────────────────────────────────────────${NC}"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_HOST" "${v_host}" "Bind address (0.0.0.0 = all interfaces)"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_ORIGINS" "${v_origins}" "Allowed CORS origins (* = any)"
        echo ""
        echo -e "  ${BOLD}── Performance ──────────────────────────────────────${NC}"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_FLASH_ATTENTION" "${v_flash}" "Cuts KV cache VRAM ~40% — recommend ON (1)"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_KV_CACHE_TYPE" "${v_kv}" "KV cache quant: f16 | q8_0 | q4_0 — q8_0 saves RAM"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_NUM_PARALLEL" "${v_npar}" "Concurrent requests (1 = no contention)"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_MAX_QUEUE" "${v_mq}" "Request queue depth before rejecting"
        echo ""
        echo -e "  ${BOLD}── Memory ───────────────────────────────────────────${NC}"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_KEEP_ALIVE" "${v_ka}" "Hold model in RAM after last req (0/-1/5m/24h)"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_MAX_LOADED_MODELS" "${v_maxm}" "Max models in RAM simultaneously"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_NOPRUNE" "${v_noprune}" "Prevent auto-deletion of model files (1=on)"
        echo ""
        echo -e "  ${BOLD}── GPU / ROCm (${D_GPU_GFX:-unknown}) ───────────────────────${NC}"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "HSA_OVERRIDE_GFX_VERSION" "${v_hsa}" "CRITICAL: must match your GPU gfx ID (gfx1151 → 11.5.1)"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "ROCR_VISIBLE_DEVICES" "${v_rocr}" "Pin to GPU 0 (unified memory)"
        echo ""
        echo -e "  ${BOLD}── Privacy / Debug ──────────────────────────────────${NC}"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "DO_NOT_TRACK" "${v_dnt}" "Telemetry opt-out"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "OLLAMA_DEBUG" "${v_debug}" "Verbose logging (1=on, use for troubleshooting)"
        echo ""
        echo -e "  ${BOLD}── zmenu (per-request, not systemd) ─────────────────${NC}"
        printf "  %-35s ${BCYN}%-12s${NC}  ${DIM}%s${NC}\n" "num_ctx" "${ZMENU_AI_CONTEXT_LENGTH}" "Context window sent with each API request"
        echo ""

        echo "   1)  Flash Attention          (ON/OFF)"
        echo "   2)  KV Cache Type            (f16 / q8_0 / q4_0)"
        echo "   3)  Keep Alive               (unload timer)"
        echo "   4)  Max Loaded Models"
        echo "   5)  Num Parallel             (concurrent requests)"
        echo "   6)  Max Queue"
        echo "   7)  HSA GFX Version          (ROCm GPU hint)"
        echo "   8)  ROCR Visible Devices"
        echo "   9)  Ollama Host              (bind address)"
        echo "   0)  OLLAMA_ORIGINS           (CORS)"
        echo "   a)  DO_NOT_TRACK / NOPRUNE   (privacy)"
        echo "   b)  OLLAMA_DEBUG             (verbose logging)"
        echo "   c)  Apply full recommended profile for ZBook"
        echo "   d)  Raw edit override.conf"
        echo "   R)  Reload Ollama            (apply changes)"
        echo ""
        echo "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _ai_set_flash_attn; pause ;;
            2) _ai_set_kv_cache; pause ;;
            3) _ai_set_keep_alive; pause ;;
            4) _ai_set_max_models; pause ;;
            5) _ai_set_num_parallel; pause ;;
            6) _ai_set_max_queue; pause ;;
            7) _ai_set_hsa_gfx; pause ;;
            8) _ai_set_rocr_devices; pause ;;
            9) _ai_set_ollama_host; pause ;;
            0) _ai_set_ollama_origins; pause ;;
            a) _ai_set_privacy; pause ;;
            b) _ai_set_debug; pause ;;
            c) _ai_apply_zbook_profile; pause ;;
            d) _ai_edit_ollama_override; pause ;;
            R) _ai_reload_ollama; pause ;;
            r) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_ai_edit_ollama_override() {
    local override_dir="/etc/systemd/system/ollama.service.d"
    local override_file="${override_dir}/override.conf"
    if [[ ! -d "$override_dir" ]]; then
        echo "  Creating override directory..."
        sudo mkdir -p "$override_dir" 2>/dev/null || { echo -e "  ${FAIL}  Failed (need sudo)"; return; }
    fi
    if [[ ! -f "$override_file" ]]; then
        echo "  Creating default override file..."
        sudo tee "$override_file" >/dev/null 2>&1 << 'OLLAMAEOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_KEEP_ALIVE=10m"
Environment="OLLAMA_MAX_QUEUE=8"
Environment="HSA_OVERRIDE_GFX_VERSION=11.5.1"
Environment="ROCR_VISIBLE_DEVICES=0"
Environment="DO_NOT_TRACK=1"
Environment="OLLAMA_NOPRUNE=1"
OLLAMAEOF
    fi
    sudo ${ZMENU_PREFERRED_EDITOR} "$override_file"
    echo -e "  ${DIM}  Remember to press R (Reload Ollama) to apply changes${NC}"
}

_ai_ollama_env_set() {
    local key="$1" val="$2"
    local override_dir="/etc/systemd/system/ollama.service.d"
    local override_file="${override_dir}/override.conf"
    if [[ ! -d "$override_dir" ]]; then
        sudo mkdir -p "$override_dir" 2>/dev/null || { echo -e "  ${FAIL}  Failed"; return 1; }
    fi
    if [[ ! -f "$override_file" ]]; then
        sudo bash -c "echo '[Service]' > '${override_file}'" 2>/dev/null
    fi
    if sudo grep -q "Environment=\"${key}=" "$override_file" 2>/dev/null; then
        sudo sed -i "s|Environment=\"${key}=.*\"|Environment=\"${key}=${val}\"|" "$override_file" 2>/dev/null
    else
        sudo bash -c "echo 'Environment=\"${key}=${val}\"' >> '${override_file}'" 2>/dev/null
    fi
    echo -e "  ${OK}  Set ${key}=${val}"
}

_ai_set_flash_attn() {
    header
    echo -e "${BCYN}┄ FLASH ATTENTION${NC}"
    echo ""
    echo "  Reduces KV cache VRAM usage by ~40% and speeds up inference."
    echo "  On your ZBook unified memory pool, this is always recommended ON."
    echo ""
    echo "   1)  ON   (recommended)"
    echo "   2)  OFF"
    echo ""
    read -rp "  Select (1-2): " n
    case $n in
        1) _ai_ollama_env_set "OLLAMA_FLASH_ATTENTION" "1" ;;
        2) _ai_ollama_env_set "OLLAMA_FLASH_ATTENTION" "0" ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_kv_cache() {
    header
    echo -e "${BCYN}┄ KV CACHE TYPE${NC}"
    echo ""
    echo "  Controls quantization of the KV attention cache."
    echo "  Lower precision = less RAM per token = longer effective context."
    echo ""
    echo "   1)  f16    — full precision, most accurate, highest VRAM"
    echo "   2)  q8_0   — 8-bit quant, minimal quality loss (recommended)"
    echo "   3)  q4_0   — 4-bit quant, half the VRAM of f16, slight quality drop"
    echo ""
    read -rp "  Select (1-3): " n
    local val=""
    case $n in
        1) val="f16" ;; 2) val="q8_0" ;; 3) val="q4_0" ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    _ai_ollama_env_set "OLLAMA_KV_CACHE_TYPE" "$val"
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_keep_alive() {
    header
    echo -e "${BCYN}┄ KEEP ALIVE${NC}"
    echo ""
    echo "  How long to hold a model in RAM after the last request."
    echo "  Longer = faster next response, more RAM held. Shorter = RAM freed sooner."
    echo ""
    echo "   1)  0       — unload immediately after each request"
    echo "   2)  5m      — 5 minutes"
    echo "   3)  10m     — 10 minutes (recommended)"
    echo "   4)  30m     — 30 minutes"
    echo "   5)  24h     — keep loaded all day"
    echo "   6)  -1      — never unload (until manual or restart)"
    echo "   7)  custom  — enter your own value"
    echo ""
    read -rp "  Select (1-7): " n
    local val=""
    case $n in
        1) val="0" ;; 2) val="5m" ;; 3) val="10m" ;;
        4) val="30m" ;; 5) val="24h" ;; 6) val="-1" ;;
        7) read -rp "  Enter value (e.g. 2h, 45m, 3600): " val ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    _ai_ollama_env_set "OLLAMA_KEEP_ALIVE" "$val"
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_max_models() {
    header
    echo -e "${BCYN}┄ MAX LOADED MODELS${NC}"
    echo ""
    echo "  Maximum number of models held in RAM simultaneously."
    echo "  On unified memory, loading multiple large models will fragment your pool."
    echo ""
    echo "   1)  1  — recommended (prevents contention, best for 23–36 GB models)"
    echo "   2)  2  — only with small models (< 8 GB each)"
    echo "   3)  3  — risky, only for embed + tiny models"
    echo ""
    read -rp "  Select (1-3): " n
    local val=""
    case $n in 1) val="1" ;; 2) val="2" ;; 3) val="3" ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;; esac
    _ai_ollama_env_set "OLLAMA_MAX_LOADED_MODELS" "$val"
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_num_parallel() {
    header
    echo -e "${BCYN}┄ NUM PARALLEL${NC}"
    echo ""
    echo "  How many requests Ollama processes simultaneously per model."
    echo "  Higher = more throughput but more RAM per slot."
    echo "  For a single-user local setup, 1 is ideal."
    echo ""
    echo "   1)  1  — recommended for local single-user (no contention)"
    echo "   2)  2  — useful if running Open WebUI + CLI simultaneously"
    echo "   3)  4  — only if running a shared/team instance"
    echo ""
    read -rp "  Select (1-3): " n
    local val=""
    case $n in 1) val="1" ;; 2) val="2" ;; 3) val="4" ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;; esac
    _ai_ollama_env_set "OLLAMA_NUM_PARALLEL" "$val"
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_max_queue() {
    header
    echo -e "${BCYN}┄ MAX QUEUE${NC}"
    echo ""
    echo "  Max number of requests queued before Ollama starts rejecting."
    echo "  For local use, 8 is more than enough."
    echo ""
    echo "   1)  4   — tight queue, faster rejection on overload"
    echo "   2)  8   — recommended"
    echo "   3)  16  — larger queue for multi-user / n8n pipelines"
    echo "   4)  custom"
    echo ""
    read -rp "  Select (1-4): " n
    local val=""
    case $n in
        1) val="4" ;; 2) val="8" ;; 3) val="16" ;;
        4) read -rp "  Enter value: " val ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    _ai_ollama_env_set "OLLAMA_MAX_QUEUE" "$val"
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_hsa_gfx() {
    header
    echo -e "${BCYN}┄ HSA_OVERRIDE_GFX_VERSION${NC}"
    echo ""
    echo "  Tells ROCm which GPU architecture to target."
    echo "  Your GPU (${D_GPU_GFX:-unknown}) may not be in ROCm's official support table."
    echo "  This override tells ROCm which architecture to target — required for GPU inference."
    echo "  Without this, Ollama falls back to CPU (10× slower)."
    echo ""
    echo "   1)  11.5.1  — correct for gfx1151 (Strix Halo / Radeon 8060S)"
    echo "   2)  custom  — enter manually"
    echo ""
    read -rp "  Select (1-2): " n
    local val=""
    case $n in
        1) val="11.5.1" ;;
        2) read -rp "  Enter GFX version (e.g. 11.0.0): " val ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    _ai_ollama_env_set "HSA_OVERRIDE_GFX_VERSION" "$val"
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_rocr_devices() {
    header
    echo -e "${BCYN}┄ ROCR_VISIBLE_DEVICES${NC}"
    echo ""
    echo "  Pins Ollama to a specific GPU index."
    echo "  Your ZBook has one GPU (index 0). Setting this prevents accidental CPU fallback."
    echo ""
    echo "   1)  0   — GPU 0 (correct for ZBook)"
    echo "   2)  unset — let ROCm auto-select"
    echo ""
    read -rp "  Select (1-2): " n
    case $n in
        1) _ai_ollama_env_set "ROCR_VISIBLE_DEVICES" "0" ;;
        2)
            local override_file="/etc/systemd/system/ollama.service.d/override.conf"
            sudo sed -i '/Environment="ROCR_VISIBLE_DEVICES=/d' "$override_file" 2>/dev/null \
                && echo -e "  ${OK}  Removed ROCR_VISIBLE_DEVICES" \
                || echo -e "  ${FAIL}  Could not edit file" ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_ollama_host() {
    header
    echo -e "${BCYN}┄ OLLAMA HOST${NC}"
    echo ""
    echo "  Which address Ollama binds to."
    echo ""
    echo "   1)  0.0.0.0      — all interfaces (LAN accessible)"
    echo "   2)  127.0.0.1    — localhost only (most secure)"
    echo "   3)  custom       — enter manually"
    echo ""
    read -rp "  Select (1-3): " n
    local val=""
    case $n in
        1) val="0.0.0.0" ;; 2) val="127.0.0.1" ;;
        3) read -rp "  Enter address (e.g. 192.168.1.100): " val ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    _ai_ollama_env_set "OLLAMA_HOST" "$val"
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_ollama_origins() {
    header
    echo -e "${BCYN}┄ OLLAMA ORIGINS (CORS)${NC}"
    echo ""
    echo "  Controls which browser origins can call the Ollama API."
    echo "  Open WebUI requires this to be set to * or its specific URL."
    echo ""
    echo "   1)  *                    — allow all (recommended for local Open WebUI)"
    echo "   2)  http://localhost:3000 — Open WebUI only"
    echo "   3)  custom               — enter manually"
    echo ""
    read -rp "  Select (1-3): " n
    local val=""
    case $n in
        1) val="*" ;; 2) val="http://localhost:3000" ;;
        3) read -rp "  Enter origin: " val ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    _ai_ollama_env_set "OLLAMA_ORIGINS" "$val"
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_privacy() {
    header
    echo -e "${BCYN}┄ PRIVACY SETTINGS${NC}"
    echo ""
    echo "  DO_NOT_TRACK=1    — opt out of Ollama telemetry"
    echo "  OLLAMA_NOPRUNE=1  — prevent Ollama auto-deleting model files"
    echo ""
    echo "   1)  Enable both  (recommended)"
    echo "   2)  Disable both"
    echo "   3)  DO_NOT_TRACK only"
    echo "   4)  OLLAMA_NOPRUNE only"
    echo ""
    read -rp "  Select (1-4): " n
    case $n in
        1) _ai_ollama_env_set "DO_NOT_TRACK" "1"
           _ai_ollama_env_set "OLLAMA_NOPRUNE" "1" ;;
        2) _ai_ollama_env_set "DO_NOT_TRACK" "0"
           _ai_ollama_env_set "OLLAMA_NOPRUNE" "0" ;;
        3) _ai_ollama_env_set "DO_NOT_TRACK" "1" ;;
        4) _ai_ollama_env_set "OLLAMA_NOPRUNE" "1" ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_set_debug() {
    header
    echo -e "${BCYN}┄ OLLAMA DEBUG${NC}"
    echo ""
    echo "  Enables verbose logging to journald."
    echo "  Use when troubleshooting GPU fallback, model load failures, or slow inference."
    echo "  Turn off during normal use — it writes a lot."
    echo ""
    echo "   1)  OFF  — normal operation (recommended)"
    echo "   2)  ON   — verbose logging"
    echo ""
    read -rp "  Select (1-2): " n
    case $n in
        1) _ai_ollama_env_set "OLLAMA_DEBUG" "0" ;;
        2) _ai_ollama_env_set "OLLAMA_DEBUG" "1" ;;
        *) echo -e "${RED}  Invalid.${NC}"; return ;;
    esac
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama${NC}"
}

_ai_apply_zbook_profile() {
    header
    echo -e "${BCYN}┄ APPLY ZBOOK RECOMMENDED PROFILE${NC}"
    echo ""
    echo "  This will write the full recommended configuration for:"
    echo "  ${ZMENU_MACHINE_LABEL:-this machine} (${D_GPU_GFX:-unknown} / ${D_MEM_TOTAL_MB:-?} MB unified memory)"
    echo ""
    echo -e "  ${BYEL}Settings to be applied:${NC}"
    echo "    OLLAMA_HOST              = 0.0.0.0"
    echo "    OLLAMA_FLASH_ATTENTION   = 1"
    echo "    OLLAMA_KV_CACHE_TYPE     = q8_0"
    echo "    OLLAMA_MAX_LOADED_MODELS = 1"
    echo "    OLLAMA_NUM_PARALLEL      = 1"
    echo "    OLLAMA_KEEP_ALIVE        = 10m"
    echo "    OLLAMA_MAX_QUEUE         = 8"
    echo "    HSA_OVERRIDE_GFX_VERSION = 11.5.1"
    echo "    ROCR_VISIBLE_DEVICES     = 0"
    echo "    DO_NOT_TRACK             = 1"
    echo "    OLLAMA_NOPRUNE           = 1"
    echo "    OLLAMA_DEBUG             = 0"
    echo ""
    if ! confirm "Apply this profile?"; then return; fi
    _ai_ollama_env_set "OLLAMA_HOST"              "0.0.0.0"
    _ai_ollama_env_set "OLLAMA_FLASH_ATTENTION"   "1"
    _ai_ollama_env_set "OLLAMA_KV_CACHE_TYPE"     "q8_0"
    _ai_ollama_env_set "OLLAMA_MAX_LOADED_MODELS" "1"
    _ai_ollama_env_set "OLLAMA_NUM_PARALLEL"      "1"
    _ai_ollama_env_set "OLLAMA_KEEP_ALIVE"        "10m"
    _ai_ollama_env_set "OLLAMA_MAX_QUEUE"         "8"
    _ai_ollama_env_set "HSA_OVERRIDE_GFX_VERSION" "11.5.1"
    _ai_ollama_env_set "ROCR_VISIBLE_DEVICES"     "0"
    _ai_ollama_env_set "DO_NOT_TRACK"             "1"
    _ai_ollama_env_set "OLLAMA_NOPRUNE"           "1"
    _ai_ollama_env_set "OLLAMA_DEBUG"             "0"
    echo ""
    echo -e "  ${OK}  ZBook profile applied."
    echo -e "  ${DIM}  Press R on settings menu to reload Ollama and activate${NC}"
}

_ai_reload_ollama() {
    echo "  Reloading Ollama (daemon-reload + restart)..."
    if sudo -n systemctl daemon-reload 2>/dev/null && sudo -n systemctl restart ollama 2>/dev/null; then
        echo -e "  ${OK}  Ollama reloaded"
    else
        echo -e "  ${DIM}  (prompting for password)${NC}"
        sudo systemctl daemon-reload 2>/dev/null \
            && sudo systemctl restart ollama 2>/dev/null \
            && echo -e "  ${OK}  Ollama reloaded" \
            || echo -e "  ${FAIL}  Failed to reload"
    fi
    sleep 2
    _disc_ollama
    _sel_ai_model
    echo -e "  ${OK}  Active model: ${ZMENU_AI_MODEL:-none}"
}

_ai_stop_ollama() {
    header
    echo -e "${BCYN}┄ STOP OLLAMA${NC}"
    echo ""
    if [[ "$D_OLLAMA_RUNNING" == false ]]; then
        echo -e "  ${IDLE}  Ollama is not running"; return
    fi
    local ps_info
    ps_info=$(curl -sf "${D_OLLAMA_URL}/api/ps" 2>/dev/null || true)
    if [[ -n "$ps_info" ]]; then
        echo "$ps_info" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for m in d.get('models', []):
        name = m.get('name','?')
        sz = m.get('size_vram', 0) / (1024**3)
        print(f'  Loaded: {name}  ({sz:.1f} GB VRAM)')
except: pass
" 2>/dev/null || true
        echo ""
    fi
    echo -e "  Stopping Ollama..."
    if sudo -n systemctl stop ollama 2>/dev/null; then
        echo -e "  ${OK}  Ollama stopped"
    else
        echo -e "  ${DIM}  (prompting for password)${NC}"
        sudo systemctl stop ollama 2>/dev/null \
            && echo -e "  ${OK}  Ollama stopped" \
            || echo -e "  ${FAIL}  Could not stop Ollama"
    fi
    D_OLLAMA_RUNNING=false
    D_OLLAMA_ACTIVE_MODEL=""
}

_ai_start_ollama() {
    header
    echo -e "${BCYN}┄ START OLLAMA${NC}"
    echo ""
    if [[ "$D_OLLAMA_RUNNING" == true ]]; then
        echo -e "  ${OK}  Ollama is already running at ${D_OLLAMA_URL}"; return
    fi
    echo "  Starting Ollama..."
    if sudo -n systemctl start ollama 2>/dev/null; then
        echo -e "  ${OK}  Ollama started"
    else
        echo -e "  ${DIM}  (prompting for password)${NC}"
        sudo systemctl start ollama 2>/dev/null \
            && echo -e "  ${OK}  Ollama started" \
            || echo -e "  ${FAIL}  Could not start Ollama"
    fi
    sleep 2
    _disc_ollama
    _sel_ai_model
    echo -e "  ${OK}  Model: ${ZMENU_AI_MODEL}"
}

_ai_unload_model() {
    header
    echo -e "${BCYN}┄ UNLOAD MODEL (free VRAM)${NC}"
    echo ""
    if [[ "$D_OLLAMA_RUNNING" == false ]]; then
        echo -e "  ${IDLE}  Ollama is not running"; return
    fi
    local ps_info
    ps_info=$(curl -sf "${D_OLLAMA_URL}/api/ps" 2>/dev/null || true)
    if [[ -n "$ps_info" ]]; then
        echo "$ps_info" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    models = d.get('models', [])
    if not models: print('  No models currently loaded')
    else:
        for m in models:
            sz = m.get('size_vram', 0) / (1024**3)
            print(f'  Loaded: {m[\"name\"]}  ({sz:.1f} GB VRAM)')
except: print('  Could not query Ollama')
" 2>/dev/null || true
    fi
    echo ""
    echo "  Sending unload request..."
    local models_to_unload
    models_to_unload=$(curl -sf "${D_OLLAMA_URL}/api/ps" 2>/dev/null \
        | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for m in d.get('models', []): print(m.get('name',''))
except: pass
" 2>/dev/null || true)
    if [[ -z "$models_to_unload" ]]; then
        echo -e "  ${IDLE}  No models loaded"; return
    fi
    while IFS= read -r model_name; do
        [[ -z "$model_name" ]] && continue
        curl -sf "${D_OLLAMA_URL}/api/generate" \
            -H "Content-Type: application/json" \
            -d "{\"model\": \"${model_name}\", \"keep_alive\": 0}" \
            >/dev/null 2>&1 \
            && echo -e "  ${OK}  Unloaded: ${model_name}" \
            || echo -e "  ${WARN}  Could not unload: ${model_name}"
    done <<< "$models_to_unload"
    D_OLLAMA_ACTIVE_MODEL=""
    echo -e "  ${DIM}  VRAM freed within a few seconds${NC}"
}

_ai_test_inference() {
    header
    echo -e "${BCYN}┄ INFERENCE TEST${NC}"
    if [[ -z "$ZMENU_AI_MODEL" || "$ZMENU_AI_MODEL" == "no-models-found" ]]; then
        echo -e "  ${FAIL}  No model available"; return
    fi
    echo "  Sending test prompt to: ${ZMENU_AI_MODEL}"
    echo ""
    local response
    local hsa_ver=""
    [[ -n "$D_GPU_GFX" ]] && hsa_ver="${D_GPU_GFX#gfx}"
    response=$(HSA_OVERRIDE_GFX_VERSION="${hsa_ver:-${HSA_OVERRIDE_GFX_VERSION:-}}" \
        ollama run "$ZMENU_AI_MODEL" "Reply with exactly one word: ONLINE" 2>&1)
    if echo "$response" | grep -qi "online"; then
        echo -e "  ${OK}  Model responded: ${response}"
        echo -e "  ${OK}  GPU inference confirmed"
    else
        echo -e "  ${WARN}  Response: ${response}"
    fi
}

_ai_switch_model() {
    header
    echo -e "${BCYN}┄ SWITCH ACTIVE MODEL${NC}"
    echo ""
    if [[ ${#D_OLLAMA_MODELS[@]} -eq 0 ]]; then
        echo -e "  ${FAIL}  No models available"; pause; return
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
        i=$((i + 1))
    done
    echo ""
    read -rp "  Select number: " n
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#D_OLLAMA_MODELS[@]} ]]; then
        ZMENU_AI_MODEL="${D_OLLAMA_MODELS[$((n-1))]}"
        if grep -q "ZMENU_AI_MODEL" "$ZMENU_CONFIG_FILE"; then
            sed -i "s|^ZMENU_AI_MODEL=.*|ZMENU_AI_MODEL=\"${ZMENU_AI_MODEL}\"|" "$ZMENU_CONFIG_FILE"
        else
            echo "ZMENU_AI_MODEL=\"${ZMENU_AI_MODEL}\"" >> "$ZMENU_CONFIG_FILE"
        fi
        echo -e "  ${OK}  Active model: ${ZMENU_AI_MODEL}"
    fi
    pause
}

_ai_set_context_length() {
    header
    echo -e "${BCYN}┄ CONTEXT WINDOW SIZE${NC}"
    echo ""
    echo -e "  Current: ${BOLD}${ZMENU_AI_CONTEXT_LENGTH}${NC} tokens"
    echo ""
    echo -e "  ${DIM}Controls how many tokens Ollama allocates (num_ctx).${NC}"
    echo -e "  ${DIM}Larger = more context but slower prefill and more memory.${NC}"
    echo ""
    echo "  Presets:"
    echo -e "   1)  4096     ${DIM}— minimal, fast${NC}"
    echo -e "   2)  8192     ${DIM}— recommended default${NC}"
    echo -e "   3)  16384    ${DIM}— balanced${NC}"
    echo -e "   4)  32768    ${DIM}— long documents${NC}"
    echo -e "   5)  65536    ${DIM}— very long context${NC}"
    echo -e "   6)  Custom"
    echo ""
    read -rp "  Select (1-6): " n
    local new_ctx=""
    case $n in
        1) new_ctx=4096 ;; 2) new_ctx=8192 ;; 3) new_ctx=16384 ;;
        4) new_ctx=32768 ;; 5) new_ctx=65536 ;;
        6) read -rp "  Enter context length (1024-262144): " custom
           if [[ "$custom" =~ ^[0-9]+$ ]] && [[ "$custom" -ge 1024 ]] && [[ "$custom" -le 262144 ]]; then
               new_ctx="$custom"
               if [[ "$custom" -gt 65536 ]]; then
                   echo -e "  ${WARN}  Large context will use significant memory"
                   confirm "Continue?" || { pause; return; }
               fi
           else
               echo -e "  ${FAIL}  Invalid"; pause; return
           fi ;;
        *) echo -e "${RED}  Invalid.${NC}"; pause; return ;;
    esac
    ZMENU_AI_CONTEXT_LENGTH="$new_ctx"
    if grep -q "ZMENU_AI_CONTEXT_LENGTH" "$ZMENU_CONFIG_FILE"; then
        sed -i "s|^ZMENU_AI_CONTEXT_LENGTH=.*|ZMENU_AI_CONTEXT_LENGTH=${new_ctx}|" "$ZMENU_CONFIG_FILE"
    else
        echo "ZMENU_AI_CONTEXT_LENGTH=${new_ctx}" >> "$ZMENU_CONFIG_FILE"
    fi
    echo -e "  ${OK}  Context window: ${new_ctx} tokens"
    pause
}

# ── LM Studio sub-menu ─────────────────────────────────────
_ai_sub_lms() {
    while true; do
        header
        echo -e "${BCYN}┄ LM STUDIO ────────────────────────────────────────────${NC}"
        echo ""
        if [[ "$D_LMS_RUNNING" == true ]]; then
            echo -e "  Status:  ${OK} running at ${D_LMS_URL}"
            echo -e "  ${DIM}Models visible via API:${NC}"
            for m in "${D_LMS_MODELS[@]}"; do echo "    · $m"; done
        else
            echo -e "  Status:  ${IDLE} stopped (optional)"
        fi
        echo ""
        local lms_dir="${HOME}/.lmstudio/models"
        echo -e "  ${DIM}GGUF files on disk:${NC}"
        if [[ -d "$lms_dir" ]]; then
            find "$lms_dir" -name "*.gguf" 2>/dev/null | while read -r f; do
                printf "    %-50s  %s\n" "$(basename "$f")" "$(du -sh "$f" 2>/dev/null | cut -f1)"
            done
        else
            echo "    ${lms_dir} not found"
        fi
        echo ""
        echo "   1)  Start server    2)  Stop server    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) lms server start 2>/dev/null && echo -e "  ${OK}  Started" || echo -e "  ${FAIL}  Failed"
               sleep 2; _disc_lms; pause ;;
            2) lms server stop 2>/dev/null && echo -e "  ${OK}  Stopped" || echo -e "  ${FAIL}  Failed"
               sleep 1; _disc_lms; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

# ── Open WebUI sub-menu ────────────────────────────────────
_ai_sub_owui() {
    while true; do
        header
        echo -e "${BCYN}┄ OPEN WEBUI ───────────────────────────────────────────${NC}"
        echo ""
        if curl -sf "${OWUI_URL}" >/dev/null 2>&1; then
            echo -e "  Status:  ${OK} running at ${OWUI_URL}"
            docker inspect --format '  Container: {{.State.Status}}' open-webui 2>/dev/null || true
        else
            echo -e "  Status:  ${IDLE} not running"
        fi
        echo ""
        if $D_OLLAMA_RUNNING; then
            echo -e "  Ollama backend: ${OK} reachable"
        else
            echo -e "  Ollama backend: ${FAIL} not running"
        fi
        echo ""
        echo "   1)  Open in browser"
        echo "   2)  Restart container"
        echo "   3)  Stop container"
        echo "   4)  Start container"
        echo "   5)  View logs (last 50)"
        echo ""
        echo "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) if command -v xdg-open >/dev/null 2>&1; then xdg-open "${OWUI_URL}" &>/dev/null &
               else echo "  Open: ${OWUI_URL}"; fi
               pause ;;
            2) docker restart open-webui 2>/dev/null && echo -e "  ${OK}  Restarted" || echo -e "  ${FAIL}  Failed"; pause ;;
            3) docker stop open-webui 2>/dev/null && echo -e "  ${OK}  Stopped" || echo -e "  ${FAIL}  Failed"; pause ;;
            4) docker start open-webui 2>/dev/null && echo -e "  ${OK}  Started" || echo -e "  ${FAIL}  Failed"; pause ;;
            5) header; echo -e "${BCYN}┄ OPEN WEBUI LOGS${NC}"; echo ""
               docker logs --tail 50 open-webui 2>/dev/null | sed 's/^/  /' || echo "  No logs"
               pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

# ──────────────────────────────────────────────────────────
#  MODULE 4: APPS & SERVICES (Docker)
# ──────────────────────────────────────────────────────────

# ============================================================
#  MODULE: SYSTEM SCAN — registry-driven inventory + security
#  Every known app defined once. Live cross-reference at runtime.
# ============================================================

# App registry — pipe-delimited fields:
#   display_name | installed_check | process_name | service_name | port | config_path | category | description
# installed_check: path or command name to test with command -v / -x
# process_name: for pgrep -x (empty = skip process check)
# service_name: for systemctl (empty = skip)
# port: listening port to verify (empty = skip)
_SCAN_REGISTRY=(
    # ── AI Inference ────────────────────────────────────────
    "Zenny-Core|${ZENNY_BINARY}|${ZENNY_PROCESS}||unix:${D_ZENNY_SOCKET}|${ZENNY_BINARY}|ai-inference|Local LLM inference engine (Vulkan/llama.cpp, Unix socket)"
    "Ollama|ollama|ollama|ollama.service|11434|~/.ollama|ai-inference|HTTP-based LLM server (legacy — replaced by Zenny-Core)"
    "LM Studio||lmstudio||1234|~/.lmstudio|ai-inference|GUI model downloader and inference server"
    # ── AI Tools ────────────────────────────────────────────
    "Claude Code|claude|claude|||~/.claude|ai-tools|Anthropic Claude Code CLI agent"
    "OpenCode|${OPENCODE_BIN}|${OPENCODE_PROCESS}|||${OPENCODE_CFG}|ai-tools|Standalone coding agent CLI (separate from Zenny-Core)"
    "Open WebUI|docker:open-webui|||3000||ai-tools|Web chat interface for local models (Docker)"
    "Crawl4AI|docker:crawl4ai|||11235||ai-tools|AI-powered web scraper (Docker)"
    "n8n|docker:n8n|||5678|~/.n8n|ai-tools|Workflow automation (Docker)"
    "SearXNG|docker:searxng|||8080||ai-tools|Private web search (Docker)"
    # ── Networking ──────────────────────────────────────────
    "Tailscale|tailscale|tailscaled|tailscaled.service||/etc/tailscale|networking|Zero-config VPN mesh network"
    "OpenVPN|openvpn|openvpn|openvpn.service|||networking|VPN client/server"
    "Docker|docker|dockerd|docker.service|||/etc/docker|containers|Container runtime engine"
    # ── Dev Tools ───────────────────────────────────────────
    "Node.js|node||||~/.nvm|dev|JavaScript runtime (via nvm)"
    "Python3|python3||||/usr/lib/python3|dev|Python interpreter"
    "Rust/Cargo|rustc||||~/.cargo|dev|Rust compiler toolchain"
    "pip3|pip3|||||dev|Python package manager"
)

# Check one registry entry. Outputs a formatted status line.
# Returns: "STATUS|display_name|version_or_info|resource_info|port_info|config_path|description"
_scan_entry() {
    local rec="$1"
    local name installed_check process svc port config cat desc
    IFS='|' read -r name installed_check process svc port config cat desc <<< "$rec"

    local is_installed=false is_running=false run_info="" ver_info="" res_info=""

    # ── Docker container check ─────────────────────────────
    if [[ "$installed_check" == docker:* ]]; then
        local cname="${installed_check#docker:}"
        if [[ "$D_DOCKER_RUNNING" == true ]]; then
            is_installed=true
            local cstatus; cstatus=$(docker ps -a --filter "name=^${cname}$" --format "{{.Status}}" 2>/dev/null || echo "")
            if [[ "$cstatus" == Up* ]]; then
                is_running=true
                run_info="${cstatus}"
                # Resource usage
                res_info=$(docker stats --no-stream --format "{{.CPUPerc}} cpu  {{.MemUsage}}" "$cname" 2>/dev/null || echo "")
            elif [[ -n "$cstatus" ]]; then
                run_info="${cstatus}"
            fi
        fi
    else
        # ── Binary existence check ─────────────────────────
        local bin_path=""
        if [[ -n "$installed_check" ]]; then
            if [[ "$installed_check" == /* ]] || [[ "$installed_check" == ~* ]]; then
                local expanded="${installed_check/\~/$HOME}"
                [[ -x "$expanded" ]] && { is_installed=true; bin_path="$expanded"; }
            else
                bin_path=$(command -v "$installed_check" 2>/dev/null || true)
                [[ -n "$bin_path" ]] && is_installed=true
            fi
        fi

        # ── Process check ─────────────────────────────────
        if [[ -n "$process" ]]; then
            if pgrep -x "$process" >/dev/null 2>&1; then
                is_running=true
                local pid; pid=$(pgrep -x "$process" | head -1)
                # CPU and RSS from ps
                res_info=$(ps -p "$pid" -o pid=,pcpu=,rss= 2>/dev/null \
                    | awk '{printf "pid:%s  %.1f%%cpu  %.0fMB", $1, $2, $3/1024}' || echo "pid:${pid}")
                is_installed=true
            fi
        fi

        # ── Unix socket check (zenny-core) ────────────────
        if [[ "$port" == unix:* ]]; then
            local sock="${port#unix:}"
            [[ -S "$sock" ]] && is_running=true
        fi

        # ── Systemd service check ──────────────────────────
        if [[ -n "$svc" ]] && ! $is_running; then
            local svc_state; svc_state=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
            [[ "$svc_state" == "active" ]] && is_running=true
            run_info="service:${svc_state}"
        fi
    fi

    # ── Determine status indicator ────────────────────────
    local indicator label
    if $is_running; then
        indicator="$OK"; label="RUNNING"
    elif $is_installed; then
        indicator="$IDLE"; label="stopped"
    else
        indicator="$IDLE"; label="—"
    fi

    printf "%s|%s|%s|%s|%s|%s|%s|%s\n" \
        "$indicator" "$name" "$label" "$run_info" "$res_info" "$port" "$config" "$desc"
}

# Render all registry entries grouped by category
_scan_display() {
    local categories=("ai-inference" "ai-tools" "networking" "containers" "dev")
    local category_labels=("AI Inference" "AI Tools" "Networking" "Containers" "Dev Tools")

    local i=0
    for cat in "${categories[@]}"; do
        echo -e "  ${BOLD}${category_labels[$i]}${NC}"
        for rec in "${_SCAN_REGISTRY[@]}"; do
            local rec_cat; rec_cat=$(echo "$rec" | cut -d'|' -f7)
            [[ "$rec_cat" != "$cat" ]] && continue
            local result; result=$(_scan_entry "$rec")
            local indicator name label run_info res_info port config desc
            IFS='|' read -r indicator name label run_info res_info port config desc <<< "$result"
            local detail="${res_info}"
            # Only show port and run_info when actually running
            if [[ "$label" == "RUNNING" ]]; then
                [[ -n "$run_info" ]] && detail="${run_info}${detail:+  }${detail}"
                [[ -n "$port" && "$port" != unix:* ]] && detail+="${detail:+  }:${port}"
            fi
            printf "    %b  %-18s %-10s  %b%s%b\n" \
                "$indicator" "$name" "$label" \
                "$DIM" "$detail" "$NC"
        done
        echo ""
        i=$((i + 1))
    done
}

# Security view — processes NOT in the registry consuming significant resources
# Risk tiers:
#   SAFE  (grey ○)  — owned by current user, running from trusted paths
#   WARN  (yellow●) — root-owned, or path outside trusted locations
#   FLAG  (red  ●)  — running from /tmp, /dev/shm, /run/user, or hidden dirs
_scan_unknowns() {
    header
    echo -e "${BCYN}┄ UNKNOWN PROCESSES  ${DIM}(not in app registry)${NC}"
    echo ""

    # Build known basenames from registry (field 3 = process name)
    local known_procs=()
    for rec in "${_SCAN_REGISTRY[@]}"; do
        local proc; proc=$(echo "$rec" | cut -d'|' -f3)
        [[ -n "$proc" ]] && known_procs+=("$proc")
    done
    # Core OS and desktop processes — always safe to ignore
    known_procs+=(
        bash zsh sh dash fish
        python3 python python2 perl ruby
        ssh sshd sftp-server
        systemd systemd-journal systemd-logind systemd-udevd systemd-resolved systemd-networkd
        dbus-daemon dbus-broker
        kworker kswapd kcompactd migration ksoftirqd kthreadd irq
        containerd dockerd docker-proxy runc
        Xorg Xwayland gnome-shell gdm mutter gjs
        gnome-terminal-server gnome-text-editor gnome-calculator gnome-calendar
        gnome-software gnome-control-center gnome-session-binary
        nautilus nemo thunar
        pulseaudio pipewire pipewire-pulse wireplumber
        NetworkManager wpa_supplicant ModemManager dhclient dhcpcd
        tailscaled openvpn
        cups cupsd avahi-daemon
        postgres redis nginx apache2 php-fpm
        snapd snap
        grep awk sed find xargs ps pgrep pkill
        htop top btop
        tmux screen
        zmenu
        at-spi2-registryd at-spi-bus-launcher
        xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-gtk
        gsd-xsettings gsd-color gsd-keyboard gsd-media-keys gsd-power gsd-print-notifications
        gsd-rfkill gsd-screensaver-proxy gsd-sharing gsd-smartcard gsd-sound gsd-wacom
        evolution-source-registry evolution-addressbook-factory evolution-calendar-factory
        evolution-alarm-notify
        tracker-miner-fs tracker-extract
        update-notifier update-manager
        chrome chromium firefox
        node npm npx
        zed-editor zed
        code code-server
        vim nvim emacs nano
        git cargo rustc gcc clang make
        mutter-x11-frames
    )

    # Trusted path prefixes — processes here owned by current user are SAFE
    local _me; _me=$(whoami)
    local trusted_paths=(
        "/usr/bin/" "/usr/lib/" "/usr/libexec/" "/usr/share/"
        "/usr/sbin/"
        "/lib/" "/lib64/"
        "/snap/"
        "${HOME}/.local/"
        "${HOME}/.cargo/"
        "${HOME}/.nvm/"
        "${HOME}/projects/"
        "/opt/"
    )

    echo -e "  ${DIM}Risk tiers:  ${OK} safe (known path, your user)  ${WARN} review (root or unusual)  ${FAIL} investigate (/tmp, hidden)${NC}"
    echo ""

    local cnt_flag=0 cnt_warn=0 cnt_safe=0
    while IFS= read -r line; do
        local proc_user pid pcpu pmem rss comm
        read -r proc_user pid pcpu pmem rss comm _ <<< "$line"
        [[ -z "$pid" ]] && continue
        local rss_mb=$(( rss / 1024 ))
        local comm_base; comm_base=$(basename "$comm")

        # Check if basename matches a known process
        local known=false
        for kp in "${known_procs[@]}"; do
            [[ "$comm_base" == "$kp" ]] && { known=true; break; }
        done
        $known && continue

        # Determine risk tier
        local tier="warn"
        local indicator="$WARN"

        # FLAG: running from suspicious locations
        # Exception: /tmp/.mount_*/  = AppImage self-mount (normal, safe)
        if [[ "$comm" == /tmp/.mount_* ]]; then
            tier="safe"; indicator="$IDLE"
        elif [[ "$comm" == /tmp/* || "$comm" == /dev/shm/* || "$comm" == /run/user/*/tmp* || "$comm" == */\.* ]]; then
            tier="flag"; indicator="$FAIL"

        # FLAG: root-owned process from non-system path
        elif [[ "$proc_user" == "root" ]]; then
            local in_sys=false
            for tp in "/usr/bin/" "/usr/sbin/" "/usr/lib/" "/usr/libexec/" "/lib/" "/sbin/" "/bin/" "/opt/"; do
                [[ "$comm" == ${tp}* ]] && { in_sys=true; break; }
            done
            $in_sys && { indicator="$WARN"; tier="warn"; } || { indicator="$FAIL"; tier="flag"; }

        # SAFE: current user + trusted path
        elif [[ "$proc_user" == "$_me" ]]; then
            local in_trusted=false
            for tp in "${trusted_paths[@]}"; do
                [[ "$comm" == ${tp}* ]] && { in_trusted=true; break; }
            done
            $in_trusted && { indicator="$IDLE"; tier="safe"; }
        fi

        local tier_color tier_word
        case $tier in
            safe) tier_color="$DIM";  tier_word="safe";   cnt_safe=$((cnt_safe + 1)) ;;
            warn) tier_color="$BYEL"; tier_word="review"; cnt_warn=$((cnt_warn + 1)) ;;
            flag) tier_color="$BRED"; tier_word="FLAG";   cnt_flag=$((cnt_flag + 1)) ;;
        esac

        # tier_color uses %b (interprets \033 escapes), tier_word uses %s (plain text + padding)
        printf "    %b  %-26s %b%-6s%b  pid:%-7s  %5s%%cpu  %4dMB  user:%s\n" \
            "$indicator" "$comm_base" \
            "$tier_color" "$tier_word" "$NC" \
            "$pid" "$pcpu" "$rss_mb" "$proc_user"

    done < <(ps aux --sort=-%mem 2>/dev/null \
        | awk 'NR>1 && ($6/1024 > 50 || $3 > 1.0){print $1,$2,$3,$4,$6,$11}' \
        | head -50)

    echo ""
    if [[ $cnt_flag -gt 0 ]]; then
        echo -e "  ${FAIL}  ${cnt_flag} process(es) need investigation — unusual path or root from non-system location"
    fi
    if [[ $cnt_warn -gt 0 ]]; then
        echo -e "  ${WARN}  ${cnt_warn} process(es) worth reviewing — run 'C) Ask AI' for analysis"
    fi
    if [[ $cnt_flag -eq 0 && $cnt_warn -eq 0 ]]; then
        echo -e "  ${OK}  All unlisted processes are safe (known user + trusted path)"
    fi
    if [[ $cnt_safe -gt 0 ]]; then
        echo -e "  ${DIM}  ${cnt_safe} safe (your apps, trusted paths — not a concern)${NC}"
    fi
    echo ""
    echo -e "  ${DIM}Protocol: FLAG = kill + investigate path origin | WARN = verify with 'lsof -p <pid>' | safe = ignore${NC}"
    echo ""
}

# Per-app drill-down — show full detail + available commands
_scan_detail() {
    local rec="$1"
    local name installed_check process svc port config cat desc
    IFS='|' read -r name installed_check process svc port config cat desc <<< "$rec"

    header
    echo -e "${BCYN}┄ ${name} ────────────────────────────────────────────────${NC}"
    echo ""
    echo -e "  ${DIM}${desc}${NC}"
    echo ""

    # Status
    local result; result=$(_scan_entry "$rec")
    local indicator rlabel run_info res_info
    IFS='|' read -r indicator rlabel _label run_info res_info _ _ _ <<< "$result"
    echo -e "  Status:    ${indicator}  ${_label}  ${run_info}"
    [[ -n "$res_info" ]] && echo -e "  Resources: ${DIM}${res_info}${NC}"
    [[ -n "$port" && "$port" != unix:* ]] && echo -e "  Port:      :${port}"
    [[ -n "$svc" ]] && echo -e "  Service:   ${svc}  ($(systemctl is-active "$svc" 2>/dev/null || echo 'n/a'))"

    # Config files
    if [[ -n "$config" ]]; then
        local expanded="${config/\~/$HOME}"
        echo ""
        echo -e "  ${BOLD}Config:${NC}"
        find "$expanded" -maxdepth 2 \( -name "*.json" -o -name "*.yaml" -o -name "*.yml" -o -name "*.env" -o -name "AI.md" -o -name "config" \) 2>/dev/null \
            | head -10 | sed "s|${HOME}|~|g; s/^/    /"
    fi

    # Available commands
    echo ""
    echo -e "  ${BOLD}Commands:${NC}"
    local cmds=()
    [[ -n "$svc" ]] && cmds+=("  systemctl start ${svc}" "  systemctl stop ${svc}" "  systemctl status ${svc}" "  journalctl -u ${svc} -f")
    [[ "$installed_check" == docker:* ]] && {
        local cn="${installed_check#docker:}"
        cmds+=("  docker start ${cn}" "  docker stop ${cn}" "  docker logs ${cn} -f" "  docker stats ${cn}")
    }
    [[ -n "$process" ]] && cmds+=("  pgrep -x ${process}" "  pkill ${process}")
    for cmd in "${cmds[@]}"; do echo -e "  ${DIM}${cmd}${NC}"; done

    echo ""
    echo "   l)  Show logs    s)  Start    S)  Stop    C)  ✦ Ask AI    r)  Back"
    echo ""
    read -rp "  Selection: " ch
    case $ch in
        l) _scan_app_logs "$rec"; pause ;;
        s) _scan_app_start "$rec"; pause ;;
        S) _scan_app_stop "$rec"; pause ;;
        C) _cc_inline "$name" _ctx_apps_services _apply_apps_services; pause ;;
        r|R) return ;;
    esac
}

_scan_app_logs() {
    local rec="$1"
    local name installed_check process svc _ _ _ _
    IFS='|' read -r name installed_check process svc _ _ _ _ <<< "$rec"
    echo ""
    if [[ "$installed_check" == docker:* ]]; then
        docker logs "${installed_check#docker:}" --tail 30 2>/dev/null | sed 's/^/  /'
    elif [[ -n "$svc" ]]; then
        journalctl -u "$svc" --no-pager -n 30 2>/dev/null | sed 's/^/  /'
    else
        echo -e "  ${IDLE}  No log source configured for ${name}"
    fi
}

_scan_app_start() {
    local rec="$1"
    local name installed_check process svc _ _ _ _
    IFS='|' read -r name installed_check process svc _ _ _ _ <<< "$rec"
    if [[ "$installed_check" == docker:* ]]; then
        docker start "${installed_check#docker:}" 2>/dev/null \
            && echo -e "  ${OK}  Started: ${name}" || echo -e "  ${FAIL}  Failed"
    elif [[ -n "$svc" ]]; then
        sudo systemctl start "$svc" 2>/dev/null \
            && echo -e "  ${OK}  Started: ${svc}" || echo -e "  ${FAIL}  Failed (may need sudo password)"
    elif [[ "$name" == "Zenny-Core" ]]; then
        _zenny_start
    else
        echo -e "  ${IDLE}  No start handler for ${name} — use the dedicated module"
    fi
}

_scan_app_stop() {
    local rec="$1"
    local name installed_check process svc _ _ _ _
    IFS='|' read -r name installed_check process svc _ _ _ _ <<< "$rec"
    if [[ "$installed_check" == docker:* ]]; then
        docker stop "${installed_check#docker:}" 2>/dev/null \
            && echo -e "  ${OK}  Stopped: ${name}" || echo -e "  ${FAIL}  Failed"
    elif [[ -n "$svc" ]]; then
        sudo systemctl stop "$svc" 2>/dev/null \
            && echo -e "  ${OK}  Stopped: ${svc}" || echo -e "  ${FAIL}  Failed"
    elif [[ "$name" == "Zenny-Core" ]]; then
        _zenny_stop
    elif [[ "$name" == "OpenCode" ]]; then
        _opencode_stop
    elif [[ -n "$process" ]]; then
        pkill -x "$process" 2>/dev/null \
            && echo -e "  ${OK}  Stopped: ${name}" || echo -e "  ${IDLE}  ${name} was not running"
    fi
}

# Context function for system scan AI
_ctx_system_scan() {
    printf "Section focus: full system inventory — all installed apps, running processes, services, ports\n\n"
    printf "Known app registry:\n"
    for rec in "${_SCAN_REGISTRY[@]}"; do
        local result; result=$(_scan_entry "$rec")
        local indicator name label run_info res_info port _ desc
        IFS='|' read -r indicator name label run_info res_info port _ desc <<< "$result"
        printf "  %-18s %-14s %s %s\n" "$name" "$label" "$run_info" "$res_info"
    done
    printf "\nDocker containers:\n"
    docker ps -a --format "  {{.Names}}: {{.Status}}  {{.Ports}}" 2>/dev/null || printf "  (docker not running)\n"
    printf "\nListening ports:\n"
    ss -tlnp 2>/dev/null | grep LISTEN | awk '{print "  "$4"\t"$6}' | head -20
}
_apply_system_scan() { _apply_generic "$1" "System Scan"; }

_ctx_packages() {
    printf "Section focus: installed packages, user tools, and package hygiene\n\n"
    printf "Snap packages:\n"
    snap list 2>/dev/null | awk 'NR>1{printf "  %-26s %s\n", $1, $2}' | head -30 || printf "  (snap not available)\n"
    printf "\nUser binaries (~/.local/bin):\n"
    ls -1 "${HOME}/.local/bin/" 2>/dev/null | sed 's/^/  /' || printf "  (none)\n"
    printf "\nCargo tools (~/.cargo/bin):\n"
    ls -1 "${HOME}/.cargo/bin/" 2>/dev/null | grep -v '\.d$' | sed 's/^/  /' || printf "  (none)\n"
    printf "\nnpm global:\n"
    npm list -g --depth=0 2>/dev/null | tail -n +2 | sed 's/[├└─ ]*/  /' | head -15 || printf "  (none)\n"
    printf "\npip user:\n"
    pip3 list --user 2>/dev/null | tail -n +3 | awk '{printf "  %-26s %s\n", $1, $2}' | head -20 || printf "  (none)\n"
    printf "\nKnown hygiene issues:\n"
    # rls deprecated
    [[ -f "${HOME}/.cargo/bin/rls" ]] && printf "  - rls: deprecated Rust Language Server (superseded by rust-analyzer)\n"
    # snap disk usage
    command -v snap >/dev/null 2>&1 && printf "  - snap disk: %s\n" "$(du -sh /var/lib/snapd/snaps 2>/dev/null | cut -f1 || echo '?')"
}
_apply_packages() { _apply_generic "$1" "Packages"; }

_scan_packages() {
    while true; do
        header
        echo -e "${BCYN}┄ INSTALLED PACKAGES ───────────────────────────────────${NC}"
        echo ""

        # ── Snap packages (skip base/runtime entries) ─────────────
        if command -v snap >/dev/null 2>&1; then
            echo -e "  ${BOLD}Snap  ${DIM}(apps only — base/core runtimes filtered)${NC}"
            snap list 2>/dev/null | awk 'NR==1{next}
                $1 ~ /^(bare|core|core[0-9]+|snapd|snapd-desktop-integration|gtk-common-themes|gnome-[0-9]|mesa-)/ {next}
                {printf "    %-28s %-16s %s\n", $1, $2, $NF}' | head -30
            local _snap_app_count; _snap_app_count=$(snap list 2>/dev/null | awk 'NR>1 &&
                $1 !~ /^(bare|core|core[0-9]+|snapd|snapd-desktop-integration|gtk-common-themes|gnome-[0-9]|mesa-)/' \
                | wc -l)
            local _snap_base_count; _snap_base_count=$(snap list 2>/dev/null | awk 'NR>1 &&
                $1 ~ /^(bare|core|core[0-9]+|snapd|snapd-desktop-integration|gtk-common-themes|gnome-[0-9]|mesa-)/' \
                | wc -l)
            local _snap_disk; _snap_disk=$(du -sh /var/lib/snapd/snaps 2>/dev/null | cut -f1 || echo '?')
            echo -e "  ${DIM}  ${_snap_app_count} apps  +  ${_snap_base_count} runtime bases  ·  disk: ${_snap_disk}${NC}"
            echo ""
        fi

        # ── Flatpak ───────────────────────────────────────────────
        if command -v flatpak >/dev/null 2>&1; then
            local _fp_count; _fp_count=$(flatpak list --app 2>/dev/null | wc -l)
            if [[ $_fp_count -gt 0 ]]; then
                echo -e "  ${BOLD}Flatpak${NC}"
                flatpak list --app --columns=name,version,origin 2>/dev/null \
                    | awk '{printf "    %-28s %-14s %s\n", $1, $2, $3}' | head -20
                echo -e "  ${DIM}  ${_fp_count} flatpak apps${NC}"
                echo ""
            fi
        fi

        # ── User-installed binaries ───────────────────────────────
        if [[ -d "${HOME}/.local/bin" ]]; then
            local _bins; _bins=$(ls -1 "${HOME}/.local/bin/" 2>/dev/null)
            if [[ -n "$_bins" ]]; then
                echo -e "  ${BOLD}~/.local/bin  ${DIM}(user-installed tools)${NC}"
                echo "$_bins" | awk '{printf "    %s\n", $0}'
                echo ""
            fi
        fi

        # ── Cargo binaries ────────────────────────────────────────
        if [[ -d "${HOME}/.cargo/bin" ]]; then
            local _cargo_bins; _cargo_bins=$(ls -1 "${HOME}/.cargo/bin/" 2>/dev/null | grep -v '\.d$')
            if [[ -n "$_cargo_bins" ]]; then
                echo -e "  ${BOLD}~/.cargo/bin  ${DIM}(Rust tools)${NC}"
                echo "$_cargo_bins" | awk '{printf "    %s\n", $0}'
                echo ""
            fi
        fi

        # ── npm global ────────────────────────────────────────────
        if command -v npm >/dev/null 2>&1; then
            local _npm; _npm=$(npm list -g --depth=0 2>/dev/null | tail -n +2 | sed 's/[├└─ ]*//' | head -15)
            if [[ -n "$_npm" ]]; then
                echo -e "  ${BOLD}npm global${NC}"
                echo "$_npm" | awk '{printf "    %s\n", $0}'
                echo ""
            fi
        fi

        # ── pip user ──────────────────────────────────────────────
        if command -v pip3 >/dev/null 2>&1; then
            local _pip; _pip=$(pip3 list --user 2>/dev/null | tail -n +3 | head -25)
            if [[ -n "$_pip" ]]; then
                echo -e "  ${BOLD}pip (user)${NC}"
                echo "$_pip" | awk '{printf "    %-28s %s\n", $1, $2}'
                echo ""
            fi
        fi

        echo -e "  ${DIM}Use C) to ask Zenny: what's deprecated, what's bloat, what can be removed safely.${NC}"
        echo ""
        echo "   C)  ✦ Ask AI — hygiene, deprecated tools, cleanup    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            C) _cc_inline "Packages" _ctx_packages _apply_packages; pause ;;
            r|R|q) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

mod_system_scan() {
    while true; do
        header
        echo -e "${BCYN}┄ SYSTEM SCAN ──────────────────────────────────────────${NC}"
        echo ""
        _scan_display
        echo -e "  ${DIM}$(date '+%H:%M:%S')  ●=running  ○=stopped  —=not installed${NC}"
        echo ""
        echo "   r)  Refresh    d)  Drill-down (pick app)    u)  Unknown processes"
        echo "   p)  Packages   m)  Manage Docker    E)  Export    C)  ✦ Ask AI    b)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            r|R) discover; continue ;;
            d|D)
                echo ""
                local i=1
                for rec in "${_SCAN_REGISTRY[@]}"; do
                    local n; n=$(echo "$rec" | cut -d'|' -f1)
                    printf "   %2d)  %s\n" "$i" "$n"
                    i=$((i + 1))
                done
                echo ""
                read -rp "  Select app number: " n
                if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#_SCAN_REGISTRY[@]} ]]; then
                    _scan_detail "${_SCAN_REGISTRY[$((n-1))]}"
                fi ;;
            u|U) _scan_unknowns; pause ;;
            p|P) _scan_packages ;;
            m|M) mod_apps_services ;;
            E) export_report "System Scan"; pause ;;
            C) _cc_inline "System Scan" _ctx_system_scan _apply_system_scan; pause ;;
            b|q) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

mod_apps_services() {
    while true; do
        header
        echo -e "${BCYN}┄ APPS & SERVICES ──────────────────────────────────────${NC}"
        echo ""
        if [[ "$D_DOCKER_RUNNING" == true ]]; then
            echo -e "  ${OK}  Docker running"
            echo ""
            docker ps --format "  {{.Names}}: {{.Status}} · {{.Ports}}" 2>/dev/null || echo "  no containers"
        else
            echo -e "  ${FAIL}  Docker not running"
        fi
        echo ""
        echo "   a)  Container list         (status · resources)"
        echo "   b)  Container logs         (pick container)"
        echo "   c)  System prune           (clean unused)"
        echo "   d)  Start a service        (n8n · SearXNG · Crawl4AI · Open WebUI)"
        echo "   e)  Stop a container"
        echo "   f)  Restart a container"
        echo ""
        echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _docker_list; pause ;;
            b) _docker_logs ;;
            c) _docker_prune ;;
            d) _docker_start ;;
            e) _docker_stop ;;
            f) _docker_restart ;;
            E) export_report "Docker"; pause ;;
            C) _cc_inline "Apps & Services" _ctx_apps_services _apply_apps_services; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_docker_list() {
    header
    echo -e "${BCYN}┄ RUNNING CONTAINERS${NC}"
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null | sed 's/^/  /' || echo "  None"
    echo ""
    echo -e "${BCYN}┄ RESOURCE USAGE${NC}"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" 2>/dev/null | sed 's/^/  /' || echo "  None"
    echo ""
    echo -e "${BCYN}┄ IMAGES${NC}"
    docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" 2>/dev/null | sed 's/^/  /' | head -20
}

_docker_logs() {
    header
    echo -e "${BCYN}┄ CONTAINER LOGS${NC}"
    echo ""
    if [[ ${#D_CONTAINERS[@]} -eq 0 ]]; then echo "  No running containers"; pause; return; fi
    local i=1
    for c in "${D_CONTAINERS[@]}"; do echo "   ${i})  ${c%%:*}"; i=$((i + 1)); done
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
    echo "   4)  Open WebUI   (AI chat interface · :3000)"
    echo ""
    echo "   r)  Back"
    echo ""
    read -rp "  Select: " n
    local name url image vol port
    case $n in
        1) name=n8n;      port=5678;  image=n8nio/n8n;                vol="-v n8n_data:/home/node/.n8n" ;;
        2) name=searxng;  port=8080;  image=searxng/searxng;          vol="" ;;
        3) name=crawl4ai; port=11235; image=unclecode/crawl4ai:latest; vol="" ;;
        4) docker run -d --name open-webui --restart unless-stopped \
               -p 127.0.0.1:3000:8080 \
               --add-host=host.docker.internal:host-gateway \
               -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
               -v open-webui:/app/backend/data \
               ghcr.io/open-webui/open-webui:main 2>/dev/null \
               && echo -e "  ${OK}  Open WebUI started → http://localhost:3000" \
               || echo -e "  ${WARN}  Already running or image missing"
           pause; return ;;
        r|R) return ;;
        *) echo -e "${RED}  Invalid.${NC}"; sleep 1; return ;;
    esac
    # shellcheck disable=SC2086
    docker run -d --name "$name" --restart unless-stopped \
        -p "127.0.0.1:${port}:${port}" $vol "$image" 2>/dev/null \
        && echo -e "  ${OK}  ${name} started on 127.0.0.1:${port}" \
        || echo -e "  ${WARN}  Already running or image missing"
    pause
}

_docker_pick_container() {
    local scope="${1:-running}"
    local -a ctrs=()
    if [[ "$scope" == "all" ]]; then
        while IFS= read -r line; do ctrs+=("$line"); done < <(docker ps -a --format '{{.Names}}' 2>/dev/null)
    else
        while IFS= read -r line; do ctrs+=("$line"); done < <(docker ps --format '{{.Names}}' 2>/dev/null)
    fi
    if [[ ${#ctrs[@]} -eq 0 ]]; then echo "  No containers found"; echo ""; echo "NONE"; return; fi
    local i=1
    for c in "${ctrs[@]}"; do
        local status; status=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null)
        echo "   ${i})  ${c}  (${status})"; i=$((i + 1))
    done
    echo ""
    read -rp "  Select (or Enter to cancel): " n
    if [[ -z "$n" ]]; then echo "CANCEL"; return; fi
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#ctrs[@]} ]]; then
        echo "${ctrs[$((n-1))]}"
    else echo "INVALID"; fi
}

_docker_stop() {
    header
    echo -e "${BCYN}┄ STOP CONTAINER${NC}"
    echo ""
    local name; name=$(_docker_pick_container "running" | tail -1)
    case "$name" in NONE|CANCEL|INVALID) pause; return ;; esac
    if confirm "Stop container: ${name}?"; then
        docker stop "$name" 2>/dev/null && echo -e "  ${OK}  Stopped: ${name}" || echo -e "  ${FAIL}  Failed"
    fi
    pause
}

_docker_restart() {
    header
    echo -e "${BCYN}┄ RESTART CONTAINER${NC}"
    echo ""
    local name; name=$(_docker_pick_container "all" | tail -1)
    case "$name" in NONE|CANCEL|INVALID) pause; return ;; esac
    docker restart "$name" 2>/dev/null && echo -e "  ${OK}  Restarted: ${name}" || echo -e "  ${FAIL}  Failed"
    pause
}

# ──────────────────────────────────────────────────────────
#  MODULE 5: HARDWARE (CPU, GPU, NPU, NVMe, power, thermals)
# ──────────────────────────────────────────────────────────

mod_hardware() {
    while true; do
        header
        echo -e "${BCYN}┄ HARDWARE ─────────────────────────────────────────────${NC}"
        echo ""
        echo "   a)  Full resource audit     (CPU · RAM · Disk · Swap)"
        echo "   b)  Live process monitor    (htop / top)"
        echo "   c)  Thermal dashboard       (CPU · GPU · battery)"
        echo "   d)  Hardware profile        (CPU · RAM · PCIe · NVMe)"
        echo "   e)  Power & battery         (TDP · profiles · uptime)"
        echo "   f)  GPU full status         (ROCm · VRAM · compute)"
        echo "   g)  NPU status              (XDNA driver · device)"
        echo "   h)  Check HSA env var       (needed for GPU inference)"
        echo ""
        echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _sys_resources; pause ;;
            b) htop 2>/dev/null || top; pause ;;
            c) _sys_thermal; pause ;;
            d) _sys_hardware; pause ;;
            e) _sys_power; pause ;;
            f) _hw_gpu; pause ;;
            g) _hw_npu; pause ;;
            h) _hw_hsa; pause ;;
            E) export_report "Hardware"; pause ;;
            C) _cc_inline "Hardware" _ctx_hardware _apply_hardware; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_sys_resources() {
    header
    echo -e "${BCYN}┄ FULL RESOURCE AUDIT${NC}"
    echo ""
    echo -e "${BCYN}┄ CPU${NC}"
    echo "  ${D_CPU_MODEL}"
    echo "  ${D_CPU_CORES} threads, governor: ${D_CPU_GOVERNOR}"
    echo ""
    echo -e "${BCYN}┄ MEMORY${NC}"
    free -h | awk '/^Mem/{printf "  RAM:  %s used / %s total (%s free, %s buff/cache)\n",$3,$2,$4,$6}'
    free -h | awk '/^Swap/{printf "  Swap: %s used / %s total (%s free)\n",$3,$2,$4}'
    echo ""
    echo -e "${BCYN}┄ DISK${NC}"
    df -h / | awk 'NR==2{printf "  Root: %s used / %s total (%s free, %s full)\n",$3,$2,$4,$5}'
    echo ""
    echo -e "${BCYN}┄ LOAD${NC}"
    awk '{printf "  Load average: %s  %s  %s\n",$1,$2,$3}' /proc/loadavg
    echo ""
    echo -e "${BCYN}┄ TOP PROCESSES (by CPU)${NC}"
    ps aux --sort=-%cpu | awk 'NR<=6{printf "  %-20s %5s%% CPU  %5s%% MEM\n",$11,$3,$4}' 2>/dev/null || true
}

_sys_thermal() {
    header
    echo -e "${BCYN}┄ THERMAL DASHBOARD${NC}"
    echo ""
    if command -v sensors >/dev/null 2>&1; then
        sensors 2>/dev/null | grep -E '°C|temp|Tctl|Tdie|edge' | sed 's/^/  /'
    else
        echo "  lm-sensors not installed: sudo apt install lm-sensors"
    fi
    echo ""
    echo -e "${BCYN}┄ GPU TEMPERATURE${NC}"
    [[ -n "$D_GPU_TEMP" ]] && echo "  GPU: ${D_GPU_TEMP}°C" || echo "  Not available"
    echo ""
    echo -e "${BCYN}┄ BATTERY${NC}"
    if [[ -d /sys/class/power_supply/BAT0 ]]; then
        local cap stat
        cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "?")
        stat=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "?")
        echo "  Battery: ${cap}% (${stat})"
    else
        echo "  No battery detected (AC power)"
    fi
}

_sys_hardware() {
    header
    echo -e "${BCYN}┄ HARDWARE PROFILE${NC}"
    echo ""
    echo -e "${BCYN}┄ CPU${NC}"
    lscpu 2>/dev/null | grep -E 'Model name|Architecture|CPU\(s\)|Thread|Core|Socket|MHz|cache' | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ MEMORY${NC}"
    sudo dmidecode -t memory 2>/dev/null | grep -E 'Size|Speed|Type:|Manufacturer' \
        | grep -v "No Module" | head -8 | sed 's/^/  /' || free -h | head -2 | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ STORAGE${NC}"
    lsblk -d -o NAME,SIZE,MODEL,TRAN 2>/dev/null | sed 's/^/  /'
    echo ""
    echo -e "${BCYN}┄ PCIe DEVICES (GPU/NPU/NVMe)${NC}"
    lspci 2>/dev/null | grep -iE 'vga|display|3d|npu|nvme|accelerat' | sed 's/^/  /'
}

_sys_power() {
    header
    echo -e "${BCYN}┄ POWER & BATTERY${NC}"
    echo ""
    echo -e "${BCYN}┄ POWER PROFILE${NC}"
    if command -v powerprofilesctl >/dev/null 2>&1; then
        echo "  Active: $(powerprofilesctl get 2>/dev/null || echo 'unknown')"
        echo "  Available:"
        powerprofilesctl list 2>/dev/null | sed 's/^/    /' || true
    else
        echo "  power-profiles-daemon not found"
    fi
    echo ""
    if [[ -d /sys/class/power_supply/BAT0 ]]; then
        local cap stat watt
        cap=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null || echo "?")
        stat=$(cat /sys/class/power_supply/BAT0/status 2>/dev/null || echo "?")
        watt=$(awk '{printf "%.1f", $1/1000000}' /sys/class/power_supply/BAT0/power_now 2>/dev/null || echo "?")
        echo -e "${BCYN}┄ BATTERY${NC}"
        echo "  Level: ${cap}%  Status: ${stat}  Draw: ${watt}W"
    fi
    echo ""
    echo -e "${BCYN}┄ CPU FREQUENCY${NC}"
    cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null \
        | awk '{printf "  Core %-3d  %5.0f MHz\n", NR-1, $1/1000}' | head -24
    echo ""
    echo -e "${BCYN}┄ UPTIME${NC}"
    uptime -p | sed 's/^/  /'
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
            rocminfo 2>/dev/null | grep -E "Name|Marketing|Chip|Compute|Max Clock" | head -20 | sed 's/^/  /'
            ;;
        nvidia)
            nvidia-smi 2>/dev/null | sed 's/^/  /'
            ;;
        amdgpu-sysfs)
            echo -e "  ${WARN}  rocm-smi not in PATH — add /opt/rocm/bin to PATH"
            for d in /sys/class/hwmon/hwmon*; do
                local n; n=$(cat "$d/name" 2>/dev/null || echo "")
                [[ "$n" != *amdgpu* ]] && continue
                echo "  Device: $n"
                for f in "$d"/temp*_input; do
                    [[ -f "$f" ]] && awk '{printf "  Temp: %.1f°C\n", $1/1000}' "$f"
                done
            done
            ;;
        *) echo -e "  ${FAIL}  No GPU driver detected" ;;
    esac
    echo ""
    echo -e "${BCYN}┄ HSA_OVERRIDE_GFX_VERSION${NC}"
    local hsa="${HSA_OVERRIDE_GFX_VERSION:-NOT SET}"
    echo "  Current value: ${hsa}"
    if [[ "$hsa" == "NOT SET" && -n "$D_GPU_GFX" ]]; then
        echo -e "  ${BYEL}Fix: export HSA_OVERRIDE_GFX_VERSION=${D_GPU_GFX#gfx}${NC}"
    fi
}

_hw_npu() {
    header
    echo -e "${BCYN}┄ NPU / XDNA${NC}"
    echo ""
    echo "  Kernel modules:"
    for mod in amdxdna ryzen_ai npu amd_ipu; do
        lsmod 2>/dev/null | grep -qi "$mod" && echo -e "  ${OK}  ${mod}"
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
    local gfx_num="${D_GPU_GFX#gfx}"
    local gfx_hint=""
    if [[ ${#gfx_num} -eq 4 ]]; then
        gfx_hint="${gfx_num:0:2}.${gfx_num:2:1}.${gfx_num:3:1}"
    else
        gfx_hint="${gfx_num}"
    fi
    local hsa_cur="${HSA_OVERRIDE_GFX_VERSION:-NOT SET}"
    echo "  GPU GFX detected:            ${D_GPU_GFX:-unknown}"
    echo "  Recommended HSA override:    ${gfx_hint}"
    echo "  Current HSA_OVERRIDE:        ${hsa_cur}"
    echo ""
    if [[ "$hsa_cur" == "NOT SET" ]]; then
        echo -e "  ${FAIL}  HSA_OVERRIDE_GFX_VERSION not set"
        echo "  Run:  export HSA_OVERRIDE_GFX_VERSION=${gfx_hint}"
        echo "  Permanent: echo 'export HSA_OVERRIDE_GFX_VERSION=${gfx_hint}' >> ~/.bashrc"
    elif [[ "$hsa_cur" == "$gfx_hint" ]]; then
        echo -e "  ${OK}  Matches detected GPU"
    else
        echo -e "  ${WARN}  Set to ${hsa_cur} but recommended is ${gfx_hint}"
    fi
}

# ──────────────────────────────────────────────────────────
#  MODULE 6: SECURITY & PRIVACY
# ──────────────────────────────────────────────────────────

mod_security() {
    while true; do
        header
        echo -e "${BCYN}┄ SECURITY & PRIVACY ───────────────────────────────────${NC}"
        echo ""
        echo -e "  ${BOLD}Security${NC}"
        echo "   a)  Open ports audit"
        echo "   b)  Firewall status        (UFW + DOCKER-USER)"
        echo "   c)  Failed login audit"
        echo "   d)  Sudo/auth events       (last 48h)"
        echo "   e)  Rootkit quick check"
        echo "   f)  Outbound connections"
        echo ""
        echo -e "  ${BOLD}Privacy & Telemetry${NC}"
        echo "   g)  Live traffic monitor   (nethogs)"
        echo "   h)  Telemetry status       (opt-out vars)"
        echo "   i)  Browser privacy        (Chromium + Firefox)"
        echo "   j)  Tailscale              (status · stop · disable)"
        echo "   k)  Service audit          (Ollama · Docker · snap)"
        echo "   l)  Apply privacy lockdown (guided or one-shot)"
        echo ""
        echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
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
            h) _priv_telemetry_status ;;
            i) _priv_browser ;;
            j) _priv_tailscale ;;
            k) _priv_service_audit; pause ;;
            l) _priv_lockdown ;;
            E) export_report "Security & Privacy"; pause ;;
            C) _cc_inline "Security & Privacy" _ctx_security _apply_security; pause ;;
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
    sudo ufw status verbose 2>/dev/null | sed 's/^/  /' || echo "  ufw not installed"
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
    for f in /var/log/auth.log /var/log/secure; do [[ -f "$f" ]] && logfile="$f" && break; done
    if [[ -n "$logfile" ]]; then
        echo "  Source: $logfile"
        echo "  Top offending IPs:"
        sudo grep -i "failed\|invalid\|authentication failure" "$logfile" 2>/dev/null \
            | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' \
            | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
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
    sudo journalctl _COMM=sudo --since "48 hours ago" 2>/dev/null | tail -40 | sed 's/^/  /'
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
    echo -e "${BCYN}┄ UNUSUAL SUID BINARIES  ${DIM}(host filesystem only)${NC}"
    echo -e "  ${DIM}Scanning... Docker/containerd/snap image layers excluded${NC}"
    echo ""
    # Use -prune to skip directories entirely (faster + no SIGPIPE from head)
    # Standard host SUID locations are safe; Docker/containerd are container image layers on disk
    local _unusual
    _unusual=$(sudo find / \
        \( -path /proc -o -path /sys \
           -o -path /var/lib/docker \
           -o -path /var/lib/containerd \
           -o -path /snap \
           -o -path /usr/bin -o -path /usr/sbin \
           -o -path /usr/lib -o -path /usr/libexec \
           -o -path /bin -o -path /sbin \
        \) -prune \
        -o -perm /4000 -print \
        2>/dev/null)
    if [[ -z "$_unusual" ]]; then
        echo -e "  ${OK}  No unusual SUID binaries found on host system"
    else
        echo -e "  ${WARN}  SUID binaries outside standard paths — review these:"
        echo "$_unusual" | sed 's/^/    /'
    fi
    echo ""
    echo -e "  ${DIM}Note: Docker/containerd paths excluded — standard Linux binaries inside${NC}"
    echo -e "  ${DIM}container images (su, passwd, mount) are normal and not a host risk.${NC}"
}

_sec_outbound() {
    header
    echo -e "${BCYN}┄ OUTBOUND CONNECTIONS (non-loopback)${NC}"
    ss -tnp 2>/dev/null | awk 'NR>1 && $5 !~ /127\.|::1|\*/' | sed 's/^/  /' | head -30
}

_priv_traffic() {
    header
    echo -e "${BCYN}┄ LIVE TRAFFIC MONITOR${NC}"
    echo ""
    if ! command -v nethogs >/dev/null 2>&1; then
        echo -e "  ${WARN}  nethogs not installed"
        if confirm "Install nethogs now?"; then sudo apt install nethogs -y; else pause; return; fi
    fi
    echo "  Launching nethogs — press q to quit..."
    sleep 1
    sudo nethogs 2>/dev/null || echo -e "  ${FAIL}  nethogs failed"
    pause
}

_priv_telemetry_status() {
    while true; do
        header
        echo -e "${BCYN}┄ TELEMETRY STATUS ─────────────────────────────────────${NC}"
        echo ""

        local issues=0

        # ── Section 1: Environment variables + persistence ──────
        echo -e "  ${BOLD}Environment Variables${NC}  ${DIM}(SET+persisted / session-only / MISSING)${NC}"
        local env_vars=(
            "DO_NOT_TRACK:1" "TELEMETRY_DISABLED:1" "DISABLE_TELEMETRY:1"
            "DOTNET_CLI_TELEMETRY_OPTOUT:1" "NEXT_TELEMETRY_DISABLED:1"
            "GATSBY_TELEMETRY_DISABLED:1" "NUXT_TELEMETRY_DISABLED:1"
            "ASTRO_TELEMETRY_DISABLED:1" "HOMEBREW_NO_ANALYTICS:1"
            "SAM_CLI_TELEMETRY:0" "SCARF_ANALYTICS:false"
        )
        for entry in "${env_vars[@]}"; do
            local var="${entry%%:*}" expected="${entry##*:}"
            local current; current=$(printenv "$var" 2>/dev/null || echo "")
            local persisted=false
            grep -q "export ${var}" ~/.bashrc 2>/dev/null && persisted=true
            grep -q "export ${var}" ~/.profile 2>/dev/null && persisted=true

            if [[ "$current" == "$expected" ]] && $persisted; then
                printf "    %b  %-36s %b%s%b\n" "$OK" "${var}=${current}" "$DIM" "persisted" "$NC"
            elif [[ "$current" == "$expected" ]] && ! $persisted; then
                printf "    %b  %-36s %bsession only — not in ~/.bashrc%b\n" "$WARN" "${var}=${current}" "$BYEL" "$NC"
                issues=$((issues + 1))
            else
                printf "    %b  %-36s %bMISSING (should be %s)%b\n" "$FAIL" "${var}" "$BRED" "$expected" "$NC"
                issues=$((issues + 1))
            fi
        done
        echo ""

        # ── Section 2: App-specific telemetry ───────────────────
        echo -e "  ${BOLD}App Telemetry${NC}"

        # Zed editor — uses JSON5 format (allows comments), grep is more reliable than json.load
        local zed_cfg="${HOME}/.config/zed/settings.json"
        if [[ -f "$zed_cfg" ]]; then
            # Strip // comments before checking, then grep for false values
            local zed_stripped; zed_stripped=$(grep -v '^\s*//' "$zed_cfg" 2>/dev/null || cat "$zed_cfg")
            local zed_diag_ok=false zed_metrics_ok=false
            echo "$zed_stripped" | grep -qE '"diagnostics"\s*:\s*false' && zed_diag_ok=true
            echo "$zed_stripped" | grep -qE '"metrics"\s*:\s*false'     && zed_metrics_ok=true
            if $zed_diag_ok && $zed_metrics_ok; then
                printf "    %b  %-20s %b%s%b\n" "$OK" "Zed editor" "$DIM" "diagnostics=false  metrics=false" "$NC"
            else
                local _zd; $zed_diag_ok   && _zd="false" || _zd="not set"
                local _zm; $zed_metrics_ok && _zm="false" || _zm="not set"
                printf "    %b  %-20s diagnostics=%-10s metrics=%-10s %brun z) to fix%b\n" \
                    "$WARN" "Zed editor" "$_zd" "$_zm" "$BYEL" "$NC"
                issues=$((issues + 1))
            fi
        else
            printf "    %b  %-20s %b%s%b\n" "$IDLE" "Zed editor" "$DIM" "not installed" "$NC"
        fi

        # Chromium flags
        local chrome_flags="${HOME}/.config/chromium-flags.conf"
        if [[ -f "$chrome_flags" ]] && grep -q "disable-metrics-reporting" "$chrome_flags" 2>/dev/null; then
            printf "    %b  %-20s %b%s%b\n" "$OK" "Chromium" "$DIM" "privacy flags applied" "$NC"
        elif command -v chromium-browser >/dev/null 2>&1 || command -v chromium >/dev/null 2>&1 || [[ -d "/snap/chromium" ]]; then
            printf "    %b  %-20s %bno flags file — run i) Browser Privacy%b\n" "$WARN" "Chromium" "$BYEL" "$NC"
            issues=$((issues + 1))
        else
            printf "    %b  %-20s %b%s%b\n" "$IDLE" "Chromium" "$DIM" "not installed" "$NC"
        fi

        # snap metrics — capture stderr to distinguish "no attribute" from real values
        local _snap_out _snap_err _snap_ok=false
        if command -v snap >/dev/null 2>&1; then
            _snap_out=$(snap get system metrics.enable 2>/tmp/zmenu-snap-err || true)
            _snap_err=$(cat /tmp/zmenu-snap-err 2>/dev/null || true)
            if [[ "$_snap_out" == "false" ]]; then
                printf "    %b  %-20s %b%s%b\n" "$OK" "snap" "$DIM" "metrics.enable=false" "$NC"
            elif echo "$_snap_err" | grep -q "no.*attribute\|not found\|has no"; then
                # Attribute doesn't exist on this snap version — not a configurable setting, not an issue
                printf "    %b  %-20s %b%s%b\n" "$IDLE" "snap" "$DIM" "metrics.enable not supported on this version" "$NC"
            elif [[ -n "$_snap_out" ]]; then
                printf "    %b  %-20s metrics.enable=%-8s  %brun s) to fix%b\n" "$WARN" "snap" "$_snap_out" "$BYEL" "$NC"
                issues=$((issues + 1))
            else
                printf "    %b  %-20s %b%s%b\n" "$IDLE" "snap" "$DIM" "could not read (may need sudo)" "$NC"
            fi
        else
            printf "    %b  %-20s %b%s%b\n" "$IDLE" "snap" "$DIM" "not installed" "$NC"
        fi

        # Ollama service telemetry override
        if systemctl list-unit-files ollama.service &>/dev/null 2>&1; then
            if [[ -f /etc/systemd/system/ollama.service.d/override.conf ]] && \
               grep -q "DO_NOT_TRACK" /etc/systemd/system/ollama.service.d/override.conf 2>/dev/null; then
                printf "    %b  %-20s %b%s%b\n" "$OK" "Ollama service" "$DIM" "DO_NOT_TRACK override present" "$NC"
            else
                printf "    %b  %-20s %bno systemd override — run l) Lockdown%b\n" "$WARN" "Ollama service" "$BYEL" "$NC"
                issues=$((issues + 1))
            fi
        else
            printf "    %b  %-20s %b%s%b\n" "$IDLE" "Ollama service" "$DIM" "not installed" "$NC"
        fi

        # npm
        if command -v npm >/dev/null 2>&1; then
            # npm has no global telemetry flag but packages like update-notifier respect DO_NOT_TRACK
            if [[ "${DO_NOT_TRACK:-}" == "1" ]]; then
                printf "    %b  %-20s %b%s%b\n" "$OK" "npm / node pkgs" "$DIM" "covered by DO_NOT_TRACK=1" "$NC"
            else
                printf "    %b  %-20s %bDO_NOT_TRACK not set in session%b\n" "$WARN" "npm / node pkgs" "$BYEL" "$NC"
            fi
        fi
        echo ""

        # ── Section 3: Active outbound to telemetry endpoints ───
        echo -e "  ${BOLD}Outbound Connections${NC}  ${DIM}(known telemetry endpoints)${NC}"
        local telem_domains="sentry.io|telemetry|metrics\.google|segment\.io|amplitude\.com|mixpanel\.com|analytics\.google|datadog|newrelic|honeycomb|posthog|hotjar|fullstory|logrocket"
        local telem_hits; telem_hits=$(ss -tnp state established 2>/dev/null \
            | awk 'NR>1{print $5}' \
            | grep -iE "$telem_domains" || true)
        if [[ -n "$telem_hits" ]]; then
            echo -e "    ${FAIL}  Active connections to telemetry endpoints detected:"
            echo "$telem_hits" | sed "s/^/      ${BRED}/ ; s/$/${NC}/"
            issues=$((issues + 1))
        else
            echo -e "    ${OK}  ${DIM}No active connections to known telemetry endpoints${NC}"
        fi
        echo ""

        # ── Summary ─────────────────────────────────────────────
        if [[ $issues -eq 0 ]]; then
            echo -e "  ${OK}  All telemetry opt-outs confirmed (session + persisted)"
        else
            echo -e "  ${WARN}  ${issues} item(s) need attention"
        fi
        echo ""
        echo "   f)  Fix env vars     (write missing to ~/.bashrc + source)"
        echo "   z)  Fix Zed          (set telemetry: false in settings.json)"
        echo "   s)  Fix snap         (disable snap metrics)"
        echo "   l)  Full lockdown    (all items at once)"
        echo "   C)  ✦ Ask AI         r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            f|F) _priv_apply_env_vars; echo -e "  ${OK}  Env vars written. Run: source ~/.bashrc"; pause ;;
            z|Z) _priv_fix_zed; pause ;;
            s|S)
                local _serr; _serr=$(sudo snap set system metrics.enable=false 2>&1)
                if [[ $? -eq 0 ]]; then
                    echo -e "  ${OK}  snap metrics disabled"
                elif echo "$_serr" | grep -q "no.*attribute\|not found\|has no"; then
                    echo -e "  ${IDLE}  snap metrics.enable is not a configurable attribute on this version — not needed"
                else
                    echo -e "  ${WARN}  ${_serr}"
                fi
                pause ;;
            l|L) _priv_lockdown ;;
            C) _cc_inline "Security" _ctx_security _apply_security; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_priv_fix_zed() {
    local zed_cfg="${HOME}/.config/zed/settings.json"
    mkdir -p "${HOME}/.config/zed"
    if [[ -f "$zed_cfg" ]]; then
        # Patch existing settings — merge telemetry block
        python3 - "$zed_cfg" << 'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
d.setdefault('telemetry', {})
d['telemetry']['diagnostics'] = False
d['telemetry']['metrics'] = False
with open(path, 'w') as f:
    json.dump(d, f, indent=2)
print("  Patched: " + path)
PYEOF
    else
        printf '{\n  "telemetry": {\n    "diagnostics": false,\n    "metrics": false\n  }\n}\n' > "$zed_cfg"
        echo -e "  ${OK}  Created: ${zed_cfg}"
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
        echo "   r)  Back"
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
    cat "$flags_file" | sed 's/^/    /'
    echo ""
    echo -e "  ${DIM}  Restart Chromium for changes to take effect${NC}"
}

_priv_chromium_check() {
    header
    echo -e "${BCYN}┄ CHROMIUM FLAGS CHECK${NC}"
    echo ""
    local flags_file="${HOME}/.config/chromium-flags.conf"
    if [[ -f "$flags_file" ]]; then
        echo -e "  ${OK}  Flags file exists"
        cat "$flags_file" | sed 's/^/    /'
    else
        echo -e "  ${WARN}  No flags file — run option a)"
    fi
}

_priv_firefox() {
    header
    echo -e "${BCYN}┄ FIREFOX TELEMETRY${NC}"
    echo ""
    local prefs; prefs=$(find "${HOME}/.mozilla/firefox" -name "prefs.js" 2>/dev/null | head -1)
    if [[ -z "$prefs" ]]; then echo -e "  ${WARN}  Firefox profile not found"; pause; return; fi
    echo "  Profile: $prefs"
    local settings=("toolkit.telemetry.enabled" "toolkit.telemetry.unified" "datareporting.healthreport.uploadEnabled" "app.shield.optoutstudies.enabled")
    for s in "${settings[@]}"; do
        if grep -q "$s" "$prefs" 2>/dev/null; then
            local val; val=$(grep "$s" "$prefs" | grep -o 'true\|false')
            [[ "$val" == "false" ]] && echo -e "  ${OK}  ${s} = false" || echo -e "  ${WARN}  ${s} = ${val}"
        else
            echo -e "  ${IDLE}  ${s} = not set"
        fi
    done
    echo ""
    if confirm "Apply telemetry opt-out?"; then
        echo -e "  ${BYEL}  Note: Firefox must be closed${NC}"
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
        echo -e "  ${OK}  Applied. Backup: ${prefs}.bak"
    fi
}

_priv_tailscale() {
    header
    echo -e "${BCYN}┄ TAILSCALE${NC}"
    echo ""
    if ! command -v tailscale >/dev/null 2>&1; then echo -e "  ${IDLE}  Not installed"; pause; return; fi
    local ts_status; ts_status=$(tailscale status 2>/dev/null || echo "not running")
    local ts_active; ts_active=$(systemctl is-active tailscaled 2>/dev/null)
    local ts_enabled; ts_enabled=$(systemctl is-enabled tailscaled 2>/dev/null)
    echo "  Service: ${ts_active}    Autostart: ${ts_enabled}"
    echo "$ts_status" | sed 's/^/  /' | head -10
    echo ""
    echo "   a)  Stop    b)  Disable autostart    c)  Stop + disable    d)  Start    r)  Back"
    read -rp "  Selection: " ch
    case $ch in
        a) sudo systemctl stop tailscaled && echo -e "  ${OK}  Stopped" || echo -e "  ${FAIL}  Failed"; pause ;;
        b) sudo systemctl disable tailscaled && echo -e "  ${OK}  Disabled" || echo -e "  ${FAIL}  Failed"; pause ;;
        c) sudo systemctl stop tailscaled && sudo systemctl disable tailscaled && echo -e "  ${OK}  Done" || echo -e "  ${FAIL}  Failed"; pause ;;
        d) sudo systemctl start tailscaled && echo -e "  ${OK}  Started" || echo -e "  ${FAIL}  Failed"; pause ;;
        r|R) return ;;
    esac
}

_priv_service_audit() {
    header
    echo -e "${BCYN}┄ SERVICE PHONE-HOME AUDIT${NC}"
    echo ""
    echo -e "${BCYN}  Ollama${NC}"
    local ollama_override="/etc/systemd/system/ollama.service.d/override.conf"
    if [[ -f "$ollama_override" ]] && grep -q "DO_NOT_TRACK" "$ollama_override"; then
        echo -e "  ${OK}  Telemetry override present"
    else
        echo -e "  ${WARN}  No telemetry override — run lockdown"
    fi
    echo ""
    echo -e "${BCYN}  Docker${NC}"
    [[ -f "/etc/docker/daemon.json" ]] && { echo -e "  ${OK}  daemon.json present"; cat /etc/docker/daemon.json | sed 's/^/    /'; } || echo -e "  ${IDLE}  No daemon.json"
    echo ""
    echo -e "${BCYN}  Snap${NC}"
    local snap_metrics; snap_metrics=$(snap get system metrics.enable 2>/dev/null || echo "unknown")
    [[ "$snap_metrics" == "false" ]] && echo -e "  ${OK}  Metrics disabled" || echo -e "  ${WARN}  Metrics: ${snap_metrics}"
    echo ""
    echo -e "${BCYN}  Current outbound${NC}"
    ss -tnp 2>/dev/null | awk 'NR>1 && $5 !~ /127\.|::1|\*/' | sed 's/^/  /' | head -15
    [[ -z "$(ss -tnp 2>/dev/null | awk 'NR>1 && $5 !~ /127\.|::1|\*/')" ]] && echo -e "  ${OK}  No external connections"
}

_priv_lockdown() {
    header
    echo -e "${BCYN}┄ PRIVACY LOCKDOWN${NC}"
    echo ""
    echo "   a)  Guided  — step through each item"
    echo "   b)  One-shot — apply everything"
    echo "   r)  Back"
    echo ""
    read -rp "  Selection: " ch
    case $ch in a) _priv_lockdown_guided ;; b) _priv_lockdown_oneshot ;; r|R) return ;; esac
}

_priv_lockdown_guided() {
    header
    echo -e "${BCYN}┄ GUIDED PRIVACY LOCKDOWN${NC}"
    echo ""
    echo -e "${BOLD}  Step 1: Telemetry env vars${NC}"
    if confirm "Add telemetry opt-out vars to ~/.bashrc?"; then _priv_apply_env_vars; echo -e "  ${OK}  Done"; else echo -e "  ${DIM}  Skipped${NC}"; fi
    echo ""
    echo -e "${BOLD}  Step 2: Ollama override${NC}"
    if confirm "Create Ollama telemetry override?"; then _priv_apply_ollama_override; echo -e "  ${OK}  Done"; else echo -e "  ${DIM}  Skipped${NC}"; fi
    echo ""
    echo -e "${BOLD}  Step 3: Snap metrics${NC}"
    if confirm "Disable Snap metrics?"; then sudo snap set system metrics.enable=false 2>/dev/null && echo -e "  ${OK}  Done" || echo -e "  ${WARN}  Failed"; else echo -e "  ${DIM}  Skipped${NC}"; fi
    echo ""
    echo -e "${BOLD}  Step 4: Tailscale${NC}"
    if command -v tailscale >/dev/null 2>&1; then
        if confirm "Stop and disable Tailscale?"; then sudo systemctl stop tailscaled 2>/dev/null; sudo systemctl disable tailscaled 2>/dev/null; echo -e "  ${OK}  Done"; else echo -e "  ${DIM}  Skipped${NC}"; fi
    else echo -e "  ${IDLE}  Not installed"; fi
    echo ""
    echo -e "${BOLD}  Step 5: Chromium flags${NC}"
    if confirm "Apply Chromium privacy flags?"; then _priv_chromium_apply; else echo -e "  ${DIM}  Skipped${NC}"; fi
    echo ""
    echo -e "  ${OK}  Guided lockdown complete"
    echo -e "  ${DIM}  Run: source ~/.bashrc${NC}"
    pause
}

_priv_lockdown_oneshot() {
    header
    echo -e "${BCYN}┄ ONE-SHOT PRIVACY LOCKDOWN${NC}"
    echo ""
    if ! confirm "Apply ALL privacy settings?"; then return; fi
    echo ""
    echo "  [1/5] Telemetry env vars..."; _priv_apply_env_vars && echo -e "  ${OK}  Done" || echo -e "  ${WARN}  Partial"
    echo "  [2/5] Ollama override..."; _priv_apply_ollama_override && echo -e "  ${OK}  Done" || echo -e "  ${WARN}  Failed"
    echo "  [3/5] Snap metrics..."; sudo snap set system metrics.enable=false 2>/dev/null && echo -e "  ${OK}  Done" || echo -e "  ${IDLE}  Snap not found"
    echo "  [4/5] Tailscale..."
    if command -v tailscale >/dev/null 2>&1; then sudo systemctl stop tailscaled 2>/dev/null; sudo systemctl disable tailscaled 2>/dev/null; echo -e "  ${OK}  Done"; else echo -e "  ${IDLE}  Not installed"; fi
    echo "  [5/5] Chromium flags..."; _priv_chromium_apply >/dev/null 2>&1 && echo -e "  ${OK}  Done"
    echo ""
    echo -e "  ${OK}  Lockdown complete. Run: source ~/.bashrc"
    pause
}

_priv_apply_env_vars() {
    if grep -q "DO_NOT_TRACK" ~/.bashrc; then
        sed -i '/DO_NOT_TRACK/d; /TELEMETRY_DISABLED/d; /DISABLE_TELEMETRY/d; /DOTNET_CLI_TELEMETRY/d; /NEXT_TELEMETRY/d; /GATSBY_TELEMETRY/d; /NUXT_TELEMETRY/d; /ASTRO_TELEMETRY/d; /HOMEBREW_NO_ANALYTICS/d; /SAM_CLI_TELEMETRY/d; /SCARF_ANALYTICS/d; /Privacy.*Zero Telemetry/d' ~/.bashrc
    fi
    printf '\n# Privacy / Zero Telemetry\n' >> ~/.bashrc
    printf 'export DO_NOT_TRACK=1\nexport TELEMETRY_DISABLED=1\nexport DISABLE_TELEMETRY=1\n' >> ~/.bashrc
    printf 'export DOTNET_CLI_TELEMETRY_OPTOUT=1\nexport NEXT_TELEMETRY_DISABLED=1\n' >> ~/.bashrc
    printf 'export GATSBY_TELEMETRY_DISABLED=1\nexport NUXT_TELEMETRY_DISABLED=1\n' >> ~/.bashrc
    printf 'export ASTRO_TELEMETRY_DISABLED=1\nexport HOMEBREW_NO_ANALYTICS=1\n' >> ~/.bashrc
    printf 'export SAM_CLI_TELEMETRY=0\nexport SCARF_ANALYTICS=false\n' >> ~/.bashrc
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

# ──────────────────────────────────────────────────────────
#  MODULE 7: MAINTENANCE
# ──────────────────────────────────────────────────────────

mod_maintenance() {
    while true; do
        header
        echo -e "${BCYN}┄ MAINTENANCE ──────────────────────────────────────────${NC}"
        echo ""
        echo "   a)  System updates         (apt check · upgrade)"
        echo "   b)  Disk audit & cleanup"
        echo "   c)  SMART disk health"
        echo "   d)  Journal errors         (last 24h)"
        echo "   e)  Journal size trim      (vacuum to 200MB)"
        echo ""
        echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _maint_updates ;;
            b) _maint_disk ;;
            c) _maint_smart; pause ;;
            d) _maint_journal_errors; pause ;;
            e) _maint_journal_trim; pause ;;
            E) export_report "Maintenance"; pause ;;
            C) _cc_inline "Maintenance" _ctx_maintenance _apply_maintenance; pause ;;
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
        local disk_used disk_total disk_free disk_pct
        read -r disk_total disk_used disk_pct < <(df -BG / | awk 'NR==2{gsub(/G/,"",$2); gsub(/G/,"",$3); gsub(/%/,"",$5); print $2,$3,$5}')
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

        local ai_lms ai_ollama apt_cache journal_sz
        ai_lms=$(du -sh "${HOME}/.lmstudio/models" 2>/dev/null | cut -f1 || echo "0")
        ai_ollama=$(du -sh "${HOME}/.ollama/models" 2>/dev/null | cut -f1 || echo "0")
        apt_cache=$(du -sh /var/cache/apt 2>/dev/null | cut -f1 || echo "?")
        journal_sz=$(du -sh /var/log/journal 2>/dev/null | cut -f1 || echo "?")
        printf "  %-30s  %s\n" "LM Studio models:" "$ai_lms"
        printf "  %-30s  %s\n" "Ollama models:" "$ai_ollama"
        printf "  %-30s  %s\n" "APT cache:" "$apt_cache"
        printf "  %-30s  %s\n" "Journal logs:" "$journal_sz"
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
            c) snap list --all 2>/dev/null | awk '/disabled/{print $1,$3}' | while read -r sn rv; do sudo snap remove "$sn" --revision="$rv" 2>/dev/null; done
               echo -e "  ${OK}  Done"; pause ;;
            d) _docker_prune ;;
            A) sudo apt clean && sudo apt autoremove -y >/dev/null 2>&1
               sudo journalctl --vacuum-size=200M >/dev/null 2>&1
               snap list --all 2>/dev/null | awk '/disabled/{print $1,$3}' | while read -r sn rv; do sudo snap remove "$sn" --revision="$rv" 2>/dev/null; done
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
    if ! command -v smartctl >/dev/null 2>&1; then echo "  sudo apt install smartmontools"; return; fi
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
    sudo journalctl -p err --since "24 hours ago" 2>/dev/null | grep -v "^--" | tail -60 | sed 's/^/  /'
}

_maint_journal_trim() {
    header
    echo -e "${BCYN}┄ JOURNAL VACUUM${NC}"
    sudo journalctl --vacuum-size=200M 2>/dev/null | sed 's/^/  /'
    echo -e "  ${OK}  Done"
    pause
}

# ──────────────────────────────────────────────────────────
#  MODULE 8: PROJECTS
# ──────────────────────────────────────────────────────────

mod_projects() {
    while true; do
        header
        echo -e "${BCYN}┄ PROJECTS  (${ZMENU_PROJECTS_DIR}) ─────────────────────${NC}"
        echo ""
        local -a proj_paths=()
        if [[ -d "$ZMENU_PROJECTS_DIR" ]]; then
            while IFS= read -r -d '' p; do proj_paths+=("$p")
            done < <(find "$ZMENU_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z 2>/dev/null || true)
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
            i=$((i + 1))
        done
        echo ""
        echo "   n)  New project"
        echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            n|N) _proj_new ;;
            E) export_report "Projects"; pause ;;
            C) _cc_inline "Projects" _ctx_projects _apply_projects; pause ;;
            r|R) break ;;
            *)
                if [[ "$ch" =~ ^[0-9]+$ ]] && [[ "$ch" -ge 1 ]] && [[ "$ch" -le ${#proj_paths[@]} ]]; then
                    _proj_open "${proj_paths[$((ch-1))]}"
                else
                    echo -e "${RED}  Invalid.${NC}"; sleep 1
                fi ;;
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
        [[ -f "${path}/AI.md" ]] && echo -e "  ${OK}  AI.md present" || echo -e "  ${WARN}  No AI.md"
        [[ -f "${path}/.config/ai/settings.json" ]] && echo -e "  ${OK}  settings.json present" || echo -e "  ${WARN}  No settings.json"
        echo ""
        echo "   a)  Open terminal here"
        echo "   b)  Launch AI session"
        echo "   c)  Edit AI.md"
        echo "   d)  Edit settings.json"
        echo "   E)  Export    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) if command -v gnome-terminal >/dev/null 2>&1; then gnome-terminal --working-directory="$path" &>/dev/null &
               else echo "  cd ${path}"; fi ;;
            b) cc_launch "Project: ${name}" "Working on project at ${path}. Read AI.md if present." "$path" "--tui"; pause ;;
            c) ${ZMENU_PREFERRED_EDITOR} "${path}/AI.md" ;;
            d) mkdir -p "${path}/.config/ai"; ${ZMENU_PREFERRED_EDITOR} "${path}/.config/ai/settings.json" ;;
            E) export_report "Project: ${name}"; pause ;;
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
    if [[ -d "$path" ]]; then echo -e "  ${WARN}  Already exists: ${path}"; pause; return; fi
    mkdir -p "${path}/.config/ai"
    cat > "${path}/AI.md" << EOF
# ${name}
> Created: $(date '+%B %Y')

## What to Build

## Stack
$(uname -o) · $(uname -r) · ${D_CPU_MODEL}
Zenny-Core (${ZMENU_AI_MODEL:-auto}) · Docker
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

# ──────────────────────────────────────────────────────────
#  AI BACKEND PICKER
# ──────────────────────────────────────────────────────────

_ai_backend_picker() {
    while true; do
        header
        echo -e "${BCYN}┄ AI BACKEND ───────────────────────────────────────────${NC}"
        echo ""
        echo -e "  Preference:  ${BOLD}${ZMENU_AI_BACKEND:-auto}${NC}  ${DIM}(saved to ~/.zmenu/config)${NC}"
        echo -e "  Active now:  ${BOLD}${AI_BACKEND_LABEL:-none}${NC}  ${DIM}(runtime status — see AI Engine module)${NC}"
        echo ""

        local z_status oc_status ol_status
        [[ "$D_ZENNY_RUNNING" == true ]] \
            && z_status="${OK} running  ${#D_ZENNY_MODELS[@]} model(s)" \
            || z_status="${IDLE} stopped"
        if pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
            oc_status="${OK} RUNNING  (TUI-only — inline chat uses Zenny)"
        elif _opencode_available; then
            oc_status="${IDLE} installed (not running)"
        else
            oc_status="${IDLE} not installed"
        fi
        [[ "$D_OLLAMA_RUNNING" == true ]] \
            && ol_status="${WARN} running (should be disabled)" \
            || ol_status="${IDLE} disabled"

        # Show current chat model
        local chat_model_display="${ZMENU_ZENNY_CHAT_MODEL:-auto (${ZMENU_AI_MODEL##*/})}"

        echo -e "   1)  auto       — best available (Zenny → Ollama)"
        echo -e "   2)  zenny      ${z_status}"
        echo -e "   3)  opencode   ${oc_status}"
        echo -e "   4)  ollama     ${ol_status}"
        echo ""
        echo -e "   z)  Zenny chat model  ${DIM}(current: ${chat_model_display})${NC}"
        echo ""
        echo -e "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _ai_backend_set "auto"     ;;
            2) _ai_backend_set "zenny"    ;;
            3) _ai_backend_set "opencode" ;;
            4) _ai_backend_set "ollama"   ;;
            z) _ai_zenny_chat_model_pick; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_ai_backend_set() {
    local backend="$1"
    if grep -q '^ZMENU_AI_BACKEND=' "$ZMENU_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^ZMENU_AI_BACKEND=.*|ZMENU_AI_BACKEND=\"${backend}\"|" "$ZMENU_CONFIG_FILE"
    else
        printf '\nZMENU_AI_BACKEND="%s"\n' "$backend" >> "$ZMENU_CONFIG_FILE"
    fi
    ZMENU_AI_BACKEND="$backend"
    _sel_ai_backend
    echo -e "  ${OK}  Backend preference: ${backend}  →  active: ${AI_BACKEND_LABEL}"
    sleep 1
}

_ai_zenny_chat_model_pick() {
    header
    echo -e "${BCYN}┄ ZENNY CHAT MODEL${NC}"
    echo ""
    echo -e "  ${DIM}This model is used for all inline 'Ask AI' sessions.${NC}"
    echo -e "  ${DIM}Pick a smaller/faster model for quick questions.${NC}"
    echo ""
    if [[ ${#D_ZENNY_KEYS[@]} -eq 0 ]]; then
        echo -e "  ${FAIL}  Zenny-Core not running or no models found"; return
    fi
    echo "   0)  auto  (smallest available model)"
    local i=1
    for key in "${D_ZENNY_KEYS[@]}"; do
        local disp="${D_ZENNY_MODELS[$((i-1))]:-$key}"
        local marker=""
        [[ "$key" == "$ZMENU_ZENNY_CHAT_MODEL" ]] && marker=" ${DIM}← current${NC}"
        [[ -z "$ZMENU_ZENNY_CHAT_MODEL" && "$key" == "$(_zenny_pick_chat_model)" ]] \
            && marker=" ${DIM}← auto-selected${NC}"
        printf "   %d)  %-45s %b\n" "$i" "$disp" "$marker"
        i=$((i + 1))
    done
    echo ""
    read -rp "  Select (0-$((i-1))): " n
    local chosen=""
    if [[ "$n" == "0" ]]; then
        chosen=""
        echo -e "  ${OK}  Auto-select enabled (will pick smallest available)"
    elif [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -lt $i ]]; then
        chosen="${D_ZENNY_KEYS[$((n-1))]}"
        echo -e "  ${OK}  Chat model: ${chosen}"
    else
        echo -e "${RED}  Invalid.${NC}"; return
    fi
    if grep -q '^ZMENU_ZENNY_CHAT_MODEL=' "$ZMENU_CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^ZMENU_ZENNY_CHAT_MODEL=.*|ZMENU_ZENNY_CHAT_MODEL=\"${chosen}\"|" "$ZMENU_CONFIG_FILE"
    else
        printf '\nZMENU_ZENNY_CHAT_MODEL="%s"\n' "$chosen" >> "$ZMENU_CONFIG_FILE"
    fi
    ZMENU_ZENNY_CHAT_MODEL="$chosen"
    _sel_ai_backend
}


# ──────────────────────────────────────────────────────────
#  SETTINGS (merged from old Manage Z-Menu + AI Inspector)
# ──────────────────────────────────────────────────────────

mod_settings() {
    while true; do
        header
        echo -e "${BCYN}┄ SETTINGS ─────────────────────────────────────────────${NC}"
        echo ""
        echo "  Version:  ${ZMENU_VERSION}"
        echo "  Source:   ${ZMENU_SELF}"
        echo "  Config:   ${ZMENU_CONFIG_FILE}"
        echo -e "  AI:       ${AI_BACKEND_LABEL}  ${DIM}(${ZMENU_AI_MODEL})${NC}"
        echo ""

        local inst_ver
        inst_ver=$(grep 'ZMENU_VERSION=' "$ZMENU_INSTALL_PATH" 2>/dev/null | head -1 | cut -d'"' -f2 || echo "not installed")
        [[ -z "$inst_ver" ]] && inst_ver="not installed"
        if [[ "$inst_ver" == "$ZMENU_VERSION" ]]; then
            echo -e "  Installed: ${BGRN}✓ ${inst_ver} matches${NC}"
        elif [[ "$ZMENU_SELF" == "$ZMENU_INSTALL_PATH" ]]; then
            echo -e "  Installed: ${BGRN}✓ running from install path${NC}"
        else
            echo -e "  Installed: ${BYEL}${inst_ver} (source is ${ZMENU_VERSION})${NC}"
        fi

        local sudoers_ok=false
        sudo -n systemctl status ollama >/dev/null 2>&1 && sudoers_ok=true
        $sudoers_ok && echo -e "  Ollama sudo: ${BGRN}✓ passwordless${NC}" || echo -e "  Ollama sudo: ${BYEL}requires password${NC}"
        echo ""

        echo -e "  ${BOLD}Z-Menu${NC}"
        echo "   a)  Reinstall from source"
        echo "   b)  Edit source"
        echo "   c)  Edit config"
        echo "   d)  Check environment vars"
        echo "   e)  Re-run discovery"
        echo "   f)  Setup passwordless Ollama"
        echo ""
        echo -e "  ${BOLD}AI${NC}"
        echo "   l)  AI Backend               (Zenny · OpenCode · Ollama)"
        echo "   w)  Sovereign Wiki            (view · refresh knowledge base)"
        echo ""
        echo -e "  ${BOLD}AI Inspector${NC}"
        echo "   g)  Global settings.json"
        echo "   h)  Global AI.md"
        echo "   i)  Skills viewer/editor"
        echo "   j)  MCP servers"
        echo "   k)  Project inspector"
        echo ""
        echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _mgmt_reinstall; pause ;;
            b) set +e; ${ZMENU_PREFERRED_EDITOR} "$ZMENU_SELF"; set -e ;;
            c) cfg_edit ;;
            d) _mgmt_envcheck; pause ;;
            e) echo "  Re-running discovery..."; discover; echo -e "  ${OK}  Done"; pause ;;
            f) _mgmt_sudoers_ollama; pause ;;
            l) _ai_backend_picker ;;
            w) _wiki_show; pause ;;
            g) _cc_global_settings ;;
            h) _cc_global_md ;;
            i) _cc_skills ;;
            j) _cc_mcps ;;
            k) _cc_project_inspector ;;
            E) export_report "Settings"; pause ;;
            C) _cc_inline "Settings" _ctx_settings _apply_settings; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_mgmt_reinstall() {
    if [[ "$ZMENU_SELF" == "$ZMENU_INSTALL_PATH" ]]; then
        echo -e "  ${WARN}  Source and install are the same"; return
    fi
    sudo cp "$ZMENU_SELF" "$ZMENU_INSTALL_PATH" && sudo chmod +x "$ZMENU_INSTALL_PATH" \
        && echo -e "  ${OK}  Installed to ${ZMENU_INSTALL_PATH}" \
        || echo -e "  ${FAIL}  Failed"
}

_mgmt_envcheck() {
    header
    echo -e "${BCYN}┄ ENVIRONMENT VARIABLES${NC}"
    echo ""
    local hsa_expected=""
    if [[ -n "$D_GPU_GFX" ]]; then
        local gfx_num="${D_GPU_GFX#gfx}"
        [[ ${#gfx_num} -eq 4 ]] && hsa_expected="${gfx_num:0:2}.${gfx_num:2:1}.${gfx_num:3:1}" || hsa_expected="${gfx_num}"
    fi
    _env_check "HSA_OVERRIDE_GFX_VERSION" "${hsa_expected:-unknown}" "ROCm GPU hint (derived from ${D_GPU_GFX:-unknown})"
    _env_check "DOCKER_HOST" "unix:///run/docker.sock" "Docker socket"
}

_env_check() {
    local var="$1" expected="$2" desc="$3"
    local cur="${!var:-NOT SET}"
    printf "\n  ${BOLD}%s${NC}\n  %s\n" "$var" "$desc"
    if [[ "$cur" == "NOT SET" ]]; then
        printf "  ${BRED}NOT SET${NC}  →  echo 'export %s=%s' >> ~/.bashrc\n" "$var" "$expected"
    elif [[ "$cur" == "$expected" ]]; then
        printf "  ${BGRN}✓  %s${NC}\n" "$cur"
    else
        printf "  ${BYEL}%s  (expected: %s)${NC}\n" "$cur" "$expected"
    fi
}

_mgmt_sudoers_ollama() {
    header
    echo -e "${BCYN}┄ PASSWORDLESS OLLAMA CONTROL${NC}"
    echo ""
    if sudo -n systemctl status ollama >/dev/null 2>&1; then
        echo -e "  ${OK}  Already configured"
        cat /etc/sudoers.d/zmenu-ollama 2>/dev/null | sed 's/^/  /' || true
        return
    fi
    echo "  Creates sudoers rule for: systemctl stop|start|restart|status ollama"
    echo ""
    if ! confirm "Set up passwordless Ollama control?"; then return; fi
    local user; user=$(whoami)
    local rule="${user} ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop ollama, /usr/bin/systemctl start ollama, /usr/bin/systemctl restart ollama, /usr/bin/systemctl status ollama"
    if echo "$rule" | sudo tee /etc/sudoers.d/zmenu-ollama >/dev/null 2>&1 \
        && sudo chmod 0440 /etc/sudoers.d/zmenu-ollama \
        && sudo visudo -c -f /etc/sudoers.d/zmenu-ollama >/dev/null 2>&1; then
        echo -e "  ${OK}  Sudoers rule installed"
    else
        sudo rm -f /etc/sudoers.d/zmenu-ollama 2>/dev/null
        echo -e "  ${FAIL}  Failed"
    fi
}

# ── AI Inspector functions ─────────────────────────────────

_cc_global_settings() {
    header
    echo -e "${BCYN}┄ GLOBAL SETTINGS  (~/.config/ai/settings.json)${NC}"
    echo ""
    local f="${HOME}/.config/ai/settings.json"
    if [[ -f "$f" ]]; then
        echo -e "  ${OK}  File present"
        echo ""; cat "$f" | sed 's/^/  /'
    else
        echo -e "  ${WARN}  Not found"
    fi
    echo ""
    echo "   e)  Edit    r)  Back"
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
        echo ""; cat "$f" | sed 's/^/  /' | head -40
        [[ $lines -gt 40 ]] && echo "  ${DIM}... $((lines-40)) more lines${NC}"
    else
        echo -e "  ${WARN}  Not found"
    fi
    echo ""
    echo "   e)  Edit    r)  Back"
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
            while IFS= read -r -d '' f; do skill_files+=("$f")
            done < <(find "$skills_dir" -name "*.md" -print0 2>/dev/null | sort -z)
        fi
        if [[ ${#skill_files[@]} -eq 0 ]]; then
            echo -e "  ${IDLE}  No skills yet."
        else
            local i=1
            for f in "${skill_files[@]}"; do
                printf "   %d)  ${BOLD}%-28s${NC}  ${DIM}%d lines${NC}\n" "$i" "$(basename "$f" .md)" "$(wc -l < "$f")"
                i=$((i + 1))
            done
        fi
        echo ""
        echo "   n)  New skill    r)  Back"
        echo ""
        read -rp "  Select: " ch
        case $ch in
            r|R) break ;;
            n|N) _cc_skill_new; continue ;;
            *)
                if [[ "$ch" =~ ^[0-9]+$ ]] && [[ "$ch" -ge 1 ]] && [[ "$ch" -le ${#skill_files[@]} ]]; then
                    local sf="${skill_files[$((ch-1))]}"
                    header; echo -e "${BCYN}┄ SKILL: $(basename "$sf" .md)${NC}"; echo ""
                    cat "$sf" | sed 's/^/  /'
                    echo ""
                    echo "   e)  Edit    d)  Delete    r)  Back"
                    read -rp "  Selection: " act
                    case $act in
                        e|E) ${ZMENU_PREFERRED_EDITOR} "$sf" ;;
                        d|D) confirm "Delete?" && rm "$sf" && echo -e "  ${OK}  Deleted"; pause ;;
                    esac
                fi ;;
        esac
    done
}

_cc_skill_new() {
    header
    echo -e "${BCYN}┄ NEW SKILL${NC}"
    echo ""
    read -rp "  Skill name: " name
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
        echo -e "  ${WARN}  No settings.json"
        echo "   a)  Add MCP server    r)  Back"
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
    if not servers: print("  No MCP servers registered.")
    else:
        print(f"  {len(servers)} server(s):\n")
        for name, cfg in servers.items():
            t = cfg.get('transport', cfg.get('type', '?'))
            u = cfg.get('url', cfg.get('command', ''))
            print(f"    {name}  ({t})  {u}")
except Exception as e: print(f"  Error: {e}")
PYEOF
    echo ""
    echo "   a)  Add    e)  Edit settings.json    r)  Back"
    read -rp "  Selection: " ch
    case $ch in a|A) _cc_mcp_add ;; e|E) ${ZMENU_PREFERRED_EDITOR} "$settings" ;; esac
}

_cc_mcp_add() {
    header
    echo -e "${BCYN}┄ ADD MCP SERVER${NC}"
    echo ""
    read -rp "  Server name: " mcp_name; [[ -z "$mcp_name" ]] && return
    read -rp "  URL: " mcp_url; [[ -z "$mcp_url" ]] && return
    read -rp "  Transport [sse/http/stdio] (default: sse): " mcp_transport
    mcp_transport="${mcp_transport:-sse}"
    local settings="${HOME}/.config/ai/settings.json"
    python3 - "$settings" "$mcp_name" "$mcp_transport" "$mcp_url" << 'PYEOF'
import json, sys
f, name, transport, url = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try: d = json.load(open(f))
except: d = {}
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
    echo -e "  ${DIM}[md]=AI.md  [set]=settings  [sk]=skills  [mcp]=MCP  [git]=branch${NC}"
    echo ""
    local -a proj_paths=()
    if [[ -d "$ZMENU_PROJECTS_DIR" ]]; then
        while IFS= read -r -d '' p; do proj_paths+=("$p")
        done < <(find "$ZMENU_PROJECTS_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z 2>/dev/null || true)
    fi
    if [[ ${#proj_paths[@]} -eq 0 ]]; then echo "  No projects"; pause; return; fi
    local i=1
    for p in "${proj_paths[@]}"; do
        local pn; pn=$(basename "$p")
        local badges=""
        [[ -f "${p}/AI.md" ]] && badges+="${BGRN}[md]${NC} " || badges+="${BRED}[no md]${NC} "
        [[ -f "${p}/.config/ai/settings.json" ]] && badges+="${BGRN}[set]${NC} " || badges+="${BYEL}[no set]${NC} "
        local sk=0
        [[ -d "${p}/.config/ai/skills" ]] && sk=$(find "${p}/.config/ai/skills" -name "*.md" 2>/dev/null | wc -l)
        [[ $sk -gt 0 ]] && badges+="${BCYN}[${sk}sk]${NC} "
        if [[ -d "${p}/.git" ]]; then
            local br; br=$(git -C "$p" branch --show-current 2>/dev/null || echo "?")
            badges+="${DIM}[${br}]${NC}"
        fi
        printf "   %d)  ${BOLD}%-22s${NC}  %b\n" "$i" "$pn" "$badges"
        i=$((i + 1))
    done
    echo ""
    echo "   r)  Back"
    read -rp "  Select: " ch
    case $ch in
        r|R) return ;;
        *)
            if [[ "$ch" =~ ^[0-9]+$ ]] && [[ "$ch" -ge 1 ]] && [[ "$ch" -le ${#proj_paths[@]} ]]; then
                _cc_proj_detail "${proj_paths[$((ch-1))]}"
            fi ;;
    esac
}

_cc_proj_detail() {
    local path="$1"
    local name; name=$(basename "$path")
    header
    echo -e "${BCYN}┄ PROJECT: ${name}${NC}"
    echo ""
    echo -e "${BOLD}  AI.md${NC}"
    if [[ -f "${path}/AI.md" ]]; then
        echo -e "  ${OK}  Present  ($(wc -l < "${path}/AI.md") lines)"
        head -25 "${path}/AI.md" | sed 's/^/    /'
    else echo -e "  ${WARN}  Missing"; fi
    echo ""
    echo -e "${BOLD}  settings.json${NC}"
    if [[ -f "${path}/.config/ai/settings.json" ]]; then
        echo -e "  ${OK}  Present"
        cat "${path}/.config/ai/settings.json" | sed 's/^/    /'
    else echo -e "  ${WARN}  Missing"; fi
    echo ""
    echo -e "${BOLD}  Skills${NC}"
    if [[ -d "${path}/.config/ai/skills" ]]; then
        find "${path}/.config/ai/skills" -name "*.md" 2>/dev/null | while read -r sf; do
            echo -e "    ${BGRN}●${NC}  $(basename "$sf" .md)"
        done
    else echo -e "  ${IDLE}  None"; fi
    echo ""
    echo "   e)  Edit AI.md    s)  Edit settings.json    r)  Back"
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
        dashboard
        echo -e "  ${BOLD}${BBLU}┄ MENU ─────────────────────────────────────────────────${NC}"
        echo ""
        echo "   1)  Dashboard               (refresh status above)"
        echo "   2)  Find Problems            (full bottleneck sweep)"
        echo "   3)  AI Engine                (Zenny-Core · OpenCode · LM Studio · Ollama)"
        echo "   4)  System Scan              (all apps · services · resources · security)"
        echo "   5)  Hardware                 (CPU · GPU · NPU · power · thermals)"
        echo "   6)  Security & Privacy       (ports · firewall · telemetry)"
        echo "   7)  Maintenance              (updates · disk · SMART · journal)"
        echo "   8)  Projects                 (open · create · AI sessions)"
        echo ""
        echo "   s)  Settings                 (zmenu config · AI inspector · env)"
        echo "   E)  Export full report"
        echo "   q)  Exit"
        echo ""
        read -rp "  $(printf '%b' "${BOLD}Selection:${NC} ")" choice
        case $choice in
            1) discover ;;
            2) mod_find_problems ;;
            3) mod_ai_engine ;;
            4) mod_system_scan ;;
            5) mod_hardware ;;
            6) mod_security ;;
            7) mod_maintenance ;;
            8) mod_projects ;;
            s|S) mod_settings ;;
            E) export_report "Full System"; pause ;;
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
    --export)
        _bootstrap
        export_report "CLI Export"
        cat "$ZMENU_REPORT_FILE"
        exit 0
        ;;
    --help|-h)
        echo "Usage: zmenu [--run <function>] [--context] [--export] [--help]"
        echo "  --run <fn>    Execute a module function headlessly"
        echo "  --context     Dump live system context to stdout"
        echo "  --export      Generate markdown report to ~/zmenu-report.md"
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
