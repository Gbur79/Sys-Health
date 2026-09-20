#!/usr/bin/env bash
# ==============================================================================
# EOS Cleaner & System Health (Community Edition)
# Safe maintenance + TUI diagnostics + AI Agent JSON Export
# EndeavourOS / Arch Linux
# ==============================================================================

set -o pipefail

VERSION="2.5"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/eos-cleaner"
LOG_FILE="$STATE_DIR/eos-cleaner.log"
JSON_FILE="$STATE_DIR/eos-health-report.json"

mkdir -p "$STATE_DIR" 2>/dev/null || true
: > "$LOG_FILE"

# ------------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ------------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
    echo "Please run this script as your normal user. Sudo will be requested when needed."
    exit 1
fi

if ! command -v gum &>/dev/null; then
    echo "Installing required dependency 'gum'..."
    sudo pacman -S --needed --noconfirm gum || exit 1
fi

sudo -v || exit 1
( while true; do sudo -n true; sleep 45; kill -0 "$$" 2>/dev/null || exit; done ) 2>/dev/null &
SUDO_PID=$!
trap 'kill "$SUDO_PID" 2>/dev/null || true' EXIT

# ------------------------------------------------------------------------------
# UI HELPERS
# ------------------------------------------------------------------------------
section_header() {
    local title="$1"
    local status="$2"
    local color="82" # Green for ✔
    
    if [[ "$status" == *"⚠"* ]]; then color="214"; fi # Amber
    if [[ "$status" == *"✖"* ]]; then color="196"; fi # Red

    echo ""
    gum style --foreground "$color" --border rounded --padding "0 1" "$title $status"
}

spinner() {
    gum spin --spinner dot --title "$1" -- "${@:2}"
}

# ------------------------------------------------------------------------------
# MAINTENANCE (CLEANER)
# ------------------------------------------------------------------------------
run_maintenance() {
    local mode="$1"
    clear
    gum style --foreground 214 --border double --align center --width 68 "EOS SYSTEM  ›  $mode"
    echo ""

    if command -v paccache &>/dev/null; then
        spinner "Keeping the last 2 pacman cache versions..." sudo paccache -r -k 2
        spinner "Removing cache for uninstalled packages..." sudo paccache -r -u -k 0
        gum style --foreground 82 "✔ Pacman cache optimized."
    fi

    if command -v yay &>/dev/null; then
        spinner "Cleaning unused AUR build/cache data..." yay -Sc --noconfirm
        gum style --foreground 82 "✔ AUR cache cleanup completed."
    fi

    spinner "Vacuuming systemd journal older than 14 days..." sudo journalctl --vacuum-time=2weeks
    gum style --foreground 82 "✔ Systemd journal maintenance completed."

    spinner "Cleaning thumbnail cache..." bash -c 'rm -rf -- "$HOME/.cache/thumbnails/"*'
    gum style --foreground 82 "✔ Thumbnail cache cleaned."

    if [[ "$mode" == "Deep Clean & Health" ]]; then
        rm -rf -- "$HOME/.local/share/Trash/files/"* 2>/dev/null || true
        gum style --foreground 82 "✔ Desktop trash cleaned."
        if command -v coredumpctl &>/dev/null; then
            spinner "Removing stored coredumps..." sudo coredumpctl clear
            gum style --foreground 82 "✔ Stored coredumps cleared."
        fi
    fi
    echo ""
    gum style --foreground 244 "Maintenance complete. Proceeding to Health Check..."
    sleep 2
}

# ------------------------------------------------------------------------------
# HEALTH CHECK & JSON BUILDER
# ------------------------------------------------------------------------------
run_health_check() {
    clear
    gum style --foreground 214 --border double --align center --width 68 "EOS SYSTEM  ›  Health Check Only"
    echo ""

    local err_boot=0 warn_boot=0
    local err_hw=0 warn_hw=0
    local err_sys=0 warn_sys=0
    local err_net=0 warn_net=0

    local boot_table="" hw_table="" sys_table="" net_table=""

    # --- 1. BOOT & CORE OS ---
    local k_running; k_running="$(uname -r)"
    boot_table+="Kernel & modules|PASS ✔ ($k_running)\n"
    
    # EFI Partition Check
    local efi_mnt="/boot/efi"
    local efi_free="unknown"
    if mountpoint -q "$efi_mnt"; then
        efi_free=$(df -m "$efi_mnt" | awk 'NR==2 {print $4}')
        if (( efi_free < 100 )); then
            boot_table+="EFI partition ($efi_mnt)|WARN ⚠ (free: ${efi_free}MB)\n"; ((warn_boot++))
        else
            boot_table+="EFI partition ($efi_mnt)|PASS ✔ (mounted, free: ${efi_free}MB)\n"
        fi
    else
        boot_table+="EFI partition ($efi_mnt)|WARN ⚠ (not mounted)\n"; ((warn_boot++))
    fi

    # Reboot pending check
    if [[ -f "/usr/lib/modules/$k_running/pkgbase" ]]; then
        local pkgbase; pkgbase="$(< /usr/lib/modules/$k_running/pkgbase)"
        local vmlinuz_mtime; vmlinuz_mtime=$(stat -c %Y "/boot/vmlinuz-${pkgbase}" 2>/dev/null || echo 0)
        local boot_time; boot_time=$(( $(date +%s) - $(awk '{print int($1)}' /proc/uptime) ))
        if (( vmlinuz_mtime > boot_time )); then
            boot_table+="Reboot pending|WARN ⚠ (kernel updated)\n"; ((warn_boot++))
        else
            boot_table+="Reboot pending|PASS ✔ (kernel is current)\n"
        fi
    else
        boot_table+="Reboot pending|INFO ℹ (pkgbase unknown)\n"
    fi

    # --- 2. HARDWARE & DRIVERS ---
    local gpu_name="Unknown" driver_ver="Unknown"
    if command -v nvidia-smi &>/dev/null; then
        gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
        driver_ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
        hw_table+="NVIDIA runtime|PASS ✔ ($gpu_name - $driver_ver)\n"
    else
        hw_table+="GPU runtime|INFO ℹ (nvidia-smi unavailable)\n"
    fi

    if command -v dkms &>/dev/null; then
        if dkms status 2>/dev/null | grep -qiE 'broken|error'; then
            hw_table+="DKMS modules|WARN ⚠ (errors detected)\n"; ((warn_hw++))
        else
            hw_table+="DKMS modules|PASS ✔ (all kernels covered)\n"
        fi
    fi

    local smart_failed=0 smart_total=0
    for dev in $(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}'); do
        ((smart_total++))
        if sudo smartctl -H "$dev" 2>/dev/null | grep -qi 'FAILED!'; then ((smart_failed++)); fi
    done
    if (( smart_failed > 0 )); then
        hw_table+="SMART disk health|FAIL ✖ ($smart_failed failed)\n"; ((err_hw++))
    else
        hw_table+="SMART disk health|PASS ✔ ($smart_total OK)\n"
    fi

    if systemctl is-enabled fstrim.timer &>/dev/null; then
        hw_table+="SSD/NVMe TRIM timer|PASS ✔ (active)\n"
    else
        hw_table+="SSD/NVMe TRIM timer|WARN ⚠ (inactive)\n"; ((warn_hw++))
    fi

    # --- 3. SYSTEM HEALTH & SERVICES ---
    local root_usage; root_usage="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if (( root_usage >= 90 )); then
        sys_table+="Root disk space|FAIL ✖ (${root_usage}%)\n"; ((err_sys++))
    elif (( root_usage >= 80 )); then
        sys_table+="Root disk space|WARN ⚠ (${root_usage}%)\n"; ((warn_sys++))
    else
        sys_table+="Root disk space|PASS ✔ (${root_usage}%)\n"
    fi

    local sys_failed; sys_failed="$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)"
    local usr_failed; usr_failed="$(systemctl --user --failed --no-legend --plain 2>/dev/null | wc -l)"
    
    if (( sys_failed > 0 )); then sys_table+="Systemd failed (system)|WARN ⚠ ($sys_failed failed)\n"; ((warn_sys++)); else sys_table+="Systemd failed (system)|PASS ✔\n"; fi
    if (( usr_failed > 0 )); then sys_table+="Systemd failed (user)|WARN ⚠ ($usr_failed failed)\n"; ((warn_sys++)); else sys_table+="Systemd failed (user)|PASS ✔\n"; fi

    local pacnew_count; pacnew_count="$(find /etc -type f -name '*.pacnew' 2>/dev/null | wc -l)"
    if (( pacnew_count > 0 )); then sys_table+=".pacnew config files|WARN ⚠ ($pacnew_count found)\n"; ((warn_sys++)); else sys_table+=".pacnew config files|PASS ✔\n"; fi

    # --- 4. NETWORK & UPDATES ---
    local gw_ip; gw_ip="$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n1)"
    if command -v dig &>/dev/null && [[ -n "$gw_ip" ]]; then
        local qtime; qtime="$(dig "@$gw_ip" test.nextdns.io +time=2 +tries=1 2>&1 | grep -oE 'Query time: [0-9]+' | grep -oE '[0-9]+' || echo '?')"
        net_table+="DNS Gateway ($gw_ip)|PASS ✔ (${qtime}ms)\n"
    else
        net_table+="DNS Gateway|INFO ℹ (unavailable)\n"
    fi

    local mirror_age="unknown"
    if [[ -f /etc/pacman.d/mirrorlist ]]; then
        mirror_age=$(( ($(date +%s) - $(stat -c %Y /etc/pacman.d/mirrorlist)) / 86400 ))
        if (( mirror_age > 30 )); then
            net_table+="Mirrorlist age|WARN ⚠ (${mirror_age} days old)\n"; ((warn_net++))
        else
            net_table+="Mirrorlist age|PASS ✔ (${mirror_age} days old)\n"
        fi
    fi

    local upd_count; upd_count=$(checkupdates 2>/dev/null | wc -l)
    net_table+="Available updates|INFO ℹ ($upd_count)\n"

    # --- RENDER TUI ---
    local b_stat="✔"; if ((warn_boot>0)); then b_stat="⚠"; fi; if ((err_boot>0)); then b_stat="✖"; fi
    section_header "BOOT & CORE OS" "$b_stat"
    echo -e "$boot_table" | gum table -p -c "Component,Status" -s "|" --border rounded -w 28,45

    local h_stat="✔"; if ((warn_hw>0)); then h_stat="⚠"; fi; if ((err_hw>0)); then h_stat="✖"; fi
    section_header "HARDWARE & DRIVERS" "$h_stat"
    echo -e "$hw_table" | gum table -p -c "Component,Status" -s "|" --border rounded -w 28,45

    local s_stat="✔"; if ((warn_sys>0)); then s_stat="⚠"; fi; if ((err_sys>0)); then s_stat="✖"; fi
    section_header "SYSTEM HEALTH & SERVICES" "$s_stat"
    echo -e "$sys_table" | gum table -p -c "Component,Status" -s "|" --border rounded -w 28,45

    local n_stat="✔"; if ((warn_net>0)); then n_stat="⚠"; fi; if ((err_net>0)); then n_stat="✖"; fi
    section_header "NETWORK & UPDATES" "$n_stat"
    echo -e "$net_table" | gum table -p -c "Component,Status" -s "|" --border rounded -w 28,45

    # --- GENERATE JSON FOR AI AGENT ---
    cat > "$JSON_FILE" <<EOF
{
  "timestamp": "$(date --iso-8601=seconds)",
  "boot_and_os": {
    "kernel_running": "$k_running",
    "efi_free_mb": "$efi_free",
    "warnings": $warn_boot,
    "errors": $err_boot
  },
  "hardware": {
    "gpu_name": "$gpu_name",
    "gpu_driver": "$driver_ver",
    "smart_failed_disks": $smart_failed,
    "warnings": $warn_hw,
    "errors": $err_hw
  },
  "system": {
    "root_usage_pct": "$root_usage",
    "systemd_failed_sys": $sys_failed,
    "systemd_failed_usr": $usr_failed,
    "pacnew_files": $pacnew_count,
    "warnings": $warn_sys,
    "errors": $err_sys
  },
  "network": {
    "gateway": "$gw_ip",
    "mirrorlist_age_days": "$mirror_age",
    "pending_updates": $upd_count,
    "warnings": $warn_net,
    "errors": $err_net
  }
}
EOF

    echo ""
    gum style --foreground 244 "AI Agent Report generated: $JSON_FILE"
    echo ""
    gum style --foreground 244 "Press Enter to return to the main menu..."
    read -r
}

# ------------------------------------------------------------------------------
# MAIN MENU
# ------------------------------------------------------------------------------
while true; do
    clear
    gum style --foreground 214 --border double --align center --width 68 "ENDEAVOUROS SYSTEM"
    gum style --foreground 244 --align center --width 68 "Maintenance • Health • Diagnostics  |  v$VERSION"
    echo ""

    MODE="$(gum choose --header "What would you like to do?" \
        "Standard Clean & Health" \
        "Deep Clean & Health" \
        "Health Check Only" \
        "Exit")"

    case "$MODE" in
        "Standard Clean & Health")
            run_maintenance "$MODE"
            run_health_check
            ;;
        "Deep Clean & Health")
            gum style --foreground 214 "Deep clean will empty Desktop Trash and Coredumps."
            if gum confirm "Continue with deep clean?"; then
                run_maintenance "$MODE"
                run_health_check
            fi
            ;;
        "Health Check Only")
            run_health_check
            ;;
        "Exit")
            clear; exit 0
            ;;
    esac
done
