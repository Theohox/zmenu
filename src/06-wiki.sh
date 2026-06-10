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
        printf "LM Studio:   %s\n" "$($D_LMS_RUNNING && echo 'running' || echo 'off')"
        printf "Ollama:      %s\n" "$($D_OLLAMA_RUNNING && echo 'RUNNING' || echo 'stopped')"
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

