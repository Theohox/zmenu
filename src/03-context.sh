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

