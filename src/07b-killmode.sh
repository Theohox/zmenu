# shellcheck shell=bash
# ============================================================
#  SECTION 11 — KILL MODE: STOP THE BULLSHIT
#  Task manager for killing runaway processes fast.
#  No dead ends. Every screen lets you act.
# ============================================================

_kill_process_menu() {
    local pid="$1" pname="$2" pcpu="${3:-}" pmem="${4:-}" default_act="${5:-}"
    echo ""
    echo "  Selected: ${BOLD}${pname}${NC} (pid ${pid})"
    [[ -n "$pcpu" && "$pcpu" != "?" ]] && echo "  CPU: ${pcpu}%"
    [[ -n "$pmem" && "$pmem" != "?" ]] && echo "  RAM: ${pmem}%"

    local act="$default_act"
    if [[ -z "$act" ]]; then
        echo ""
        echo "   k)  SIGTERM  — graceful kill (let it clean up)"
        echo "   K)  SIGKILL  — force kill   (cannot be blocked)"
        echo "   i)  Info     — files, cwd, command line"
        echo "   c)  Cancel"
        echo ""
        read -rp "  Action: " act
    fi

    case "$act" in
        k|K)
            local sig="TERM"
            [[ "$act" == "K" ]] && sig="KILL"
            if kill -"$sig" "$pid" 2>/dev/null; then
                echo -e "  ${OK}  Sent SIG${sig} to ${pname} (pid ${pid})"
                _session_log "kill" "SIG${sig} ${pname} (pid ${pid})" "OK"
            else
                echo -e "  ${FAIL}  Failed — check permissions (maybe root-owned?)"
                _session_log "kill" "SIG${sig} ${pname} (pid ${pid})" "FAIL"
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
        c|C|'')
            return ;;
        *)
            echo -e "  ${RED}Invalid action${NC}"
            sleep 0.3
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
            _kill_process_menu "$pid" "$pname" "$pcpu" "" "$act"
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
            _kill_process_menu "$pid" "$pname" "" "$pmem" "$act"
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
            local gname gcount gram _gstatus
            IFS='|' read -r gname gcount gram _gstatus <<< "$grp"
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
            local gname gcount gram _gstatus
            IFS='|' read -r gname gcount gram _gstatus <<< "$grp"

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
                        pkill -x "hermes" 2>/dev/null || true
                        pkill -f "hermes gateway" 2>/dev/null || true
                        ;;
                    Docker)
                        if [[ "$D_DOCKER_RUNNING" == true ]]; then
                            local _containers=()
                            mapfile -t _containers < <(docker ps -q 2>/dev/null || true)
                            [[ ${#_containers[@]} -gt 0 ]] && docker stop "${_containers[@]}" 2>/dev/null || true
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
            "${HOME}/.rustup/" "${HOME}/.pyenv/"
            "${HOME}/.kimi-code/" "${HOME}/.opencode/" "${HOME}/.lmstudio/"
            "${HOME}/projects/" "/opt/"
        )

        local lines=()
        local i=1
        while IFS= read -r line; do
            local proc_user pid pcpu pmem rss comm
            read -r proc_user pid pcpu pmem rss comm _ <<< "$line"
            [[ -z "$pid" ]] && continue
            local rss_mb=$((rss / 1024))
            local exe_path
            exe_path=$(_proc_exe_path "$pid")
            [[ -z "$exe_path" ]] && continue
            local comm_base; comm_base=$(basename "$exe_path")

            local known=false
            for kp in "${known_procs[@]}"; do
                [[ "$comm_base" == "$kp" ]] && { known=true; break; }
            done
            $known && continue

            local tier="warn"
            local indicator="$WARN"

            # SAFE: current user + trusted path
            if [[ "$proc_user" == "$_me" ]]; then
                local in_trusted=false
                for tp in "${trusted_paths[@]}"; do
                    [[ "$exe_path" == ${tp}* ]] && { in_trusted=true; break; }
                done
                if $in_trusted; then
                    tier="safe"; indicator="$IDLE"
                fi
            fi

            # SUSPICIOUS locations (only evaluated if not already safe)
            if [[ "$tier" != "safe" ]]; then
                if [[ "$exe_path" == /tmp/.mount_* ]]; then
                    tier="safe"; indicator="$IDLE"
                elif [[ "$exe_path" == /tmp/* || "$exe_path" == /dev/shm/* || "$exe_path" == /run/user/*/tmp* || "$exe_path" == /run/shm/* || "$exe_path" == /var/tmp/* ]]; then
                    tier="flag"; indicator="$FAIL"
                elif [[ "$proc_user" == "root" ]]; then
                    local in_sys=false
                    for tp in "/usr/bin/" "/usr/sbin/" "/usr/lib/" "/usr/libexec/" "/lib/" "/lib64/" "/sbin/" "/bin/" "/opt/"; do
                        [[ "$exe_path" == ${tp}* ]] && { in_sys=true; break; }
                    done
                    $in_sys && { indicator="$WARN"; tier="warn"; } || { indicator="$FAIL"; tier="flag"; }
                fi
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
        echo "   3)  Process groups           (kill Desktop/Shell · Lemonade · Hermes · Docker · etc)"
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
