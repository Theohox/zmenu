# zmenu — Sovereign AI Dashboard

A single-file bash CLI dashboard for AMD Strix Halo laptops running Ubuntu 24.04 LTS.
No cloud dependency, no telemetry, no install script — one file, dropped in `/usr/local/bin`.

**Tested on:** HP ZBook Ultra 14 G1a · AMD Ryzen AI MAX+ PRO 395 · Radeon 8060S (gfx1151) · Ubuntu 24.04 LTS  
**Version:** 5.11.0

---

## What It Is

zmenu is a terminal dashboard that gives you a single entry point for everything happening on a
Strix Halo machine: AI inference engines, hardware telemetry, system health, maintenance, security,
and project management. It's designed around the philosophy that **you own your machine** — no data
leaves, no vendor lock-in, and the AI assistant uses only knowledge it gathered from your own system.

It works with or without any AI backend. Every hardware, maintenance, and security feature is
independent.

---

## Architecture — Three Layers

```
┌─────────────────────────────────────────────────────────┐
│  Discovery (live shell commands)                         │
│  Runs at startup and on-demand. Probes what IS there     │
│  right now: processes, GPU state, services, files.       │
│  Populates D_* variables. No opinions, no hardcoding.    │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│  Wiki (~/.zmenu/wiki/*.md)                               │
│  Persistent, structured knowledge about THIS machine.    │
│  Generated from discovery. Grows over time as you        │
│  install tools, tune settings, and run apply actions.    │
│  This is what the AI reads — not hardcoded prompts.      │
└────────────────────────┬────────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────────┐
│  AI (C) Ask AI in any section)                           │
│  Interprets the wiki + live section context to answer    │
│  questions, diagnose problems, and suggest commands.     │
│  Routed to whichever backend is active.                  │
└─────────────────────────────────────────────────────────┘
```

**Key principle:** shell commands discover facts, the wiki stores them, and the AI interprets them.
No shell conditionals simulate AI judgment. No hardcoded package knowledge. If it's installed,
discovery finds it. If it needs a recommendation, that's the AI's job.

---

## AI Backends

zmenu routes `C) Ask AI` through whichever backend you have configured. **None are required** —
all non-AI features work without any backend installed.

| Backend | Type | When to use |
|---------|------|-------------|
| **Zenny-Core** | Local, Vulkan | Strix Halo / AMD with Vulkan compute |
| **Ollama** | Local, ROCm or CPU | ROCm-supported GPUs, or CPU inference |
| **Claude Code CLI** | Cloud API | Anthropic cloud, fastest for complex tasks |
| **OpenCode** | TUI agent | Full interactive coding sessions |
| **Any OpenAI-compatible endpoint** | Local or remote | llama.cpp server, LM Studio, vLLM, etc. |

The fallback chain is: `Zenny-Core → Ollama → none`. You can pin a backend in Settings → AI Backend
or set `ZMENU_AI_BACKEND=zenny|ollama|opencode|auto` in `~/.zmenu/config`.

### Vulkan vs ROCm — Why It Matters for Strix Halo

**ROCm** is AMD's GPU compute stack for ML workloads. It officially supports a specific list of GPU
architectures. Strix Halo (gfx1151) is not on that list in ROCm 6.x. Ollama with ROCm either
falls back to CPU, or requires the `HSA_OVERRIDE_GFX_VERSION=11.5.1` workaround — which works but
can break across ROCm updates.

**Vulkan compute** is supported on any GPU with a Vulkan driver. AMD's RADV driver (ships in Mesa
with Ubuntu 24.04) provides full Vulkan compute support for gfx1151 out of the box. Tools like
llama.cpp (and Zenny-Core, which wraps it) use the Vulkan backend for GPU inference without any
ROCm dependency.

On Strix Halo's **unified memory architecture**, CPU and GPU share the same LPDDR5 pool. With
Vulkan inference, the entire system RAM pool is available for model layers with zero copy overhead —
a 128 GB machine can load a 70B Q4 model and still have headroom. ROCm's VRAM allocation is
separate and limited by the UMA Frame Buffer BIOS setting.

**Bottom line:** if you're on Strix Halo, Vulkan-based inference (llama.cpp/Zenny-Core, LM Studio,
or any Vulkan-capable server) outperforms ROCm-based Ollama in both compatibility and throughput.

### Bringing Your Own Inference Stack

zmenu is not tied to any specific inference tool. The AI backend just needs to be reachable:
- **Local llama.cpp server** (`llama-server`): configure Ollama backend to point to it, or wire
  directly via the socket/HTTP API
- **LM Studio**: discovered automatically via port 1234
- **Remote Ollama**: set `OLLAMA_HOST` in Ollama settings, zmenu auto-detects
- **vLLM / other OpenAI-compatible**: point a backend entry at the endpoint URL

---

## Feature Modules

### 1) Dashboard
Live overview rendered at startup and on refresh:
- AI backend status (which engine is running, which model is loaded)
- GPU: driver, gfx ID, temperature, utilization, VRAM used/total
- CPU: model, core count, load average
- RAM: total, used, swap
- Key service states (Zenny-Core, Ollama, Docker, Open WebUI)
- Wiki freshness timestamp and pending change count

### 2) Find Problems
Full bottleneck sweep across the system:
- AI inference health (backend running, model loaded, socket reachable)
- Memory pressure (swap usage, OOM events, RAM headroom)
- GPU thermal events, throttling, VRAM saturation
- Disk space, filesystem health, SMART status summary
- CPU throttle counters, P-state status, governor
- Failed systemd units, journal error spike detection
- Open ports that shouldn't be open, firewall gaps
- AI-assisted analysis: `C) Ask AI` sends all findings to your backend with a structured prompt
  asking for prioritized recommendations

### 3) AI Engine
Management panel for all inference backends:

**Zenny-Core sub-menu:**
- Start / stop the local inference server
- View running models and their memory footprint
- Benchmark token throughput
- Install as a systemd service (survives reboots)
- Socket health check

**Ollama sub-menu** (legacy):
- Start / stop Ollama
- Switch loaded model
- Full settings panel: Flash Attention, KV cache type, keep-alive timer, HSA GFX override,
  CORS origins, debug logging, concurrent requests, queue depth
- Apply recommended profile for Strix Halo with one command
- Reload Ollama after config changes

**OpenCode sub-menu:**
- Launch OpenCode TUI (full coding agent session)
- Configure Ollama provider for OpenCode
- Open current project in Zed via ACP protocol
- Upgrade OpenCode

**LM Studio:**
- Status and model listing (LM Studio is a model downloader/GUI, not a daemon — monitoring only)

**AI Session:**
- Opens an OpenCode TUI session pre-loaded with the zmenu system context (hardware facts, wiki state)

### 4) System Scan
Registry-driven inventory of every tool and service on the machine:
- Installed / running / port-open status for each registered app
- Categories: AI Inference, AI Tools, Networking, Containers, Dev
- Drill-down on any entry: process details, config path, logs
- Wiki-integrated: scan state is reflected in the AI context for `C) Ask AI`

Default registry includes: Zenny-Core, Ollama, LM Studio, Claude Code, OpenCode, Open WebUI,
Crawl4AI, n8n, SearXNG, Tailscale, OpenVPN, Docker, Node.js, Python3, Rust/Cargo, pip3.

Adding a new app: one line in the `_SCAN_REGISTRY` array. Scanner, wiki, and AI context pick it up automatically.

### 5) Hardware
Live hardware telemetry and control:
- Real-time resource monitor (CPU per-core, RAM, swap, load)
- htop / top launcher
- Thermal dashboard: CPU Tctl/Tdie, GPU edge temp, throttle events, ACPI thermal zones
- Hardware profile: full CPU/RAM/PCIe/NVMe enumeration via lshw and lspci
- Power & battery: TDP, current power profile, CPU governor, AMD P-State mode, uptime
- GPU full status: ROCm/VRAM/compute stats from rocm-smi, gfx ID, HSA env check
- NPU status: XDNA driver presence, /dev/accel0 enumeration
- HSA env check: verifies `HSA_OVERRIDE_GFX_VERSION` is set correctly for your GPU

### 6) Security & Privacy
Layered privacy controls:

**Port & firewall audit:**
- All listening ports with process names
- UFW status and rules
- Active outbound connections (catches unexpected phone-home)

**Service telemetry:**
- Ollama telemetry opt-out status
- Docker daemon.json review
- Snap metrics status
- Chromium telemetry flags

**Tailscale management:**
- Status, start/stop, enable/disable autostart

**Privacy lockdown:**
- Guided (step-by-step) or one-shot mode
- Writes telemetry opt-out env vars to ~/.bashrc
- Creates Ollama systemd override with DO_NOT_TRACK
- Disables Snap metrics
- Applies Chromium privacy flags

### 7) Maintenance
System hygiene automation:
- Package updates: `apt update`, upgrade preview, one-command upgrade
- Disk usage: top consumers by directory, df overview
- SMART status: disk health via smartctl
- Journal: error/warning scan, disk usage, vacuum
- Snap refresh and cleanup
- Cargo, pip, npm outdated package scan
- Docker: image prune, volume cleanup, container review
- Apply any of the above via AI suggestion (`C) Ask AI` → `apply`)

### 8) Projects
Project-aware workspace:
- Scans `ZMENU_PROJECTS_DIR` (default `~/projects`) for git repos
- Shows per-project status: branch, uncommitted changes, AI.md presence
- Open a project: launches OpenCode TUI or Zenny-Core inline chat in project context
- Create new project: scaffold directory structure, init git, create AI.md template
- Edit project AI.md: per-project instructions file read by the AI for that session
- Edit project settings.json: per-project AI agent configuration

### Settings
- Edit `~/.zmenu/config` directly or via guided prompts
- AI backend picker with live status for each backend
- Re-run discovery (after installing new tools)
- Wiki viewer and force-refresh
- Zenny chat model picker (which model `C) Ask AI` uses)
- Environment inspector: shows current $PATH, GPU env vars, HSA settings

---

## Apply Engine

Every `C) Ask AI` session supports an `apply` command. Type `apply` after the AI gives a
suggestion, and zmenu extracts the shell commands from the AI's last response and runs them.

**Safety model (allowlist):**
Only these command prefixes may be extracted and executed:
`systemctl`, `apt`, `docker`, `pkill`, `kill`, `mkdir`, `rm` (no `-rf /`), `cp`, `mv`, `chmod`,
`chown`, `python3`, `pip`, `curl`, `powerprofilesctl`, `cpupower`, `journalctl`, `sed`, `awk`, `tee`

**Hard blocks regardless of context:**
- Any command targeting `zmenu`, `bash`, or the current shell PID
- Launching zenny-core in background (would create duplicate instances)
- `sudo rm -rf` (destructive)
- Commands with `$(...)` or backtick substitution (injection risk)

After apply runs, the wiki's `changes.md` is updated so the AI knows what was applied.

---

## Install

```bash
chmod +x zmenu.sh
sudo cp zmenu.sh /usr/local/bin/zmenu
```

No build step. Config and wiki are created on first run at `~/.zmenu/`.

### Prerequisites

**Required:**
- `bash` 5.x, `python3`, `curl`, `awk`, `sed`

**Recommended:**
- `rocm-smi`, `rocminfo` — GPU monitoring (AMD)
- `lm-sensors` — CPU thermal monitoring
- `htop`, `smartmontools`, `lshw`

**At least one AI backend** (optional — all other features work without one):
- Your preferred local inference server (see AI Backends section above)
- Or Claude Code CLI (`claude`) for cloud-based assistance

---

## Configuration

`~/.zmenu/config` is created on first run. Key settings:

```bash
# AI backend: auto | zenny | opencode | ollama
ZMENU_AI_BACKEND="auto"

# Path to your local inference binary (if not on $PATH or ~/.local/bin)
ZMENU_ZENNY_BINARY="${HOME}/.local/bin/zenny-core"

# GPU gfx ID override — required if rocminfo reports wrong ID
# Strix Halo: rocminfo reports gfx1100, real die is gfx1151
ZMENU_GPU_GFX_OVERRIDE=gfx1151

# Machine label shown in AI system prompts and wiki (defaults to hostname)
ZMENU_MACHINE_LABEL="My Strix Halo Box"

# Projects directory scanned by the Projects module
ZMENU_PROJECTS_DIR="${HOME}/projects"

# Context window size for AI sessions
ZMENU_AI_CONTEXT_LENGTH=8192

# Preferred text editor
ZMENU_PREFERRED_EDITOR="${VISUAL:-${EDITOR:-nano}}"
```

---

## BIOS Settings for Strix Halo

These are not obvious and significantly affect performance and AI inference throughput.

### Memory

| Setting | Recommended | Why |
|---------|-------------|-----|
| UMA Frame Buffer / iGPU Frame Buffer | **8 GB or higher** | Sets VRAM for ROCm tools. Default (512 MB) starves GPU inference. For Vulkan inference this matters less (unified pool), but ROCm tools still need it. |
| Memory Speed | **8000 MT/s** (max) | Memory bandwidth is the primary bottleneck for LLM token throughput on unified memory. Higher = faster tokens/sec. |
| Memory Interleaving | **Enabled** | Spreads accesses across memory channels for better aggregate bandwidth. |

### CPU & Power

| Setting | Recommended | Why |
|---------|-------------|-----|
| TDP / PPT (sustained) | **55–65 W** | Default sustained TDP on many Strix Halo laptops is 45 W. Raising to 55–65 W lets the CPU and GPU sustain peak clocks through long inference runs. |
| Boost / Turbo | **Enabled** | Required for peak single-thread and GPU compute performance. |
| AMD P-State | **Enabled (active mode)** | Enables fine-grained kernel frequency control. Required for `powerprofilesctl` and performance governor to work. |
| Cool & Quiet | **Disabled** or Performance | Interferes with sustained compute workloads by aggressively throttling. |

### Platform

| Setting | Recommended | Why |
|---------|-------------|-----|
| IOMMU / AMD-Vi | **Enabled** | Required for VFIO/GPU passthrough and Docker GPU access. Also improves device isolation. |
| Above 4G Decoding | **Enabled** | Required for large PCIe device memory mappings. |
| NPU / AI Accelerator | **Enabled** | Required for XDNA driver (`amdxdna`) to enumerate `/dev/accel0`. Not currently used for LLM inference but needed for future XDNA workloads. |
| NVMe PCIe Generation | **Gen 5** (if available) | Some laptops default to Gen 4 for compatibility. Gen 5 gives significantly higher sequential read throughput for loading large model files from disk. |
| Secure Boot | Leave on for Ubuntu | Ubuntu 24.04 ships signed kernels. Only disable if using unsigned drivers. |

---

## GPU Notes — gfx1151 / Strix Halo

`rocminfo` and some tools report this die as `gfx1100`. The actual ID is `gfx1151`. zmenu
auto-corrects this during discovery (gfx1100 → gfx1151). To force a different value:

```bash
# ~/.zmenu/config
ZMENU_GPU_GFX_OVERRIDE=gfx1151
```

For ROCm-dependent tools (Ollama, PyTorch ROCm):
```bash
export HSA_OVERRIDE_GFX_VERSION=11.5.1
export ROCR_VISIBLE_DEVICES=0
```

zmenu's Ollama settings panel (`AI Engine → Ollama → Settings → 7`) can write these to the
Ollama systemd override file for you.
