<img width="569" height="372" alt="image" src="https://github.com/user-attachments/assets/77598da6-9340-48b6-803f-17689cfb81f8" />
<img width="687" height="1099" alt="image" src="https://github.com/user-attachments/assets/e33c6eb1-d666-4ebb-9fa8-4a6da4f021c3" />

# Arch System Health & Diagnostics

[![Arch Linux](https://img.shields.io/badge/Arch%20Linux-Compatible-blue?logo=archlinux)](https://archlinux.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An interactive TUI diagnostic suite, system health audit, and AI-assisted troubleshooting report tool for **Arch Linux and Arch-based distributions** (EndeavourOS, Manjaro, CachyOS, etc.).

> **Disclaimer:** This is an independent, unofficial community project. It is **not** developed, maintained, or endorsed by the EndeavourOS team or Arch Linux. It is designed to assist users in understanding, inspecting, and maintaining their systems safely.

---

## Key Design Principles

1. **Safety & Non-Invasiveness First (Read-Only by default):**
   The primary action is a comprehensive system audit. It never modifies, uninstalls, or deletes anything without explicit, separated confirmation.
2. **Context for AI Agents (Agentic Handoff):**
   Produces structured, machine-readable diagnostic telemetry (`summary.json`, hardware/software snapshots) ready to feed directly into CLI AI assistants (Goose, Claude Code, Aider, local LLMs) for conservative, data-driven troubleshooting.
3. **No Guesswork for Rolling Releases:**
   Focuses on core Arch Linux failure points: out-of-sync kernels/modules, ESP/EFI mounts, DKMS builds, fallback initramfs integrity, pending reboot indicators, `.pacnew` tracking, upstream Arch News manual interventions, and CVE security auditing.

---

## Features

### 1. Comprehensive Health Audit (Read-Only)
* **Kernel & Modules:** Confirms running kernel modules match `/usr/lib/modules/$(uname -r)`.
* **Initramfs & Boot Integrity:** Verifies normal and fallback initramfs images across Dracut and Mkinitcpio configurations.
* **ESP / EFI Health:** Validates EFI system partition mount point (`/boot`, `/efi`, or `/boot/efi`) and checks for low free space (< 30 MB).
* **Superseded Kernel Detection:** Detects if `vmlinuz` was updated after boot, warning that a reboot is pending.
* **Crash & Unclean Shutdown Detection:** Inspects previous boot logs and filesystem journal recovery (`systemd-fsck`, unclean journald flags) to detect ungraceful power-offs and hard freezes.
* **Hardware, Thermals & GPU Lockup:** GPU driver runtime status (NVIDIA, AMD, Intel), Xorg fliplock stall / kernel Xid error monitoring, DKMS build status, CPU temperatures (`lm_sensors`), disk SMART health (`smartctl`), and SSD TRIM timer status (`fstrim.timer`).
* **Storage, Services & Recovery Keys:** Root disk space thresholds, failed systemd units (both system and user levels), and Magic SysRq emergency recovery validation (`kernel.sysrq`).
* **Package Management & Security:**
  * Pacman database stale lock detection (`db.lck`).
  * Package file integrity auditing (`pacman -Qk`).
  * Unmerged configuration files (`.pacnew`).
  * Mirrorlist freshness check (Arch and distribution mirrorlists).
  * Direct Arch News RSS feed check for required **manual interventions**.
  * Official Arch Security Tracker (`arch-audit`), clearly separating actionable repository fixes from unclosed upstream tracker backlog.
  * Installed foreign/AUR packages audit notice.

### 2. AI Agent Handoff (Structured Diagnostics)
Every health audit run automatically compiles:
* A structured, machine-readable **`summary.json`** located at `~/.local/state/system-health/summary.json`.
* An exportable **software state snapshot** (`software-state.txt`) capturing installed kernels, headers, GPU drivers, modules, and dracut/mkinitcpio configs.
* A one-click prompt ready to paste into AI coding assistants for conservative, context-aware diagnosis.

### 3. Safe System Maintenance (Optional)
* **Paccache management:** Keep the last 2 versions of installed packages, clean uninstalled cache with `paccache -r -u -k 0`.
* **AUR build cache cleanup:** Cleans unneeded build artifacts via `yay` or `paru`.
* **Systemd journal vacuuming:** Vacuums logs older than 14 days without wiping recent boot context.
* **Thumbnail cache cleanup:** Clears `$HOME/.cache/thumbnails`.
* **Optional Deep Clean:** Separate mode with explicit confirmation to clean Desktop Trash, browser caches (`cache2`), and stored coredumps.

---

## Comparison: Archcanary vs. Arch System Health

| Feature | **Archcanary** | **Arch System Health & Diagnostics** |
| :--- | :--- | :--- |
| **Primary Focus** | **Malware & threat detection** | **System hygiene, kernel/boot diagnostics & health audit** |
| **Detection Scope** | AUR supply-chain attacks, blacklisted hashes, trojans, RATs, suspicious eBPF | Boot/ESP, kernels, DKMS, journal & unclean shutdowns, GPU lockups/fliplock, SysRq, failed units, mirror freshness, `.pacnew`, Arch News, CVE audit |
| **Execution Mode** | Read-Only security scan | **Read-Only audit by default** + optional interactive maintenance |
| **Security Audit** | Known malicious AUR package feeds | Official Arch Security Tracker (`arch-audit`) for core/extra repos |
| **AI Integration** | None | Generates machine-readable `summary.json` and snapshots for AI agents |

Both tools complement each other: Archcanary verifies package security against malicious threat actors, while Arch System Health keeps your operating system stable, transparent, and easy to diagnose.

---

## Prerequisites

* **Required:**
  * `gum` (charmbracelet's tool for interactive terminal UI):
    ```bash
    sudo pacman -S gum
    ```
* **Recommended for full functionality:**
  * `pacman-contrib` (provides `paccache` and `checkupdates`)
  * `arch-audit` (provides CVE audit from security.archlinux.org)
  * `lm_sensors`, `smartmontools` (for temperatures and disk SMART health)
  * `figlet`, `lolcat` (for header banners)
  * `btop` (for live monitor)

---

## Usage

### 1. Interactive Terminal UI (TUI)
Run the script without arguments:
```bash
./system-health.sh
```
*(Prompts for `sudo` up front to authenticate for privileged checks and maintenance tasks).*

### 2. Automated & AI Agent CLI Modes (Non-Interactive)
The script supports headless execution designed for CLI AI agents (Goose, Claude Code, Aider), CI/CD pipelines, or cron scripts:

* **Non-interactive health audit & report generation:**
  ```bash
  ./system-health.sh --audit
  # Exit codes: 0 = ALL_CLEAR, 1 = ACTION_REQUIRED, 2 = REVIEW_WARNINGS
  ```
* **Output latest summary telemetry in JSON format:**
  ```bash
  ./system-health.sh --json
  ```
* **Output system software state snapshot:**
  ```bash
  ./system-health.sh --snapshot
  ```
* **Output full plain text audit log:**
  ```bash
  ./system-health.sh --report
  ```
* **Non-interactive safe maintenance followed by audit:**
  ```bash
  ./system-health.sh --maintenance
  ```

---

## Optional Configuration

You can customize behavior without modifying the script by creating `~/.config/system-health/system-health.conf` or `~/.config/system-health.conf`:

```bash
# Custom host for DNS resolution test (default: archlinux.org)
DNS_TEST_HOST="archlinux.org"

# Custom DNS resolver to test against (e.g. local router or pfSense IP)
# DNS_TEST_SERVER="192.168.1.1"

# Skip time-consuming package file integrity check (0 = disabled, 1 = skip)
SKIP_INTEGRITY=0
```

---

## License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

