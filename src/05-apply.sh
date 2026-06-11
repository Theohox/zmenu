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

