# shellcheck shell=bash
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

    if command -v radeontop >/dev/null 2>&1; then
        D_RADEONTOP_AVAILABLE=true
        D_RADEONTOP_BIN="$(command -v radeontop)"
    fi

    if command -v sensors >/dev/null 2>&1; then
        D_SENSORS_AVAILABLE=true
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


