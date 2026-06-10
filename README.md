# zmenu — Sovereign System Dashboard

A single-file bash CLI dashboard for AMD Strix Halo laptops running Ubuntu 24.04 LTS.
No cloud dependency, no telemetry, no install script — one file, dropped in `/usr/local/bin`.

**Tested on:** HP ZBook Ultra 14 G1a · AMD Ryzen AI MAX+ PRO 395 · Radeon 8060S (gfx1151) · Ubuntu 24.04 LTS  
**Version:** 5.12.0

---

## What It Is

zmenu is a terminal dashboard that gives you a single entry point for everything happening on a
Strix Halo machine: hardware telemetry, system health, maintenance, security, containers,
and project management. It's designed around the philosophy that **you own your machine** — no data
leaves, no vendor lock-in.

Every feature works standalone. No external services required.

---

## Architecture

### Source Build System

zmenu is built from modular source files in `src/`:

```
src/
  00-header.sh        # version, globals, colours
  01-config.sh        # config init/load/edit
  02-discovery.sh     # all system probes (D_* variables)
  03-context.sh       # live context generator for AI
  04-ai.sh            # AI backend launcher
  05-apply.sh         # apply engine (safe command execution)
  06-wiki.sh          # persistent wiki generation
  07-chrome.sh        # UI chrome: header, dashboard, pause, export
  07b-killmode.sh     # KILL MODE task manager
  08-modules.sh       # all menu modules
  08b-diagnostics.sh  # kworker storm, external tools, sensors
  09-main.sh          # main menu loop + entrypoint
```

Run `./build.sh` to concatenate all sources into `zmenu.sh`. The built file is what gets installed
to `/usr/local/bin/zmenu`.

### Two Layers

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
│  install tools, tune settings, and run maintenance.      │
└─────────────────────────────────────────────────────────┘
```

**Key principle:** shell commands discover facts, the wiki stores them. No hardcoded package knowledge.
If it's installed, discovery finds it.

---

## AI Integration (Optional)

zmenu can optionally integrate with local AI inference tools for chat and diagnostics. **None are
required** — all dashboard features work standalone.

| Tool | Discovery | Notes |
|------|-----------|-------|
| **Ollama** | Port 11434 + process check | Primary supported backend |
| **OpenCode** | `~/.opencode/bin/opencode` | TUI coding agent |
| **LM Studio** | Port 1234 | Monitored only (status, model dir size) |
| **Claude Code** | `claude` on `$PATH` | Discovered as installed app only |

### Ollama on Strix Halo

Strix Halo (gfx1151) is not officially supported by ROCm 6.x. Ollama with ROCm either falls back to
CPU or requires `HSA_OVERRIDE_GFX_VERSION=11.5.1`. The zmenu Ollama settings panel can write this
override to the systemd service file for you.

---

## Feature Modules

### 1) KILL MODE — Stop the Bullshit
The first thing you see when your machine is melting. A proper task manager:
- **Top CPU consumers** — numbered list; type `1k` for SIGTERM, `1K` for SIGKILL, `1i` for info
- **Top RAM consumers** — same pattern, find what's eating memory
- **Process groups** — kill entire Lemonade, Hermes, Docker, Zed groups in one shot
- **Unknown / suspicious processes** — processes not in the registry, flagged by risk tier, all killable
- **Kill by PID** — enter any process ID directly

Every screen gives you actions. No dead ends.

### 2) AI Engine
Optional management panel for local inference tools:

**Ollama sub-menu:**
- Start / stop Ollama
- Switch loaded model
- Full settings panel: Flash Attention, KV cache type, keep-alive timer, HSA GFX override,
  CORS origins, debug logging, concurrent requests, queue depth
- Apply recommended profile for Strix Halo with one command
- Reload Ollama after config changes

**OpenCode sub-menu:**
- Launch OpenCode TUI (full coding agent session)
- Configure Ollama provider for OpenCode
- Open Zed in current directory (manual ACP setup required)
- Upgrade OpenCode

**LM Studio:**
- Status and model listing (monitoring only — LM Studio is a GUI, not a daemon)

**Lemonade:**
- Start / stop the `lemond` orchestrator
- Live backend inventory: llama-server, sd-server, whisper-server, kokoro-server
- Per-backend PID, port, and RAM footprint
- Kill all Lemonade processes (SIGTERM with verify)

**Hermes:**
- Start / stop the Hermes desktop + CLI + gateway stack
- Per-component PID visibility (Desktop, CLI, Gateway)
- Kill all Hermes processes (SIGTERM with verify)

### 3) Docker & Services
Container and service control:
- Running container list with status, ports, resources
- Container logs (pick any running container)
- System prune (clean unused images/volumes/networks)
- Start / stop / restart individual containers
- Process groups view (Lemonade, Hermes, Docker, Zed, System) — with kill actions
- Systemd user services (active user services list)

### 4) System Scan
Registry-driven inventory of every tool and service on the machine:
- Installed / running / port-open status for each registered app
- Categories: AI Inference, AI Tools, Networking, Containers, Dev
- Drill-down on any entry: process details, config path, logs, start/stop commands
- Unknown processes scan — processes not in the registry, risk-tiered
- Export full scan report to markdown

Default registry includes: Ollama, LM Studio, Claude Code, OpenCode, Lemonade, Hermes,
Open WebUI, Crawl4AI, n8n, SearXNG, Tailscale, OpenVPN, Docker, Node.js, Python3, Rust/Cargo, pip3.

Adding a new app: one line in the `_SCAN_REGISTRY` array. Scanner and wiki pick it up automatically.

### 5) Hardware
Live hardware telemetry and control:
- Real-time resource monitor (CPU per-core, RAM, swap, load)
- htop / top / btop / glances launcher
- Thermal dashboard: CPU Tctl/Tdie, GPU edge temp, throttle events, ACPI thermal zones
- Hardware profile: full CPU/RAM/PCIe/NVMe enumeration via lshw and lspci
- Power & battery: TDP, current power profile, CPU governor, AMD P-State mode, uptime
- GPU full status: ROCm/VRAM/compute stats from rocm-smi, gfx ID, HSA env check
- NPU status: XDNA driver presence, /dev/accel0 enumeration
- HSA env check: verifies `HSA_OVERRIDE_GFX_VERSION` is set correctly for your GPU

### 6) Find Problems
Full bottleneck sweep across the system:
- AI inference health (backend running, model loaded, socket reachable)
- Memory pressure (swap usage, OOM events, RAM headroom)
- GPU thermal events, throttling, VRAM saturation
- Disk space, filesystem health, SMART status summary
- CPU throttle counters, P-state status, governor
- Failed systemd units, journal error spike detection
- Open ports that shouldn't be open, firewall gaps
- Kernel worker storm detection (kworker CPU spikes)
- Export findings to markdown report

### 7) Projects
Project-aware workspace:
- Scans `ZMENU_PROJECTS_DIR` (default `~/projects`) for git repos
- Shows per-project status: branch, uncommitted changes, AI.md presence
- Open a project: launches OpenCode TUI in project context
- Create new project: scaffold directory structure, init git, create AI.md template
- Edit project AI.md: per-project instructions file
- Edit project settings.json: per-project configuration

### 8) Settings
- Edit `~/.zmenu/config` directly or via guided prompts
- Re-run discovery (after installing new tools)
- Wiki viewer and force-refresh
- Environment inspector: shows current $PATH, GPU env vars, HSA settings
- Reinstall / update zmenu binary

---

## Apply Engine

When using an AI backend (Ollama), you can type `apply` after the AI gives a suggestion, and
zmenu extracts the shell commands from the AI's last response and runs them.

**Safety model (allowlist):**
Only these command prefixes may be extracted and executed:
`sudo`, `systemctl`, `sysctl`, `docker`, `pkill`, `kill`, `killall`, `apt`, `apt-get`, `snap`,
`mkdir`, `rm`, `cp`, `mv`, `chmod`, `chown`, `ln`, `tee`, `cat`, `echo`, `printf`, `export`, `unset`,
`python3`, `pip`, `pip3`, `curl`, `wget`, `powerprofilesctl`, `cpupower`, `journalctl`, `dmesg`,
`git`, `sed`, `awk`

**Hard blocks regardless of context:**
- Any command targeting `zmenu`, `bash`, or the current shell PID
- Re-launching zmenu from inside apply
- `rm -rf` on any root path (destructive)
- Commands with `$(...)` or backtick substitution (injection risk)

After apply runs, the wiki's `changes.md` is updated.

---

## Install

```bash
./build.sh
```

Then install (one of these):

```bash
# Option A: symlink (recommended for development — updates on every build)
sudo ln -sf "$(realpath zmenu.sh)" /usr/local/bin/zmenu
sudo chmod +x /usr/local/bin/zmenu

# Option B: hard copy
sudo cp zmenu.sh /usr/local/bin/zmenu
sudo chmod +x /usr/local/bin/zmenu
```

Config and wiki are created on first run at `~/.zmenu/`.

**Development:** edit files in `src/`, then run `./build.sh` to regenerate `zmenu.sh`.

### CLI Usage

```bash
# Interactive TUI (default)
zmenu

# Run a specific function headlessly (no TUI, outputs to stdout)
zmenu --run <function_name>
# Example: zmenu --run mod_hardware

# Dump the current system context to stdout (for debugging AI prompts)
zmenu --context
```

### Prerequisites

**Required:**
- `bash` 5.x, `python3`, `curl`, `awk`, `sed`

**Recommended:**
- `rocm-smi`, `rocminfo` — GPU monitoring (AMD)
- `lm-sensors` — CPU thermal monitoring
- `htop`, `smartmontools`, `lshw`

**Optional AI tools** (not required for any dashboard feature):
- Ollama (ROCm or CPU inference)
- OpenCode (TUI coding agent)

---

## Configuration

`~/.zmenu/config` is created on first run. Key settings:

```bash
# AI backend: auto | opencode | ollama
ZMENU_AI_BACKEND="auto"

# GPU gfx ID override — required if rocminfo reports wrong ID
# Strix Halo: rocminfo reports gfx1100, real die is gfx1151
ZMENU_GPU_GFX_OVERRIDE=gfx1151

# Machine label shown in wiki (defaults to hostname)
ZMENU_MACHINE_LABEL="My Strix Halo Box"

# Projects directory scanned by the Projects module
ZMENU_PROJECTS_DIR="${HOME}/projects"

# Context window size for AI sessions (when Ollama is used)
ZMENU_AI_CONTEXT_LENGTH=8192

# Preferred text editor
ZMENU_PREFERRED_EDITOR="${VISUAL:-${EDITOR:-nano}}"

# Headless mode (set to 1 for non-TTY environments, auto-set by --run)
ZMENU_HEADLESS=0
```

---

## BIOS Settings for Strix Halo

These are not obvious and significantly affect system performance.

### Memory

| Setting | Recommended | Why |
|---------|-------------|-----|
| UMA Frame Buffer / iGPU Frame Buffer | **8 GB or higher** | Sets VRAM for ROCm tools. Default (512 MB) starves GPU compute. |
| Memory Speed | **8000 MT/s** (max) | Memory bandwidth is the primary bottleneck for GPU compute on unified memory. Higher = faster. |
| Memory Interleaving | **Enabled** | Spreads accesses across memory channels for better aggregate bandwidth. |

### CPU & Power

| Setting | Recommended | Why |
|---------|-------------|-----|
| TDP / PPT (sustained) | **55–65 W** | Default sustained TDP on many Strix Halo laptops is 45 W. Raising to 55–65 W lets the CPU and GPU sustain peak clocks through long compute workloads. |
| Boost / Turbo | **Enabled** | Required for peak single-thread and GPU compute performance. |
| AMD P-State | **Enabled (active mode)** | Enables fine-grained kernel frequency control. Required for `powerprofilesctl` and performance governor to work. |
| Cool & Quiet | **Disabled** or Performance | Interferes with sustained compute workloads by aggressively throttling. |

### Platform

| Setting | Recommended | Why |
|---------|-------------|-----|
| IOMMU / AMD-Vi | **Enabled** | Required for VFIO/GPU passthrough and Docker GPU access. Also improves device isolation. |
| Above 4G Decoding | **Enabled** | Required for large PCIe device memory mappings. |
| NPU / AI Accelerator | **Enabled** | Required for XDNA driver (`amdxdna`) to enumerate `/dev/accel0`. Needed for future XDNA workloads. |
| NVMe PCIe Generation | **Gen 5** (if available) | Some laptops default to Gen 4 for compatibility. Gen 5 gives significantly higher sequential read throughput. |
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
