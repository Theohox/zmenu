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
        echo "   r)  Refresh    E)  Export full report    q)  Exit"
        echo ""
        read -rp "  $(printf '%b' "${BOLD}Selection:${NC} ")" choice
        case $choice in
            1) mod_kill_mode ;;
            2) mod_ai_engine ;;
            3) mod_apps_services ;;
            4) mod_system_scan ;;
            5) mod_hardware ;;
            6) mod_find_problems ;;
            7) mod_projects ;;
            8) mod_settings ;;
            r|R) discover ;;
            E) export_report "Full System"; pause ;;
            q|Q) printf '\n%b  Sovereign. Signing off.%b\n\n' "${BGRN}" "${NC}"; exit 0 ;;
            *) echo -e "${RED}  Invalid.${NC}"; sleep 0.5 ;;
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
