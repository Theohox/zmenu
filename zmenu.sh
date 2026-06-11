#!/usr/bin/env bash
# ============================================================
#  Z-MENU  —  Built 2026-06-11 08:28:39
#  Auto-generated from src/*.sh — edit sources, not this file
#  Build: ./build.sh
# ============================================================


# ═══════════════════════════════════════════════════════════
#  MODULE: 00-header.sh
# ═══════════════════════════════════════════════════════════

#!/usr/bin/env bash
# ============================================================
#  Z-MENU  v5.13.2
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
readonly ZMENU_VERSION="5.13.6"
readonly ZMENU_SELF="$(realpath "${BASH_SOURCE[0]}")"
readonly ZMENU_INSTALL_PATH="/usr/local/bin/zmenu"

# ── Config directory & defaults ────────────────────────────
ZMENU_CONFIG_DIR="${HOME}/.zmenu"
ZMENU_CONFIG_FILE="${ZMENU_CONFIG_DIR}/config"
ZMENU_WIKI_DIR="${ZMENU_CONFIG_DIR}/wiki"
ZMENU_HISTORY_DIR="${ZMENU_CONFIG_DIR}/history"
ZMENU_SESSION_LOG="${ZMENU_HISTORY_DIR}/commands.jsonl"
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
_on_err() {
    local _safe_cmd
    _safe_cmd=$(echo "$BASH_COMMAND" | sed 's/\(token\|key\|password\|secret\|api_key\|auth\)=[^[:space:]]*/\1=***/gi')
    echo "[$(date '+%H:%M:%S')] ERR line $1: $_safe_cmd" >> "$ZMENU_ERROR_LOG"
}

# ── Cleanup on exit ────────────────────────────────────────
_zmenu_cleanup() {
    rm -f /tmp/zmenu-chat-*.json /tmp/zmenu-session-*.md /tmp/zmenu-ai-apply.txt /tmp/zmenu-bp.txt 2>/dev/null || true
}
trap _zmenu_cleanup EXIT

# Ensure error log has restrictive permissions
touch "$ZMENU_ERROR_LOG" 2>/dev/null && chmod 600 "$ZMENU_ERROR_LOG" 2>/dev/null || true

# ============================================================

# ═══════════════════════════════════════════════════════════
#  MODULE: 01-config.sh
# ═══════════════════════════════════════════════════════════

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
}

cfg_edit() {
    ${ZMENU_PREFERRED_EDITOR} "$ZMENU_CONFIG_FILE"
    cfg_load
}


# ═══════════════════════════════════════════════════════════
#  MODULE: 02-discovery.sh
# ═══════════════════════════════════════════════════════════

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

AI_BACKEND_ACTIVE=""        # resolved at runtime: opencode|ollama|none
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
D_MEM_AVAIL_MB=""
D_SWAP_TOTAL_MB=""
D_SWAP_USED_MB=""

D_SERVICES=()
D_OPEN_PORTS=()

# ── LLM-Gateway (Rust slot orchestrator) ─────────────────
D_GATEWAY_RUNNING=false
D_GATEWAY_URL=""
D_GATEWAY_VER=""
D_GATEWAY_SLOTS_VAR=()
D_GATEWAY_SLOTS_STATE=()
D_GATEWAY_SLOTS_MODEL=()
D_GATEWAY_SLOTS_RSS=()
D_GATEWAY_SLOTS_KV=()
D_GATEWAY_SLOTS_INFLIGHT=()

# ── Lemonade (AI lab orchestrator) ───────────────────────
D_LEMONADE_RUNNING=false
D_LEMONADE_PID=""
D_LEMONADE_PORT=""
D_LEMONADE_BACKENDS=()      # "name|type|port|pid|ram_mb"

# ── Hermes (desktop + CLI gateway) ───────────────────────
D_HERMES_RUNNING=false
D_HERMES_DESKTOP_PID=""
D_HERMES_CLI_PID=""
D_HERMES_GATEWAY_PID=""

# ── Port→Process collision registry ──────────────────────
# Built once at discovery start. Maps "port" → "process_name".
# Used by ALL port-based discovery to avoid false positives.
D_PORT_OWNER_MAP=()         # "port|process_name"

# ── Expanded AI infrastructure discovery ─────────────────
D_LITELLM_RUNNING=false
D_LITELLM_URL=""
D_VLLM_RUNNING=false
D_VLLM_URL=""
D_COMFYUI_RUNNING=false
D_COMFYUI_URL=""
D_TRITON_RUNNING=false
D_TRITON_URL=""
D_NGINX_RUNNING=false
D_CTOP_RUNNING=false
D_SGLANG_RUNNING=false
D_SGLANG_URL=""
D_TABBYAPI_RUNNING=false
D_TABBYAPI_URL=""
D_LOCALAI_RUNNING=false
D_LOCALAI_URL=""

# ── Systemd user services ────────────────────────────────
D_USER_SERVICES=()

# ── Process groups (aggregated summaries) ────────────────
D_PROCESS_GROUPS=()         # "GroupName|count|ram_mb|status"
# ── Diagnostics (kworker, external tools)
D_KWORKER_GROUPS=()
D_KWORKER_STORM=false
D_RADEONTOP_AVAILABLE=false
D_RADEONTOP_BIN=""
D_SENSORS_AVAILABLE=false
D_SENSORS_FULL=()

# ── Build port→process collision registry ─────────────────
# Call once before ANY port-based discovery. Prevents false positives
# when multiple services share the same port (e.g. Lemonade + LLM-Gateway on 8090).
_disc_build_port_map() {
    D_PORT_OWNER_MAP=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && D_PORT_OWNER_MAP+=("$line")
    done < <(ss -tlnp 2>/dev/null | awk 'NR>1 && /LISTEN/ {
        n=split($4,a,":"); port=a[n]
        for (i=1; i<=NF; i++) {
            if ($i ~ /users:/) {
                field=$i
                sub(/users:\(\("/, "", field)
                sub(/".*/, "", field)
                sub(/.*\//, "", field)
                if (field != "") print port "|" field
                break
            }
        }
    }' | sort -t'|' -k1 -n -u || true)
}

# Look up process name for a given port from the collision registry.
# Returns empty string if port not found or map not built.
_disc_port_owner() {
    local port="$1"
    local rec
    for rec in "${D_PORT_OWNER_MAP[@]}"; do
        [[ "${rec%%|*}" == "$port" ]] && { echo "${rec#*|}"; return; }
    done
}

# Generic process-first service discovery helper.
# Args: process_pattern port_default health_path [json_field_to_validate]
# Sets D_*_RUNNING and D_*_URL if successful.
_disc_probe_service() {
    local _proc_pat="$1" _port_default="$2" _health_path="$3" _validate_field="${4:-}"
    local _running_var="$5" _url_var="$6"

    # 1. Try process-first discovery
    local _pid
    _pid=$(pgrep -x "$_proc_pat" 2>/dev/null | head -1 || true)
    [[ -z "$_pid" ]] && _pid=$(pgrep -f "$_proc_pat" 2>/dev/null | head -1 || true)

    local _port="$_port_default" _url
    if [[ -n "$_pid" ]]; then
        # Process found — look up its actual port
        local _found_port
        _found_port=$(ss -tlnp 2>/dev/null | awk -v p="$_pid" '$0 ~ "pid="p"," {n=split($4,a,":"); print a[n]}' | head -1 || true)
        [[ -n "$_found_port" ]] && _port="$_found_port"
    fi

    _url="http://localhost:${_port}"

    # 2. Cross-check port ownership (collision registry)
    local _owner
    _owner=$(_disc_port_owner "$_port" 2>/dev/null || true)
    if [[ -n "$_owner" && -n "$_pid" ]]; then
        # If we have both process and port owner, they should roughly match
        # Allow some flexibility (e.g. python → uvicorn for FastAPI apps)
        case "$_proc_pat" in
            litellm) [[ "$_owner" != *"litellm"* && "$_owner" != *"python"* && "$_owner" != *"uvicorn"* ]] && return ;;
            vllm)    [[ "$_owner" != *"vllm"* && "$_owner" != *"python"* ]] && return ;;
            comfyui) [[ "$_owner" != *"comfy"* && "$_owner" != *"python"* ]] && return ;;
            tritonserver) [[ "$_owner" != *"triton"* ]] && return ;;
            sglang)  [[ "$_owner" != *"sglang"* && "$_owner" != *"python"* ]] && return ;;
            tabbyapi) [[ "$_owner" != *"tabby"* && "$_owner" != *"python"* && "$_owner" != *"uvicorn"* ]] && return ;;
            local-ai) [[ "$_owner" != *"local"* && "$_owner" != *"python"* ]] && return ;;
            llm-gateway) [[ "$_owner" == *"lemond"* || "$_owner" == *"lemonade"* ]] && return ;;
        esac
    fi

    # 3. Query health endpoint
    local _resp
    _resp=$(curl -sf --max-time 0.5 "${_url}${_health_path}" 2>/dev/null || echo "")
    [[ -z "$_resp" ]] && return

    # 4. Validate response structure if requested
    if [[ -n "$_validate_field" ]]; then
        local _has_field
        _has_field=$(echo "$_resp" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print('ok' if '${_validate_field}' in d else '')
except: print('')
" 2>/dev/null || echo "")
        [[ -z "$_has_field" ]] && return
    fi

    # 5. Success — set variables via eval
    eval "$_running_var=true"
    eval "$_url_var=\"$_url\""
}

discover() {
    # Discovery must never abort startup; keep failures isolated per probe.

    # Phase 1: Build port→process collision registry FIRST
    _disc_build_port_map || true

    # Phase 2: Process-first discovery for all services
    _disc_cpu || true
    _disc_memory || true
    _disc_ollama || true
    _disc_lms || true
    _disc_llm_gateway || true
    _disc_ai_tool || true
    _disc_claude || true
    _disc_docker || true
    _disc_gpu || true
    _disc_npu || true
    _disc_services || true
    _disc_lemonade || true
    _disc_hermes || true
    _disc_litellm || true
    _disc_vllm || true
    _disc_comfyui || true
    _disc_triton || true
    _disc_nginx || true
    _disc_ctop || true
    _disc_sglang || true
    _disc_tabbyapi || true
    _disc_localai || true
    _disc_systemd_user || true
    _disc_process_groups || true
    _disc_kworkers || true
    _disc_external_tools || true
    _disc_ports || true
    _sel_ai_backend || true
    ( _wiki_full_refresh ) 2>/dev/null || true
    _history_append || true
}

# ── History & Persistence ──────────────────────────────────
_history_append() {
    mkdir -p "$ZMENU_HISTORY_DIR"
    local hf="$ZMENU_HISTORY_DIR/metrics.$(date +%Y%m%d).jsonl"
    local load1; load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
    printf '%s\n' \
        "{\"t\":\"$(date -Iseconds)\",\"gpu_temp\":${D_GPU_TEMP:-0},\"gpu_use\":${D_GPU_USE:-0},\"ram_used_mb\":${D_MEM_USED_MB:-0},\"ram_total_mb\":${D_MEM_TOTAL_MB:-0},\"swap_used_mb\":${D_SWAP_USED_MB:-0},\"load1\":${load1},\"docker_containers\":${#D_CONTAINERS[@]}}" \
        >> "$hf"
    chmod 600 "$hf" 2>/dev/null || true
    _history_rotate
}

_history_rotate() {
    # Gzip files older than 7 days, remove gzipped files older than 90 days
    find "$ZMENU_HISTORY_DIR" -name 'metrics.*.jsonl' -mtime +7 -exec gzip -q {} \; 2>/dev/null || true
    find "$ZMENU_HISTORY_DIR" -name 'metrics.*.jsonl.gz' -mtime +90 -delete 2>/dev/null || true
}

# Load last N records for trend comparison. Returns deltas as shell variables.
# Usage: _history_load_trend [minutes_back]  (default: 5)
_history_load_trend() {
    local minutes="${1:-5}"
    local cutoff; cutoff=$(date -d "-${minutes} minutes" +%s 2>/dev/null || echo "0")
    [[ "$cutoff" == "0" ]] && return
    local latest_file
    latest_file=$(ls -1 "$ZMENU_HISTORY_DIR"/metrics.*.jsonl 2>/dev/null | tail -1)
    [[ -z "$latest_file" ]] && return
    # Pure Python: find first record with timestamp >= cutoff
    local _json_out
    _json_out=$(python3 -c '
import json,sys,datetime
cutoff=int(sys.argv[1]); hf=sys.argv[2]
try:
    with open(hf) as f:
        for line in f:
            d=json.loads(line)
            ts=datetime.datetime.fromisoformat(d["t"].replace("Z","+00:00")).timestamp()
            if ts>=cutoff:
                print(json.dumps(d))
                break
except Exception:
    pass
' "$cutoff" "$latest_file" 2>/dev/null)
    [[ -z "$_json_out" ]] && return
    D_HIST_GPU_TEMP=$(echo "$_json_out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('gpu_temp',0))" 2>/dev/null || echo "0")
    D_HIST_GPU_USE=$(echo "$_json_out"  | python3 -c "import sys,json; print(json.load(sys.stdin).get('gpu_use',0))" 2>/dev/null || echo "0")
    D_HIST_RAM_USED=$(echo "$_json_out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ram_used_mb',0))" 2>/dev/null || echo "0")
    D_HIST_LOAD1=$(echo "$_json_out" | python3 -c "import sys,json; print(json.load(sys.stdin).get('load1',0))" 2>/dev/null || echo "0")
}

_history_trend_str() {
    local current="$1" past="$2" label="${3:-}"
    local delta=0
    # Pure bash integer math — strip decimals, subtract, round
    if [[ "$current" =~ ^[0-9]+(\.[0-9]+)?$ && "$past" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        local c_int p_int
        c_int=${current%%.*}
        p_int=${past%%.*}
        delta=$((c_int - p_int))
    fi
    if [[ "$delta" -gt 0 ]]; then
        echo "${DIM}▲(+${delta}${label})${NC}"
    elif [[ "$delta" -lt 0 ]]; then
        echo "${DIM}▼(${delta}${label})${NC}"
    fi
}

# ── Sparklines ─────────────────────────────────────────────
# Read last N values of a given metric from today's JSONL history.
# Usage: _sparkline_read <metric_key> <count>
# Sets D_SPARKLINE_VALS as space-separated values, D_SPARKLINE_MAX.
_sparkline_read() {
    local metric="$1"
    local count="${2:-30}"
    D_SPARKLINE_VALS=""
    D_SPARKLINE_MAX=1
    local hf="$ZMENU_HISTORY_DIR/metrics.$(date +%Y%m%d).jsonl"
    [[ -f "$hf" ]] || return
    local _out
    _out=$(python3 -c '
import json,sys
metric=sys.argv[1]; count=int(sys.argv[2]); hf=sys.argv[3]
vals=[]
try:
    with open(hf) as f:
        for line in f:
            d=json.loads(line)
            v=d.get(metric,0)
            if isinstance(v,(int,float)):
                vals.append(float(v))
    vals=vals[-count:] if len(vals)>count else vals
    if vals:
        mx=max(vals)
        print(" ".join(str(int(v)) for v in vals))
        print(int(mx) if mx>=1 else 1)
except Exception:
    pass
' "$metric" "$count" "$hf" 2>/dev/null)
    [[ -z "$_out" ]] && return
    D_SPARKLINE_MAX=$(echo "$_out" | tail -1)
    D_SPARKLINE_VALS=$(echo "$_out" | head -1)
}

# Render space-separated values as ASCII sparkline.
# Usage: _sparkline_render "1 3 5 7 9" <max>
_sparkline_render() {
    local vals="$1"
    local max="${2:-1}"
    [[ -z "$vals" ]] && return
    [[ "$max" -lt 1 ]] && max=1
    local bars=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
    local v out=""
    for v in $vals; do
        local idx=$((v * 7 / max))
        [[ "$idx" -gt 7 ]] && idx=7
        out+="${bars[$idx]}"
    done
    echo "$out"
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
    local _mem_line _swap_line
    _mem_line=$(free -m | awk '/^Mem/{print $2,$3,$4,$7}' || echo "0 0 0 0")
    _swap_line=$(free -m | awk '/^Swap/{print $2,$3}' || echo "0 0")
    read -r D_MEM_TOTAL_MB D_MEM_USED_MB D_MEM_FREE_MB D_MEM_AVAIL_MB <<< "$_mem_line" || true
    read -r D_SWAP_TOTAL_MB D_SWAP_USED_MB <<< "$_swap_line" || true
    # Ensure defaults if empty
    : "${D_MEM_TOTAL_MB:=0}" "${D_MEM_USED_MB:=0}" "${D_MEM_FREE_MB:=0}" "${D_MEM_AVAIL_MB:=0}"
    : "${D_SWAP_TOTAL_MB:=0}" "${D_SWAP_USED_MB:=0}"
}

# ── Ollama ─────────────────────────────────────────────────
_disc_ollama() {
    local candidates=(11434 11435 11436)
    for port in "${candidates[@]}"; do
        local url="http://localhost:${port}"
        if curl -sf --max-time 0.2 "${url}/api/tags" >/dev/null 2>&1; then
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
    tags=$(curl -sf --max-time 1 "${D_OLLAMA_URL}/api/tags" 2>/dev/null || echo "")
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

# ── LM Studio ──────────────────────────────────────────────
_disc_lms() {
    local candidates=(1234 1235 8080)
    for port in "${candidates[@]}"; do
        local url="http://localhost:${port}"
        if curl -sf --max-time 0.2 "${url}/v1/models" >/dev/null 2>&1; then
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

# ── LLM-Gateway (Rust slot orchestrator) ─────────────────
_disc_llm_gateway() {
    D_GATEWAY_RUNNING=false
    D_GATEWAY_URL=""
    D_GATEWAY_VER=""
    D_GATEWAY_SLOTS_VAR=()
    D_GATEWAY_SLOTS_STATE=()
    D_GATEWAY_SLOTS_MODEL=()
    D_GATEWAY_SLOTS_RSS=()
    D_GATEWAY_SLOTS_KV=()
    D_GATEWAY_SLOTS_INFLIGHT=()

    # Use the generic process-first probe helper
    _disc_probe_service "llm-gateway" "${GATEWAY_PORT:-8090}" "/health" "version" \
        "D_GATEWAY_RUNNING" "D_GATEWAY_URL" || true

    [[ "$D_GATEWAY_RUNNING" != true ]] && return

    # Extract version from validated health response
    local health_resp
    health_resp=$(curl -sf --max-time 0.3 "${D_GATEWAY_URL}/health" 2>/dev/null || echo "")
    D_GATEWAY_VER=$(echo "$health_resp" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('version','?'))
except: print('?')
" 2>/dev/null || echo "?")

    # Fetch slot status
    local status_resp
    status_resp=$(curl -sf --max-time 0.5 "${D_GATEWAY_URL}/status" 2>/dev/null || echo "")
    [[ -z "$status_resp" ]] && return

    # Parse slots into parallel arrays
    while IFS='|' read -r var state model rss kv inflight; do
        D_GATEWAY_SLOTS_VAR+=("$var")
        D_GATEWAY_SLOTS_STATE+=("$state")
        D_GATEWAY_SLOTS_MODEL+=("$model")
        D_GATEWAY_SLOTS_RSS+=("$rss")
        D_GATEWAY_SLOTS_KV+=("$kv")
        D_GATEWAY_SLOTS_INFLIGHT+=("$inflight")
    done < <(echo "$status_resp" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for s in d.get('slots',[]):
        print('|'.join([
            s.get('variable',''),
            s.get('state',''),
            s.get('model',''),
            str(s.get('rss_mb',0)),
            str(s.get('kv_cache_mb',0)),
            str(s.get('inflight',0))
        ]))
except: pass
" 2>/dev/null || true)
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
    # Hard-disabled to avoid any startup risk from missing/removed claude tooling.
    D_CLAUDE_BIN=""
    D_CLAUDE_VER=""
    D_CLAUDE_SESSION=false
    return 0
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
            local tf; tf=$(ls "$d"/temp*_input 2>/dev/null | head -1) || true
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
    local keywords=("ollama" "docker" "n8n" "lmstudio" "rocm" "amd" "containerd" "open-webui" "lemonade" "hermes" "zed" "supavisor" "realtime" "postgrest" "nginx" "uvicorn" "redis" "bitwarden" "tailscale" "lemond" "litellm" "vllm" "comfyui" "triton" "sglang" "tabbyapi" "local-ai")
    for svc in $units; do
        for kw in "${keywords[@]}"; do
            if [[ "$svc" == *"$kw"* ]]; then
                D_SERVICES+=("$svc")
                break
            fi
        done
    done

    # Also scan user services
    local user_units
    user_units=$(systemctl --user list-units --type=service --state=active \
        --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' || true)
    for svc in $user_units; do
        for kw in "${keywords[@]}"; do
            if [[ "$svc" == *"$kw"* ]]; then
                D_SERVICES+=("$svc")
                break
            fi
        done
    done
}

# ── Lemonade (lemond + backends) ───────────────────────────
_disc_lemonade() {
    D_LEMONADE_RUNNING=false
    D_LEMONADE_PID=""
    D_LEMONADE_PORT=""
    D_LEMONADE_BACKENDS=()

    local pid
    pid=$(pgrep -x "lemond" 2>/dev/null | head -1) || true
    [[ -z "$pid" ]] && pid=$(pgrep -f "lemond" 2>/dev/null | head -1) || true
    [[ -z "$pid" ]] && return

    D_LEMONADE_RUNNING=true
    D_LEMONADE_PID="$pid"
    # Prefer port 8090 (Lemonade API) if found, otherwise first match
    local _ports
    _ports=$(ss -tlnp 2>/dev/null | awk -v p="$pid" '$0 ~ "pid="p"," {n=split($4,a,":"); print a[n]}' | sort -n || true)
    D_LEMONADE_PORT="8090"
    while IFS= read -r _p; do
        [[ -n "$_p" ]] && D_LEMONADE_PORT="$_p"
        [[ "$_p" == "8090" ]] && break
    done <<< "$_ports"

    local backend_procs=("llama-server" "sd-server" "whisper-server" "kokoro-server" "koko")
    local backend_names=("llama-server" "sd-server" "whisper-server" "kokoro" "koko")
    local i=0
    for proc in "${backend_procs[@]}"; do
        local bpid
        bpid=$(pgrep -x "$proc" 2>/dev/null | head -1) || true
        [[ -z "$bpid" ]] && bpid=$(pgrep -f "$proc" 2>/dev/null | head -1) || true
        if [[ -n "$bpid" ]]; then
            local ram_mb port
            ram_mb=$(awk '/VmRSS/{print int($2/1024)}' /proc/$bpid/status 2>/dev/null || echo "0")
            port=$(ss -tlnp 2>/dev/null | awk -v p="$bpid" '$0 ~ "pid="p"," {n=split($4,a,":"); print a[n]}' | head -1 || true)
            D_LEMONADE_BACKENDS+=("${backend_names[$i]}|backend|${port}|${bpid}|${ram_mb}")
        fi
        i=$((i + 1))
    done
}

# ── Hermes (desktop + CLI gateway) ─────────────────────────
_disc_hermes() {
    D_HERMES_RUNNING=false
    D_HERMES_DESKTOP_PID=""
    D_HERMES_CLI_PID=""
    D_HERMES_GATEWAY_PID=""

    D_HERMES_DESKTOP_PID=$(pgrep -f "Hermes" 2>/dev/null | head -1 || true)
    D_HERMES_CLI_PID=$(pgrep -x "hermes_cli" 2>/dev/null | head -1 || true)
    [[ -z "$D_HERMES_CLI_PID" ]] && D_HERMES_CLI_PID=$(pgrep -f "hermes_cli" 2>/dev/null | head -1 || true)
    D_HERMES_GATEWAY_PID=$(pgrep -f "python.*hermes.*gateway" 2>/dev/null | head -1 || true)
    [[ -z "$D_HERMES_GATEWAY_PID" ]] && D_HERMES_GATEWAY_PID=$(pgrep -f "python.*hermes" 2>/dev/null | head -1 || true)

    [[ -n "$D_HERMES_DESKTOP_PID" || -n "$D_HERMES_CLI_PID" || -n "$D_HERMES_GATEWAY_PID" ]] && D_HERMES_RUNNING=true
}

# ── LiteLLM (AI gateway / proxy) ─────────────────────────
_disc_litellm() {
    D_LITELLM_RUNNING=false
    D_LITELLM_URL=""
    _disc_probe_service "litellm" "4000" "/health" "status" \
        "D_LITELLM_RUNNING" "D_LITELLM_URL" || true
}

# ── vLLM (high-throughput inference) ─────────────────────
_disc_vllm() {
    D_VLLM_RUNNING=false
    D_VLLM_URL=""
    _disc_probe_service "vllm" "8000" "/health" "" \
        "D_VLLM_RUNNING" "D_VLLM_URL" || true
}

# ── ComfyUI (Stable Diffusion UI) ────────────────────────
_disc_comfyui() {
    D_COMFYUI_RUNNING=false
    D_COMFYUI_URL=""
    _disc_probe_service "comfyui" "8188" "/" "" \
        "D_COMFYUI_RUNNING" "D_COMFYUI_URL" || true
}

# ── NVIDIA Triton Inference Server ───────────────────────
_disc_triton() {
    D_TRITON_RUNNING=false
    D_TRITON_URL=""
    _disc_probe_service "tritonserver" "8000" "/v2/health/ready" "" \
        "D_TRITON_RUNNING" "D_TRITON_URL" || true
}

# ── nginx (reverse proxy, often fronts AI services) ──────
_disc_nginx() {
    D_NGINX_RUNNING=false
    if pgrep -x "nginx" >/dev/null 2>&1; then
        D_NGINX_RUNNING=true
    fi
}

# ── ctop (container top monitor) ─────────────────────────
_disc_ctop() {
    D_CTOP_RUNNING=false
    if pgrep -x "ctop" >/dev/null 2>&1; then
        D_CTOP_RUNNING=true
    fi
}

# ── SGLang (high-performance inference) ──────────────────
_disc_sglang() {
    D_SGLANG_RUNNING=false
    D_SGLANG_URL=""
    _disc_probe_service "sglang" "30000" "/health" "" \
        "D_SGLANG_RUNNING" "D_SGLANG_URL" || true
}

# ── TabbyAPI (ExLlamaV2/V3 server) ───────────────────────
_disc_tabbyapi() {
    D_TABBYAPI_RUNNING=false
    D_TABBYAPI_URL=""
    _disc_probe_service "tabbyapi" "5000" "/v1/models" "" \
        "D_TABBYAPI_RUNNING" "D_TABBYAPI_URL" || true
}

# ── LocalAI (OpenAI-compatible local server) ─────────────
_disc_localai() {
    D_LOCALAI_RUNNING=false
    D_LOCALAI_URL=""
    _disc_probe_service "local-ai" "8080" "/v1/models" "" \
        "D_LOCALAI_RUNNING" "D_LOCALAI_URL" || true
}

# ── Systemd user services ──────────────────────────────────
_disc_systemd_user() {
    D_USER_SERVICES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && D_USER_SERVICES+=("$line")
    done < <(systemctl --user list-units --type=service --state=active \
        --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' | sort || true)
}

# ── Process groups ─────────────────────────────────────────
_disc_process_groups() {
    D_PROCESS_GROUPS=()

    # Helper: sum RSS for a list of PIDs
    _sum_rss() {
        local pids="$1"
        local total=0
        for p in $pids; do
            local rss
            rss=$(ps -p "$p" -o rss= 2>/dev/null | awk '{print $1}' || echo "0")
            total=$((total + rss))
        done
        echo "$((total / 1024))"
    }

    # Lemonade group
    local lemonade_pids
    lemonade_pids=$(pgrep -d' ' -x "lemond" 2>/dev/null || true)
    for b in llama-server sd-server whisper-server kokoro-server koko; do
        local bp
        bp=$(pgrep -d' ' -x "$b" 2>/dev/null || true)
        [[ -n "$bp" ]] && lemonade_pids="${lemonade_pids:+$lemonade_pids }$bp"
    done
    if [[ -n "$lemonade_pids" ]]; then
        local count ram
        count=$(echo "$lemonade_pids" | wc -w)
        ram=$(_sum_rss "$lemonade_pids")
        D_PROCESS_GROUPS+=("Lemonade|${count}|${ram}|running")
    fi

    # Hermes group
    local hermes_pids
    hermes_pids="${D_HERMES_DESKTOP_PID:+$D_HERMES_DESKTOP_PID }${D_HERMES_CLI_PID:+$D_HERMES_CLI_PID }${D_HERMES_GATEWAY_PID:+$D_HERMES_GATEWAY_PID }"
    hermes_pids=$(echo "$hermes_pids" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [[ -n "$hermes_pids" ]]; then
        local count ram
        count=$(echo "$hermes_pids" | wc -w)
        ram=$(_sum_rss "$hermes_pids")
        D_PROCESS_GROUPS+=("Hermes|${count}|${ram}|running")
    fi

    # Docker group
    if [[ "$D_DOCKER_RUNNING" == true ]]; then
        local dcount
        dcount=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l || echo "0")
        [[ "$dcount" -gt 0 ]] && D_PROCESS_GROUPS+=("Docker|${dcount}|0|running")
    fi

    # Zed group
    local zed_pids
    zed_pids=$(pgrep -d' ' -x "zed-editor" 2>/dev/null || true)
    [[ -z "$zed_pids" ]] && zed_pids=$(pgrep -d' ' -x "zed" 2>/dev/null || true)
    if [[ -n "$zed_pids" ]]; then
        local count ram
        count=$(echo "$zed_pids" | wc -w)
        ram=$(_sum_rss "$zed_pids")
        D_PROCESS_GROUPS+=("Zed|${count}|${ram}|running")
    fi

    # vLLM group
    if [[ "$D_VLLM_RUNNING" == true ]]; then
        local vllm_pids
        vllm_pids=$(pgrep -d' ' -f "vllm" 2>/dev/null || true)
        if [[ -n "$vllm_pids" ]]; then
            local count ram
            count=$(echo "$vllm_pids" | wc -w)
            ram=$(_sum_rss "$vllm_pids")
            D_PROCESS_GROUPS+=("vLLM|${count}|${ram}|running")
        fi
    fi

    # ComfyUI group
    if [[ "$D_COMFYUI_RUNNING" == true ]]; then
        local comfy_pids
        comfy_pids=$(pgrep -d' ' -f "comfy" 2>/dev/null || true)
        if [[ -n "$comfy_pids" ]]; then
            local count ram
            count=$(echo "$comfy_pids" | wc -w)
            ram=$(_sum_rss "$comfy_pids")
            D_PROCESS_GROUPS+=("ComfyUI|${count}|${ram}|running")
        fi
    fi

    # Triton group
    if [[ "$D_TRITON_RUNNING" == true ]]; then
        local triton_pids
        triton_pids=$(pgrep -d' ' -x "tritonserver" 2>/dev/null || true)
        if [[ -n "$triton_pids" ]]; then
            local count ram
            count=$(echo "$triton_pids" | wc -w)
            ram=$(_sum_rss "$triton_pids")
            D_PROCESS_GROUPS+=("Triton|${count}|${ram}|running")
        fi
    fi

    # SGLang group
    if [[ "$D_SGLANG_RUNNING" == true ]]; then
        local sglang_pids
        sglang_pids=$(pgrep -d' ' -f "sglang" 2>/dev/null || true)
        if [[ -n "$sglang_pids" ]]; then
            local count ram
            count=$(echo "$sglang_pids" | wc -w)
            ram=$(_sum_rss "$sglang_pids")
            D_PROCESS_GROUPS+=("SGLang|${count}|${ram}|running")
        fi
    fi

    # System services group (just count, no RAM aggregation)
    local svc_count
    svc_count=${#D_SERVICES[@]}
    [[ "$svc_count" -gt 0 ]] && D_PROCESS_GROUPS+=("System services|${svc_count}|0|active")
}

# ── Listening ports ────────────────────────────────────────
_disc_ports() {
    while IFS= read -r line; do
        [[ -n "$line" ]] && D_OPEN_PORTS+=("$line")
    done < <(ss -tlnp 2>/dev/null \
        | awk 'NR>1 {n=split($4,a,":"); p=a[n]; if(p~/^[0-9]+$/) print p":"$6}' \
        | sort -t: -k1 -n || true)
}

# Sets AI_BACKEND_ACTIVE, AI_BACKEND_LABEL, ZMENU_AI_MODEL
_sel_ai_backend() {
    local want="${ZMENU_AI_BACKEND:-auto}"
    AI_BACKEND_ACTIVE="none"
    AI_BACKEND_LABEL="none"

    case "$want" in
        opencode)
            if _opencode_available; then
                AI_BACKEND_ACTIVE="opencode"
                AI_BACKEND_LABEL="OpenCode (TUI)"
                ZMENU_AI_MODEL="opencode"
            fi ;;
        ollama)
            if [[ "$D_OLLAMA_RUNNING" == true ]]; then
                AI_BACKEND_ACTIVE="ollama"
                AI_BACKEND_LABEL="Ollama"
                ZMENU_AI_MODEL="${D_OLLAMA_MODELS[0]:-none}"
            fi ;;
        auto|*)
            # Priority: auto-select best available
            if [[ "$D_OLLAMA_RUNNING" == true && ${#D_OLLAMA_MODELS[@]} -gt 0 ]]; then
                AI_BACKEND_ACTIVE="ollama"
                AI_BACKEND_LABEL="Ollama (auto)"
                ZMENU_AI_MODEL="${D_OLLAMA_MODELS[0]}"
            elif _opencode_available; then
                AI_BACKEND_ACTIVE="opencode"
                AI_BACKEND_LABEL="OpenCode (auto)"
                ZMENU_AI_MODEL="opencode"
            fi ;;
    esac
}

# Keep old name as alias for any external calls
_sel_ai_model() { _sel_ai_backend; }


# ═══════════════════════════════════════════════════════════
#  MODULE: 03-context.sh
# ═══════════════════════════════════════════════════════════

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
        if [[ "$D_OLLAMA_RUNNING" == true ]]; then
            echo "Ollama: RUNNING at ${D_OLLAMA_URL}"
        else
            echo "Ollama: STOPPED"
        fi
        echo ""
        if [[ "$D_LMS_RUNNING" == true ]]; then
            echo "LM Studio: RUNNING at ${D_LMS_URL}"
            for m in "${D_LMS_MODELS[@]}"; do echo "  - $m"; done
        else
            echo "LM Studio: not running"
        fi
        echo ""
        if [[ "$D_GATEWAY_RUNNING" == true ]]; then
            echo "LLM-Gateway: RUNNING at ${D_GATEWAY_URL} (v${D_GATEWAY_VER})"
            echo "Slots:"
            local _gi
            for _gi in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
                printf "  %-22s  %-8s  %s  %s MB  inflight:%s\n" \
                    "${D_GATEWAY_SLOTS_VAR[$_gi]}" \
                    "${D_GATEWAY_SLOTS_STATE[$_gi]}" \
                    "${D_GATEWAY_SLOTS_MODEL[$_gi]}" \
                    "${D_GATEWAY_SLOTS_RSS[$_gi]}" \
                    "${D_GATEWAY_SLOTS_INFLIGHT[$_gi]}"
            done
        else
            echo "LLM-Gateway: not running"
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


# ═══════════════════════════════════════════════════════════
#  MODULE: 04-ai.sh
# ═══════════════════════════════════════════════════════════

# ============================================================
#  SECTION 4 — LOCAL AI LAUNCHER
# ============================================================

OWUI_PORT="${OWUI_PORT:-3000}"
OWUI_URL="http://localhost:${OWUI_PORT}"

OPENCODE_BIN="${HOME}/.opencode/bin/opencode"
OPENCODE_PROCESS="opencode"
OPENCODE_CFG="${HOME}/.config/opencode"

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

# Generate structured JSON context for deterministic AI parsing.
# Included in the system prompt as a fenced JSON block.
# All dynamic data passed via env vars to avoid shell escaping issues.
_build_context_json() {
    local _containers="[]"
    if [[ ${#D_CONTAINERS[@]} -gt 0 ]]; then
        _containers=$(printf '%s\n' "${D_CONTAINERS[@]}" | python3 -c '
import json,sys
arr=[]
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    parts=l.split(":",1)
    arr.append({"name":parts[0],"status":parts[1] if len(parts)>1 else "unknown"})
print(json.dumps(arr))
' 2>/dev/null || echo "[]")
    fi
    local _services="[]"
    if [[ ${#D_SERVICES[@]} -gt 0 ]]; then
        _services=$(printf '%s\n' "${D_SERVICES[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))' 2>/dev/null || echo "[]")
    fi
    local _load1; _load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
    CTX_CPU_MODEL="${D_CPU_MODEL:-unknown}" \
    CTX_CPU_CORES="${D_CPU_CORES:-0}" \
    CTX_CPU_GOV="${D_CPU_GOVERNOR:-unknown}" \
    CTX_MEM_TOTAL="${D_MEM_TOTAL_MB:-0}" \
    CTX_MEM_USED="${D_MEM_USED_MB:-0}" \
    CTX_SWAP_USED="${D_SWAP_USED_MB:-0}" \
    CTX_GPU_DRIVER="${D_GPU_DRIVER:-none}" \
    CTX_GPU_GFX="${D_GPU_GFX:-unknown}" \
    CTX_GPU_TEMP="${D_GPU_TEMP:-0}" \
    CTX_GPU_USE="${D_GPU_USE:-0}" \
    CTX_NPU_DRIVER="${D_NPU_DRIVER:-none}" \
    CTX_NPU_DEVICE="${D_NPU_DEVICE:-none}" \
    CTX_LOAD1="$_load1" \
    CTX_CONTAINERS="$_containers" \
    CTX_SERVICES="$_services" \
    CTX_OLLAMA_RUNNING="${D_OLLAMA_RUNNING:-false}" \
    CTX_BACKEND="${AI_BACKEND_LABEL:-none}" \
    CTX_AI_MODEL="${ZMENU_AI_MODEL:-auto}" \
    python3 -c '
import json,sys,os
d={
    "cpu":{"model":os.environ.get("CTX_CPU_MODEL",""),"cores":int(os.environ.get("CTX_CPU_CORES","0") or 0),"governor":os.environ.get("CTX_CPU_GOV","")},
    "ram":{"total_mb":int(os.environ.get("CTX_MEM_TOTAL","0") or 0),"used_mb":int(os.environ.get("CTX_MEM_USED","0") or 0),"swap_used_mb":int(os.environ.get("CTX_SWAP_USED","0") or 0)},
    "gpu":{"driver":os.environ.get("CTX_GPU_DRIVER",""),"gfx":os.environ.get("CTX_GPU_GFX",""),"temp_c":int(os.environ.get("CTX_GPU_TEMP","0") or 0),"util_pct":int(os.environ.get("CTX_GPU_USE","0") or 0)},
    "npu":{"driver":os.environ.get("CTX_NPU_DRIVER",""),"device":os.environ.get("CTX_NPU_DEVICE","")},
    "load":{"1min":float(os.environ.get("CTX_LOAD1","0") or 0)},
    "docker":{"containers":json.loads(os.environ.get("CTX_CONTAINERS","[]"))},
    "services":json.loads(os.environ.get("CTX_SERVICES","[]")),
    "ollama":{"running":os.environ.get("CTX_OLLAMA_RUNNING","")=="true"},
    "ai_backend":{"label":os.environ.get("CTX_BACKEND",""),"model":os.environ.get("CTX_AI_MODEL","")}
}
print(json.dumps(d,indent=2))
' 2>/dev/null || echo '{}'
}

# _cc_write_rules — writes context into opencode's rules file for the session
# OpenCode auto-loads ~/.config/opencode/rules.md as persistent instructions
_cc_write_rules() {
    local context="$1"
    local rules_dir="${OPENCODE_CFG}"
    mkdir -p "$rules_dir"
    chmod 700 "$rules_dir" 2>/dev/null || true
    printf '%s' "$context" > "${rules_dir}/rules.md"
    chmod 600 "${rules_dir}/rules.md" 2>/dev/null || true
}

# ============================================================
#  AI BACKEND ADAPTERS
#  Each adapter takes (sys_prompt, hist_file) and prints response.
#  hist_file is a JSON array: [{"role":"user","content":"..."},...]
# ============================================================

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
        echo -e "  ${DIM}  Install: curl -fsSL https://opencode.ai/install -o /tmp/opencode-install.sh${NC}"
        echo -e "  ${DIM}  Review:  less /tmp/opencode-install.sh && bash /tmp/opencode-install.sh${NC}"
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
        echo -e "  ${WARN}  AI backend is set to OpenCode, but Ask AI requires Ollama."
        echo -e "  ${DIM}  Go to Settings → l) AI Backend and switch to 'ollama'.${NC}"
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

    # Action history — last 10 applied commands for AI context
    local _action_history=""
    if [[ -f "$ZMENU_SESSION_LOG" ]]; then
        _action_history=$(tail -50 "$ZMENU_SESSION_LOG" 2>/dev/null | grep '"action":"apply"' | tail -10 | \
            python3 -c "import sys,json; [print(f\"- {json.loads(l).get('t','')}  {json.loads(l).get('detail','')}\") for l in sys.stdin]" 2>/dev/null || true)
    fi

    local _ctx_json
    _ctx_json=$(_build_context_json 2>/dev/null || echo '{}')

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

## Structured Data (DO NOT MODIFY THIS JSON BLOCK)
\`\`\`json
${_ctx_json}
\`\`\`

## Section: ${section_title}

${scoped_context}

---
## Recent Actions (what the user already did)
${_action_history:-(no recent actions)}

---
## Your role
You are an expert assistant embedded in the zmenu sovereign dashboard
on this specific machine. The facts above are ground truth — never
contradict them or suggest alternatives already present.
Be concise and direct. Give exact copy-paste commands.
When the user types 'apply', the last suggestion has been run —
acknowledge it and advise what to check next.
If the user already performed an action recently, do not suggest it again —
instead suggest the NEXT logical step.

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

        # Apply last suggestion — preview first, then confirm
        if [[ "$user_input" == "apply" || "$user_input" == "apply that" ]]; then
            echo ""
            if [[ -n "$apply_fn" ]] && declare -f "$apply_fn" >/dev/null 2>&1; then
                # Extract proposed commands for preview
                local proposed_cmds
                proposed_cmds=$(echo "$last_ai_response" | awk '/^```/{p=!p; next} p && /[^[:space:]]/{print}')
                if [[ -z "$proposed_cmds" ]]; then
                    proposed_cmds=$(echo "$last_ai_response" | grep -E '^[[:space:]]*(sudo |systemctl |sysctl |docker |pkill |kill |apt |mkdir |rm |cp |mv |chmod |chown |python3 |pip |curl |powerprofilesctl |journalctl |sed |awk |tee |cat |echo |printf |export |unset |git |wget |dmesg |cpupower )')
                fi
                if [[ -n "$proposed_cmds" ]]; then
                    echo -e "  ${BCYN}Commands to execute:${NC}"
                    echo "$proposed_cmds" | sed 's/^/    /'
                    echo ""
                    printf '  Execute these commands? (y/N): '
                    IFS= read -r _confirm
                    if [[ ! "$_confirm" =~ ^[Yy]$ ]]; then
                        echo -e "  ${DIM}Cancelled.${NC}"
                        echo ""
                        continue
                    fi
                fi
                echo -e "  ${BCYN}✦ Applying...${NC}"
                if "$apply_fn" "$last_ai_response"; then
                    echo -e "  ${OK}  Applied."
                else
                    echo -e "  ${WARN}  Apply returned with issues — check output above."
                fi
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



# ═══════════════════════════════════════════════════════════
#  MODULE: 05-apply.sh
# ═══════════════════════════════════════════════════════════

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

# ── Safe command execution — replaces eval with direct array expansion ──
# Parses a command string into an array respecting single/double quotes,
# then validates no dangerous metacharacters exist before executing.
_apply_safe_exec() {
    local cmd="$1"
    local -a args=() arg="" in_quote="" ch escaped=false

    # Parse command string into array, respecting quotes
    for ((i=0; i<${#cmd}; i++)); do
        ch="${cmd:$i:1}"
        if $escaped; then
            arg+="$ch"
            escaped=false
            continue
        fi
        if [[ "$ch" == "\\" ]]; then
            escaped=true
            continue
        fi
        if [[ -n "$in_quote" ]]; then
            if [[ "$ch" == "$in_quote" ]]; then
                in_quote=""
            else
                arg+="$ch"
            fi
            continue
        fi
        if [[ "$ch" == "'" || "$ch" == '"' ]]; then
            in_quote="$ch"
            continue
        fi
        if [[ "$ch" == " " || "$ch" == $'\t' ]]; then
            if [[ -n "$arg" ]]; then
                args+=("$arg")
                arg=""
            fi
            continue
        fi
        arg+="$ch"
    done
    [[ -n "$arg" ]] && args+=("$arg")

    # Must have at least one argument
    if [[ ${#args[@]} -eq 0 ]]; then
        echo -e "  ${FAIL}  No command to execute"
        return 1
    fi

    # Block dangerous metacharacters in any argument
    local _arg
    for _arg in "${args[@]}"; do
        if printf '%s' "$_arg" | grep -qE '[;|&<>$`{}()]'; then
            echo -e "  ${FAIL}  BLOCKED: argument contains shell metacharacter"
            return 1
        fi
    done

    # Execute safely — no re-parsing, no eval.
    # Redirect stderr to error log so users see failures (e.g. sudo password prompt)
    "${args[@]}" 2>>"$ZMENU_ERROR_LOG"
}

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

    local _ran_ok=false
    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue

        # ── Safety checks — block commands that would kill zmenu,
        #    the shell, or cause duplicate daemon instances.
        local _blocked=false
        local _block_reason=""

        # 1) Determine the actual command (strip sudo)
        local _check_cmd="$cmd"
        [[ "$cmd" == sudo* ]] && _check_cmd="${cmd#sudo }"
        local _first_word="${_check_cmd%% *}"

        # 2) Allowlist check — first word must be in _APPLY_ALLOWED_PREFIXES
        local _allowed=false
        local _prefix
        for _prefix in "${_APPLY_ALLOWED_PREFIXES[@]}"; do
            [[ "$_first_word" == "$_prefix" ]] && { _allowed=true; break; }
        done
        if ! $_allowed; then
            _blocked=true; _block_reason="command '$_first_word' is not in the allowlist"
        fi

        # 3) Block subshell wrappers (bash/sh/python3 with -c)
        if [[ "$_first_word" == "bash" || "$_first_word" == "sh" || "$_first_word" == "python3" ]] && \
           [[ "$cmd" == *" -c "* || "$cmd" == *" -c"* ]]; then
            _blocked=true; _block_reason="subshell with -c not allowed (injection risk)"
        fi

        # 4) Kill zmenu or the current shell
        if printf '%s' "$cmd" | grep -qE "(pkill|killall|kill)[[:space:]].*zmenu"; then
            _blocked=true; _block_reason="would kill zmenu itself"
        fi
        if printf '%s' "$cmd" | grep -qE "(pkill|killall)[[:space:]].*bash"; then
            _blocked=true; _block_reason="would kill the shell"
        fi
        # Re-launching zmenu inside apply (infinite nesting)
        if printf '%s' "$cmd" | grep -qE "^[[:space:]]*(zmenu|${ZMENU_INSTALL_PATH})[[:space:]]*\$"; then
            _blocked=true; _block_reason="cannot re-launch zmenu from inside zmenu"
        fi

        # 5) Destructive rm — check parsed args, not raw string
        if [[ "$_first_word" == "rm" ]]; then
            local _has_r=false _has_f=false _has_root=false
            local _a
            for _a in $cmd; do
                [[ "$_a" == "rm" ]] && continue
                [[ "$_a" == sudo ]] && continue
                # Strip quotes for flag detection
                local _b="${_a//\"/}"
                _b="${_b//\'/}"
                [[ "${_b#-}" == *"r"* || "${_b#-}" == *"R"* ]] && _has_r=true
                [[ "${_b#-}" == *"f"* || "${_b#-}" == *"F"* ]] && _has_f=true
                [[ "$_b" == "/" || "$_b" == "/"* ]] && _has_root=true
            done
            if $_has_r && $_has_f && $_has_root; then
                _blocked=true; _block_reason="destructive recursive rm on root path"
            fi
        fi

        # 6) Command substitution — injection risk
        if printf '%s' "$cmd" | grep -qE '\$\(.*\)|`.*`'; then
            _blocked=true; _block_reason="command substitution not allowed (injection risk)"
        fi
        # Command chaining / piping / redirection
        if printf '%s' "$cmd" | grep -qE '[;|&>]'; then
            _blocked=true; _block_reason="command chaining / piping / redirection not allowed"
        fi

        if $_blocked; then
            echo -e "  ${FAIL}  BLOCKED: ${cmd}"
            echo -e "  ${DIM}  Reason: ${_block_reason}${NC}"
            _wiki_log_change "$section" "$cmd" "BLOCKED — ${_block_reason}"
            _session_log "apply" "$cmd" "BLOCKED — ${_block_reason}" || true
            continue
        fi

        echo -e "  ${DIM}Running: ${cmd}${NC}"
        if _apply_safe_exec "$cmd"; then
            _ran_ok=true
            echo -e "  ${OK}  OK"
            _wiki_log_change "$section" "$cmd" "OK"
            _session_log "apply" "$cmd" "OK" || true
        else
            echo -e "  ${WARN}  Non-zero: ${cmd}"
            _wiki_log_change "$section" "$cmd" "FAIL"
            _session_log "apply" "$cmd" "FAIL" || true
        fi
    done <<< "$cmds"

    $_ran_ok
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
    local pid; pid=$(pgrep -x "$OPENCODE_PROCESS" | head -1) || true
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
# ── AI Engine context ─────────────────────────────────────
_ctx_ai_engine() {
    printf "Section focus: AI stack health and configuration\n\n"
    printf "GPU driver:      %s  (Vulkan backend)\n" "$D_GPU_DRIVER"
    printf "GPU:             %s\n" "${D_GPU_GFX:-?}"
    printf "Memory pool:     %s MB total (unified — GPU shares with RAM)\n" "$D_MEM_TOTAL_MB"
    printf "\nOllama:          %s\n" "$(${D_OLLAMA_RUNNING} && echo 'RUNNING' || echo 'stopped')"
    printf "\nOpenCode:        %s\n" "$(pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1 && echo "RUNNING (pid: $(pgrep -x "$OPENCODE_PROCESS" | head -1))" || (_opencode_available && echo "installed (not running)" || echo 'not installed'))"
    printf "Open WebUI:      %s\n" "$(curl -sf "${OWUI_URL}" >/dev/null 2>&1 && echo "running at ${OWUI_URL}" || echo 'not running')"
    printf "LM Studio:       %s\n" "$(${D_LMS_RUNNING} && echo "running at ${D_LMS_URL} (download only)" || echo 'off')"
    printf "\nLLM-Gateway:     %s\n" "$(${D_GATEWAY_RUNNING} && echo "running at ${D_GATEWAY_URL} (v${D_GATEWAY_VER})" || echo 'stopped')"
    if [[ "$D_GATEWAY_RUNNING" == true ]]; then
        printf "Slots:\n"
        local i
        for i in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
            printf "  %-20s  %-8s  %s  %s MB  inflight:%s\n" \
                "${D_GATEWAY_SLOTS_VAR[$i]}" \
                "${D_GATEWAY_SLOTS_STATE[$i]}" \
                "${D_GATEWAY_SLOTS_MODEL[$i]}" \
                "${D_GATEWAY_SLOTS_RSS[$i]}" \
                "${D_GATEWAY_SLOTS_INFLIGHT[$i]}"
        done
    fi
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
    # OpenVPN config directory — show actual file counts, not raw ls output
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


# ═══════════════════════════════════════════════════════════
#  MODULE: 06-wiki.sh
# ═══════════════════════════════════════════════════════════

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
        printf "## GPU for Inference\n"
        printf "Device:  %s  driver: %s\n" "${D_GPU_GFX:-unknown}" "${D_GPU_DRIVER:-none}"
        printf "Backend: Vulkan  HSA_OVERRIDE_GFX_VERSION=%s\n" "${HSA_OVERRIDE_GFX_VERSION:-NOT SET — required!}"
        printf "\n## Other Tools\n"
        printf "OpenCode:    %s\n" "$(pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1 && echo "RUNNING (pid: $(pgrep -x "$OPENCODE_PROCESS" | head -1))" || (_opencode_available 2>/dev/null && echo 'installed (not running)' || echo 'not installed'))"
        printf "             Process name: opencode   Stop it with: pkill opencode\n"
        printf "LM Studio:   %s\n" "$($D_LMS_RUNNING && echo 'running' || echo 'off')"
        printf "Ollama:      %s\n" "$($D_OLLAMA_RUNNING && echo 'RUNNING' || echo 'stopped')"
        printf "Open WebUI:  %s\n" "$(curl -sf "${OWUI_URL:-http://localhost:3000}" >/dev/null 2>&1 && echo "running at ${OWUI_URL:-http://localhost:3000}" || echo 'not running')"
    } > "${ZMENU_WIKI_DIR}/ai-stack.md"

    # ── opencode.md ─────────────────────────────────────────
    {
        printf "# OpenCode — %s\n\n" "$ts"
        printf "## What OpenCode Is\n"
        printf "OpenCode is a standalone coding agent CLI built on the OpenCode protocol.\n"
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
        printf "Install:    curl -fsSL https://opencode.ai/install -o /tmp/opencode-install.sh\n"
        printf "Review:     less /tmp/opencode-install.sh && bash /tmp/opencode-install.sh\n\n"
        printf "## Configuration\n"
        printf "Config dir:  ~/.config/opencode/\n"
        printf "Config file: ~/.config/opencode/opencode.json\n"
        printf "Rules file:  ~/.config/opencode/rules.md  (zmenu injects context here)\n\n"
        printf "## zmenu Integration\n"
        printf "zmenu 'AI Engine → 3) OpenCode' manages OpenCode configuration.\n"
        printf "zmenu 'AI Engine → 6) AI session' launches the OpenCode TUI.\n"
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

# ═══════════════════════════════════════════════════════════
#  MODULE: 07b-killmode.sh
# ═══════════════════════════════════════════════════════════

# ============================================================
#  SECTION 11 — KILL MODE: STOP THE BULLSHIT
#  Task manager for killing runaway processes fast.
#  No dead ends. Every screen lets you act.
# ============================================================

_kill_process_menu() {
    local pid="$1" pname="$2" pcpu="${3:-}" pmem="${4:-}"
    echo ""
    echo "  Selected: ${BOLD}${pname}${NC} (pid ${pid})"
    [[ -n "$pcpu" && "$pcpu" != "?" ]] && echo "  CPU: ${pcpu}%"
    [[ -n "$pmem" && "$pmem" != "?" ]] && echo "  RAM: ${pmem}%"
    echo ""
    echo "   k)  SIGTERM  — graceful kill (let it clean up)"
    echo "   K)  SIGKILL  — force kill   (cannot be blocked)"
    echo "   i)  Info     — files, cwd, command line"
    echo "   c)  Cancel"
    echo ""
    read -rp "  Action: " act
    case "$act" in
        k)
            if kill -TERM "$pid" 2>/dev/null; then
                echo -e "  ${OK}  Sent SIGTERM to ${pname} (pid ${pid})"
                _session_log "kill" "SIGTERM ${pname} (pid ${pid})" "OK"
            else
                echo -e "  ${FAIL}  Failed — try SIGKILL or run with sudo"
                _session_log "kill" "SIGTERM ${pname} (pid ${pid})" "FAIL"
            fi
            ;;
        K)
            if kill -KILL "$pid" 2>/dev/null; then
                echo -e "  ${OK}  Sent SIGKILL to ${pname} (pid ${pid})"
                _session_log "kill" "SIGKILL ${pname} (pid ${pid})" "OK"
            else
                echo -e "  ${FAIL}  Failed — check permissions (maybe root-owned?)"
                _session_log "kill" "SIGKILL ${pname} (pid ${pid})" "FAIL"
            fi
            ;;
        i|I)
            echo ""
            ps -p "$pid" -o pid,ppid,user,%cpu,%mem,rss,comm,args 2>/dev/null | sed 's/^/  /'
            echo ""
            local cwd; cwd=$(readlink /proc/$pid/cwd 2>/dev/null || echo "?")
            echo "  CWD: ${cwd}"
            local nfiles; nfiles=$(lsof -p "$pid" 2>/dev/null | awk 'NR>1 && $5=="REG"' | wc -l)
            echo "  Open files: ${nfiles}"
            echo ""
            read -rp "  $(printf '%b' "${DIM}[Enter] back${NC}") " _
            ;;
    esac
}

_kill_top_cpu() {
    while true; do
        header
        echo -e "${BRED}┄ TOP CPU CONSUMERS ────────────────────────────────────${NC}"
        echo ""
        local lines=()
        local i=1
        while IFS='|' read -r pid pcpu comm user; do
            [[ -z "$pid" ]] && continue
            lines+=("${pid}|${pcpu}|${comm}|${user}")
            local base; base=$(basename "$comm")
            printf "   %2d)  %-8s %6s%%  %-22s  %s\n" "$i" "$pid" "$pcpu" "$base" "$user"
            i=$((i + 1))
        done < <(ps aux --sort=-%cpu 2>/dev/null | awk 'NR>1 {printf "%s|%s|%s|%s\n", $2, $3, $11, $1}' | head -15)

        if [[ ${#lines[@]} -eq 0 ]]; then
            echo "  No processes found"
            pause
            return
        fi

        echo ""
        echo "  Enter number + action (e.g. 1k, 3K, 2i) or:"
        echo "   r) refresh    b) back    q) quit zmenu"
        echo ""
        read -rp "  Selection: " sel

        [[ "$sel" == "b" || -z "$sel" ]] && break
        [[ "$sel" == "r" || "$sel" == "R" ]] && continue
        [[ "$sel" == "q" || "$sel" == "Q" ]] && { printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0; }

        local n act
        if [[ "$sel" =~ ^([0-9]+)([kKiI])$ ]]; then
            n="${BASH_REMATCH[1]}"
            act="${BASH_REMATCH[2]}"
        elif [[ "$sel" =~ ^[0-9]+$ ]]; then
            n="$sel"
            act=""
        else
            echo -e "  ${RED}Invalid format. Use: 3k, 5K, 2i, or just 3${NC}"
            sleep 0.5
            continue
        fi

        if [[ "$n" -ge 1 && "$n" -le ${#lines[@]} ]]; then
            local pid pcpu comm user
            IFS='|' read -r pid pcpu comm user <<< "${lines[$((n-1))]}"
            local pname; pname=$(basename "$comm")
            _kill_process_menu "$pid" "$pname" "$pcpu"
        fi
    done
}

_kill_top_mem() {
    while true; do
        header
        echo -e "${BRED}┄ TOP RAM CONSUMERS ────────────────────────────────────${NC}"
        echo ""
        local lines=()
        local i=1
        while IFS='|' read -r pid pmem rss comm user; do
            [[ -z "$pid" ]] && continue
            lines+=("${pid}|${pmem}|${rss}|${comm}|${user}")
            local base; base=$(basename "$comm")
            local rss_mb=$((rss / 1024))
            printf "   %2d)  %-8s %6s%%  %5dMB  %-22s  %s\n" "$i" "$pid" "$pmem" "$rss_mb" "$base" "$user"
            i=$((i + 1))
        done < <(ps aux --sort=-rss 2>/dev/null | awk 'NR>1 {printf "%s|%s|%s|%s|%s\n", $2, $4, $6, $11, $1}' | head -15)

        if [[ ${#lines[@]} -eq 0 ]]; then
            echo "  No processes found"
            pause
            return
        fi

        echo ""
        echo "  Enter number + action (e.g. 1k, 3K, 2i) or:"
        echo "   r) refresh    b) back    q) quit zmenu"
        echo ""
        read -rp "  Selection: " sel

        [[ "$sel" == "b" || -z "$sel" ]] && break
        [[ "$sel" == "r" || "$sel" == "R" ]] && continue
        [[ "$sel" == "q" || "$sel" == "Q" ]] && { printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0; }

        local n act
        if [[ "$sel" =~ ^([0-9]+)([kKiI])$ ]]; then
            n="${BASH_REMATCH[1]}"
            act="${BASH_REMATCH[2]}"
        elif [[ "$sel" =~ ^[0-9]+$ ]]; then
            n="$sel"
            act=""
        else
            echo -e "  ${RED}Invalid format. Use: 3k, 5K, 2i, or just 3${NC}"
            sleep 0.5
            continue
        fi

        if [[ "$n" -ge 1 && "$n" -le ${#lines[@]} ]]; then
            local pid pmem rss comm user
            IFS='|' read -r pid pmem rss comm user <<< "${lines[$((n-1))]}"
            local pname; pname=$(basename "$comm")
            _kill_process_menu "$pid" "$pname" "" "$pmem"
        fi
    done
}

_kill_groups() {
    while true; do
        header
        echo -e "${BRED}┄ PROCESS GROUPS ───────────────────────────────────────${NC}"
        echo ""
        _disc_process_groups >/dev/null 2>&1 || true

        if [[ ${#D_PROCESS_GROUPS[@]} -eq 0 ]]; then
            echo -e "  ${IDLE}  No process groups running${NC}"
            pause
            return
        fi

        local i=1
        for grp in "${D_PROCESS_GROUPS[@]}"; do
            local gname gcount gram gstatus
            IFS='|' read -r gname gcount gram gstatus <<< "$grp"
            if [[ "$gname" == "Docker" ]]; then
                printf "   %2d)  %-18s %d containers\n" "$i" "$gname" "$gcount"
            elif [[ "$gram" -gt 0 ]]; then
                printf "   %2d)  %-18s %d procs  %dMB\n" "$i" "$gname" "$gcount" "$gram"
            else
                printf "   %2d)  %-18s %d procs\n" "$i" "$gname" "$gcount"
            fi
            i=$((i + 1))
        done

        echo ""
        echo "  Select group to kill, or:  r) refresh  b) back  q) quit"
        echo ""
        read -rp "  Selection: " n

        [[ "$n" == "b" || -z "$n" ]] && break
        [[ "$n" == "r" || "$n" == "R" ]] && continue
        [[ "$n" == "q" || "$n" == "Q" ]] && { printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0; }

        if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#D_PROCESS_GROUPS[@]} ]]; then
            local grp="${D_PROCESS_GROUPS[$((n-1))]}"
            local gname gcount gram gstatus
            IFS='|' read -r gname gcount gram gstatus <<< "$grp"

            echo ""
            if confirm "Kill entire ${gname} group? (${gcount} procs, ${gram}MB)"; then
                case "$gname" in
                    Lemonade)
                        pkill -x "lemond" 2>/dev/null || true
                        pkill -x "llama-server" 2>/dev/null || true
                        pkill -x "sd-server" 2>/dev/null || true
                        pkill -x "whisper-server" 2>/dev/null || true
                        pkill -x "kokoro-server" 2>/dev/null || true
                        pkill -x "koko" 2>/dev/null || true
                        ;;
                    Hermes)
                        pkill -f "Hermes" 2>/dev/null || true
                        pkill -x "hermes_cli" 2>/dev/null || true
                        pkill -f "python.*hermes.*gateway" 2>/dev/null || true
                        ;;
                    Docker)
                        if [[ "$D_DOCKER_RUNNING" == true ]]; then
                            docker stop $(docker ps -q) 2>/dev/null || true
                        fi
                        ;;
                    Zed)
                        pkill -x "zed-editor" 2>/dev/null || true
                        pkill -x "zed" 2>/dev/null || true
                        ;;
                    "System services")
                        echo -e "  ${WARN}  Use systemctl to stop individual services${NC}"
                        pause
                        continue
                        ;;
                    *)
                        echo -e "  ${WARN}  No mass-kill handler for ${gname}${NC}"
                        pause
                        continue
                        ;;
                esac
                echo -e "  ${OK}  ${gname} shutdown signal sent"
                _session_log "kill_group" "${gname} (${gcount} procs, ${gram}MB)" "OK"
                sleep 1
            fi
        fi
    done
}

_kill_unknowns() {
    while true; do
        header
        echo -e "${BRED}┄ UNKNOWN / SUSPICIOUS PROCESSES ───────────────────────${NC}"
        echo ""

        local known_procs=(
            bash zsh sh dash fish python3 python python2 perl ruby
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
            lemond hermes hermes_cli
            llama-server sd-server whisper-server kokoro-server koko
            code code-server
            vim nvim emacs nano
            git cargo rustc gcc clang make
            mutter-x11-frames
        )

        local _me; _me=$(whoami)
        local trusted_paths=(
            "/usr/bin/" "/usr/lib/" "/usr/libexec/" "/usr/share/"
            "/usr/sbin/" "/lib/" "/lib64/" "/snap/"
            "${HOME}/.local/" "${HOME}/.cargo/" "${HOME}/.nvm/"
            "${HOME}/projects/" "/opt/"
        )

        local lines=()
        local i=1
        while IFS= read -r line; do
            local proc_user pid pcpu pmem rss comm
            read -r proc_user pid pcpu pmem rss comm _ <<< "$line"
            [[ -z "$pid" ]] && continue
            local rss_mb=$((rss / 1024))
            local comm_base; comm_base=$(basename "$comm")

            local known=false
            for kp in "${known_procs[@]}"; do
                [[ "$comm_base" == "$kp" ]] && { known=true; break; }
            done
            $known && continue

            local tier="warn"
            local indicator="$WARN"
            if [[ "$comm" == /tmp/.mount_* ]]; then
                tier="safe"; indicator="$IDLE"
            elif [[ "$comm" == /tmp/* || "$comm" == /dev/shm/* || "$comm" == /run/user/*/tmp* || "$comm" == */.* ]]; then
                tier="flag"; indicator="$FAIL"
            elif [[ "$proc_user" == "root" ]]; then
                local in_sys=false
                for tp in "/usr/bin/" "/usr/sbin/" "/usr/lib/" "/usr/libexec/" "/lib/" "/sbin/" "/bin/" "/opt/"; do
                    [[ "$comm" == ${tp}* ]] && { in_sys=true; break; }
                done
                $in_sys && { indicator="$WARN"; tier="warn"; } || { indicator="$FAIL"; tier="flag"; }
            elif [[ "$proc_user" == "$_me" ]]; then
                local in_trusted=false
                for tp in "${trusted_paths[@]}"; do
                    [[ "$comm" == ${tp}* ]] && { in_trusted=true; break; }
                done
                $in_trusted && { indicator="$IDLE"; tier="safe"; }
            fi

            [[ "$tier" == "safe" ]] && continue

            lines+=("${pid}|${comm}|${pcpu}|${rss_mb}|${proc_user}|${tier}")
            local tier_word="REVIEW"
            [[ "$tier" == "flag" ]] && tier_word="FLAG"
            printf "   %2d)  %b  %-24s pid:%-7s %5s%%cpu  %4dMB  %s  %s\n" \
                "$i" "$indicator" "$comm_base" "$pid" "$pcpu" "$rss_mb" "$proc_user" "$tier_word"
            i=$((i + 1))
        done < <(ps aux --sort=-%mem 2>/dev/null \
            | awk 'NR>1 && ($6/1024 > 20 || $3 > 0.5){print $1,$2,$3,$4,$6,$11}' \
            | head -30)

        if [[ ${#lines[@]} -eq 0 ]]; then
            echo -e "  ${OK}  No suspicious processes found${NC}"
            pause
            return
        fi

        echo ""
        echo "  Enter number + action (e.g. 1k, 3K, 2i) or:"
        echo "   r) refresh    b) back    q) quit zmenu"
        echo ""
        read -rp "  Selection: " sel

        [[ "$sel" == "b" || -z "$sel" ]] && break
        [[ "$sel" == "r" || "$sel" == "R" ]] && continue
        [[ "$sel" == "q" || "$sel" == "Q" ]] && { printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0; }

        local n act
        if [[ "$sel" =~ ^([0-9]+)([kKiI])$ ]]; then
            n="${BASH_REMATCH[1]}"
            act="${BASH_REMATCH[2]}"
        elif [[ "$sel" =~ ^[0-9]+$ ]]; then
            n="$sel"
            act=""
        else
            echo -e "  ${RED}Invalid format. Use: 3k, 5K, 2i, or just 3${NC}"
            sleep 0.5
            continue
        fi

        if [[ "$n" -ge 1 && "$n" -le ${#lines[@]} ]]; then
            local pid comm pcpu rss_mb user tier
            IFS='|' read -r pid comm pcpu rss_mb user tier <<< "${lines[$((n-1))]}"
            local pname; pname=$(basename "$comm")
            _kill_process_menu "$pid" "$pname" "$pcpu"
        fi
    done
}

_kill_by_pid() {
    header
    echo -e "${BRED}┄ KILL BY PID ──────────────────────────────────────────${NC}"
    echo ""
    read -rp "  Enter PID: " pid
    if [[ "$pid" =~ ^[0-9]+$ ]] && [[ -d "/proc/$pid" ]]; then
        local comm pcpu pmem
        comm=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
        pcpu=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo "?")
        pmem=$(ps -p "$pid" -o %mem= 2>/dev/null || echo "?")
        _kill_process_menu "$pid" "$comm" "$pcpu" "$pmem"
    elif [[ -n "$pid" ]]; then
        echo -e "  ${FAIL}  PID ${pid} not found"
    fi
    pause
}

mod_kill_mode() {
    while true; do
        header
        echo -e "${BRED}┄ KILL MODE — STOP THE BULLSHIT ────────────────────────${NC}"
        echo ""
        echo "   1)  Top CPU consumers        (find what's hammering your CPU)"
        echo "   2)  Top RAM consumers        (find what's eating your memory)"
        echo "   3)  Process groups           (kill Lemonade · Hermes · Docker · etc)"
        echo "   4)  Unknown / suspicious     (processes not in registry)"
        echo "   5)  Kill by PID              (enter any process ID)"
        echo ""
        echo "   r)  Refresh    b)  Back    q)  Quit zmenu"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _kill_top_cpu ;;
            2) _kill_top_mem ;;
            3) _kill_groups ;;
            4) _kill_unknowns ;;
            5) _kill_by_pid ;;
            r|R) discover ;;
            b|"") break ;;
            q|Q) printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
#  MODULE: 07-chrome.sh
# ═══════════════════════════════════════════════════════════

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
    echo ""; read -rp "  $(printf '%b' "${DIM}[Enter] back${NC}") " _
}

confirm() {
    local prompt="$1"
    read -rp "  ${prompt} (y/N): " _c
    [[ "$_c" =~ ^[Yy]$ ]]
}

submenu_footer() {
    echo ""
    echo -e "  ${DIM}─────────────────────────────────────────${NC}"
    echo -e "  ${DIM}[Enter]=back    [r]=refresh    [q]=quit zmenu${NC}"
}

# ── Session logging ────────────────────────────────────────
_session_log() {
    local action="$1"
    local detail="${2:-}"
    local result="${3:-}"
    mkdir -p "$ZMENU_HISTORY_DIR"
    # Use Python to generate valid JSON — prevents injection if detail/result contain quotes/newlines
    _SL_T="$(date -Iseconds)" \
    _SL_A="$action" \
    _SL_D="$detail" \
    _SL_R="$result" \
    python3 -c '
import json,os
record={"t":os.environ.get("_SL_T",""),"action":os.environ.get("_SL_A",""),"detail":os.environ.get("_SL_D",""),"result":os.environ.get("_SL_R","")}
print(json.dumps(record))
' >> "$ZMENU_SESSION_LOG"
    chmod 600 "$ZMENU_SESSION_LOG" 2>/dev/null || true
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
        local disk_info; disk_info=$(df -h / | awk 'NR==2{printf "%s used / %s (%s free)",$3,$2,$4}') || true
        echo "- Disk: ${disk_info}"
        echo "- Load: $(awk '{print $1,$2,$3}' /proc/loadavg)"
        echo ""

        echo "## AI Stack"
        if [[ "$D_GATEWAY_RUNNING" == true ]]; then
            echo "- LLM-Gateway: RUNNING at ${D_GATEWAY_URL} (v${D_GATEWAY_VER})"
            local _gi
            for _gi in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
                printf "  - %-22s  %-8s  %s  %s MB  inflight:%s\n" \
                    "${D_GATEWAY_SLOTS_VAR[$_gi]}" \
                    "${D_GATEWAY_SLOTS_STATE[$_gi]}" \
                    "${D_GATEWAY_SLOTS_MODEL[$_gi]}" \
                    "${D_GATEWAY_SLOTS_RSS[$_gi]}" \
                    "${D_GATEWAY_SLOTS_INFLIGHT[$_gi]}"
            done
        else
            echo "- LLM-Gateway: STOPPED"
        fi
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
    _disc_lemonade || true
    _disc_hermes || true
    _disc_process_groups || true
    _history_load_trend 5 || true

    # Load sparkline data
    local _spark_gpu="" _spark_ram="" _spark_load=""
    local _pts="${ZMENU_SPARKLINE_POINTS:-30}"
    _sparkline_read "gpu_temp" "$_pts" || true
    [[ -n "${D_SPARKLINE_VALS:-}" ]] && _spark_gpu=$(_sparkline_render "$D_SPARKLINE_VALS" "$D_SPARKLINE_MAX")
    _sparkline_read "ram_used_mb" "$_pts" || true
    [[ -n "${D_SPARKLINE_VALS:-}" ]] && _spark_ram=$(_sparkline_render "$D_SPARKLINE_VALS" "$D_SPARKLINE_MAX")
    _sparkline_read "load1" "$_pts" || true
    [[ -n "${D_SPARKLINE_VALS:-}" ]] && _spark_load=$(_sparkline_render "$D_SPARKLINE_VALS" "$D_SPARKLINE_MAX")

    local _olla _olla_info
    if [[ "$D_OLLAMA_RUNNING" == true ]]; then
        _olla=$OK; _olla_info="running at ${D_OLLAMA_URL}"
    else
        _olla=$IDLE; _olla_info="stopped"
    fi

    local _lms
    $D_LMS_RUNNING && _lms=$OK || _lms=$IDLE

    # ── Memory Pool ───────────────────────────────────────
    # Real breakdown: used = apps+cache; available = what apps can actually use
    local mem_pct=0 avail_pct=0
    [[ "$D_MEM_TOTAL_MB" -gt 0 ]] && mem_pct=$((D_MEM_USED_MB * 100 / D_MEM_TOTAL_MB))
    [[ "$D_MEM_TOTAL_MB" -gt 0 ]] && avail_pct=$((D_MEM_AVAIL_MB * 100 / D_MEM_TOTAL_MB))
    local _mem
    if [[ $avail_pct -gt 30 ]]; then _mem=$OK
    elif [[ $avail_pct -gt 10 ]]; then _mem=$WARN
    else _mem=$FAIL; fi

    # Memory consumers (top 5 by RSS)
    local mem_consumers
    mem_consumers=$(ps aux --sort=-rss 2>/dev/null \
        | awk 'NR>1 && NR<=6{printf "      %-18s %5.0f MB\n", $11, $6/1024}' || true)

    # Swap
    local _swap
    if [[ "$D_SWAP_USED_MB" -gt 100 ]]; then _swap=$WARN
    elif [[ "$D_SWAP_USED_MB" -gt 0 ]]; then _swap=$OK
    else _swap=$IDLE; fi

    # ── GPU ───────────────────────────────────────────────
    local _gpu _gpu_info
    local _gpu_trend="" _gpu_use_trend=""
    [[ -n "${D_HIST_GPU_TEMP:-}" ]] && _gpu_trend=$(_history_trend_str "${D_GPU_TEMP:-0}" "$D_HIST_GPU_TEMP" "°C")
    [[ -n "${D_HIST_GPU_USE:-}" ]]  && _gpu_use_trend=$(_history_trend_str "${D_GPU_USE:-0}" "$D_HIST_GPU_USE" "%")
    case "$D_GPU_DRIVER" in
        rocm)         _gpu=$OK;   _gpu_info="${D_GPU_GFX}  ${D_GPU_TEMP:-?}°C ${_gpu_trend}  ${D_GPU_USE:-?}% ${_gpu_use_trend}" ;;
        nvidia)       _gpu=$OK;   _gpu_info="${D_GPU_GFX}  ${D_GPU_TEMP:-?}°C ${_gpu_trend}  ${D_GPU_USE:-?}% ${_gpu_use_trend}" ;;
        amdgpu-sysfs) _gpu=$WARN; _gpu_info="sysfs only  ${D_GPU_TEMP:-?}°C ${_gpu_trend}  ${DIM}(rocm-smi not in PATH)${NC}" ;;
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
    local disk_pct; disk_pct=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5}') || true
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
    # Handle decimal temps (e.g. 79.2) by stripping decimal part
    therm_val="${therm_val%%.*}"
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

    # Recently used — top 3 recent menu selections from session log
    local _recent
    _recent=$(tail -100 "$ZMENU_SESSION_LOG" 2>/dev/null | grep '"action":"menu_select"' | \
        python3 -c "import sys,json; items=[json.loads(l).get('detail','') for l in sys.stdin]; uniq=[]; [uniq.append(x) for x in items if x not in uniq]; print(', '.join(uniq[:3]))" 2>/dev/null || true)
    if [[ -n "$_recent" ]]; then
        echo -e "  ${DIM}Recent:${NC}  $_recent"
        echo ""
    fi

    # Hardware — primary for a discovery system
    echo -e "  ${BOLD}Hardware${NC}"
    echo -e "    GPU       ${_gpu}  ${_gpu_info}"
    [[ -n "$_spark_gpu" ]] && echo -e "    ${DIM}      ${_spark_gpu}${NC}"
    echo -e "    NPU       ${_npu}  ${_npu_info}"
    echo -e "    Thermals  ${_therm}  CPU: ${cpu_temp:-?}°C  GPU: ${D_GPU_TEMP:-?}°C"
    local _load_trend=""
    [[ -n "${D_HIST_LOAD1:-}" ]] && _load_trend=$(_history_trend_str "$load1" "$D_HIST_LOAD1" "")
    echo -e "    Load      ${_load}  $(awk '{printf "%s %s %s",$1,$2,$3}' /proc/loadavg)  ${_load_trend} ${DIM}(${D_CPU_CORES} threads)${NC}"
    [[ -n "$_spark_load" ]] && echo -e "    ${DIM}      ${_spark_load}${NC}"
    if [[ "$_load" == "$FAIL" ]]; then
        echo -e "    ${BRED}→ CRITICAL: System overloaded! Use KILL MODE (option 1)${NC}"
    elif [[ "$_load" == "$WARN" ]]; then
        echo -e "    ${BYEL}→ Load high. KILL MODE (option 1) can help.${NC}"
    fi
    echo ""

    # Memory Pool
    local _ram_trend=""
    [[ -n "${D_HIST_RAM_USED:-}" ]] && _ram_trend=$(_history_trend_str "${D_MEM_USED_MB:-0}" "$D_HIST_RAM_USED" "MB")
    echo -e "  ${BOLD}Memory Pool${NC}    ${_mem}  ${D_MEM_USED_MB}/${D_MEM_TOTAL_MB} MB used ${_ram_trend} ·  ${D_MEM_AVAIL_MB} MB available"
    [[ -n "$_spark_ram" ]] && echo -e "    ${DIM}      ${_spark_ram}${NC}"
    echo -e "    ${_swap}  Swap: ${D_SWAP_USED_MB}/${D_SWAP_TOTAL_MB} MB"
    if [[ -n "$mem_consumers" ]]; then
        echo -e "    ${DIM}Top consumers:${NC}"
        echo -e "$mem_consumers"
    fi
    if [[ "$_mem" == "$FAIL" ]]; then
        echo -e "    ${BRED}→ CRITICAL: Memory low! Use KILL MODE (option 1)${NC}"
    elif [[ "$_mem" == "$WARN" ]]; then
        echo -e "    ${BYEL}→ Memory stressed. KILL MODE (option 1) can help.${NC}"
    fi
    echo ""

    # Running Backends & Apps
    local _apps_any=false
    if [[ "$D_LEMONADE_RUNNING" == true || "$D_HERMES_RUNNING" == true || \
          "$D_DOCKER_RUNNING" == true || ${#D_PROCESS_GROUPS[@]} -gt 0 ]]; then
        echo -e "  ${BOLD}Running Backends & Apps${NC}"
        _apps_any=true
    fi
    if [[ "$D_LEMONADE_RUNNING" == true || ${#D_LEMONADE_BACKENDS[@]} -gt 0 ]]; then
        if [[ "$D_LEMONADE_RUNNING" == true ]]; then
            echo -e "    Lemonade  ${OK}  port ${D_LEMONADE_PORT:-?}  pid ${D_LEMONADE_PID:-?}"
        else
            echo -e "    Lemonade  ${IDLE}  not running"
        fi
        local _b
        for _b in "${D_LEMONADE_BACKENDS[@]}"; do
            local _b_name _b_type _b_port _b_pid _b_ram
            IFS='|' read -r _b_name _b_type _b_port _b_pid _b_ram <<< "$_b"
            echo -e "      ${_b_name}  ${OK}  port ${_b_port:-—}  pid ${_b_pid}  ${_b_ram} MB"
        done
    fi
    if [[ "$D_HERMES_RUNNING" == true ]]; then
        echo -e "    Hermes"
        [[ -n "$D_HERMES_DESKTOP_PID" ]] && echo -e "      Desktop  ${OK}  pid ${D_HERMES_DESKTOP_PID}"
        [[ -n "$D_HERMES_CLI_PID" ]]     && echo -e "      CLI      ${OK}  pid ${D_HERMES_CLI_PID}"
        [[ -n "$D_HERMES_GATEWAY_PID" ]] && echo -e "      Gateway  ${OK}  pid ${D_HERMES_GATEWAY_PID}"
    fi
    if [[ "$D_DOCKER_RUNNING" == true ]]; then
        echo -e "    Docker    ${OK}  ${#D_CONTAINERS[@]} container(s)"
        local _c
        for _c in "${D_CONTAINERS[@]}"; do
            local _cname _cstatus
            _cname="${_c%%:*}"
            _cstatus="${_c#*:}"
            echo -e "      ${_cname}  ${DIM}${_cstatus}${NC}"
        done
    fi
    # Top CPU consumers by group
    local cpu_groups
    cpu_groups=$(ps aux --sort=-%cpu 2>/dev/null | awk '
        NR>1 {
            cmd=$11; cpu=$3
            if (cmd ~ /lemond|llama-server|sd-server|whisper-server|kokoro-server|koko/) grp="Lemonade"
            else if (cmd ~ /Hermes|hermes_cli|hermes.*gateway/) grp="Hermes"
            else if (cmd ~ /docker|containerd/) grp="Docker"
            else if (cmd ~ /zed|zeditor/) grp="Zed"
            else if (cmd ~ /ollama/) grp="Ollama"
            else if (cmd ~ /python.*gateway|llm-gateway/) grp="LLM-Gateway"
            else grp=cmd
            gcpu[grp]+=cpu
        }
        END {
            for (g in gcpu) printf "%.1f %s\n", gcpu[g], g
        }
    ' | sort -rn | head -5 | awk '{printf "      %-14s %5.1f %%\n", $2":", $1}' || true)
    if [[ -n "$cpu_groups" ]]; then
        echo -e "    ${DIM}Top CPU consumers:${NC}"
        echo -e "$cpu_groups"
    fi
    if $_apps_any; then
        echo ""
    fi

    # Kworker storm alert
    if [[ "$D_KWORKER_STORM" == true ]]; then
        _kworker_dashboard_alert
    fi

    # Services
    echo -e "  ${BOLD}Services${NC}"
    echo -e "    Docker    ${_dock}  ${_dock_info}"
    if [[ "$D_NGINX_RUNNING" == true ]]; then
        echo -e "    Nginx     ${OK}  running"
    fi
    if [[ "$D_CTOP_RUNNING" == true ]]; then
        echo -e "    ctop      ${OK}  running"
    fi
    echo -e "    Disk      ${_disk}  ${disk_pct}% used"
    echo ""

    # AI Engine — last, collapsible (only if any backend is running)
    local _ai_any=false
    if [[ "$D_OLLAMA_RUNNING" == true || \
          "$D_LMS_RUNNING" == true || "$D_CLAUDE_SESSION" == true || \
          "$D_GATEWAY_RUNNING" == true || \
          "$D_LITELLM_RUNNING" == true || \
          "$D_VLLM_RUNNING" == true || \
          "$D_COMFYUI_RUNNING" == true || \
          "$D_TRITON_RUNNING" == true || \
          "$D_SGLANG_RUNNING" == true || \
          "$D_TABBYAPI_RUNNING" == true || \
          "$D_LOCALAI_RUNNING" == true ]] || \
       pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
        echo -e "  ${BOLD}AI Engine${NC}"
        _ai_any=true
    fi
    if [[ "$D_CLAUDE_SESSION" == true ]]; then
        echo -e "    Claude Code ${OK}  session active  v${D_CLAUDE_VER}"
    fi
    if pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
        echo -e "    OpenCode    ${OK}  RUNNING  v$( "$(_opencode_cmd)" --version 2>/dev/null || echo '?' )"
    fi
    if [[ "$D_OLLAMA_RUNNING" == true ]]; then
        echo -e "    Ollama      ${OK}  running at ${D_OLLAMA_URL}"
    fi
    if [[ "$D_LMS_RUNNING" == true ]]; then
        echo -e "    LM Studio   ${OK}  ${D_LMS_URL}"
    fi
    if [[ "$D_GATEWAY_RUNNING" == true ]]; then
        echo -e "    LLM-Gateway ${OK}  v${D_GATEWAY_VER}  ${D_GATEWAY_URL}"
        local _slot_color _slot_state
        for i in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
            _slot_state="${D_GATEWAY_SLOTS_STATE[$i]}"
            _slot_color=$IDLE
            [[ "$_slot_state" == "Active" ]] && _slot_color=$OK
            [[ "$_slot_state" == "Error" ]]  && _slot_color=$FAIL
            echo -e "      ${D_GATEWAY_SLOTS_VAR[$i]}  ${_slot_color}  ${D_GATEWAY_SLOTS_MODEL[$i]}  ${D_GATEWAY_SLOTS_RSS[$i]} MB  ${_slot_state}"
        done
    fi
    if [[ "$D_LITELLM_RUNNING" == true ]]; then
        echo -e "    LiteLLM     ${OK}  ${D_LITELLM_URL}"
    fi
    if [[ "$D_VLLM_RUNNING" == true ]]; then
        echo -e "    vLLM        ${OK}  ${D_VLLM_URL}"
    fi
    if [[ "$D_SGLANG_RUNNING" == true ]]; then
        echo -e "    SGLang      ${OK}  ${D_SGLANG_URL}"
    fi
    if [[ "$D_TABBYAPI_RUNNING" == true ]]; then
        echo -e "    TabbyAPI    ${OK}  ${D_TABBYAPI_URL}"
    fi
    if [[ "$D_LOCALAI_RUNNING" == true ]]; then
        echo -e "    LocalAI     ${OK}  ${D_LOCALAI_URL}"
    fi
    if [[ "$D_COMFYUI_RUNNING" == true ]]; then
        echo -e "    ComfyUI     ${OK}  ${D_COMFYUI_URL}"
    fi
    if [[ "$D_TRITON_RUNNING" == true ]]; then
        echo -e "    Triton      ${OK}  ${D_TRITON_URL}"
    fi
    if $_ai_any; then
        echo ""
    fi

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


# ═══════════════════════════════════════════════════════════
#  MODULE: 08b-diagnostics.sh
# ═══════════════════════════════════════════════════════════

# ============================================================
#  SECTION 10 — DIAGNOSTICS & EXTERNAL TOOLS
#  Kworker storm detection, external monitor launchers,
#  expanded hardware telemetry.
# ============================================================

_disc_kworkers() {
    D_KWORKER_GROUPS=()
    D_KWORKER_STORM=false

    local -A kcpu kcount
    local total_cpu=0

    # Read all kworker lines from ps in one shot
    local ps_out
    ps_out=$(ps -eo comm,%cpu --no-headers 2>/dev/null | grep '^\[kworker' || true)
    [[ -z "$ps_out" ]] && return

    while IFS= read -r line; do
        local name cpu
        name=$(echo "$line" | awk '{print $1}')
        cpu=$(echo "$line" | awk '{print $2}')
        # Extract suffix: e.g. [kworker/u128:3-gfx_0.0.0] → gfx_0.0.0
        local suffix="other"
        if [[ "$name" == *-""* ]]; then
            suffix="${name##*-}"
            # Strip trailing ']' if present
            suffix="${suffix%\]}"
        fi
        # Group related workers
        local group="$suffix"
        [[ "$group" == gfx_* ]] && group="gfx"
        [[ "$group" == comp_* ]] && group="comp"
        [[ "$group" == dm_vblank* ]] && group="dm_vblank"
        [[ "$group" == mm_percpu* ]] && group="mm_percpu"
        [[ "$group" == events_unbound* ]] && group="events_unbound"
        [[ "$group" == kvfree_rcu* ]] && group="kvfree_rcu"

        kcpu["$group"]=$(awk "BEGIN {printf \"%.1f\", ${kcpu[$group]:-0} + $cpu}")
        kcount["$group"]=$((${kcount[$group]:-0} + 1))
        total_cpu=$(awk "BEGIN {printf \"%.1f\", $total_cpu + $cpu}")
    done <<< "$ps_out"

    # Build summary array
    for g in "${!kcpu[@]}"; do
        local c="${kcpu[$g]}"
        local n="${kcount[$g]}"
        local status="ok"
        # Flag storm if any group uses >5% CPU
        if awk "BEGIN {exit !($c > 5.0)}"; then
            status="storm"
            D_KWORKER_STORM=true
        fi
        D_KWORKER_GROUPS+=("$g|$n|$c|$status")
    done

    # Also flag if total kworker CPU >10%
    if awk "BEGIN {exit !($total_cpu > 10.0)}"; then
        D_KWORKER_STORM=true
    fi
}

# ── External tool discovery ────────────────────────────────
_disc_external_tools() {
    D_RADEONTOP_AVAILABLE=false
    D_RADEONTOP_BIN=""
    D_SENSORS_AVAILABLE=false
    D_SENSORS_FULL=()

    if command -v radeontop >/dev/null 2>&1; then
        D_RADEONTOP_AVAILABLE=true
        D_RADEONTOP_BIN="$(command -v radeontop)"
    fi

    if command -v sensors >/dev/null 2>&1; then
        D_SENSORS_AVAILABLE=true
        while IFS= read -r line; do
            [[ -n "$line" ]] && D_SENSORS_FULL+=("$line")
        done < <(sensors 2>/dev/null || true)
    fi
}

# ── Kworker alert renderer (for dashboard) ─────────────────
_kworker_dashboard_alert() {
    [[ "$D_KWORKER_STORM" == false ]] && return
    echo -e "  ${BOLD}Kernel Workers${NC}  ${BRED}⚠ potential storm${NC}"
    for grp in "${D_KWORKER_GROUPS[@]}"; do
        local gname gcount gcpu gstatus
        IFS='|' read -r gname gcount gcpu gstatus <<< "$grp"
        [[ "$gstatus" != "storm" ]] && continue
        local sym="${WARN}"
        printf "    %b  %-18s %s procs  %s%% CPU\n" "$sym" "$gname" "$gcount" "$gcpu"
    done
    echo ""
}

# ── Find Problems: kworker check ───────────────────────────
_bp_kworkers() {
    _disc_kworkers || true
    [[ "$D_KWORKER_STORM" == false ]] && return

    echo "  ${BRED}▸ Kernel worker storm detected${NC}"
    for grp in "${D_KWORKER_GROUPS[@]}"; do
        local gname gcount gcpu gstatus
        IFS='|' read -r gname gcount gcpu gstatus <<< "$grp"
        [[ "$gstatus" != "storm" ]] && continue
        echo "    Group '${gname}': ${gcount} workers consuming ${gcpu}% CPU"
    done
    echo ""
    echo "  ${BYEL}Possible causes:${NC}"
    echo "    • AMDGPU firmware / driver issue (amdxdna-dkms, amdgpu)"
    echo "    • NPU firmware hang after suspend/resume"
    echo "    • ROCm compute queue leak"
    echo ""
    echo "  ${BYEL}Suggested fixes:${NC}"
    echo "    1. Check dmesg:  sudo dmesg | tail -50"
    echo "    2. Reload amdxdna:  sudo modprobe -r amdxdna && sudo modprobe amdxdna"
    echo "    3. If amdgpu stuck:  sudo modprobe -r amdgpu && sudo modprobe amdgpu"
    echo "    4. Check for firmware updates:  sudo apt update && sudo apt upgrade amdxdna-dkms"
    echo ""
}

# ── Hardware: expanded sensors view ────────────────────────
_hw_sensors_full() {
    header
    echo -e "${BCYN}┄ FULL SENSOR READINGS ─────────────────────────────────${NC}"
    echo ""
    if [[ "$D_SENSORS_AVAILABLE" == false ]]; then
        echo -e "  ${FAIL}  lm-sensors not installed${NC}"
        echo "    Install: sudo apt install lm-sensors"
    else
        sensors 2>/dev/null | sed 's/^/  /' || echo "  sensors command failed"
    fi
    echo ""
}

# ── Hardware: radeontop launcher ───────────────────────────
_hw_radeontop() {
    if [[ "$D_RADEONTOP_AVAILABLE" == false ]]; then
        echo -e "  ${FAIL}  radeontop not installed${NC}"
        pause
        return
    fi
    clear
    echo "Launching radeontop (q to quit)..."
    sleep 1
    sudo "$D_RADEONTOP_BIN" -d - -l 1 2>/dev/null || "$D_RADEONTOP_BIN" -d - -l 1 2>/dev/null || {
        echo -e "  ${FAIL}  radeontop failed (may need sudo or video group membership)${NC}"
        pause
    }
}

# ── External tool quick-launchers ──────────────────────────
_tool_launcher() {
    header
    echo -e "${BCYN}┄ EXTERNAL TOOLS ───────────────────────────────────────${NC}"
    echo ""
    local _rt="${IDLE}"; [[ "$D_RADEONTOP_AVAILABLE" == true ]] && _rt="${OK}"
    echo -e "  ${_rt}  r)  radeontop    AMD GPU deep metrics"
    echo -e "  ${OK}  s)  sensors      Full sensor readings"
    echo -e "  ${OK}  t)  top          Classic process viewer"
    local _has_htop="${IDLE}"; command -v htop >/dev/null 2>&1 && _has_htop="${OK}"
    echo -e "  ${_has_htop}  h)  htop         Interactive process viewer"
    local _has_btop="${IDLE}"; command -v btop >/dev/null 2>&1 && _has_btop="${OK}"
    echo -e "  ${_has_btop}  b)  btop         Beautiful system monitor"
    local _has_glances="${IDLE}"; command -v glances >/dev/null 2>&1 && _has_glances="${OK}"
    echo -e "  ${_has_glances}  g)  glances      Full system monitor (TUI/Web)"
    echo ""
    echo "   q)  Back"
    echo ""
    read -rp "  Selection: " ch
    case "$ch" in
        r) _hw_radeontop ;;
        s) _hw_sensors_full; pause ;;
        t) clear; top; ;;
        h) command -v htop >/dev/null 2>&1 && { clear; htop; } || { echo "htop not installed"; pause; } ;;
        b) command -v btop >/dev/null 2>&1 && { clear; btop; } || { echo "btop not installed"; pause; } ;;
        g) command -v glances >/dev/null 2>&1 && { clear; glances; } || { echo "glances not installed"; pause; } ;;
        q|Q) ;;
    esac
}

# ── Tmux session manager (placeholder) ─────────────────────
_disc_tmux() {
    D_TMUX_AVAILABLE=false
    D_TMUX_SESSIONS=()
    command -v tmux >/dev/null 2>&1 || return
    D_TMUX_AVAILABLE=true
    while IFS= read -r line; do
        [[ -n "$line" ]] && D_TMUX_SESSIONS+=("$line")
    done < <(tmux list-sessions -F "#{session_name}|#{session_windows}|#{session_attached}" 2>/dev/null || true)
}

_mod_tmux() {
    _disc_tmux || true
    while true; do
        header
        echo -e "${BCYN}┄ TMUX SESSIONS ────────────────────────────────────────${NC}"
        echo ""
        if [[ "$D_TMUX_AVAILABLE" == false ]]; then
            echo -e "  ${IDLE}  tmux not installed${NC}"
            echo "    Install: sudo apt install tmux"
        elif [[ ${#D_TMUX_SESSIONS[@]} -eq 0 ]]; then
            echo -e "  ${IDLE}  No active tmux sessions${NC}"
        else
            for s in "${D_TMUX_SESSIONS[@]}"; do
                local sname swins satt
                IFS='|' read -r sname swins satt <<< "$s"
                local sym="$OK"
                [[ "$satt" == "0" ]] && sym="$WARN"
                printf "  %b  %-20s %s windows  %s\n" "$sym" "$sname" "$swins" "$( [[ "$satt" == "1" ]] && echo "attached" || echo "detached" )"
            done
        fi
        echo ""
        echo "   a)  Attach to session"
        echo "   n)  New session"
        echo "   k)  Kill session"
        echo "   q)  Back"
        echo ""
        read -rp "  Selection: " ch
        case "$ch" in
            a) [[ ${#D_TMUX_SESSIONS[@]} -gt 0 ]] && tmux attach-session -t "${D_TMUX_SESSIONS[0]%%|*}" ;;
            n) tmux new-session -d -s "zmenu-$(date +%s)"; _disc_tmux; pause ;;
            k) [[ ${#D_TMUX_SESSIONS[@]} -gt 0 ]] && tmux kill-session -t "${D_TMUX_SESSIONS[0]%%|*}"; _disc_tmux; pause ;;
            q|Q) break ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════
#  MODULE: 08-modules.sh
# ═══════════════════════════════════════════════════════════

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
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI to diagnose problems"
        fi
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
            h) _bp_kernel ;;
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
    local total; total=$(docker ps -q 2>/dev/null | wc -l) || true
    local all_total; all_total=$(docker ps -aq 2>/dev/null | wc -l) || true
    local stopped=$((all_total - total))
    if [[ $stopped -gt 5 ]]; then
        _bp_finding "warn" "${stopped} stopped containers" \
            "Stopped containers waste disk space." \
            "docker container prune -f"
    fi

    # Dangling images
    local dangling; dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l) || true
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
    local disk_pct; disk_pct=$(df / | awk 'NR==2{gsub(/%/,"",$5); print $5}') || true
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
    local root_dev; root_dev=$(lsblk -ndo NAME "$(findmnt -no SOURCE /)" 2>/dev/null || echo "") || true
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
    while true; do
        header
        echo -e "${BCYN}┄ KERNEL TUNING ────────────────────────────────────────${NC}"
        echo ""

        # vm.swappiness
        local swappiness; swappiness=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
        if [[ "$swappiness" =~ ^[0-9]+$ ]] && [[ $swappiness -gt 30 ]]; then
            echo -e "  ${WARN}  vm.swappiness = ${swappiness}  (high)${NC}"
            echo -e "  ${DIM}  Too eager to swap. For systems with lots of RAM doing AI work, lower is better.${NC}"
            echo ""
            echo "   1)  Apply fix: sudo sysctl vm.swappiness=10"
        else
            echo -e "  ${OK}  vm.swappiness = ${swappiness}  (good)${NC}"
        fi

        # vm.dirty_ratio
        local dirty; dirty=$(sysctl -n vm.dirty_ratio 2>/dev/null || echo "?")
        if [[ "$dirty" =~ ^[0-9]+$ ]] && [[ $dirty -gt 30 ]]; then
            echo -e "  ${WARN}  vm.dirty_ratio = ${dirty}  (high)${NC}"
            echo -e "  ${DIM}  Large dirty page ratio can cause I/O stalls.${NC}"
            echo ""
            echo "   2)  Apply fix: sudo sysctl vm.dirty_ratio=10"
        else
            echo -e "  ${OK}  vm.dirty_ratio = ${dirty}  (fine)${NC}"
        fi

        # fs.inotify.max_user_watches
        local inotify; inotify=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo "?")
        if [[ "$inotify" =~ ^[0-9]+$ ]] && [[ $inotify -lt 524288 ]]; then
            echo -e "  ${WARN}  fs.inotify.max_user_watches = ${inotify}  (low)${NC}"
            echo -e "  ${DIM}  Low inotify limit can cause 'no space left on device' errors in dev tools.${NC}"
            echo ""
            echo "   3)  Apply fix: raise fs.inotify.max_user_watches to 524288"
        else
            echo -e "  ${OK}  fs.inotify.max_user_watches = ${inotify}  (adequate)${NC}"
        fi

        # Transparent Huge Pages
        local thp; thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "?")
        local thp_active; thp_active=$(echo "$thp" | grep -o '\[.*\]' | tr -d '[]')
        echo -e "  ${OK}  Transparent Huge Pages: ${thp_active:-unknown}${NC}"
        echo ""

        echo "   r)  Refresh    b)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1)
                if sudo -n sysctl vm.swappiness=10 >/dev/null 2>&1; then
                    echo -e "  ${OK}  vm.swappiness set to 10"
                else
                    echo -e "  ${WARN}  Could not apply (may need sudo password)${NC}"
                    echo "    Run: sudo sysctl vm.swappiness=10"
                fi
                pause ;;
            2)
                if sudo -n sysctl vm.dirty_ratio=10 >/dev/null 2>&1; then
                    echo -e "  ${OK}  vm.dirty_ratio set to 10"
                else
                    echo -e "  ${WARN}  Could not apply (may need sudo password)${NC}"
                    echo "    Run: sudo sysctl vm.dirty_ratio=10"
                fi
                pause ;;
            3)
                if sudo -n sysctl fs.inotify.max_user_watches=524288 >/dev/null 2>&1; then
                    echo -e "  ${OK}  fs.inotify.max_user_watches set to 524288"
                else
                    echo -e "  ${WARN}  Could not apply (may need sudo password)${NC}"
                    echo "    Run: sudo sysctl fs.inotify.max_user_watches=524288"
                fi
                pause ;;
            r|R) continue ;;
            b|"") break ;;
            q|Q) printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
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
    _bp_kworkers 2>&1 | grep -v "┄\|^$" | head -20

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

        # Lemonade status
        local lemonade_label
        if [[ "$D_LEMONADE_RUNNING" == true ]]; then
            lemonade_label="${OK} port ${D_LEMONADE_PORT:-?}  pid ${D_LEMONADE_PID:-?}"
        else
            lemonade_label="${IDLE} stopped"
        fi
        echo -e "  Lemonade    ${lemonade_label}"

        # Hermes status
        local hermes_label
        if [[ "$D_HERMES_RUNNING" == true ]]; then
            hermes_label="${OK}"
            [[ -n "$D_HERMES_DESKTOP_PID" ]] && hermes_label+=" desktop:${D_HERMES_DESKTOP_PID}"
            [[ -n "$D_HERMES_CLI_PID" ]]     && hermes_label+=" cli:${D_HERMES_CLI_PID}"
            [[ -n "$D_HERMES_GATEWAY_PID" ]] && hermes_label+=" gw:${D_HERMES_GATEWAY_PID}"
        else
            hermes_label="${IDLE} stopped"
        fi
        echo -e "  Hermes      ${hermes_label}"

        # LLM-Gateway status
        local gw_label
        if [[ "$D_GATEWAY_RUNNING" == true ]]; then
            gw_label="${OK} v${D_GATEWAY_VER}  ${D_GATEWAY_URL}  ${#D_GATEWAY_SLOTS_VAR[@]} slot(s)"
        else
            gw_label="${IDLE} stopped"
        fi
        echo -e "  LLM-Gateway ${gw_label}"

        # Ollama status
        local olla_label
        if $D_OLLAMA_RUNNING; then
            olla_label="${OK} ${D_OLLAMA_URL}"
        else
            olla_label="${IDLE} stopped"
        fi
        echo -e "  Ollama      ${olla_label}"

        # LM Studio status
        local lms_label
        $D_LMS_RUNNING && lms_label="${OK} ${D_LMS_URL}" || lms_label="${IDLE} off"
        echo -e "  LM Studio   ${lms_label}"

        # OpenCode status — green only when actually running as a process
        local oc_label oc_ver
        oc_ver=$(_opencode_available && "$(_opencode_cmd)" --version 2>/dev/null | tr -d '\n' || echo "")
        if pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
            oc_label="${OK} RUNNING  v${oc_ver}"
        elif _opencode_available; then
            oc_label="${IDLE} installed (not running)  v${oc_ver}"
        else
            oc_label="${IDLE} not installed"
        fi
        echo -e "  OpenCode    ${oc_label}"

        # ── AI Infrastructure ─────────────────────────────────
        local litellm_label
        if [[ "$D_LITELLM_RUNNING" == true ]]; then
            litellm_label="${OK} ${D_LITELLM_URL}"
        else
            litellm_label="${IDLE} stopped"
        fi
        echo -e "  LiteLLM     ${litellm_label}"

        local vllm_label
        if [[ "$D_VLLM_RUNNING" == true ]]; then
            vllm_label="${OK} ${D_VLLM_URL}"
        else
            vllm_label="${IDLE} stopped"
        fi
        echo -e "  vLLM        ${vllm_label}"

        local comfy_label
        if [[ "$D_COMFYUI_RUNNING" == true ]]; then
            comfy_label="${OK} ${D_COMFYUI_URL}"
        else
            comfy_label="${IDLE} stopped"
        fi
        echo -e "  ComfyUI     ${comfy_label}"

        local triton_label
        if [[ "$D_TRITON_RUNNING" == true ]]; then
            triton_label="${OK} ${D_TRITON_URL}"
        else
            triton_label="${IDLE} stopped"
        fi
        echo -e "  Triton      ${triton_label}"

        local nginx_label
        if [[ "$D_NGINX_RUNNING" == true ]]; then
            nginx_label="${OK} running"
        else
            nginx_label="${IDLE} stopped"
        fi
        echo -e "  nginx       ${nginx_label}"

        local ctop_label
        if [[ "$D_CTOP_RUNNING" == true ]]; then
            ctop_label="${OK} running"
        else
            ctop_label="${IDLE} stopped"
        fi
        echo -e "  ctop        ${ctop_label}"

        local sglang_label
        if [[ "$D_SGLANG_RUNNING" == true ]]; then
            sglang_label="${OK} ${D_SGLANG_URL}"
        else
            sglang_label="${IDLE} stopped"
        fi
        echo -e "  SGLang      ${sglang_label}"

        local tabby_label
        if [[ "$D_TABBYAPI_RUNNING" == true ]]; then
            tabby_label="${OK} ${D_TABBYAPI_URL}"
        else
            tabby_label="${IDLE} stopped"
        fi
        echo -e "  TabbyAPI    ${tabby_label}"

        local localai_label
        if [[ "$D_LOCALAI_RUNNING" == true ]]; then
            localai_label="${OK} ${D_LOCALAI_URL}"
        else
            localai_label="${IDLE} stopped"
        fi
        echo -e "  LocalAI     ${localai_label}"
        echo ""

        echo "   1)  Lemonade               (start · stop · backend status)"
        echo "   2)  Hermes                 (start · stop · gateway status)"
        echo "   3)  Ollama                 (start · stop · settings)"
        echo "   4)  LLM-Gateway            (slot status · metrics · health)"
        echo "   5)  LM Studio             (model downloader)"
        echo "   6)  OpenCode              (coding agent · Zed · ACP)"
        echo ""
        echo "   7)  Switch model"
        echo "   8)  AI session             (OpenCode TUI with system context)"
        echo ""
        echo "   E)  Export report"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
        echo "   C)  ✦ Ask AI to diagnose the AI stack"
        fi
        echo "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _ai_sub_lemonade ;;
            2) _ai_sub_hermes ;;
            3) _ai_sub_ollama ;;
            4) mod_llm_gateway ;;
            5) _ai_sub_lms ;;
            6) _ai_sub_opencode ;;
            7) _ai_switch_model ;;
            8) cc_launch "AI Stack Assistant" \
                "You are an expert on this local AI stack. Review the context and tell me the current state of all AI services, what's working, what could be improved." "$HOME" "--tui" ;;
            E) export_report "AI Engine"; pause ;;
            C) _cc_inline "AI Engine" _ctx_ai_engine; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

# ── LLM-Gateway submenu ───────────────────────────────────
mod_llm_gateway() {
    while true; do
        header
        echo -e "${BCYN}┄ LLM-GATEWAY ──────────────────────────────────────────${NC}"
        echo ""
        if [[ "$D_GATEWAY_RUNNING" == true ]]; then
            echo -e "  ${OK} Gateway running  ${D_GATEWAY_URL}  v${D_GATEWAY_VER}"
            echo ""
            echo "  Slots:"
            local i _slot_color _slot_state
            for i in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
                _slot_state="${D_GATEWAY_SLOTS_STATE[$i]}"
                _slot_color=$IDLE
                [[ "$_slot_state" == "Active" ]] && _slot_color=$OK
                [[ "$_slot_state" == "Error" ]]  && _slot_color=$FAIL
                printf "    %-22s  %b%-8s%b  %s  %s MB  kv:%s MB  inflight:%s\n" \
                    "${D_GATEWAY_SLOTS_VAR[$i]}" \
                    "$_slot_color" "$_slot_state" "$NC" \
                    "${D_GATEWAY_SLOTS_MODEL[$i]}" \
                    "${D_GATEWAY_SLOTS_RSS[$i]}" \
                    "${D_GATEWAY_SLOTS_KV[$i]}" \
                    "${D_GATEWAY_SLOTS_INFLIGHT[$i]}"
            done
        else
            echo -e "  ${IDLE} Gateway stopped"
        fi
        echo ""
        echo "   r)  Refresh status"
        echo "   m)  View metrics         (Prometheus counters from /metrics)"
        echo "   h)  Health check         (/health endpoint)"
        if [[ -n "${ZMENU_GATEWAY_ADMIN_KEY:-}" ]]; then
            echo "   s)  Start slot"
            echo "   t)  Stop slot"
            echo "   l)  View logs"
        else
            echo "   ${DIM}s)  Start slot         (requires ZMENU_GATEWAY_ADMIN_KEY env var)${NC}"
            echo "   ${DIM}t)  Stop slot          (requires ZMENU_GATEWAY_ADMIN_KEY env var)${NC}"
            echo "   ${DIM}l)  View logs          (requires ZMENU_GATEWAY_ADMIN_KEY env var)${NC}"
        fi
        echo ""
        echo "   E)  Export report"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  Ask AI about gateway optimization"
        fi
        echo "   b)  Back    q)  Quit zmenu"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            r|R) discover ;;
            m|M)
                if [[ "$D_GATEWAY_RUNNING" == true ]]; then
                    local metrics_resp
                    metrics_resp=$(curl -sf --max-time 2 "${D_GATEWAY_URL}/metrics" 2>/dev/null || echo "")
                    if [[ -n "$metrics_resp" ]]; then
                        echo ""
                        echo "$metrics_resp" | grep -E "^llm_gateway_(requests|tokens|slot)" | head -30
                    else
                        echo -e "${RED}  Failed to fetch metrics.${NC}"
                    fi
                else
                    echo -e "${RED}  Gateway not running.${NC}"
                fi
                pause
                ;;
            h|H)
                if [[ "$D_GATEWAY_RUNNING" == true ]]; then
                    local health_resp
                    health_resp=$(curl -sf --max-time 1 "${D_GATEWAY_URL}/health" 2>/dev/null || echo "")
                    if [[ -n "$health_resp" ]]; then
                        echo ""
                        echo "$health_resp" | python3 -m json.tool 2>/dev/null || echo "$health_resp"
                    else
                        echo -e "${RED}  Health check failed.${NC}"
                    fi
                else
                    echo -e "${RED}  Gateway not running.${NC}"
                fi
                pause
                ;;
            s|S)
                if [[ -n "${ZMENU_GATEWAY_ADMIN_KEY:-}" && "$D_GATEWAY_RUNNING" == true ]]; then
                    local _choices=() _map=()
                    for i in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
                        if [[ "${D_GATEWAY_SLOTS_STATE[$i]}" != "Active" ]]; then
                            _choices+=("${#_map[@]}) ${D_GATEWAY_SLOTS_VAR[$i]} (${D_GATEWAY_SLOTS_STATE[$i]})")
                            _map+=("${D_GATEWAY_SLOTS_VAR[$i]}")
                        fi
                    done
                    if [[ ${#_choices[@]} -eq 0 ]]; then
                        echo -e "${WARN}  All slots are already Active.${NC}"
                        sleep 1
                    else
                        echo ""
                        echo "  Select slot to start:"
                        for c in "${_choices[@]}"; do echo "    $c"; done
                        read -rp "  Selection: " _sel
                        if [[ "$_sel" =~ ^[0-9]+$ ]] && [[ "$_sel" -lt "${#_map[@]}" ]]; then
                            local _target="${_map[$_sel]}"
                            echo "  Starting ${_target}..."
                            local _resp
                            _resp=$(curl -sf --max-time 5 -X POST \
                                -H "x-admin-key: ${ZMENU_GATEWAY_ADMIN_KEY}" \
                                "${D_GATEWAY_URL}/admin/slots/${_target}/start" 2>/dev/null || echo "")
                            if [[ -n "$_resp" ]]; then
                                echo -e "  ${OK}  Start command sent. Refresh to see updated state.${NC}"
                            else
                                echo -e "  ${WARN}  Start command failed or timed out.${NC}"
                            fi
                            sleep 1
                        fi
                    fi
                fi
                ;;
            t|T)
                if [[ -n "${ZMENU_GATEWAY_ADMIN_KEY:-}" && "$D_GATEWAY_RUNNING" == true ]]; then
                    local _choices=() _map=()
                    for i in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
                        if [[ "${D_GATEWAY_SLOTS_STATE[$i]}" == "Active" ]]; then
                            _choices+=("${#_map[@]}) ${D_GATEWAY_SLOTS_VAR[$i]}")
                            _map+=("${D_GATEWAY_SLOTS_VAR[$i]}")
                        fi
                    done
                    if [[ ${#_choices[@]} -eq 0 ]]; then
                        echo -e "${WARN}  No Active slots to stop.${NC}"
                        sleep 1
                    else
                        echo ""
                        echo "  Select slot to stop:"
                        for c in "${_choices[@]}"; do echo "    $c"; done
                        read -rp "  Selection: " _sel
                        if [[ "$_sel" =~ ^[0-9]+$ ]] && [[ "$_sel" -lt "${#_map[@]}" ]]; then
                            local _target="${_map[$_sel]}"
                            echo "  Stopping ${_target}..."
                            local _resp
                            _resp=$(curl -sf --max-time 5 -X POST \
                                -H "x-admin-key: ${ZMENU_GATEWAY_ADMIN_KEY}" \
                                "${D_GATEWAY_URL}/admin/slots/${_target}/stop" 2>/dev/null || echo "")
                            if [[ -n "$_resp" ]]; then
                                echo -e "  ${OK}  Stop command sent. Refresh to see updated state.${NC}"
                            else
                                echo -e "  ${WARN}  Stop command failed or timed out.${NC}"
                            fi
                            sleep 1
                        fi
                    fi
                fi
                ;;
            l|L)
                if [[ -n "${ZMENU_GATEWAY_ADMIN_KEY:-}" && "$D_GATEWAY_RUNNING" == true ]]; then
                    local _choices=() _map=()
                    for i in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
                        _choices+=("${#_map[@]}) ${D_GATEWAY_SLOTS_VAR[$i]} (${D_GATEWAY_SLOTS_STATE[$i]})")
                        _map+=("${D_GATEWAY_SLOTS_VAR[$i]}")
                    done
                    echo ""
                    echo "  Select slot for logs:"
                    for c in "${_choices[@]}"; do echo "    $c"; done
                    read -rp "  Selection: " _sel
                    if [[ "$_sel" =~ ^[0-9]+$ ]] && [[ "$_sel" -lt "${#_map[@]}" ]]; then
                        local _target="${_map[$_sel]}"
                        echo "  Fetching logs for ${_target}..."
                        local _resp
                        _resp=$(curl -sf --max-time 5 \
                            -H "x-admin-key: ${ZMENU_GATEWAY_ADMIN_KEY}" \
                            "${D_GATEWAY_URL}/admin/logs/${_target}" 2>/dev/null || echo "")
                        if [[ -n "$_resp" ]]; then
                            echo ""
                            echo "$_resp" | tail -20
                        else
                            echo -e "  ${WARN}  No logs available or request failed.${NC}"
                        fi
                        pause
                    fi
                fi
                ;;
            E) export_report "LLM-Gateway"; pause ;;
            C) _cc_inline "LLM-Gateway" _ctx_llm_gateway _apply_llm_gateway; pause ;;
            b|B) break ;;
            q|Q) printf '
%b  Sovereign. Signing off.%b

' "${BGRN}" "${NC}"; exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

# ── LLM-Gateway context (for Ask AI) ──────────────────────
_ctx_llm_gateway() {
    printf "Section focus: LLM-Gateway slot orchestrator\n\n"
    printf "Running:         %s\n" "$(${D_GATEWAY_RUNNING} && echo "yes (${D_GATEWAY_URL})" || echo 'no')"
    printf "Version:         %s\n" "${D_GATEWAY_VER:-?}"
    printf "Slots:           %d\n" "${#D_GATEWAY_SLOTS_VAR[@]}"
    local i
    for i in "${!D_GATEWAY_SLOTS_VAR[@]}"; do
        printf "  %-20s  %-8s  %s  %s MB  kv:%s MB  inflight:%s\n" \
            "${D_GATEWAY_SLOTS_VAR[$i]}" \
            "${D_GATEWAY_SLOTS_STATE[$i]}" \
            "${D_GATEWAY_SLOTS_MODEL[$i]}" \
            "${D_GATEWAY_SLOTS_RSS[$i]}" \
            "${D_GATEWAY_SLOTS_KV[$i]}" \
            "${D_GATEWAY_SLOTS_INFLIGHT[$i]}"
    done
}

_apply_llm_gateway() { _apply_generic "$1" "LLM-Gateway"; }

# ── Lemonade sub-menu ─────────────────────────────────────
_ai_sub_lemonade() {
    while true; do
        header
        echo -e "${BCYN}┄ LEMONADE ─────────────────────────────────────────────${NC}"
        echo ""
        _disc_lemonade >/dev/null 2>&1 || true

        if [[ "$D_LEMONADE_RUNNING" == true ]]; then
            echo -e "  Status:  ${OK} running  pid:${D_LEMONADE_PID:-?}  port:${D_LEMONADE_PORT:-?}"
            if [[ ${#D_LEMONADE_BACKENDS[@]} -gt 0 ]]; then
                echo ""
                echo -e "  ${BOLD}Backends:${NC}"
                for be in "${D_LEMONADE_BACKENDS[@]}"; do
                    local bname btype bport bpid bram
                    IFS='|' read -r bname btype bport bpid bram <<< "$be"
                    printf "    ${OK}  %-16s pid:%-7s port:%-5s %s\n" "$bname" "$bpid" "${bport:-—}" "${DIM}${bram}MB${NC}"
                done
            fi
        else
            echo -e "  Status:  ${IDLE} stopped"
            echo -e "  ${DIM}Start manually: lemond (or your lemonade startup script)${NC}"
        fi
        echo ""
        echo "   r)  Refresh status"
        echo -e "   s)  ${BRED}Stop Lemonade${NC}          (SIGTERM all lemonade processes)"
        echo "   b)  Back    q)  Quit zmenu"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            r|R) _disc_lemonade >/dev/null 2>&1 || true ;;
            s|S)
                if confirm "Stop all Lemonade processes?"; then
                    pkill -x "lemond" 2>/dev/null || true
                    pkill -x "llama-server" 2>/dev/null || true
                    pkill -x "sd-server" 2>/dev/null || true
                    pkill -x "whisper-server" 2>/dev/null || true
                    pkill -x "kokoro-server" 2>/dev/null || true
                    pkill -x "koko" 2>/dev/null || true
                    echo -e "  ${OK}  Stop signal sent"
                    sleep 1
                fi ;;
            b|"") break ;;
            q|Q) printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
}

# ── Hermes sub-menu ───────────────────────────────────────
_ai_sub_hermes() {
    while true; do
        header
        echo -e "${BCYN}┄ HERMES ───────────────────────────────────────────────${NC}"
        echo ""
        _disc_hermes >/dev/null 2>&1 || true

        if [[ "$D_HERMES_RUNNING" == true ]]; then
            echo -e "  Status:  ${OK} running"
            [[ -n "$D_HERMES_DESKTOP_PID" ]] && echo -e "    Desktop  ${OK}  pid ${D_HERMES_DESKTOP_PID}"
            [[ -n "$D_HERMES_CLI_PID" ]]     && echo -e "    CLI      ${OK}  pid ${D_HERMES_CLI_PID}"
            [[ -n "$D_HERMES_GATEWAY_PID" ]] && echo -e "    Gateway  ${OK}  pid ${D_HERMES_GATEWAY_PID}"
        else
            echo -e "  Status:  ${IDLE} stopped"
            echo -e "  ${DIM}Start manually: hermes_cli or your hermes startup script${NC}"
        fi
        echo ""
        echo "   r)  Refresh status"
        echo -e "   s)  ${BRED}Stop Hermes${NC}            (SIGTERM all hermes processes)"
        echo "   b)  Back    q)  Quit zmenu"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            r|R) _disc_hermes >/dev/null 2>&1 || true ;;
            s|S)
                if confirm "Stop all Hermes processes?"; then
                    pkill -f "Hermes" 2>/dev/null || true
                    pkill -x "hermes_cli" 2>/dev/null || true
                    pkill -f "python.*hermes.*gateway" 2>/dev/null || true
                    echo -e "  ${OK}  Stop signal sent"
                    sleep 1
                fi ;;
            b|"") break ;;
            q|Q) printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
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
            echo -e "  Install:  ${DIM}curl -fsSL https://opencode.ai/install -o /tmp/opencode-install.sh${NC}"
            echo -e "  Review:   ${DIM}less /tmp/opencode-install.sh && bash /tmp/opencode-install.sh${NC}"
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
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
        echo "   r)  Back"
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
        echo -e "  ${DIM}Alternative local LLM backend. Settings preserved for reference.${NC}"
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
        echo "   E)  Export    r)  Back"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
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
        echo "   r)  Back    q)  Quit zmenu"
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
            q|Q) printf '
%b  Sovereign. Signing off.%b

' "${BGRN}" "${NC}"; exit 0 ;;
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
        printf '%s\n' '[Service]' | sudo tee "$override_file" >/dev/null 2>/dev/null
    fi
    if sudo grep -q "Environment=\"${key}=" "$override_file" 2>/dev/null; then
        sudo sed -i "s|Environment=\"${key}=.*\"|Environment=\"${key}=${val}\"|" "$override_file" 2>/dev/null
    else
        printf '%s\n' "Environment=\"${key}=${val}\"" | sudo tee -a "$override_file" >/dev/null 2>/dev/null
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back"
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
    echo "   r)  Back    q)  Quit"
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
    echo "   r)  Back"
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
        echo "   1)  Start server    2)  Stop server    r)  Back    q)  Quit zmenu"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) lms server start 2>/dev/null && echo -e "  ${OK}  Started" || echo -e "  ${FAIL}  Failed"
               sleep 2; _disc_lms; pause ;;
            2) lms server stop 2>/dev/null && echo -e "  ${OK}  Stopped" || echo -e "  ${FAIL}  Failed"
               sleep 1; _disc_lms; pause ;;
            r|R) break ;;
            q|Q) printf '
%b  Sovereign. Signing off.%b

' "${BGRN}" "${NC}"; exit 0 ;;
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
        echo "   r)  Back    q)  Quit zmenu"
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
            q|Q) printf '
%b  Sovereign. Signing off.%b

' "${BGRN}" "${NC}"; exit 0 ;;
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
    "Ollama|ollama|ollama|ollama.service|11434|~/.ollama|ai-inference|HTTP-based LLM server (primary backend)"
    "LM Studio||lmstudio||1234|~/.lmstudio|ai-inference|GUI model downloader and inference server"
    "LLM-Gateway|${LLM_GATEWAY_DIR:-/home/hox/projects/llm-gateway}/target/release/llm-gateway|llm-gateway||8090|${LLM_GATEWAY_DIR:-/home/hox/projects/llm-gateway}/config/slots.toml|ai-inference|Rust slot-based LLM gateway (Workhorse, Tiny, Vision, etc.)"
    "LiteLLM||litellm||4000||ai-inference|AI gateway / proxy (OpenAI-compatible)"
    "vLLM||vllm||8000||ai-inference|High-throughput LLM inference engine"
    "ComfyUI||comfyui||8188||ai-inference|Stable Diffusion UI and inference server"
    "Triton||tritonserver||8000||ai-inference|NVIDIA Triton Inference Server"
    "SGLang||sglang||30000||ai-inference|High-performance LLM inference engine"
    "TabbyAPI||tabbyapi||5000||ai-inference|ExLlamaV2/V3 API server"
    "LocalAI||local-ai||8080||ai-inference|OpenAI-compatible local AI server"
    # ── AI Tools ────────────────────────────────────────────
    "Claude Code|claude|claude|||~/.claude|ai-tools|Anthropic Claude Code CLI agent"
    "OpenCode|${OPENCODE_BIN}|${OPENCODE_PROCESS}|||${OPENCODE_CFG}|ai-tools|Standalone coding agent CLI"
    "Open WebUI|docker:open-webui|||3000||ai-tools|Web chat interface for local models (Docker)"
    "Crawl4AI|docker:crawl4ai|||11235||ai-tools|AI-powered web scraper (Docker)"
    "n8n|docker:n8n|||5678|~/.n8n|ai-tools|Workflow automation (Docker)"
    "SearXNG|docker:searxng|||8080||ai-tools|Private web search (Docker)"
    # ── Lab Orchestration ───────────────────────────────────
    "Lemonade|lemond|lemond|lemond.service|8090|~/.lemonade|ai-tools|AI lab orchestrator (lemond + backends: llama, sd, whisper, kokoro)"
    "Hermes|hermes|hermes|hermes.service||~/.hermes|dev|Hermes desktop + CLI gateway (Electron + Python)"
    # ── Networking ──────────────────────────────────────────
    "Tailscale|tailscale|tailscaled|tailscaled.service||/etc/tailscale|networking|Zero-config VPN mesh network"
    "OpenVPN|openvpn|openvpn|openvpn.service|||networking|VPN client/server"
    "nginx|nginx|nginx|nginx.service||/etc/nginx|networking|Reverse proxy (often fronts AI services)"
    "Docker|docker|dockerd|docker.service|||/etc/docker|containers|Container runtime engine"
    "ctop|ctop|ctop|||~/.ctop|containers|Container top monitor (Docker process viewer)"
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

        # ── Discovery-assisted checks (Lemonade, Hermes) ────
        if [[ "$name" == "Lemonade" && "$D_LEMONADE_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            local be_detail=""
            for be in "${D_LEMONADE_BACKENDS[@]}"; do
                local bname _btype bport bpid bram
                IFS='|' read -r bname _btype bport bpid bram <<< "$be"
                be_detail+="${be_detail:+, }${bname}:${bpid}"
            done
            run_info="pid:${D_LEMONADE_PID}"
            [[ -n "$be_detail" ]] && run_info+="  backends:[${be_detail}]"
        elif [[ "$name" == "Hermes" && "$D_HERMES_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            local parts=""
            [[ -n "$D_HERMES_DESKTOP_PID" ]] && parts+="desktop "
            [[ -n "$D_HERMES_CLI_PID" ]] && parts+="cli "
            [[ -n "$D_HERMES_GATEWAY_PID" ]] && parts+="gateway"
            run_info="${parts}"
        elif [[ "$name" == "LiteLLM" && "$D_LITELLM_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            run_info="${D_LITELLM_URL}"
        elif [[ "$name" == "vLLM" && "$D_VLLM_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            run_info="${D_VLLM_URL}"
        elif [[ "$name" == "ComfyUI" && "$D_COMFYUI_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            run_info="${D_COMFYUI_URL}"
        elif [[ "$name" == "Triton" && "$D_TRITON_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            run_info="${D_TRITON_URL}"
        elif [[ "$name" == "nginx" && "$D_NGINX_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
        elif [[ "$name" == "ctop" && "$D_CTOP_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
        elif [[ "$name" == "SGLang" && "$D_SGLANG_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            run_info="${D_SGLANG_URL}"
        elif [[ "$name" == "TabbyAPI" && "$D_TABBYAPI_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            run_info="${D_TABBYAPI_URL}"
        elif [[ "$name" == "LocalAI" && "$D_LOCALAI_RUNNING" == true ]]; then
            is_running=true
            is_installed=true
            run_info="${D_LOCALAI_URL}"
        fi

        # ── Process check ─────────────────────────────────
        if [[ -n "$process" ]] && ! $is_running; then
            if pgrep -x "$process" >/dev/null 2>&1; then
                is_running=true
                local pid; pid=$(pgrep -x "$process" | head -1) || true
                # CPU and RSS from ps
                res_info=$(ps -p "$pid" -o pid=,pcpu=,rss= 2>/dev/null \
                    | awk '{printf "pid:%s  %.1f%%cpu  %.0fMB", $1, $2, $3/1024}' || echo "pid:${pid}")
                is_installed=true
            fi
        fi

        # ── Unix socket check ─────────────────────────────
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
    local categories=("processes" "containers" "networking" "dev" "ai-inference" "ai-tools")
    local category_labels=("Processes" "Containers" "Networking" "Dev Tools" "AI Inference" "AI Tools")

    local i=0
    for cat in "${categories[@]}"; do
        echo -e "  ${BOLD}${category_labels[$i]}${NC}"

        # Processes category renders dynamic process groups
        if [[ "$cat" == "processes" ]]; then
            if [[ ${#D_PROCESS_GROUPS[@]} -eq 0 ]]; then
                echo -e "    ${IDLE}  No grouped processes running${NC}"
            else
                for grp in "${D_PROCESS_GROUPS[@]}"; do
                    local gname gcount gram gstatus
                    IFS='|' read -r gname gcount gram gstatus <<< "$grp"
                    local indicator="$IDLE"
                    [[ "$gstatus" == "running" || "$gstatus" == "active" ]] && indicator="$OK"
                    if [[ "$gname" == "Docker" ]]; then
                        printf "    %b  %-18s %-10s  %b%d containers%b\n" \
                            "$indicator" "$gname" "$gstatus" "$DIM" "$gcount" "$NC"
                    elif [[ "$gram" -gt 0 ]]; then
                        printf "    %b  %-18s %-10s  %b%d procs  %dMB%b\n" \
                            "$indicator" "$gname" "$gstatus" "$DIM" "$gcount" "$gram" "$NC"
                    else
                        printf "    %b  %-18s %-10s  %b%d%b\n" \
                            "$indicator" "$gname" "$gstatus" "$DIM" "$gcount" "$NC"
                    fi
                done
            fi
            echo ""
            i=$((i + 1))
            continue
        fi

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
        lemond hermes hermes_cli
        llama-server sd-server whisper-server kokoro-server koko
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
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
        echo -e "  ${WARN}  ${cnt_warn} process(es) worth reviewing — run 'C) Ask AI' for analysis"
        fi
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

    while true; do
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
        echo "   l)  Show logs    s)  Start    S)  Stop    E)  Export    r)  Back"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            l) _scan_app_logs "$rec"; pause ;;
            s) _scan_app_start "$rec"; pause ;;
            S) _scan_app_stop "$rec"; pause ;;
            E) export_report "App: ${name}"; pause ;;
            C) _cc_inline "$name" _ctx_apps_services _apply_apps_services; pause ;;
            r|R|b|B) break ;;
            q|Q) exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
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

        echo -e "  ${DIM}Use C) to ask the AI: what's deprecated, what's bloat, what can be removed safely.${NC}"
        echo ""
        echo "   r)  Back"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI — hygiene, deprecated tools, cleanup"
        fi
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
        echo "   p)  Packages   m)  Manage Docker    E)  Export    b)  Back"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
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
                echo "   r)  Back"
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

        # Docker summary
        if [[ "$D_DOCKER_RUNNING" == true ]]; then
            echo -e "  ${OK}  Docker running"
            echo ""
            while IFS='|' read -r name status ports; do
                [[ -z "$name" ]] && continue
                local port_info=""
                [[ -n "$ports" && "$ports" != "<no port>" ]] && port_info=" · ${ports}"
                echo -e "    ${OK}  ${name}${DIM}  ${status}${port_info}${NC}"
            done < <(docker ps --format "{{.Names}}|{{.Status}}|{{.Ports}}" 2>/dev/null)
            local dcount
            dcount=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l || echo "0")
            [[ "$dcount" -eq 0 ]] && echo -e "    ${IDLE}  no containers running${NC}"
        else
            echo -e "  ${FAIL}  Docker not running"
        fi
        echo ""

        # Lemonade summary
        if [[ "$D_LEMONADE_RUNNING" == true ]]; then
            echo -e "  ${OK}  Lemonade  ${DIM}(pid:${D_LEMONADE_PID}  port:${D_LEMONADE_PORT})${NC}"
            for be in "${D_LEMONADE_BACKENDS[@]}"; do
                local bname btype bport bpid bram
                IFS='|' read -r bname btype bport bpid bram <<< "$be"
                printf "    ${OK}  %-16s pid:%-7s port:%-5s %s\n" "$bname" "$bpid" "${bport:-—}" "${DIM}${bram}MB${NC}"
            done
            echo ""
        fi

        # Hermes summary
        if [[ "$D_HERMES_RUNNING" == true ]]; then
            echo -e "  ${OK}  Hermes${NC}"
            [[ -n "$D_HERMES_DESKTOP_PID" ]] && echo -e "    ${OK}  desktop  ${DIM}pid:${D_HERMES_DESKTOP_PID}${NC}"
            [[ -n "$D_HERMES_CLI_PID" ]] && echo -e "    ${OK}  cli      ${DIM}pid:${D_HERMES_CLI_PID}${NC}"
            [[ -n "$D_HERMES_GATEWAY_PID" ]] && echo -e "    ${OK}  gateway  ${DIM}pid:${D_HERMES_GATEWAY_PID}${NC}"
            echo ""
        fi

        echo "   a)  Container list         (status · resources)"
        echo "   b)  Container logs         (pick container)"
        echo "   c)  System prune           (clean unused)"
        echo "   d)  Start a service        (n8n · SearXNG · Crawl4AI · Open WebUI)"
        echo "   e)  Stop a container"
        echo "   f)  Restart a container"
        echo "   g)  Process groups         (Lemonade · Hermes · Docker · Zed · System)"
        echo "   h)  Systemd user services  (active user services)"
        echo ""
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
        else
            echo "   E)  Export    r)  Back"
        fi
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _docker_list; pause ;;
            b) _docker_logs ;;
            c) _docker_prune ;;
            d) _docker_start ;;
            e) _docker_stop ;;
            f) _docker_restart ;;
            g) _show_process_groups ;;
            h) _show_systemd_user; pause ;;
            E) export_report "Docker"; pause ;;
            C) _cc_inline "Apps & Services" _ctx_apps_services _apply_apps_services; pause ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

_show_process_groups() {
    while true; do
        header
        echo -e "${BCYN}┄ PROCESS GROUPS ───────────────────────────────────────${NC}"
        echo ""
        _disc_process_groups >/dev/null 2>&1 || true
        if [[ ${#D_PROCESS_GROUPS[@]} -eq 0 ]]; then
            echo -e "  ${IDLE}  No process groups running${NC}"
            pause
            return
        fi
        local i=1
        for grp in "${D_PROCESS_GROUPS[@]}"; do
            local gname gcount gram gstatus
            IFS='|' read -r gname gcount gram gstatus <<< "$grp"
            local indicator="$IDLE"
            [[ "$gstatus" == "running" || "$gstatus" == "active" ]] && indicator="$OK"
            if [[ "$gname" == "Docker" ]]; then
                printf "   %2d)  %b  %-18s %-10s  %b%d containers%b\n" \
                    "$i" "$indicator" "$gname" "$gstatus" "$DIM" "$gcount" "$NC"
            elif [[ "$gram" -gt 0 ]]; then
                printf "   %2d)  %b  %-18s %-10s  %b%d procs  %dMB%b\n" \
                    "$i" "$indicator" "$gname" "$gstatus" "$DIM" "$gcount" "$gram" "$NC"
            else
                printf "   %2d)  %b  %-18s %-10s  %b%d%b\n" \
                    "$i" "$indicator" "$gname" "$gstatus" "$DIM" "$gcount" "$NC"
            fi
            i=$((i + 1))
        done
        echo ""
        echo "  Select group to kill, or:  r) refresh  b) back  q) quit"
        echo ""
        read -rp "  Selection: " n
        [[ "$n" == "b" || -z "$n" ]] && break
        [[ "$n" == "r" || "$n" == "R" ]] && continue
        [[ "$n" == "q" || "$n" == "Q" ]] && { printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0; }
        if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le ${#D_PROCESS_GROUPS[@]} ]]; then
            local grp="${D_PROCESS_GROUPS[$((n-1))]}"
            local gname gcount gram gstatus
            IFS='|' read -r gname gcount gram gstatus <<< "$grp"
            echo ""
            if confirm "Kill entire ${gname} group? (${gcount} procs, ${gram}MB)"; then
                case "$gname" in
                    Lemonade)
                        pkill -x "lemond" 2>/dev/null || true
                        pkill -x "llama-server" 2>/dev/null || true
                        pkill -x "sd-server" 2>/dev/null || true
                        pkill -x "whisper-server" 2>/dev/null || true
                        pkill -x "kokoro-server" 2>/dev/null || true
                        pkill -x "koko" 2>/dev/null || true
                        ;;
                    Hermes)
                        pkill -f "Hermes" 2>/dev/null || true
                        pkill -x "hermes_cli" 2>/dev/null || true
                        pkill -f "python.*hermes.*gateway" 2>/dev/null || true
                        ;;
                    Docker)
                        if [[ "$D_DOCKER_RUNNING" == true ]]; then
                            docker stop $(docker ps -q) 2>/dev/null || true
                        fi
                        ;;
                    Zed)
                        pkill -x "zed-editor" 2>/dev/null || true
                        pkill -x "zed" 2>/dev/null || true
                        ;;
                    "System services")
                        echo -e "  ${WARN}  Use systemctl to stop individual services${NC}"
                        pause
                        continue
                        ;;
                    *)
                        echo -e "  ${WARN}  No mass-kill handler for ${gname}${NC}"
                        pause
                        continue
                        ;;
                esac
                echo -e "  ${OK}  ${gname} shutdown signal sent"
                sleep 1
            fi
        fi
    done
}

_show_systemd_user() {
    header
    echo -e "${BCYN}┄ SYSTEMD USER SERVICES ────────────────────────────────${NC}"
    echo ""
    if [[ ${#D_USER_SERVICES[@]} -eq 0 ]]; then
        echo -e "  ${IDLE}  No active user services${NC}"
    else
        for svc in "${D_USER_SERVICES[@]}"; do
            local status
            status=$(systemctl --user is-active "$svc" 2>/dev/null || echo "unknown")
            local indicator="$IDLE"
            [[ "$status" == "active" ]] && indicator="$OK"
            printf "  %b  %-40s %s\n" "$indicator" "$svc" "$status"
        done
    fi
    echo ""
}

_docker_list() {
    header
    echo -e "${BCYN}┄ RUNNING CONTAINERS${NC}"
    local count=0
    while IFS='|' read -r name status ports image; do
        [[ -z "$name" ]] && continue
        local port_info=""
        [[ -n "$ports" && "$ports" != "<no port>" ]] && port_info=" · ${ports}"
        printf "  ${OK}  %-20s %-18s  ${DIM}%s${NC}%s\n" "$name" "$status" "$image" "$port_info"
        count=$((count + 1))
    done < <(docker ps --format "{{.Names}}|{{.Status}}|{{.Ports}}|{{.Image}}" 2>/dev/null)
    [[ "$count" -eq 0 ]] && echo "  ${IDLE}  No running containers"
    echo ""
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
    echo "   r)  Back    q)  Quit"
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
    echo "   r)  Back"
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
        echo "   i)  radeontop               (AMD GPU deep metrics)"
        echo "   j)  Full sensor readings    (lm-sensors all zones)"
        echo "   k)  External tools          (htop · btop · glances · tmux)"
        echo ""
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   E)  Export    C)  ✦ Ask AI    r)  Back"
        else
            echo "   E)  Export    r)  Back"
        fi
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
            i) _hw_radeontop; pause ;;
            j) _hw_sensors_full; pause ;;
            k) _tool_launcher ;;
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
        echo "   E)  Export    r)  Back"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
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
        echo "   r)  Back    q)  Quit zmenu"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
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
            q|Q) printf '
%b  Sovereign. Signing off.%b

' "${BGRN}" "${NC}"; exit 0 ;;
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
    while true; do
        header
        echo -e "${BCYN}┄ TAILSCALE${NC}"
        echo ""
        if ! command -v tailscale >/dev/null 2>&1; then echo -e "  ${IDLE}  Not installed"; pause; break; fi
        local ts_status; ts_status=$(tailscale status 2>/dev/null || echo "not running")
        local ts_active; ts_active=$(systemctl is-active tailscaled 2>/dev/null)
        local ts_enabled; ts_enabled=$(systemctl is-enabled tailscaled 2>/dev/null)
        echo "  Service: ${ts_active}    Autostart: ${ts_enabled}"
        echo "$ts_status" | sed 's/^/  /' | head -10
        echo ""
        echo "   a)  Stop    b)  Disable autostart    c)  Stop + disable    d)  Start    r)  Back    q)  Quit"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) sudo systemctl stop tailscaled && echo -e "  ${OK}  Stopped" || echo -e "  ${FAIL}  Failed"; pause ;;
            b) sudo systemctl disable tailscaled && echo -e "  ${OK}  Disabled" || echo -e "  ${FAIL}  Failed"; pause ;;
            c) sudo systemctl stop tailscaled && sudo systemctl disable tailscaled && echo -e "  ${OK}  Done" || echo -e "  ${FAIL}  Failed"; pause ;;
            d) sudo systemctl start tailscaled && echo -e "  ${OK}  Started" || echo -e "  ${FAIL}  Failed"; pause ;;
            r|R|b|B) break ;;
            q|Q) exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
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
    while true; do
        header
        echo -e "${BCYN}┄ PRIVACY LOCKDOWN${NC}"
        echo ""
        echo "   a)  Guided  — step through each item"
        echo "   b)  One-shot — apply everything"
        echo "   r)  Back    q)  Quit"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a) _priv_lockdown_guided ;;
            b) _priv_lockdown_oneshot ;;
            r|R|b|B) break ;;
            q|Q) exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
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
        echo "   E)  Export    r)  Back"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
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
        echo "   E)  Export    r)  Back"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
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
$(uname -o) · Docker
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

        local oc_status ol_status
        if pgrep -x "$OPENCODE_PROCESS" >/dev/null 2>&1; then
            oc_status="${OK} RUNNING  (TUI-only — not for inline chat)"
        elif _opencode_available; then
            oc_status="${IDLE} installed (not running)"
        else
            oc_status="${IDLE} not installed"
        fi
        [[ "$D_OLLAMA_RUNNING" == true ]] \
            && ol_status="${OK} running  ${D_OLLAMA_ACTIVE_MODEL:-}" \
            || ol_status="${IDLE} stopped"

        echo -e "   1)  auto       — best available (Ollama → OpenCode)"
        echo -e "   2)  opencode   ${oc_status}"
        echo -e "   3)  ollama     ${ol_status}"
        echo ""
        echo -e "   r)  Back    q)  Quit zmenu"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _ai_backend_set "auto"     ;;
            2) _ai_backend_set "opencode" ;;
            3) _ai_backend_set "ollama"   ;;
            r|R) break ;;
            q|Q) printf '
%b  Sovereign. Signing off.%b

' "${BGRN}" "${NC}"; exit 0 ;;
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
        echo "   l)  AI Backend               (OpenCode · Ollama)"
        echo "   w)  Sovereign Wiki            (view · refresh knowledge base)"
        echo ""
        echo -e "  ${BOLD}AI Inspector${NC}"
        echo "   g)  Global settings.json"
        echo "   h)  Global AI.md"
        echo "   i)  Skills viewer/editor"
        echo "   j)  MCP servers"
        echo "   k)  Project inspector"
        echo ""
        echo "   E)  Export    r)  Back"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
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
            j) _cc_mcps; pause ;;
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
    while true; do
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
        echo "   e)  Edit    r)  Back    q)  Quit"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            e|E) mkdir -p "${HOME}/.config/ai"; ${ZMENU_PREFERRED_EDITOR} "$f" ;;
            r|R|b|B) break ;;
            q|Q) exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
}

_cc_global_md() {
    while true; do
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
        echo "   e)  Edit    r)  Back    q)  Quit"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            e|E) mkdir -p "${HOME}/.config/ai"; ${ZMENU_PREFERRED_EDITOR} "$f" ;;
            r|R|b|B) break ;;
            q|Q) exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
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
    while true; do
        header
        echo -e "${BCYN}┄ MCP SERVERS${NC}"
        echo ""
        local settings="${HOME}/.config/ai/settings.json"
        if [[ ! -f "$settings" ]]; then
            echo -e "  ${WARN}  No settings.json${NC}"
            echo ""
            echo "   a)  Add MCP server"
            echo "   r)  Back"
            echo ""
            read -rp "  Selection: " ch
            case $ch in
                a|A) _cc_mcp_add ;;
                r|R) break ;;
                *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
            esac
            continue
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
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            a|A) _cc_mcp_add ;;
            e|E) ${ZMENU_PREFERRED_EDITOR} "$settings" ;;
            r|R) break ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
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
    while true; do
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
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            e|E) ${ZMENU_PREFERRED_EDITOR} "${path}/AI.md" ;;
            s|S) mkdir -p "${path}/.config/ai"; ${ZMENU_PREFERRED_EDITOR} "${path}/.config/ai/settings.json" ;;
            r|R|b|B) break ;;
            q|Q) exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
}

# ============================================================
#  UNIVERSAL SEARCH
# ============================================================

_search_universal() {
    header
    echo -e "${BCYN}┄ SEARCH ───────────────────────────────────────────────${NC}"
    echo ""
    printf '  Query: '
    local query=""
    IFS= read -r query
    if [[ -z "$query" ]]; then
        echo -e "  ${DIM}Search cancelled.${NC}"
        sleep 0.5
        return
    fi
    echo ""

    local _found=false

    # Processes
    echo -e "  ${BOLD}Processes:${NC}"
    local _procs
    _procs=$(ps aux 2>/dev/null | grep -i "$query" | grep -v grep | head -5 | \
        awk '{printf "    %-12s %5.1f%% %6.0f MB  %s\n", $2, $3, $6/1024, $11}' 2>/dev/null || true)
    if [[ -n "$_procs" ]]; then
        echo "$_procs"; _found=true
    else
        echo -e "    ${DIM}(no matches)${NC}"
    fi
    echo ""

    # Services
    echo -e "  ${BOLD}Services:${NC}"
    local _svcs
    _svcs=$(printf '%s\n' "${D_SERVICES[@]}" 2>/dev/null | grep -i "$query" | sed 's/^/    /' 2>/dev/null || true)
    if [[ -n "$_svcs" ]]; then
        echo "$_svcs"; _found=true
    else
        echo -e "    ${DIM}(no matches)${NC}"
    fi
    echo ""

    # Ports
    echo -e "  ${BOLD}Ports:${NC}"
    local _ports
    _ports=$(printf '%s\n' "${D_OPEN_PORTS[@]}" 2>/dev/null | grep -i "$query" | sed 's/^/    /' 2>/dev/null || true)
    if [[ -n "$_ports" ]]; then
        echo "$_ports"; _found=true
    else
        echo -e "    ${DIM}(no matches)${NC}"
    fi
    echo ""

    # Wiki
    echo -e "  ${BOLD}Wiki:${NC}"
    local _wiki
    _wiki=$(grep -ri "$query" "$ZMENU_WIKI_DIR"/*.md 2>/dev/null | head -5 | sed 's/^/    /' 2>/dev/null || true)
    if [[ -n "$_wiki" ]]; then
        echo "$_wiki"; _found=true
    else
        echo -e "    ${DIM}(no matches)${NC}"
    fi
    echo ""

    # Session history
    echo -e "  ${BOLD}Recent commands:${NC}"
    local _hist
    _hist=$(tail -20 "$ZMENU_SESSION_LOG" 2>/dev/null | grep -i "$query" | \
        python3 -c "import sys,json; [print('    ',json.loads(l).get('t',''),json.loads(l).get('action',''),json.loads(l).get('detail','')) for l in sys.stdin]" 2>/dev/null || true)
    if [[ -n "$_hist" ]]; then
        echo "$_hist"; _found=true
    else
        echo -e "    ${DIM}(no matches)${NC}"
    fi
    echo ""

    if ! $_found; then
        echo -e "  ${WARN}  No results for '${query}'"
        echo ""
    fi

    pause
}

# ============================================================
#  PER-MENU HELP
# ============================================================

_menu_help_main() {
    header
    echo -e "${BCYN}┄ HELP ─ MAIN MENU ─────────────────────────────────────${NC}"
    echo ""
    echo "  1) KILL MODE      — Stop runaway processes. Shows top CPU/RAM"
    echo "                      consumers with memory and CPU usage."
    echo "                      Type a number + k for SIGTERM (e.g. 3k),"
    echo "                      number + K for SIGKILL (e.g. 5K),"
    echo "                      number + i for process info (e.g. 2i)."
    echo ""
    echo "  2) AI Engine      — Manage inference backends (Ollama,"
    echo "                      OpenCode, LLM-Gateway, Lemonade, Hermes)."
    echo "                      Start, stop, load/unload models, benchmark."
    echo ""
    echo "  3) Docker         — Start/stop Docker, view containers,"
    echo "                      prune images, view logs."
    echo ""
    echo "  4) System Scan    — Security audit: firewall, ports, VPN,"
    echo "                      unknown services, telemetry opt-outs."
    echo ""
    echo "  5) Hardware       — GPU, NPU, CPU, thermals, power profiles,"
    echo "                      PCIe info, disk health."
    echo ""
    echo "  6) Find Problems  — Automated bottleneck sweep with fixes."
    echo "                      Press C to Ask AI for deeper analysis."
    echo ""
    echo "  7) Projects       — Open projects, create new ones,"
    echo "                      scaffold AI.md, launch coding sessions."
    echo ""
    echo "  8) Settings       — Edit config, check versions, reinstall."
    echo ""
    echo "  r) Refresh        — Re-run discovery to update live metrics"
    echo "  /) Search         — Fuzzy search processes, services, wiki"
    echo "  E) Export         — Save full markdown report to ~/zmenu-report.md"
    echo "  q) Exit           — Quit zmenu"
    echo ""
    pause
}

# ============================================================
#  SECTION 7 — MAIN MENU
# ============================================================


# ═══════════════════════════════════════════════════════════
#  MODULE: 09-main.sh
# ═══════════════════════════════════════════════════════════

main_menu() {
    while true; do
        header
        dashboard
        echo -e "  ${BOLD}${BBLU}┄ ACTIONS ──────────────────────────────────────────────${NC}"
        echo ""
        echo -e "   ${BRED}1)  KILL MODE${NC}              ← stop runaway processes NOW"
        echo "   2)  AI Engine              (inference backends)"
        echo "   3)  Docker & Services      (containers · start · stop · logs · prune)"
        echo "   4)  System Scan            (apps · ports · security · unknowns)"
        echo "   5)  Hardware               (CPU · GPU · NPU · thermals · power)"
        echo "   6)  Find Problems           (bottleneck sweep + fixes)"
        echo "   7)  Projects               (open · create · AI sessions)"
        echo "   8)  Settings               (config · editor · reinstall)"
        echo ""
        echo "   r)  Refresh    /)  Search    ?)  Help    E)  Export    q)  Exit"
        echo ""
        read -rp "  $(printf '%b' "${BOLD}Selection:${NC} ")" choice
        case $choice in
            1) _session_log "menu_select" "KILL MODE" || true; mod_kill_mode ;;
            2) _session_log "menu_select" "AI Engine" || true; mod_ai_engine ;;
            3) _session_log "menu_select" "Docker & Services" || true; mod_apps_services ;;
            4) _session_log "menu_select" "System Scan" || true; mod_system_scan ;;
            5) _session_log "menu_select" "Hardware" || true; mod_hardware ;;
            6) _session_log "menu_select" "Find Problems" || true; mod_find_problems ;;
            7) _session_log "menu_select" "Projects" || true; mod_projects ;;
            8) _session_log "menu_select" "Settings" || true; mod_settings ;;
            r|R) discover ;;
            /) _search_universal ;;
            \?) _menu_help_main ;;
            E) export_report "Full System"; pause ;;
            q|Q) printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
        esac
    done
}

# ============================================================
#  WATCH MODE — background monitoring
# ============================================================

_watch_check_thresholds() {
    local alerts=""
    # GPU temp: strip decimal before integer comparison, guard against non-numeric
    local _gpu_temp_int="${D_GPU_TEMP:-0}"
    _gpu_temp_int="${_gpu_temp_int%%.*}"
    if [[ "$_gpu_temp_int" =~ ^[0-9]+$ ]] && [[ "$_gpu_temp_int" -gt "${ZMENU_ALERT_GPU_TEMP:-85}" ]]; then
        alerts+="GPU temp: ${D_GPU_TEMP}°C (threshold: ${ZMENU_ALERT_GPU_TEMP:-85}°C)\n"
    fi
    local ram_pct=0
    local _mem_total="${D_MEM_TOTAL_MB:-0}"
    local _mem_used="${D_MEM_USED_MB:-0}"
    [[ "$_mem_total" -gt 0 ]] && ram_pct=$((_mem_used * 100 / _mem_total))
    [[ "$ram_pct" -gt "${ZMENU_ALERT_RAM_PERCENT:-90}" ]] && \
        alerts+="RAM usage: ${ram_pct}% (threshold: ${ZMENU_ALERT_RAM_PERCENT:-90}%)\n"
    [[ "${D_SWAP_USED_MB:-0}" -gt "${ZMENU_ALERT_SWAP_MB:-500}" ]] && \
        alerts+="Swap: ${D_SWAP_USED_MB} MB (threshold: ${ZMENU_ALERT_SWAP_MB:-500} MB)\n"
    local core_count=${D_CPU_CORES:-4}
    local load1; load1=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
    local load_int=${load1%.*}
    [[ "$load_int" -gt $((core_count * ${ZMENU_ALERT_LOAD_MULTIPLIER:-2})) ]] && \
        alerts+="Load: ${load1} (threshold: $((core_count * ${ZMENU_ALERT_LOAD_MULTIPLIER:-2})))\n"
    printf '%b' "$alerts"
}

_watch_alert() {
    local key="$1" message="$2"
    # Write state files to ZMENU_HISTORY_DIR (user-owned, not world-writable /tmp)
    local state_file="${ZMENU_HISTORY_DIR}/.alert-${key}"
    local last_alert=0 now
    now=$(date +%s)
    [[ -f "$state_file" ]] && last_alert=$(cat "$state_file" 2>/dev/null || echo "0")
    if (( now - last_alert > 600 )); then
        notify-send -u critical "zmenu alert" "$message" 2>/dev/null || \
            echo -e "\a\n$(date '+%H:%M') ALERT [$key]: $message" >> "$ZMENU_ERROR_LOG"
        echo "$now" > "$state_file"
    fi
}

# Lightweight discovery for watch mode — only metrics needed for thresholds
_watch_discover() {
    _disc_memory || true
    _disc_gpu || true
    # GPU temp may be set by _disc_gpu; if not, try sensors fallback
    if [[ -z "${D_GPU_TEMP:-}" ]] && command -v sensors >/dev/null 2>&1; then
        D_GPU_TEMP=$(sensors 2>/dev/null | awk '/Tctl|Tdie/{gsub(/[+°C]/,"",$2); print $2; exit}' || echo "0")
    fi
    : "${D_GPU_TEMP:=0}"
}

_watch_mode() {
    cfg_load
    local _interval="${ZMENU_WATCH_INTERVAL:-30}"
    if [[ ! "$_interval" =~ ^[0-9]+$ ]] || [[ "$_interval" -lt 5 ]]; then
        echo -e "${WARN}  Invalid ZMENU_WATCH_INTERVAL ('$_interval'). Using 30s."
        _interval=30
    fi
    echo -e "${DIM}  zmenu watch mode — checking every ${_interval}s${NC}"
    echo "  Press Ctrl+C to stop"
    echo ""
    while true; do
        _watch_discover
        local alerts
        alerts=$(_watch_check_thresholds)
        if [[ -n "$alerts" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local key
                key=$(echo "$line" | awk '{print $1}' | tr -d ':')
                _watch_alert "$key" "$line"
            done <<< "$alerts"
        fi
        sleep "$_interval"
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
    --watch|-w)
        _watch_mode
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
        echo "Usage: zmenu [--run <function>] [--watch] [--context] [--export] [--help]"
        echo "  --run <fn>    Execute a module function headlessly"
        echo "  --watch       Background monitoring with threshold alerts"
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
