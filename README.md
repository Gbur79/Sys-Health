# eos-cleaner

A fast, safe, and terminal-driven maintenance tool for **EndeavourOS / Arch Linux**. 

`eos-cleaner` combines safe package cache cleanup with a comprehensive TUI system health dashboard built with `gum`. It also exports an ultra-compact JSON health report designed specifically for AI system administration agents (like Google Antigravity or Goose CLI) to analyze problems without burning through API tokens.

---

## Key Features

* **Safe Maintenance:** Cleans pacman & AUR caches (retaining the last 2 versions), vacuums systemd journal logs (>14 days), and clears thumbnail/trash data.
* **Structured TUI Dashboard:** Grouped health status reporting across 4 core areas:
  * **Boot & Core OS:** Kernel validation, ESP (`/boot/efi`) free space, and reboot indicators.
  * **Hardware & Drivers:** NVIDIA driver runtime status, DKMS module builds, CPU temperatures, and SMART disk health.
  * **System Health & Services:** Root disk space, pacman DB locks, `.pacnew` files, and failed systemd units (both `system` and `user` level).
  * **Network & Updates:** DNS gateway latency, pending updates, and mirrorlist age checks.
* **AI Agent Handoff (JSON Export):** Automatically exports a token-optimized JSON summary (`~/.local/state/eos-cleaner/eos-health-report.json`) containing zero ANSI bloat, tailored for direct feeding into LLMs.

---

## Dependencies

The script automatically prompts to install `gum` via pacman if it is missing.

* `gum` (TUI interface)
* `pacman-contrib` (for `paccache`)
* `smartmontools` (for SMART disk checks)
* `bind` (for `dig` DNS checks)

---

## Quick Start

Run the following commands in your terminal:

```bash
# Clone the repository
git clone [https://github.com/Gbur79/eos-cleaner.git](https://github.com/Gbur79/eos-cleaner.git)

# Navigate to directory
cd eos-cleaner

# Make the script executable
chmod +x eos-cleaner.sh

# Run the cleaner
./eos-cleaner.sh


AI Agent Integration

After running a Health Check, feed the generated JSON file directly to your AI Assistant:
Plaintext

Read the EOS Health report at:
~/.local/state/eos-cleaner/eos-health-report.json

Analyze any reported warnings or errors. Propose minimal, safe, and reversible commands to fix confirmed issues.

License

MIT License. Free for community use and modification.
