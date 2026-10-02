# Arch System Health & Diagnostics (`sys-health`)

[![Arch Linux](https://img.shields.io/badge/Arch%20Linux-Compatible-blue?logo=archlinux)](https://archlinux.org/)
[![Version: 2.44](https://img.shields.io/badge/Version-2.44-orange.svg)](CHANGELOG.md)
[![Hermetic SRE Tests](https://img.shields.io/badge/SRE%20Tests-58%2F58%20Passing-brightgreen.svg)](dev-tools/test-suite.sh)
[![Changelog](https://img.shields.io/badge/Changelog-Keep%20a%20Changelog-brightgreen.svg)](CHANGELOG.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An interactive TUI diagnostic suite, deterministic system health auditor, guarded upgrade engine, and AI-assisted telemetry bridge for **Arch Linux and Arch-based distributions** (EndeavourOS, CachyOS, Manjaro, etc.).

> **Disclaimer:** This is an independent, unofficial open-source community project. It is **not** developed, maintained, or endorsed by the EndeavourOS team or Arch Linux. It is designed to assist users in understanding, inspecting, and maintaining their systems safely.

---

<img width="720" height="417" alt="image" src="https://github.com/user-attachments/assets/d3ea0be9-e044-4f09-a176-11be98f48247" />

<img width="724" height="1101" alt="image" src="https://github.com/user-attachments/assets/3427bd63-fbf6-4ad8-af2d-d39be90b8448" />

<img width="854" height="992" alt="image" src="https://github.com/user-attachments/assets/c4eea2c7-3c6e-4c12-bd7c-ef675be9297f" />

<img width="840" height="500" alt="image" src="https://github.com/user-attachments/assets/cb8841a2-aa71-4c80-959b-6c58c2b5dcad" />

---

## Why `sys-health`? (Real-World Rolling-Release Problems Solved)

Arch Linux and EndeavourOS deliver blistering speed, incredible flexibility, and bleeding-edge software. However, rolling releases can sometimes induce **"update anxiety"**—especially for newcomers migrating from Windows or Linux users who rely on their machine as a daily gaming and production driver.

A quick scan of community support forums reveals recurring pain points:
* **The "Is My System OK?" dilemma:** After an update or an unexpected freeze, users wonder: *Is my system healthy? Did everything compile? Are my services running?* Instead of forcing you to hunt through dozens of terminal commands, `sys-health` runs an automated, read-only 10-second audit that answers that question with unequivocal, traffic-light clarity.
* **Kernel & EFI mount desynchronization ("Kernel update leads to unbootable system / failure to mount /efi cleanly"):** If your ESP (EFI System Partition) is unmounted or mounted read-only during an update, new kernels get written to the root filesystem under the mountpoint. The bootloader never sees the new files, leaving you stranded at boot. `sys-health`'s **Guarded Upgrade** actively verifies ESP and `/boot` mount topology *before* transactions start, verifies multi-kernel DKMS builds for *all* installed kernels, and confirms bootloader entries before you reboot.
* **The Silent Kernel-Bootloader Drift Trap ("I installed `linux-zen`, rebooted, but it is not in the boot menu"):** In Arch Linux, kernel packages trigger ALPM hooks that compile DKMS driver modules and generate initramfs images via dracut/mkinitcpio. However, Arch intentionally does *not* ship automated hooks to run `grub-mkconfig` (avoiding lengthy `os-prober` multi-drive scanning hangs during routine updates). The consequence: new kernels sit quietly on disk and DKMS builds cleanly, but the bootloader menu never receives them. `sys-health` detects this drift across the entire Arch bootloader ecosystem, warning you with actionable, distribution-accurate remediation commands before you reboot expecting a kernel that cannot be launched.
* **Dependency breaks & partial upgrade traps (e.g., `libpcap` conflicts / broken `.so` libraries):** Updating AUR packages or isolated programs while core repository updates are pending leads to broken shared library links. `sys-health` protects package consistency: it detects database locks (`db.lck`) using `fuser`, enforces atomic upgrade ordering, and alerts you to pending Arch News manual interventions before touching a package.
* **The "Blind Orphan Purge" Trap (`pacman -Qtdq` vs Reality):** Arch elitists often chant the dogma: *"Just blindly run `pacman -Rns $(pacman -Qtdq)`—if you don't know what you have installed, you shouldn't use Arch!"* In reality, unguided orphan deletion is an operational hazard:
  1. `pacman -Qtd` flags all unrequired dependencies—including critical **optional dependencies** (`Optional For:`) that provide features in everyday applications (e.g., Dolphin losing video thumbnails, GIMP losing RAW plugins).
  2. It flags build toolchains (`rust`, `cargo`, `go`, `base-devel`, kernel headers) pulled during AUR compilations. Blindly removing them turns the next update into a 2-hour rebuild or breaks DKMS driver compilation.
  3. Purists overlook that `pacman -Rns` **does not purge downloaded package archives from the cache** (`/var/cache/pacman/pkg`)! The uninstalled software leaves dead `.pkg.tar.zst` files rotting on disk indefinitely.
  `sys-health` eliminates this guesswork with an offline 3-tier safety classifier (`classify_orphan_tier`), pre-flight SRE cascade inspection (`audit_orphan_cascade`), dual removal strategies (Target-Only `pacman -R` with zero cascade blast-radius vs. SRE-guarded `pacman -Rs`), safe `.pacsave` preservation, 1-click explicit dependency protection (`pacman -D --asexplicit`), and separately confirmed cache maintenance.
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
* **Universal Multi-Bootloader & Kernel Synchronization (`check_bootloader_sync`):** Dynamically cross-references active bootloader configurations against all installed kernel families (`/usr/lib/modules/*/pkgbase`). Supports **GRUB**, **systemd-boot**, **Limine**, **rEFInd** (with auto-discovery awareness), and standalone **UKI** (Unified Kernel Images). Features non-root privilege boundary safety (cleanly handles `0600` permissions via `sudo -n` with informative `INFO ℹ` guidance instead of false alarms), boundary-safe regex matching, and actionable remediation (`BOOTLOADER_KERNEL_DESYNC`).
* **ESP & Mount Topology Integrity:** Inspects `/etc/fstab` and `findmnt` to ensure the EFI System Partition (`/efi`, `/boot/efi`, or `/boot`) is actively mounted and writable, with sufficient free headroom (> 100 MB).
* **Multi-Kernel & DKMS Synchronization:** Audits every installed kernel series (`linux`, `linux-lts`, `linux-zen`), ensuring matching kernel headers, module directories, and compiled DKMS modules exist for each.
* **Accurate Pending Reboot Detection:** Inspects physical kernel module directories (`/usr/lib/modules/$(uname -r)`), eliminating false positives from upstream package timestamp preservation.
* **Crash & Unclean Shutdown Forensics:** Inspects previous boot journals and `systemd-fsck` recovery flags to detect dirty unmounts, power loss, or hard system freezes.
* **Runtime CPU Early Microcode Verification (`check_cpu_microcode`):** Interrogates `/sys/devices/system/cpu/cpu0/microcode/version` and early kernel logs (`journalctl -b 0 -k`), detecting runtime early microcode injection (e.g. `Intel early update: 0x1e ➔ 0x28`) and unpatched BIOS states. Gracefully accommodates virtual machines (`KVM`, `QEMU`, `Proxmox`, `VMware`) and containers (`PASS ✔ [VM guest - host managed]`).
* **Hardened Hardware, Thermals & GPU Diagnostics (`check_gpu`, `check_gpu_errors`, `check_dkms`, `check_smart`, `check_power`, `check_fstrim`):**
  * Universal 4-digit PCI domain delimitation (`0000:xx:xx.x`), preventing audio/network controller leakage into GPU driver states.
  * Real-time GPU driver telemetry (NVIDIA proprietary/legacy, AMD RADV, Intel Arc Xe with GuC initialization noise immunity).
  * Freshness-guarded Xorg fliplock inspection validated against current system boot time (`btime`).
  * Multi-kernel DKMS headers audit across all installed kernel directories (`/usr/lib/modules/*/pkgbase`).
  * Low-power HDD spin-down standby preservation (`smartctl -n standby`) and graceful VirtIO block device degradation (`/dev/vda`).
  * Hybrid SSD + HDD storage awareness for TRIM timer validation, ignoring spinning mechanical disks lacking discard.
  * Multi-battery laptop power telemetry (e.g. ThinkPad Power Bridge BAT0 + BAT1).
* **Audio Subsystem, DSP Firmware & WirePlumber Stack (`check_audio`):** Audits sound cards via ALSA `/proc/asound/cards` and PCI enumeration. Proactively inspects kernel logs for missing digital signal processor (DSP) firmware (`sof-firmware`, `alsa-ucm-conf`) common on modern Intel (10th-15th gen) and AMD laptops. Features a cross-privilege user session bridge (`sudo` -> PipeWire/PulseAudio/WirePlumber) and flags stalled Dummy Output (`auto_null`) devices.
* **Storage, Services & SysRq:** Root filesystem free space thresholds, failed systemd units (system and user sessions), emergency read-only mount detection (`ro`), and Magic SysRq emergency recovery validation (`kernel.sysrq`).
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
  * **Dynamic Mirrorlist Health & Latency Probe:** Interrogates active mirrorlist topologies resolved recursively from `pacman.conf` `Include =` directives (eliminating false readings from inactive files). Measures real-time TTFB latency to primary repositories (`curl`), natively accommodates local `file://` repositories, detects dead or hanging primary mirrors (preventing package download socket timeouts), warns on cross-continental high latency (> 400ms), and audits mirrorlist redundancy and age.
  * **Smart Arch News Correlator:** Proactively scrapes upstream Arch News with HTTP 429 rate-limiting resilience and local caching, correlating manual intervention advisories against locally installed packages (`pacman -Qq`) to eliminate false-positive alarm fatigue.
  * Official Arch Security Tracker (`arch-audit`) integration, separating actionable repository fixes from unclosed upstream backlog.

### 2. Guarded System Upgrade (Pre-Flight → Update → Post-Audit)
Eliminates rolling-release upgrade friction through a disciplined 3-phase workflow:
* **Phase 1: Pre-Flight Safety Gates:**
  1. *Privilege & Session Gate (Gate 0):* Validates sudo authentication with automated background keepalive; blocks running raw as root.
  2. *Laptop Battery Gate (Gate 0):* Detects ACPI battery power; refuses upgrades on discharging laptops below 25% battery.
  3. *Substrate & Mount Topology Gate (Gate 1):* Confirms ESP and `/boot` are mounted and writable; enforces safe disk margins (6 GB root, 4 GB pacman cache, 100 MB ESP).
  4. *Package Manager Safety Gate (Gate 2):* Verifies no background daemons hold `db.lck` and checks database consistency (`pacman -Dk`).
  5. *Network & Mirror Resilience Gate (Gate 3):* Verifies control-plane TLS/DNS connectivity via a multi-endpoint high-availability fallback pool (`archlinux.org`, `1.1.1.1`, `cloudflare.com`), probes primary mirror reachability, and triggers smart self-healing ranking (`reflector` / `rate-mirrors` / `eos-rankmirrors`) if the primary mirror is dead (preventing fatal socket timeouts), if the mirrorlist is empty/corrupt, if cross-continental latency exceeds 800ms, or if lists are older than 30 days. Employs 100% dynamic universalism across distribution ecosystems (Arch x86_64, EndeavourOS, CachyOS multi-file transactions, Manjaro, Artix, ALARM ARM-gate) with atomic staging and unique per-run backup rollback protection (`.sys-health-bak.$$.$RANDOM`).
  6. *Smart Arch News Correlator Gate (Gate 4):* Automatically correlates upstream manual intervention alerts with locally installed packages (`pacman -Qq`). Advisories for uninstalled software are transparently acknowledged without halting the workflow, reserving interactive prompts exclusively for actionable system threats.
  7. *Hardware & DKMS Gate (Gate 5):* Checks GPU driver invariants across legacy branches (Maxwell, Kepler, `nvidia-580xx`, `nvidia-470xx`, `nvidia-390xx` vs modern open/proprietary drivers), kernel header completeness across all installed kernels, and pending reboots.
* **Phase 2: Distribution Upgrade:**
  Executes the canonical distribution package manager (`eos-update`, `yay`, `paru`, or `pacman`).
* **Phase 3: Post-Flight Integrity Verification:**
  1. *Multi-Kernel DKMS Validation:* Confirms modules compiled cleanly for every installed kernel series.
  2. *Boot Image Sanity:* Verifies initramfs and kernel images exist, are parseable (`lsinitrd`/`lsinitcpio`), and have realistic sizes.
  3. *Bootloader & Kernel Synchronization:* Validates that boot entries and configurations (GRUB menuentries, systemd-boot loader configs, UKI images) actively include all installed kernel versions, preventing post-upgrade bootloader drift.
  4. *Disaster Recovery Hints:* Emits immediate, context-aware recovery commands if boot inconsistencies are detected.
  5. *Post-Upgrade Housekeeping:* Refreshes systemd daemons, clears stale locks, and provides `.pacnew` merging prompts.

### 3. Dynamic Performance Flight Recorder (`--sample`)
A zero-dependency, live performance sampling flight recorder designed to run **without root/sudo** for real-time stutter, frame drop, or network jitter triage:
* **Linux Kernel PSI (Pressure Stall Information):** Evaluates exact microsecond deltas from `/proc/pressure/{cpu,memory,io}` to quantify task starvation and detect I/O or memory thrashing.
* **GPU Dynamics & VRAM Bottleneck Detection:** Inspects live GPU utilization, clocks, P-States, and thermals. Specifically audits architectural memory boundaries (e.g. GTX 970 3.5 GB high-speed VRAM segment).
* **Gateway Jitter & Packet Loss:** Measures live ICMP round-trip latency (`min/avg/max/mdev`) and packet loss to your local gateway alongside physical NIC error counters.

### 4. Gaming & Steam Readiness Suite (`--gaming`)
* **Multilib Repository Validation:** Verifies `[multilib]` is active in `/etc/pacman.conf` (required for 32-bit Wine/Proton games).
* **Universal Multi-GPU & 32-bit Driver Stack:** Validates 64-bit and 32-bit Vulkan ICD loaders and driver stacks dynamically across AMD Radeon (RADV/AMDVLK), Intel Arc/Xe (ANV), open-source NVIDIA (NVK/Nouveau), and proprietary NVIDIA (`lib32-vulkan-icd-loader`, `lib32-nvidia-utils`, `lib32-vulkan-radeon`, `lib32-vulkan-intel`, `lib32-vulkan-nouveau`). Seamlessly inspects hybrid laptop dual-GPU setups without false alarms.
* **Proton Memory Pools & Descriptors:** Verifies `vm.max_map_count >= 1048576` (crucial for Unreal Engine 5 and modern Proton titles) and soft file descriptor headroom (`ulimit -Sn`).
* **Kernel Synchronization Primitives (`fsync` / `futex2`):** Live userspace syscall probe testing `futex_waitv` (syscall 449) availability for direct kernel synchronization without Wineserver IPC bottlenecks.
* **Kernel Split-Lock Mitigation:** Audits `/proc/sys/kernel/split_lock_mitigate` and correlates live kernel log events (`journalctl -k`) to detect 10ms execution penalties causing in-game micro-stutter.
* **GameMode & Compositor Readiness:** Verifies Feral GameMode daemon lifecycle (`gamemoded -s`), D-Bus activation, CPU frequency governors, and X11/Wayland compositor unredirection.
* **GPU VRAM Telemetry:** Live hardware segment tracking (including Maxwell GTX 970 3.5GB fast segment preservation and universal modern NVIDIA/AMD VRAM pressure warnings).
* **Multi-Client Steam & Proton Runtimes:** Comprehensive discovery of custom Proton tools (e.g. `GE-Proton`, `Proton-TKG`) across native Steam, Flatpak Steam, Flatpak Heroic, Lutris wine runners, and system-wide AUR installations.

### 5. Standalone & Third-Party Software Updates Hub (`--software`)
Bridges the gap for software installed outside distribution repositories:
* **Dynamic, Context-Aware Action UI:** Builds update menus dynamically—only tools with confirmed, pending updates are presented.
* **Multi-Distro Binary Ownership Protection (`check_binary_ownership`):** Blocks standalone updaters from overwriting packages managed by `pacman`, foreign package managers (Homebrew, Nix), or runtime shims (`cargo`, `pyenv`, `asdf`, `mise`), protecting package database integrity and multi-boot shared `$HOME` environments.
* **Partial Upgrade Shield:** Warns and prompts if AUR updates are attempted while core Arch repository updates are pending, preventing `.so` library mismatches.
* **Supported Ecosystems:**
  * **Goose AI Assistant:** Live local version vs. GitHub releases with 1-click update.
  * **UV Python Toolchain:** Safe dry-run check with 1-click `uv self update`.
  * **AUR Packages:** Filtered line-structure validation via `yay -Qua` or `paru -Qua`.
  * **Steam & Flatpak:** Differentiates self-managed game client runtimes and containerized apps.

### 6. Dynamic Orphan Triage & Package Safety Engine (`--orphans`, `-o`)
Designed to demystify package maintenance and eliminate the operational hazards of blind orphan cleaning (Fully SRE Certified in v2.42 / PATCH-031):
* **3-Tier ALPM Safety Classification (`classify_orphan_tier`):** Interrogates local package metadata (`LC_ALL=C pacman -Qi`) in a single offline batch query (< 50ms):
  * 🟢 **Tier 1 (Strict Leaf Orphans):** Truly unreferenced packages (`pacman -Qdtq` set difference, `Optional For: None`). Selectable for safe removal.
  * 🟡 **Tier 2 (Optional-Only Dependencies):** Packages actively utilized as optional dependencies by installed software (`pacman -Qdttq` set difference). Surfaces exact reverse dependencies (e.g. `dolphin`, `vlc`, `xterm`) so you never lose desktop features unexpectedly. Excluded from default batch removal.
  * 🔴 **Tier 3 (Heuristically Sensitive Packages):** Flags critical system components across the entire Arch ecosystem (kernels, bootloaders, firmware, GPU drivers, PipeWire/ALSA audio, Wayland/KWin/Hyprland compositors, SDDM/GDM display managers, Btrfs/LVM/cryptsetup tools, polkit/PAM security, compiler toolchains, and multilib `lib32-*` gaming runtimes). Excluded from automatic removal and protected with caution warnings.
* **Pre-Flight SRE Cascade Audit (`audit_orphan_cascade`):** Interrogates transaction previews (`pacman -Rs -p --print-format '%n'`) to intercept unselected cascaded dependencies. Issues critical alerts if sensitive Tier 3 packages or reverse optional dependencies are pulled into the deletion tree.
* **Dual Removal Strategy Selection:**
  * **Target-Only (`pacman -R`) [Default / Recommended]:** Zero cascade blast radius — removes only explicitly chosen packages without touching any shared dependencies.
  * **Recursive Clean (`pacman -Rs`):** Removes target packages and unneeded dependencies, fully safeguarded by the pre-flight SRE cascade auditor.
  * *Note:* Modified configuration files are safely preserved with `.pacsave` extensions in both modes.
* **Separately Confirmed Cache Maintenance:** Cleanly decouples pacman package uninstallation from archive cache purging, offering an optional, explicitly previewed `paccache --uninstalled --keep 0` clean across all configured `CacheDir` paths.
* **1-Click Explicit Protection (`--asexplicit`):** Users frequently use unrequired tools directly (e.g., `git`, `htop`, `rust`). Rather than deleting and reinstalling, `sys-health` allows marking them as explicitly installed (`sudo pacman -D --asexplicit`), permanently resolving recurring orphan alerts.
* **Non-Interactive Batch Contract:** Safe read-only reporting with zero ALPM mutations and clean `exit 0` execution when running without an interactive terminal (TTY) or via `--batch` mode.
* **Pre-Flight Gate 2 Integration:** Non-intrusively notifies users during Guarded Upgrades if unrequired orphans are pending, preventing wasted download bandwidth and obsolete AUR rebuilds.

### 7. SRE Safe Maintenance & Deep Clean (`--maintenance`, `--deep-clean`)
* **Reclaimable Space Preview:** Accurately calculates estimated reclaimable space before deleting a single file.
* **Active Browser Process Protection:** Inspects running Firefox or Chromium processes (`pgrep`). Skips browser cache cleaning during active sessions to prevent SQLite WAL corruption, lost tabs, or session restore loss.
* **Strict Shader Cache Blacklist:** Hardcoded blacklist permanently safeguarding graphics shader caches (`~/.nv`, `~/.cache/nvidia`, `~/.cache/mesa_shader_cache`, Steam shader pre-caches, DXVK caches), eliminating post-cleanup in-game stutter.
* **Offline Rollback Lifeline:** Prunes package cache retaining the last 2 versions of installed packages, while retaining **at least 1 version of uninstalled packages** (`paccache -r -u -k 1`), preserving emergency offline rollback capabilities.
* **FreeDesktop Trash & Journal Clean:** Native `gio trash --empty` and safe systemd journal vacuuming (> 30 days).
* **On-Demand Regional Mirror Ranking:** Integrates 1-click regional mirror benchmarking and atomic ranking (`reflector` / `rate-mirrors` / `eos-rankmirrors` / `pacman-mirrors`) directly into the Safe Maintenance menu, with distribution-agnostic safety gates, multi-file CachyOS rollback coordination, and per-target transaction reporting (`UPDATED`, `FAILED`, `SKIPPED`).

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
| `sys-health --orphans` (or `-o`)| Run interactive 3-tier orphan package triage & zero-residue purger. |
| `sys-health --mirrors` | Benchmark, rank, and refresh fastest regional repository mirrors. |
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
* Authoritative SRE subsystem certifications, vulnerability hit-lists, and testing matrices are tracked in [AUDIT_MATRIX.md](AUDIT_MATRIX.md).
* Upcoming proposals, community backlog, and architectural discussions are tracked in [DEVELOPMENT_PROPOSALS.md](DEVELOPMENT_PROPOSALS.md) (also available as [pending-patches.md](pending-patches.md)).

### Hermetic SRE Regression Suite (`dev-tools/test-suite.sh`)
Every release, bugfix, and patch blueprint must pass the hermetic test suite before merge:
```bash
./dev-tools/test-suite.sh
```
* **100% Mocked Roots:** Executes in isolated sandboxes (`SYS_HEALTH_ROOT`) without host mutations.
* **Coverage:** 58 deterministic assertions across 13 test suites covering Arch canonical paths, Manjaro versioned kernels, multi-initrd microcodes, systemd-boot (BLS Type #1), UKI (Type #2), Dracut, Booster, DAC permission boundaries, Safe Deep Clean, ALPM Orphan Cascade Protection, checkupdates error resilience & core package parity, and Universal Multi-GPU Gaming Readiness.

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.
