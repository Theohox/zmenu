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
        echo "   9)  Security & Privacy     (ports · firewall · telemetry · lockdown)"
        echo "   0)  Maintenance            (updates · disk · SMART · journal)"
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
            9) _session_log "menu_select" "Security & Privacy" || true; mod_security ;;
            0) _session_log "menu_select" "Maintenance" || true; mod_maintenance ;;
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
    mkdir -p "$ZMENU_HISTORY_DIR"
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
