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

        # Zenny-Core status
        local zenny_label
        if [[ "$D_ZENNY_RUNNING" == true ]]; then
            zenny_label="${OK} ${#D_ZENNY_MODELS[@]} model(s)  pid:${D_ZENNY_PID:-?}"
        else
            zenny_label="${IDLE} stopped"
        fi
        echo -e "  Zenny-Core  ${zenny_label}"

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
        echo ""

        echo "   1)  Zenny-Core             (model load · unload · benchmark · stats)"
        echo "   2)  Lemonade               (start · stop · backend status)"
        echo "   3)  Hermes                 (start · stop · gateway status)"
        echo "   4)  Ollama                 (start · stop · settings)"
        echo "   5)  LLM-Gateway            (slot status · metrics · health)"
        echo "   6)  LM Studio             (model downloader)"
        echo "   7)  OpenCode              (coding agent · Zed · ACP)"
        echo ""
        echo "   8)  Switch model"
        echo "   9)  AI session             (OpenCode TUI with system context)"
        echo ""
        echo "   E)  Export report"
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
        echo "   C)  ✦ Ask AI to diagnose the AI stack"
        fi
        echo "   r)  Back"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _ai_sub_zenny ;;
            2) _ai_sub_lemonade ;;
            3) _ai_sub_hermes ;;
            4) _ai_sub_ollama ;;
            5) mod_llm_gateway ;;
            6) _ai_sub_lms ;;
            7) _ai_sub_opencode ;;
            8) _ai_switch_model ;;
            9) cc_launch "AI Stack Assistant" \
                "You are an expert on this local AI stack. Review the context and tell me the current state of all AI services, what's working, what could be improved." "$HOME" "--tui" ;;
            E) export_report "AI Engine"; pause ;;
            C) _cc_inline "AI Engine" _ctx_ai_engine _apply_ai_engine; pause ;;
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
        if [[ -n "${ZENNY_ADMIN_KEY:-}" ]]; then
            echo "   s)  Start slot"
            echo "   t)  Stop slot"
            echo "   l)  View logs"
        else
            echo "   ${DIM}s)  Start slot         (requires ZENNY_ADMIN_KEY env var)${NC}"
            echo "   ${DIM}t)  Stop slot          (requires ZENNY_ADMIN_KEY env var)${NC}"
            echo "   ${DIM}l)  View logs          (requires ZENNY_ADMIN_KEY env var)${NC}"
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
                if [[ -n "${ZENNY_ADMIN_KEY:-}" && "$D_GATEWAY_RUNNING" == true ]]; then
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
                                -H "x-admin-key: ${ZENNY_ADMIN_KEY}" \
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
                if [[ -n "${ZENNY_ADMIN_KEY:-}" && "$D_GATEWAY_RUNNING" == true ]]; then
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
                                -H "x-admin-key: ${ZENNY_ADMIN_KEY}" \
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
                if [[ -n "${ZENNY_ADMIN_KEY:-}" && "$D_GATEWAY_RUNNING" == true ]]; then
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
                            -H "x-admin-key: ${ZENNY_ADMIN_KEY}" \
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
        if [[ "${AI_BACKEND_ACTIVE:-none}" != "none" ]]; then
            echo "   C)  ✦ Ask AI"
        fi
        echo "   r)  Back"
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
    echo "   r)  Back    q)  Quit"
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
    echo "   r)  Back    q)  Quit"
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
    echo "   r)  Back"
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
    # Validate paths before writing to systemd (prevent injection via config)
    if [[ "$ZENNY_BINARY" != /* ]] || [[ "$ZENNY_BINARY" == *$'\n'* ]] || [[ "$ZENNY_LOG" == *$'\n'* ]]; then
        echo -e "  ${FAIL}  Invalid path in ZENNY_BINARY or ZENNY_LOG — aborting"
        return 1
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
    sudo chmod 600 "$_ZENNY_SERVICE_FILE"
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
    "Zenny-Core|${ZENNY_BINARY}|${ZENNY_PROCESS}||unix:${D_ZENNY_SOCKET}|${ZENNY_BINARY}|ai-inference|Local LLM inference engine (Vulkan/llama.cpp, Unix socket)"
    "Ollama|ollama|ollama|ollama.service|11434|~/.ollama|ai-inference|HTTP-based LLM server (alternative backend)"
    "LM Studio||lmstudio||1234|~/.lmstudio|ai-inference|GUI model downloader and inference server"
    "LLM-Gateway|${LLM_GATEWAY_DIR:-/home/hox/projects/llm-gateway}/target/release/llm-gateway|llm-gateway||8090|${LLM_GATEWAY_DIR:-/home/hox/projects/llm-gateway}/config/slots.toml|ai-inference|Rust slot-based LLM gateway (Workhorse, Tiny, Vision, etc.)"
    # ── AI Tools ────────────────────────────────────────────
    "Claude Code|claude|claude|||~/.claude|ai-tools|Anthropic Claude Code CLI agent"
    "OpenCode|${OPENCODE_BIN}|${OPENCODE_PROCESS}|||${OPENCODE_CFG}|ai-tools|Standalone coding agent CLI (separate from Zenny-Core)"
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
            && ol_status="${WARN} running" \
            || ol_status="${IDLE} stopped"

        # Show current chat model
        local chat_model_display="${ZMENU_ZENNY_CHAT_MODEL:-auto (${ZMENU_AI_MODEL##*/})}"

        echo -e "   1)  auto       — best available (Zenny → Ollama)"
        echo -e "   2)  zenny      ${z_status}"
        echo -e "   3)  opencode   ${oc_status}"
        echo -e "   4)  ollama     ${ol_status}"
        echo ""
        echo -e "   z)  Zenny chat model  ${DIM}(current: ${chat_model_display})${NC}"
        echo ""
        echo -e "   r)  Back    q)  Quit zmenu"
        echo ""
        read -rp "  Selection: " ch
        case $ch in
            1) _ai_backend_set "auto"     ;;
            2) _ai_backend_set "zenny"    ;;
            3) _ai_backend_set "opencode" ;;
            4) _ai_backend_set "ollama"   ;;
            z) _ai_zenny_chat_model_pick; pause ;;
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
    echo "   r)  Back"
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
    echo "  2) AI Engine      — Manage inference backends (Zenny-Core,"
    echo "                      Ollama, OpenCode, LLM-Gateway)."
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

