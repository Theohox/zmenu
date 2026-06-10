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

# Generate structured JSON context for deterministic AI parsing.
# Included in the system prompt as a fenced JSON block.
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
    python3 -c '
import json,sys
args=sys.argv[1:]
cpu_model,cpu_cores,cpu_gov,mem_total,mem_used,swap_used,gpu_driver,gpu_gfx,gpu_temp,gpu_use,npu_driver,npu_device,load1,containers_json,services_json,zenny_running,zenny_models,ollama_running,backend_label,ai_model=args
d={
    "cpu":{"model":cpu_model,"cores":int(cpu_cores or 0),"governor":cpu_gov},
    "ram":{"total_mb":int(mem_total or 0),"used_mb":int(mem_used or 0),"swap_used_mb":int(swap_used or 0)},
    "gpu":{"driver":gpu_driver,"gfx":gpu_gfx,"temp_c":int(gpu_temp or 0),"util_pct":int(gpu_use or 0)},
    "npu":{"driver":npu_driver,"device":npu_device},
    "load":{"1min":float(load1 or 0)},
    "docker":{"containers":json.loads(containers_json)},
    "services":json.loads(services_json),
    "zenny":{"running":zenny_running=="true","models":zenny_models.split(",") if zenny_models else []},
    "ollama":{"running":ollama_running=="true"},
    "ai_backend":{"label":backend_label,"model":ai_model}
}
print(json.dumps(d,indent=2))
' \
    "${D_CPU_MODEL:-unknown}" "${D_CPU_CORES:-0}" "${D_CPU_GOVERNOR:-unknown}" \
    "${D_MEM_TOTAL_MB:-0}" "${D_MEM_USED_MB:-0}" "${D_SWAP_USED_MB:-0}" \
    "${D_GPU_DRIVER:-none}" "${D_GPU_GFX:-unknown}" "${D_GPU_TEMP:-0}" "${D_GPU_USE:-0}" \
    "${D_NPU_DRIVER:-none}" "${D_NPU_DEVICE:-none}" "${load1:-0}" \
    "$_containers" "$_services" \
    "${D_ZENNY_RUNNING:-false}" "$(IFS=,; echo "${D_ZENNY_KEYS[*]}")" \
    "${D_OLLAMA_RUNNING:-false}" "${AI_BACKEND_LABEL:-none}" "${ZMENU_AI_MODEL:-auto}" \
    2>/dev/null || echo '{}'
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

_ai_call_zenny() {
    local sys_prompt="$1"
    local hist_file="$2"
    # Use registry key for inference (not display name)
    local model="${ZMENU_AI_MODEL:-}"
    [[ -z "$model" && ${#D_ZENNY_KEYS[@]} -gt 0 ]] && model="${D_ZENNY_KEYS[0]}"
    [[ -z "$model" ]] && { echo "[error: no Zenny model available — load one first]"; return 1; }
    # Pass all dynamic data via env vars to avoid heredoc string interpolation (Python injection)
    ZENNY_HIST_FILE="$hist_file" \
    ZENNY_MODEL="$model" \
    ZENNY_SYS_PROMPT="$sys_prompt" \
    ZENNY_SOCKET="$D_ZENNY_SOCKET" \
    timeout 180 python3 -c '
import os, socket, json, sys, re

hist_file = os.environ.get("ZENNY_HIST_FILE", "")
model     = os.environ.get("ZENNY_MODEL", "")
sys_prompt = os.environ.get("ZENNY_SYS_PROMPT", "")
socket_path = os.environ.get("ZENNY_SOCKET", "")

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
        lines.append(f"{role}: {m[\"content\"]}")
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
    s.connect(socket_path)
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
        content = d.get("content", "[no content field in response]")
        # Strip Qwen3 chain-of-thought — handle closed AND unclosed blocks
        # (unclosed = model hit max_tokens before finishing the think phase)
        content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL)
        content = re.sub(r"<think>.*$", "", content, flags=re.DOTALL)
        content = content.strip()
        if not content:
            content = "[model hit token limit during thinking — try a shorter prompt or switch to a faster model in Settings → AI Backend]"
        print(content, end="")
except Exception as e:
    print(f"[error: {e}]", end="")
' 2>/dev/null
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


