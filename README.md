<img width="708" height="1067" alt="EOS Cleaner & System Health UI" src="https://github.com/user-attachments/assets/3e349a4a-a570-43d8-9aee-de5ef588e01c" />

# EOS Cleaner & System Health

A conservative maintenance toolkit and automated system health auditor for **EndeavourOS** and **Arch Linux**, featuring an interactive terminal UI and structured diagnostics designed for both human review and AI agents.

Unlike aggressive cleaning tools that blindly wipe packages and configurations, EOS Cleaner is built strictly around the official **[Arch Wiki: System Maintenance Guidelines](https://wiki.archlinux.org/title/System_maintenance)**. It prioritizes system stability, rollback capabilities, and actionable diagnostics over reclaiming every last byte.

---

## Key Features

* **Strict Safety & Rollback Protection:** 
  * Keeps the last two versions of installed packages in cache (`paccache -k 2`) so you can always roll back.
  * Preserves official pacman package cache when pruning AUR build files (`yay -Sc --aur` / `paru -Sc --aur`).
* **Deep Diagnostic Audit:**
  * **Boot & Core:** Verifies kernel modules directory matching `uname -r`, initramfs integrity (normal + fallback images), ESP mount health, and checks if a reboot is pending after a kernel update.
  * **Hardware & Drivers:** GPU runtime verification (NVIDIA / AMD / Intel), DKMS build status, CPU temperatures, SMART disk health (filters out virtual `zram`/`loop` devices), and SSD TRIM timer status.
  * **System & Services:** Real-time pacman DB lock inspection, package file integrity (`pacman -Qk`), orphaned `.pacnew` / `.pacsave` detection, and failed system/user systemd units.
  * **Network & Security:** DNS resolution latency test, available updates highlighting sensitive core components, mirrorlist age check, automated Arch Linux News feed parsing (flags *manual intervention* alerts), and vulnerability scans via `arch-audit`.
* **AI Agent Handoff:** Generates machine-readable summaries (`summary.json`) and comprehensive software snapshots (`eos-software-state.txt`) ready to feed directly into LLMs (Goose, Antigravity, Claude, ChatGPT) for safe troubleshooting.

---

## Dependencies

The script utilizes standard system utilities. While `gum` is required for the interactive UI (the script will ask before installing it), the following packages provide full diagnostic coverage:

```bash
sudo pacman -S --needed gum pacman-contrib jq bind smartmontools lm_sensors arch-audit
```

*Optional terminal monitors for live inspection:* `btop` or `glances`.

---

## Installation

Download the script to your local user `~/bin` directory and make it executable:

```bash
mkdir -p ~/bin
curl -fsSL https://raw.githubusercontent.com/Gbur79/eos-cleaner/main/eos-cleaner.sh -o ~/bin/eos-cleaner.sh
chmod +x ~/bin/eos-cleaner.sh
```

Ensure `~/bin` is in your `PATH` (default on EndeavourOS). You can then run it anytime via:

```bash
eos-cleaner.sh
```

---

## Add to Application Menu (Optional)

To integrate EOS Cleaner into your desktop application launcher (KDE Plasma, GNOME, XFCE, etc.), run the following command. It uses standard XDG categories:

```bash
mkdir -p ~/.local/share/applications
cat << 'EOF' > ~/.local/share/applications/eos-cleaner.desktop
[Desktop Entry]
Version=1.1
Type=Application
Name=System Maintenance & Repair
GenericName=System Health & Diagnostics
Comment=Interactive system cleanup and health audit
Exec=bash -ic "$HOME/bin/eos-cleaner.sh"
Icon=utilities-system-monitor
Terminal=true
Categories=System;Monitor;
StartupNotify=false
EOF
```

---

## Operating Modes

1. **Standard Clean & Health:**
   * Prunes pacman cache keeping the last 2 versions (`paccache -r -k 2`).
   * Clears cache of uninstalled packages (`paccache -r -u -k 0`).
   * Safely clears AUR build cache via `yay`/`paru`.
   * Vacuums systemd journal older than 14 days.
   * Clears thumbnail cache.
   * Executes the full system health audit.
2. **Deep Clean & Health:**
   * Includes everything from Standard Clean.
   * Empties Desktop Trash (including hidden files).
   * Safely clears browser disk caches (Firefox, Chromium).
   * Clears stored system coredumps (`coredumpctl clear`).
   * Executes the full system health audit.
3. **Health Check Only:**
   * Runs the complete diagnostic suite without altering any files or caches.
4. **AI Agent Handoff:**
   * Formats a ready-to-copy context prompt pointing to diagnostic logs, state snapshots, and JSON status.
5. **Live Monitor:**
   * Launches `btop` or `glances` for real-time performance and thermals monitoring.

---

## License

MIT License. Free to use, modify, and distribute.
```
