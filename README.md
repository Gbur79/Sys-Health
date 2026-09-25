# Arch System Health & Diagnostics (`sys-health`)

[![Arch Linux](https://img.shields.io/badge/Arch%20Linux-Compatible-blue?logo=archlinux)](https://archlinux.org/)
[![Version: 2.14](https://img.shields.io/badge/Version-2.14-orange.svg)](CHANGELOG.md)
[![Changelog](https://img.shields.io/badge/Changelog-Keep%20a%20Changelog-brightgreen.svg)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An interactive TUI diagnostic suite, deterministic system health auditor, guarded upgrade engine, and AI-assisted telemetry bridge for **Arch Linux and Arch-based distributions** (EndeavourOS, CachyOS, Manjaro, etc.).

> **Disclaimer:** This is an independent, unofficial open-source community project. It is **not** developed, maintained, or endorsed by the EndeavourOS team or Arch Linux. It is designed to assist users in understanding, inspecting, and maintaining their systems safely.

---

<img width="718" height="426" alt="Main_menu" src="https://github.com/user-attachments/assets/a3920575-ba3b-45ac-b609-af24756153c3" />

<img width="720" height="1057" alt="Health_audit_table" src="https://github.com/user-attachments/assets/3bab5ce3-c2bf-499d-a07f-194f4c9737a2" />

<img width="719" height="378" alt="software_update" src="https://github.com/user-attachments/assets/bbeff097-f1ce-4edf-b797-86aa611af4eb" />

---

## Why `sys-health`? (Real-World Rolling-Release Problems Solved)

Arch Linux and EndeavourOS deliver blistering speed, incredible flexibility, and bleeding-edge software. However, rolling releases can sometimes induce **"update anxiety"**—especially for newcomers migrating from Windows or Linux users who rely on their machine as a daily gaming and production driver.

A quick scan of community support forums reveals recurring pain points:
* **The "Is My System OK?" dilemma:** After an update or an unexpected freeze, users wonder: *Is my system healthy? Did everything compile? Are my services running?* Instead of forcing you to hunt through dozens of terminal commands, `sys-health` runs an automated, read-only 10-second audit that answers that question with unequivocal, traffic-light clarity.
* **Kernel & EFI mount desynchronization ("Kernel update leads to unbootable system / failure to mount /efi cleanly"):** If your ESP (EFI System Partition) is unmounted or mounted read-only during an update, new kernels get written to the root filesystem under the mountpoint. The bootloader never sees the new files, leaving you stranded at boot. `sys-health`'s **Guarded Upgrade** actively verifies ESP and `/boot` mount topology *before* transactions start, verifies multi-kernel DKMS builds for *all* installed kernels, and confirms bootloader entries before you reboot.
* **Dependency breaks & partial upgrade traps (e.g., `libpcap` conflicts / broken `.so` libraries):** Updating AUR packages or isolated programs while core repository updates are pending leads to broken shared library links. `sys-health` protects package consistency: it detects database locks (`db.lck`) using `fuser`, enforces atomic upgrade ordering, and alerts you to pending Arch News manual interventions before touching a package.
* **The dead laptop mid-upgrade disaster:** A kernel update interrupted by a dying battery is one of the quickest ways to corrupt an initramfs or filesystem. `sys-health` probes hardware ACPI power supplies and refuses heavy upgrades on battery power when charge is critically low (< 25%).

---

## Who Is This For?

### 1. For Linux Beginners & Windows Migrants
* **Zero elitism, zero jargon overload:** You do not need to memorize 25 arcane `systemctl`, `journalctl`, `pacman`, or `dkms` commands.
* **Strict "Do No Harm" policy:** The audit mode is 100% read-only. It never modifies, uninstalls, or cleans anything without clear, human-readable explanations and explicit confirmation.
* **Guarded 1-Click upgrades:** Takes the fear out of updating. A pre-flight safety check ensures your network, disk margins, and boot partitions are ready, runs the update, and immediately verifies that your graphics drivers and kernels compiled properly.

### 2. For Linux Veterans, Packagers & Systems Engineers
* **SRE-grade rigor:** Built strictly on zero-assumptions architecture. It does not guess your setup: it dynamically detects your bootloader (`systemd-boot`, `GRUB`, `Limine`, `rEFInd`, or `UKI`), your initramfs generator (`dracut` or `mkinitcpio`), your GPU stack (NVIDIA proprietary/open, AMD RADV, Intel Arc Xe), and session type (Wayland vs. X11).
* **Hardened file integrity:** Filters noisy ephemeral false-positives (`tmpfs`, `/tmp`, `/var/run`) during `pacman -Qk` checks to catch real binary/library corruption.
* **Upstream alignment:** Honors official Arch packaging standards, tracks unmerged `.pacnew` configuration files, and scrapes official Arch Security Tracker CVEs.

### 3. For AI-Assisted Workstations (Goose, Claude Code, Aider, Local LLMs)
* **The Token Economic Advantage:** When asking an AI agent "Why is my system stuttering?" or "Diagnose my PC", the agent usually executes 15–25 separate shell commands, dumping **15,000 to 45,000 raw tokens** into its context window. This exhausts context budgets, causes hallucinated diagnostics, and costs real money.
* **The `sys-health` Telemetry Solution:** Running `sys-health --json` executes local deterministic Bash probes in ~2 seconds and produces a tightly structured JSON summary (~40 lines, **under 500 tokens**).
* **~95%+ Token Reduction:** Gives your AI assistant instant, ground-truth context with zero hallucination at a fraction of the API cost.

```text
Traditional AI CLI Session:
[Agent runs 20 shell commands] ──> ~25,000 - 40,000 raw tokens ($$$ & slow)

sys-health AI Session:
[Agent runs 'sys-health --json'] ─> ~450 tokens structured JSON (Instant & cheap)
```

---

## Core Features

### 1. Comprehensive Health Audit (Read-Only)
* **Universal Multi-Bootloader Verification (v2.14):** Automatically identifies active bootloader (`systemd-boot`, `GRUB`, `Limine`, `rEFInd`, or standalone `UKI`) and validates that boot configurations, loader entries, and EFI binaries exist and are populated.
* **ESP & Mount Topology Integrity (v2.14):** Inspects `/etc/fstab` and `findmnt` to ensure the EFI System Partition (`/efi`, `/boot/efi`, or `/boot`) is actively mounted and writable, with sufficient free headroom (> 100 MB).
* **Multi-Kernel & DKMS Synchronization:** Audits every installed kernel series (`linux`, `linux-lts`, `linux-zen`), ensuring matching kernel headers, module directories, and compiled DKMS modules exist for each.
* **Accurate Pending Reboot Detection:** Inspects physical kernel module directories (`/usr/lib/modules/$(uname -r)`), eliminating false positives from upstream package timestamp preservation.
* **Crash & Unclean Shutdown Forensics:** Inspects previous boot journals and `systemd-fsck` recovery flags to detect dirty unmounts, power loss, or hard system freezes.
* **Hardware, Thermals & GPU Health:** Real-time driver checks (NVIDIA, AMD, Intel), Xorg fliplock stalls, kernel Xid errors, CPU thermals (`lm_sensors`), disk SMART attributes (`smartctl`), and SSD TRIM timer status (`fstrim.timer`).
* **Storage, Services & SysRq:** Root filesystem free space thresholds, failed systemd units (system and user sessions), and Magic SysRq emergency recovery validation (`kernel.sysrq`).
* **Network & Gateway Diagnostics:**
  * Active route and physical interface link state (`operstate == up`).
  * Real-time gateway ICMP round-trip latency and jitter (IPv4/IPv6).
  * Hardware NIC error counters (`rx_errors`, `tx_errors`, `rx_crc_errors`).
  * Link speed degradation detection (alerts if a gigabit/multi-gigabit NIC negotiates down to `<= 100 Mbps`).
  * **Accidental Metered Connection Gotcha:** Detects hidden NetworkManager metering flags that throttle background downloads.
  * Orphan VPN DNS resolver leak detection in `/etc/resolv.conf`.
  * DNS query latency benchmarking (`dig`).
* **Security & Package Integrity:**
  * Pacman lockfile inspection with active process holder identification via `fuser`.
  * Ephemeral-filtered package integrity checking (`pacman -Qk`).
  * Unmerged configuration file detection (`.pacnew`).
  * Mirror sync freshness tracking (`core.db`).
  * Upstream **Arch News** multi-item scraper matching manual intervention advisories against locally installed packages (`pacman -Qq`).
  * Official Arch Security Tracker (`arch-audit`) integration, separating actionable repository fixes from unclosed upstream backlog.

### 2. Guarded System Upgrade (Pre-Flight → Update → Post-Audit, v2.14)
Eliminates rolling-release upgrade friction through a disciplined 3-phase workflow:
* **Phase 1: Pre-Flight Safety Gates:**
  1. *Privilege & Session Gate (Gate 0):* Validates sudo authentication with automated background keepalive; blocks running raw as root.
  2. *Laptop Battery Gate (Gate 0):* Detects ACPI battery power; refuses upgrades on discharging laptops below 25% battery.
  3. *Substrate & Mount Topology Gate (Gate 1):* Confirms ESP and `/boot` are mounted and writable; enforces safe disk margins (6 GB root, 4 GB pacman cache, 100 MB ESP).
  4. *Package Manager Safety Gate (Gate 2):* Verifies no background daemons hold `db.lck` and checks database consistency (`pacman -Dk`).
  5. *Network & Mirror Freshness Gate (Gate 3):* Verifies TLS/DNS reachability to official infrastructure and offers 1-click regional mirror ranking (`reflector` / `eos-rankmirrors`) if lists are older than 30 days.
  6. *Arch News Human Intervention Gate (Gate 4):* Scans news feeds for manual interventions affecting installed packages.
  7. *Hardware & DKMS Gate (Gate 5):* Checks GPU driver invariants (e.g., legacy Maxwell GTX 970 vs modern drivers), kernel header completeness across all installed kernels, and pending reboots.
* **Phase 2: Distribution Upgrade:**
  Executes the canonical distribution package manager (`eos-update`, `yay`, `paru`, or `pacman`).
* **Phase 3: Post-Flight Integrity Verification:**
  1. *Multi-Kernel DKMS Validation:* Confirms modules compiled cleanly for every installed kernel series.
  2. *Boot Image Sanity:* Verifies initramfs and kernel images exist, are parseable (`lsinitrd`/`lsinitcpio`), and have realistic sizes.
  3. *Bootloader Integrity:* Validates that boot entries (GRUB menuentries, systemd-boot loader configs, UKI images) remain intact.
  4. *Disaster Recovery Hints:* Emits immediate, context-aware recovery commands if boot inconsistencies are detected.
  5. *Post-Upgrade Housekeeping:* Refreshes systemd daemons, clears stale locks, and provides `.pacnew` merging prompts.

### 3. Dynamic Performance Flight Recorder (`--sample`)
A zero-dependency, live performance sampling flight recorder designed to run **without root/sudo** for real-time stutter, frame drop, or network jitter triage:
* **Linux Kernel PSI (Pressure Stall Information):** Evaluates exact microsecond deltas from `/proc/pressure/{cpu,memory,io}` to quantify task starvation and detect I/O or memory thrashing.
* **GPU Dynamics & VRAM Bottleneck Detection:** Inspects live GPU utilization, clocks, P-States, and thermals. Specifically audits architectural memory boundaries (e.g. GTX 970 3.5 GB high-speed VRAM segment).
* **Gateway Jitter & Packet Loss:** Measures live ICMP round-trip latency (`min/avg/max/mdev`) and packet loss to your local gateway alongside physical NIC error counters.

### 4. Gaming & Steam Readiness Suite (`--gaming`)
* **Multilib Repository Validation:** Verifies `[multilib]` is active in `/etc/pacman.conf` (required for 32-bit Wine/Proton games).
* **32-bit Vulkan & Driver Stack:** Validates 64-bit and 32-bit Vulkan ICD loaders and driver stacks (`lib32-vulkan-icd-loader`, `lib32-nvidia-utils` / `lib32-vulkan-radeon`), preventing silent game launch crashes.
* **Proton Memory Pools & Descriptors:** Verifies `vm.max_map_count >= 1048576` (crucial for Unreal Engine 5 and modern Proton titles) and soft file descriptor headroom (`ulimit -Sn`).
* **Kernel Synchronization Primitives (`fsync` / `futex2`):** Live userspace syscall probe testing `futex_waitv` (syscall 449) availability for direct kernel synchronization without Wineserver IPC bottlenecks.
* **Kernel Split-Lock Mitigation:** Audits `/proc/sys/kernel/split_lock_mitigate` and correlates live kernel log events (`journalctl -k`) to detect 10ms execution penalties causing in-game micro-stutter.
* **GameMode & Compositor Readiness:** Verifies Feral GameMode daemon lifecycle (`gamemoded -t`), D-Bus activation, CPU frequency governors, and X11/Wayland compositor unredirection.
* **Steam Runtimes:** Detects custom Proton compatibility tools (e.g. `GE-Proton`).

### 5. Standalone & Third-Party Software Updates Hub (`--software`)
Bridges the gap for software installed outside distribution repositories:
* **Dynamic, Context-Aware Action UI:** Builds update menus dynamically—only tools with confirmed, pending updates are presented.
* **Binary Ownership Protection (`is_pacman_owned`):** Blocks standalone updaters from overwriting packages managed by `pacman`, protecting package database integrity and preventing shim corruption (`pyenv`, `asdf`, `cargo`).
* **Partial Upgrade Shield:** Warns and prompts if AUR updates are attempted while core Arch repository updates are pending, preventing `.so` library mismatches.
* **Supported Ecosystems:**
  * **Goose AI Assistant:** Live local version vs. GitHub releases with 1-click update.
  * **UV Python Toolchain:** Safe dry-run check with 1-click `uv self update`.
  * **AUR Packages:** Filtered line-structure validation via `yay -Qua` or `paru -Qua`.
  * **Steam & Flatpak:** Differentiates self-managed game client runtimes and containerized apps.

### 6. SRE Safe Maintenance & Deep Clean (`--maintenance`)
* **Reclaimable Space Preview:** Accurately calculates estimated reclaimable space before deleting a single file.
* **Active Browser Process Protection:** Inspects running Firefox or Chromium processes (`pgrep`). Skips browser cache cleaning during active sessions to prevent SQLite WAL corruption, lost tabs, or session restore loss.
* **Strict Shader Cache Blacklist:** Hardcoded blacklist permanently safeguarding graphics shader caches (`~/.nv`, `~/.cache/nvidia`, `~/.cache/mesa_shader_cache`, Steam shader pre-caches, DXVK caches), eliminating post-cleanup in-game stutter.
* **Offline Rollback Lifeline:** Prunes package cache retaining the last 2 versions of installed packages, while retaining **at least 1 version of uninstalled packages** (`paccache -r -u -k 1`), preserving emergency offline rollback capabilities.
* **FreeDesktop Trash & Journal Clean:** Native `gio trash --empty` and safe systemd journal vacuuming (> 14 days).

---

## Comparison: Archcanary vs. Arch System Health

| Feature | **Archcanary** | **Arch System Health & Diagnostics** |
| :--- | :--- | :--- |
| **Primary Focus** | **Malware & threat detection** | **System hygiene, boot substrate diagnostics, multi-kernel audits & guarded upgrades** |
| **Detection Scope** | AUR supply-chain attacks, blacklisted hashes, trojans, RATs, suspicious eBPF | Multi-kernel boot integrity, ESP/EFI mounts, DKMS per kernel, fliplock/GPU lockups, systemd units, NIC errors, gateway ping, DNS latency, `.pacnew`, Arch News, CVE audit |
| **Execution Mode** | Read-Only security scan | **Read-Only audit by default** + optional guarded upgrades & maintenance |
| **Safety Guardrails** | Passive inspection | Active browser process locks, partial upgrade protection, shader cache preservation, laptop battery checks, fuser DB locks |
| **AI Integration** | None | Generates machine-readable `summary.json` and snapshots for AI agents (~95% token savings) |

Both tools complement each other: Archcanary verifies package security against malicious threat actors, while Arch System Health keeps your operating system stable, transparent, and easy to maintain.

---

## Prerequisites & Installation

### Required Packages
```bash
sudo pacman -S gum iproute2 iputils psmisc glib2
```
* `gum` (charmbracelet's tool for the interactive terminal UI)
* `iproute2`, `iputils` (for network interface, routing, and ICMP diagnostics)
* `psmisc` (provides `fuser` for database lock safety)
* `glib2` (provides `gio` for compliant trash emptying)

### Recommended for Full Functionality
```bash
sudo pacman -S pacman-contrib arch-audit bind lm_sensors smartmontools
```
* `bind` (provides `dig` for DNS latency tests)
* `pacman-contrib` (provides `paccache` and `checkupdates`)
* `arch-audit` (provides official Arch CVE security auditing)
* `lm_sensors`, `smartmontools` (for hardware temperatures and disk SMART health)

### Quick Start
Clone the repository and run:
```bash
git clone https://github.com/YOUR_USERNAME/sys-health.git
cd sys-health
chmod +x sys-health.sh

# Run interactive TUI:
./sys-health.sh
```

*(Optional)* Create a symlink in your PATH:
```bash
mkdir -p ~/.local/bin
ln -s "$(pwd)/sys-health.sh" ~/.local/bin/sys-health
```

---

## Usage & CLI Reference

### 1. Interactive Terminal UI (TUI)
Simply launch `sys-health`:
```bash
sys-health
```

### 2. Automated & AI Agent CLI Modes (Headless Execution)
All non-interactive flags output plain text or structured JSON, perfect for scripts, cron jobs, and AI coding assistants:

| Command | Description |
| :--- | :--- |
| `sys-health --audit` (or `-a`) | Run read-only health audit and refresh telemetry files.<br>*Exit codes: 0 = ALL_CLEAR, 1 = ACTION_REQUIRED, 2 = REVIEW_WARNINGS* |
| `sys-health --upgrade` (or `-u`) | Run the 3-phase guarded system upgrade (Pre-Flight → Update → Post-Audit). |
| `sys-health --software` | Audit standalone & third-party updates (AUR, Goose, UV, Flatpak). |
| `sys-health --software --json` | Output standalone software status in structured JSON. |
| `sys-health --gaming` (or `-g`) | Run gaming and Steam readiness audit. |
| `sys-health --sample [SECS]` | Dynamic performance flight recorder (live PSI, GPU, gateway ping, zero sudo). |
| `sys-health --sample 3 --json` | Dynamic performance flight recorder in pure JSON for AI assistants. |
| `sys-health --json` (or `-j`) | Output latest summary telemetry JSON to stdout. |
| `sys-health --snapshot` (or `-s`)| Output complete software and driver state snapshot. |
| `sys-health --report` (or `-r`) | Output full plain-text audit report log. |
| `sys-health --maintenance` (or `-m`)| Run safe maintenance non-interactively, then execute health audit. |
| `sys-health --deep-clean` (or `-d`)| Run safe deep cleaning non-interactively, then execute health audit. |

---

## Optional Configuration

Customize parameters without modifying the script by creating `~/.config/sys-health/sys-health.conf`:

```bash
# Custom host for DNS resolution test (default: archlinux.org)
DNS_TEST_HOST="archlinux.org"

# Custom DNS resolver to test against (e.g. local router or pfSense IP)
DNS_TEST_SERVER="192.168.1.1"

# Skip time-consuming package file integrity check (0 = disabled, 1 = skip)
SKIP_INTEGRITY=0

# Custom fliplock warning threshold in Xorg.0.log (default: 10)
# FLIPLOCK_WARN_THRESHOLD=10
```

---

## Change Tracking & Roadmap

* Detailed release history and version migration notes are maintained in [CHANGELOG.md](CHANGELOG.md).
* Upcoming proposals, community backlog, and architectural discussions are tracked in [pending-patches.md](pending-patches.md).

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
