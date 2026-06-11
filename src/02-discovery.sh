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

    # Desktop/Shell group — aggregate DE processes that spike individually
    local desktop_procs=(
        Xorg Xwayland
        gnome-shell gdm gdm3 gjs mutter gnome-session-binary gnome-session-ctl
        gnome-terminal-server gnome-text-editor gnome-software gnome-control-center
        gnome-calculator gnome-calendar gnome-system-monitor gnome-screensaver
        nautilus nemo thunar dolphin
        pulseaudio pipewire pipewire-pulse wireplumber
        tracker-miner-fs tracker-extract tracker-store
        xdg-desktop-portal xdg-desktop-portal-gnome xdg-desktop-portal-kde
        xdg-document-portal polkitd polkit-agent
        kwin kwin_x11 kwin_wayland plasmashell krunner ksmserver
        dunst mako notify-osd
    )
    local desktop_pids=""
    for proc in "${desktop_procs[@]}"; do
        local dp
        dp=$(pgrep -d' ' -x "$proc" 2>/dev/null || true)
        [[ -n "$dp" ]] && desktop_pids="${desktop_pids:+$desktop_pids }$dp"
    done
    desktop_pids=$(echo "$desktop_pids" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/ $//')
    if [[ -n "$desktop_pids" ]]; then
        local count ram
        count=$(echo "$desktop_pids" | wc -w)
        ram=$(_sum_rss "$desktop_pids")
        D_PROCESS_GROUPS+=("Desktop/Shell|${count}|${ram}|running")
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

