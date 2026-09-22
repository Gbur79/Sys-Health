#!/usr/bin/env bash
# ==============================================================================
# Arch System Health & Diagnostics v2.8
# Read-only health audit + AI Agent report generator + optional maintenance
# Arch Linux & derivatives (EndeavourOS, Manjaro, CachyOS, etc.)
# Unofficial community project - Not affiliated with EndeavourOS or Arch Linux
# ==============================================================================

set -o pipefail

VERSION="2.8"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/system-health"
LOG_FILE="$STATE_DIR/system-health.log"
SUMMARY_FILE="$STATE_DIR/summary.json"
STATE_SNAPSHOT="$STATE_DIR/software-state.txt"
RAW_DIR="$STATE_DIR/runs"

mkdir -p "$STATE_DIR" "$RAW_DIR" 2>/dev/null || true

# ------------------------------------------------------------------------------
# User configuration (optional)
# ------------------------------------------------------------------------------

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/system-health/system-health.conf"
[[ ! -f "$CONFIG_FILE" ]] && CONFIG_FILE="$HOME/.config/system-health.conf"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ------------------------------------------------------------------------------
# Usage & CLI options
# ------------------------------------------------------------------------------

show_usage() {
    cat <<EOF
Arch System Health & Diagnostics v$VERSION
Usage: $(basename "$0") [OPTIONS]

Options:
  -a, --audit, --batch   Run read-only health audit & generate snapshot (non-interactive)
  -j, --json             Print latest summary JSON to stdout and exit
  -s, --snapshot         Print latest system software state snapshot to stdout and exit
  -r, --report           Print latest text audit report to stdout and exit
  -m, --maintenance      Run safe maintenance non-interactively, then run health audit
  -h, --help             Show this help message and exit
  -v, --version          Show version and exit

Configuration:
  Optional config file:
    ~/.config/system-health/system-health.conf
    or ~/.config/system-health.conf
  Supported variables:
    DNS_TEST_HOST="archlinux.org"   (host for DNS resolution test)
    DNS_TEST_SERVER=""              (optional custom resolver IP, e.g. router)
    SKIP_INTEGRITY=0                (set to 1 to skip time-consuming pacman -Qk)

Exit codes (in --audit/--batch mode):
  0: ALL_CLEAR (no errors or warnings)
  1: ACTION_REQUIRED (one or more errors detected)
  2: REVIEW_WARNINGS (warnings detected, no errors)
EOF
}

ACTION="interactive"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--audit|--batch)
            ACTION="audit"
            shift
            ;;
        -j|--json)
            ACTION="json"
            shift
            ;;
        -s|--snapshot)
            ACTION="snapshot"
            shift
            ;;
        -r|--report)
            ACTION="report"
            shift
            ;;
        -m|--maintenance)
            ACTION="maintenance"
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -v|--version)
            echo "Arch System Health & Diagnostics v$VERSION"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Run '$(basename "$0") --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Fast-paths for immediate stdout output
if [[ "$ACTION" == "json" ]]; then
    if [[ -f "$SUMMARY_FILE" ]]; then
        cat "$SUMMARY_FILE"
        echo ""
    else
        echo '{"status": "UNKNOWN", "errors": 0, "warnings": 0, "note": "No previous audit found. Run with --audit to generate."}'
    fi
    exit 0
fi

if [[ "$ACTION" == "snapshot" ]]; then
    if [[ -f "$STATE_SNAPSHOT" ]]; then
        cat "$STATE_SNAPSHOT"
    else
        echo "No software state snapshot found. Run with --audit to generate." >&2
        exit 1
    fi
    exit 0
fi

if [[ "$ACTION" == "report" ]]; then
    if [[ -f "$LOG_FILE" ]]; then
        cat "$LOG_FILE"
    else
        echo "No audit log report found. Run with --audit to generate." >&2
        exit 1
    fi
    exit 0
fi

# ------------------------------------------------------------------------------
# Safety / environment
# ------------------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "Please run this script as your normal user. sudo will be requested when needed."
    exit 1
fi

if [[ "$ACTION" == "interactive" ]] && ! command -v gum &>/dev/null; then
    echo "gum is required for the interactive UI but is not installed."
    read -r -p "Would you like to install gum now via sudo pacman -S gum? [y/N] " _gum_resp
    if [[ "$_gum_resp" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        sudo pacman -S --needed gum || exit 1
    else
        echo "Exiting. Please install gum manually: sudo pacman -S gum"
        exit 1
    fi
fi

RUN_ID="$(date '+%Y%m%d-%H%M%S')"
RUN_RAW="$RAW_DIR/$RUN_ID"
mkdir -p "$RUN_RAW"

# Retain only the last 20 run directories in $RAW_DIR
find "$RAW_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r | tail -n +21 | xargs -r rm -rf 2>/dev/null || true

PREVIOUS_RUN_SUMMARY=""
if [[ -s "$LOG_FILE" ]]; then
    PREVIOUS_RUN_SUMMARY="$(grep '^Summary:' "$LOG_FILE" | tail -n1)"
fi

# Sudo credentials management (interactive prompts vs batch best-effort)
HAVE_SUDO=0
if sudo -n true 2>/dev/null; then
    HAVE_SUDO=1
elif [[ "$ACTION" == "interactive" ]]; then
    if sudo -v; then
        HAVE_SUDO=1
    else
        echo "Authentication failed or aborted." >&2
        exit 1
    fi
elif [[ -t 0 ]] && sudo -v 2>/dev/null; then
    HAVE_SUDO=1
fi

if [[ "$HAVE_SUDO" -eq 1 ]]; then
    (
        while true; do
            sudo -n true 2>/dev/null || exit
            sleep 45
            kill -0 "$$" 2>/dev/null || exit
        done
    ) 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
    trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
fi

# ------------------------------------------------------------------------------
# UI
# ------------------------------------------------------------------------------

ui_title() {
    clear
    if command -v figlet &>/dev/null && command -v lolcat &>/dev/null; then
        figlet -f standard "SYS HEALTH" | lolcat
    else
        gum style \
            --foreground 214 \
            --border double \
            --align center \
            --width 68 \
            "ARCH SYSTEM HEALTH & AUDIT"
    fi

    gum style \
        --foreground 244 \
        --align center \
        --width 68 \
        "Diagnostics • Health Audit • AI Handoff  |  v$VERSION"

    echo ""
    local _kern _up _disk
    _kern="$(uname -r)"
    _up="$(uptime -p 2>/dev/null | sed 's/up //' || echo 'unknown')"
    _disk="$(df -P / | awk 'NR==2 {print $5}')"
    gum style \
        --foreground 81 \
        --border rounded \
        --padding "0 2" \
        --width 68 \
        --align center \
        "kernel: $_kern   uptime: $_up   /: $_disk"

    if [[ -n "$PREVIOUS_RUN_SUMMARY" ]]; then
        gum style \
            --foreground 244 \
            --align center \
            --width 68 \
            "Last run: ${PREVIOUS_RUN_SUMMARY#Summary: }"
    fi
    echo ""
}

ui_screen() {
    clear
    gum style \
        --foreground 214 \
        --border double \
        --align center \
        --width 68 \
        --padding "0 1" \
        "SYSTEM HEALTH  ›  $1"
    echo ""
}

section() {
    echo ""
    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        gum style \
            --foreground 214 \
            --border normal \
            --padding "0 1" \
            "$1"
    else
        echo "=== $1 ==="
    fi
}

ok()   { if [[ -t 1 ]] && command -v gum &>/dev/null; then gum style --foreground 82  "✔ $1"; else echo "✔ $1"; fi; }
warn() { if [[ -t 1 ]] && command -v gum &>/dev/null; then gum style --foreground 214 "⚠ $1"; else echo "⚠ $1"; fi; }
fail() { if [[ -t 1 ]] && command -v gum &>/dev/null; then gum style --foreground 196 "✖ $1"; else echo "✖ $1"; fi; }
info() { if [[ -t 1 ]] && command -v gum &>/dev/null; then gum style --foreground 81  "ℹ $1"; else echo "ℹ $1"; fi; }

spinner() {
    local title="$1"
    shift
    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        gum spin --spinner dot --title "$title" -- "$@"
    else
        "$@"
    fi
}

log() {
    printf '%s\n' "$*" >> "$LOG_FILE"
}

pause_screen() {
    echo ""
    gum style --foreground 244 "Press Enter to return to the main menu..."
    read -r
}

# ------------------------------------------------------------------------------
# Report data
# ------------------------------------------------------------------------------

AUDIT_TABLE=""
AUDIT_TABLE_BOOT=""
AUDIT_TABLE_HW=""
AUDIT_TABLE_SYS=""
AUDIT_TABLE_NET=""
AUDIT_TABLE_OTHER=""
ERRORS=0
WARNINGS=0
INFO_COUNT=0

FAILED_SERVICES=""
FAILED_USER_SERVICES=""
PACNEWS=""
UPDATES_TEXT=""
ARCH_AUDIT_TEXT=""
ARCH_AUDIT_ACTIONABLE=""
ARCH_AUDIT_ALL=""
ARCH_AUDIT_ACTIONABLE_COUNT=0
ARCH_AUDIT_TRACKER_COUNT=0
PACMAN_INTEGRITY_TEXT=""
DKMS_TEXT=""
SENSORS_TEXT=""

add_row() {
    local comp="$1"
    local clean_status="${2//|/-}"
    local sec="${3:-}"

    if [[ -z "$sec" ]]; then
        case "$comp" in
            "Kernel & modules"|"Initramfs"*|"EFI partition"*|"Reboot pending"|"Previous session shutdown")
                sec="BOOT"
                ;;
            "GPU runtime"*|"GPU errors & lockups"|"DKMS"*|"CPU temperature"|"SMART disk health"|"SSD/NVMe TRIM timer")
                sec="HW"
                ;;
            "Root disk space"|"Systemd failed"*|"Pacman DB lock"|"Package file integrity"|".pacnew"*|"Magic SysRq keys")
                sec="SYS"
                ;;
            "System DNS"|"Available updates"|"Arch News"*|"Arch security audit"|"Mirrorlist age"*)
                sec="NET"
                ;;
            *)
                sec="OTHER"
                ;;
        esac
    fi

    AUDIT_TABLE+="$comp | $clean_status\n"

    case "$sec" in
        BOOT)  AUDIT_TABLE_BOOT+="$comp | $clean_status\n" ;;
        HW)    AUDIT_TABLE_HW+="$comp | $clean_status\n" ;;
        SYS)   AUDIT_TABLE_SYS+="$comp | $clean_status\n" ;;
        NET)   AUDIT_TABLE_NET+="$comp | $clean_status\n" ;;
        *)     AUDIT_TABLE_OTHER+="$comp | $clean_status\n" ;;
    esac
}

render_audit_section() {
    local title="$1"
    local data="$2"
    local col1 col2 badge=" ✔" header_color=82

    [[ -z "$data" ]] && return

    col1=$(printf "%-28s" "Component")
    col2=$(printf "%-42s" "Status")

    if grep -q "FAIL ✖" <<< "$data"; then
        header_color=196
        badge=" ✖"
    elif grep -q "WARN ⚠" <<< "$data"; then
        header_color=214
        badge=" ⚠"
    fi

    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        echo ""
        gum style \
            --foreground "$header_color" \
            --border rounded \
            --padding "0 1" \
            --bold \
            "${title}${badge}"

        local formatted_data=""
        local line comp st
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            comp="${line%% | *}"
            st="${line#* | }"
            st="${st//|/-}"
            if (( ${#st} > 42 )); then
                st="${st:0:41}…"
            fi
            formatted_data+="$comp | $st\n"
        done <<< "$(echo -e -n "$data")"

        echo -e -n "$formatted_data" |
            gum table \
                -p \
                -c "$col1,$col2" \
                -s "|" \
                --border rounded
    else
        echo ""
        echo "=== ${title}${badge} ==="
        local line comp st
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            comp="${line%% | *}"
            st="${line#* | }"
            printf "  %-30s : %s\n" "$comp" "$st"
        done <<< "$(echo -e -n "$data")"
    fi
}

# ------------------------------------------------------------------------------
# System snapshot
# ------------------------------------------------------------------------------

collect_system_snapshot() {
    : > "$LOG_FILE"

    log "============================================================"
    log "ARCH SYSTEM HEALTH & AUDIT REPORT"
    log "============================================================"
    log "Version: $VERSION"
    log "Run ID: $RUN_ID"
    log "Date: $(date --iso-8601=seconds)"
    log "Hostname: $(hostname)"
    log "User: $USER"
    log "Kernel: $(uname -r)"
    log "Architecture: $(uname -m)"

    if [[ -f /etc/os-release ]]; then
        log "OS: $(. /etc/os-release; echo "${PRETTY_NAME:-unknown}")"
    fi

    log ""
    log "### HARDWARE"
    log "CPU: $(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    log "Memory:"
    free -h 2>/dev/null | sed 's/^/  /' >> "$LOG_FILE"
    log "Root filesystem:"
    df -h / >> "$LOG_FILE" 2>&1

    if command -v lspci &>/dev/null; then
        log "GPU:"
        lspci 2>/dev/null | grep -Ei 'VGA|3D|Display' | sed 's/^/  /' >> "$LOG_FILE"
    fi
}

refresh_state_snapshot() {
    local ts
    ts="$(date --iso-8601=seconds)"

    spinner "Refreshing system state snapshot..." bash -c "
        {
            echo '=== SYSTEM SOFTWARE STATE SNAPSHOT ==='
            echo \"Generated on: ${ts}\"
            echo ''
            echo '--- 1. Kernel Information ---'
            uname -a
            echo ''
            echo '--- 2. Installed Linux Kernels & Headers ---'
            pacman -Q 2>/dev/null | grep -E '^linux'
            echo ''
            echo '--- 3. GPU Packages (AMD/Intel/NVIDIA) ---'
            pacman -Q 2>/dev/null | grep -iE 'nvidia|amdgpu|radeon|vulkan|mesa|xf86-video'
            echo ''
            echo '--- 4. DKMS Status ---'
            dkms status 2>/dev/null || echo '(dkms not available)'
            echo ''
            echo '--- 5. Loaded GPU Kernel Modules ---'
            lsmod 2>/dev/null | grep -E '^nvidia|^nouveau|^amdgpu|^radeon|^i915|^xe|^drm'
            echo ''
            echo '--- 6. GPU Hardware & Kernel Driver in Use ---'
            lspci -k 2>/dev/null | grep -A 4 -iE 'VGA|3D|Display'
            echo ''
            echo '--- 7. Initramfs Configuration Files (Dracut / Mkinitcpio) ---'
            if [[ -d /etc/dracut.conf.d ]]; then
                echo 'Dracut configs:'
                ls -la /etc/dracut.conf.d/ 2>/dev/null
                cat /etc/dracut.conf.d/*.conf 2>/dev/null
            fi
            if [[ -f /etc/mkinitcpio.conf ]]; then
                echo 'Mkinitcpio config:'
                cat /etc/mkinitcpio.conf 2>/dev/null | grep -v '^#' | sed '/^$/d'
                ls -la /etc/mkinitcpio.d/ 2>/dev/null
            fi
            echo ''
            echo '--- 8. Boot & Filesystem Mounts ---'
            findmnt --real -o TARGET,SOURCE,FSTYPE,OPTIONS -t vfat 2>/dev/null
            echo ''
            echo '--- 9. Boot Directory Content ---'
            ls -lah /boot/ 2>/dev/null
            echo ''
            echo '--- 10. Failed Systemd Services (System) ---'
            systemctl --failed --no-legend --plain 2>/dev/null
            echo ''
            echo '--- 11. Failed Systemd Services (User) ---'
            systemctl --user --failed --no-legend --plain 2>/dev/null
            echo ''
            echo '--- 12. Desktop & Session Environment ---'
            printenv XDG_SESSION_TYPE DESKTOP_SESSION XDG_CURRENT_DESKTOP 2>/dev/null || true
        } > '$STATE_SNAPSHOT' 2>&1
    "

    if [[ -s "$STATE_SNAPSHOT" ]]; then
        ok "State snapshot refreshed: $STATE_SNAPSHOT"
        log "STATE_SNAPSHOT refreshed=$STATE_SNAPSHOT ts=$ts"
    else
        warn "State snapshot refresh failed."
        log "STATE_SNAPSHOT refresh_failed"
    fi
}

# ------------------------------------------------------------------------------
# Maintenance
# ------------------------------------------------------------------------------

run_maintenance() {
    local mode="$1"

    section "MAINTENANCE"

    if command -v paccache &>/dev/null; then
        spinner "Keeping the last 2 pacman cache versions..." \
            sudo paccache -r -k 2
        ok "Pacman cache optimized."
        log "MAINTENANCE pacman_cache=kept_2_versions"

        spinner "Removing cache for uninstalled packages..." \
            sudo paccache -r -u -k 0
        ok "Uninstalled package cache cleaned."
        log "MAINTENANCE uninstalled_package_cache=cleaned"
    else
        warn "paccache is not installed; pacman cache step skipped."
        log "MAINTENANCE paccache=not_installed"
        ((WARNINGS++))
    fi

    if command -v yay &>/dev/null; then
        spinner "Cleaning unused AUR build/cache data..." yay -Sc --aur --noconfirm
        ok "AUR cache cleanup completed."
        log "MAINTENANCE aur_cache=cleaned"
    elif command -v paru &>/dev/null; then
        spinner "Cleaning unused AUR build/cache data..." paru -Sc --aur --noconfirm
        ok "AUR cache cleanup completed."
        log "MAINTENANCE aur_cache=cleaned"
    else
        info "AUR helper (yay/paru) not found; AUR cache step skipped."
        log "MAINTENANCE aur_helper=not_found"
    fi

    spinner "Vacuuming systemd journal older than 14 days..." \
        sudo journalctl --vacuum-time=2weeks
    ok "Systemd journal maintenance completed."
    log "MAINTENANCE journal=vacuum_14days"

    if [[ -d "$HOME/.cache/thumbnails" ]]; then
        spinner "Cleaning thumbnail cache..." \
            bash -c 'rm -rf -- "$HOME/.cache/thumbnails/"*'
        ok "Thumbnail cache cleaned."
        log "MAINTENANCE thumbnails=cleaned"
    fi

    if [[ "$mode" == *"Deep Clean"* ]]; then
        section "DEEP CLEAN"

        rm -rf -- \
            "$HOME/.local/share/Trash/files"/* \
            "$HOME/.local/share/Trash/files"/.[!.]* \
            "$HOME/.local/share/Trash/info"/* \
            "$HOME/.local/share/Trash/info"/.[!.]* 2>/dev/null || true
        ok "Desktop trash cleaned."
        log "MAINTENANCE trash=cleaned"

        if [[ -d "$HOME/.cache/mozilla/firefox" ]]; then
            spinner "Cleaning Firefox cache..." \
                bash -c 'find "$HOME/.cache/mozilla/firefox/" -type d -name "cache2" -exec rm -rf -- "{}" + 2>/dev/null || true'
            ok "Firefox cache cleaned."
            log "MAINTENANCE firefox_cache=cleaned"
        fi

        if [[ -d "$HOME/.cache/chromium/Default/Cache" ]]; then
            spinner "Cleaning Chromium cache..." \
                bash -c 'rm -rf -- "$HOME/.cache/chromium/Default/Cache/"*'
            ok "Chromium cache cleaned."
            log "MAINTENANCE chromium_cache=cleaned"
        fi

        if command -v coredumpctl &>/dev/null; then
            spinner "Removing stored coredumps..." sudo coredumpctl clear
            ok "Stored coredumps cleared."
            log "MAINTENANCE coredumps=cleared"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Health checks
# ------------------------------------------------------------------------------

check_kernel() {
    local k
    k="$(uname -r)"

    if [[ -d "/usr/lib/modules/$k" ]]; then
        add_row "Kernel & modules" "PASS ✔"
        log "HEALTH kernel_modules=PASS running_kernel=$k"
    else
        add_row "Kernel & modules" "FAIL ✖"
        ((ERRORS++))
        log "HEALTH kernel_modules=FAIL missing=/usr/lib/modules/$k"
    fi
}

check_initramfs() {
    local running="$1"
    local pkgbase_file="/usr/lib/modules/$running/pkgbase"
    local pkgbase

    if [[ -f "$pkgbase_file" ]]; then
        pkgbase="$(< "$pkgbase_file")"
    else
        case "$running" in
            *-lts)      pkgbase="linux-lts"      ;;
            *-zen)      pkgbase="linux-zen"        ;;
            *-hardened) pkgbase="linux-hardened"   ;;
            *-rt)       pkgbase="linux-rt"         ;;
            *)          pkgbase="linux"            ;;
        esac
        warn "pkgbase file missing for kernel $running; guessing '$pkgbase'"
        log "HEALTH initramfs_pkgbase=guessed running=$running pkgbase=$pkgbase"
    fi

    local normal="/boot/initramfs-${pkgbase}.img"
    local fallback="/boot/initramfs-${pkgbase}-fallback.img"

    if [[ -f "$normal" ]]; then
        if [[ -f "$fallback" ]]; then
            add_row "Initramfs ($pkgbase)" "PASS ✔ (normal + fallback)"
            log "HEALTH initramfs=PASS normal=present fallback=present pkgbase=$pkgbase"
        else
            add_row "Initramfs ($pkgbase)" "WARN ⚠ (normal present, fallback missing)"
            ((WARNINGS++))
            log "HEALTH initramfs=WARN normal=present fallback=missing pkgbase=$pkgbase"
        fi
    else
        local alt
        alt="$(find /boot /efi -maxdepth 3 \( -name "*${pkgbase}*.img" -o -name "*${pkgbase}*.efi" -o -name "initrd*" \) 2>/dev/null | head -n1)"
        if [[ -n "$alt" ]]; then
            add_row "Initramfs ($pkgbase)" "PASS ✔ (detected: $(basename "$alt"))"
            log "HEALTH initramfs=PASS custom_path=$alt pkgbase=$pkgbase"
        else
            add_row "Initramfs ($pkgbase)" "FAIL ✖ (missing: $normal)"
            ((ERRORS++))
            log "HEALTH initramfs=FAIL normal_missing=$normal pkgbase=$pkgbase"
        fi
    fi
}

check_efi_mount() {
    if [[ ! -d /sys/firmware/efi ]]; then
        add_row "EFI partition (ESP)" "INFO ℹ (BIOS / Legacy system)"
        log "HEALTH efi=INFO bios_legacy"
        return
    fi

    local efi_mnt
    efi_mnt="$(findmnt -n -o TARGET -t vfat 2>/dev/null | grep -iE '^/(boot|boot/efi|efi)$' | head -n1 || true)"

    if [[ -z "$efi_mnt" ]]; then
        add_row "EFI partition (ESP)" "FAIL ✖ (no vfat mounted at /boot, /efi, or /boot/efi)"
        ((ERRORS++))
        log "HEALTH efi=FAIL mounted=NO"
        return
    fi

    local avail_mb
    avail_mb="$(df -BM "$efi_mnt" 2>/dev/null | awk 'NR==2 {gsub("M","",$4); print $4}')"

    if [[ -n "$avail_mb" ]] && (( avail_mb < 30 )); then
        add_row "EFI partition ($efi_mnt)" "WARN ⚠ (low free space: ${avail_mb}MB)"
        ((WARNINGS++))
        log "HEALTH efi=WARN low_space=${avail_mb}MB"
    else
        add_row "EFI partition ($efi_mnt)" "PASS ✔ (mounted vfat, free: ${avail_mb:-?}MB)"
        log "HEALTH efi=PASS free_mb=${avail_mb:-unknown}"
    fi
}

check_reboot_pending() {
    local running pkgbase_file pkgbase vmlinuz boot_time vmlinuz_mtime
    running="$(uname -r)"
    pkgbase_file="/usr/lib/modules/$running/pkgbase"

    if [[ ! -f "$pkgbase_file" ]]; then
        add_row "Reboot pending" "INFO ℹ (pkgbase unavailable)"
        ((INFO_COUNT++))
        log "HEALTH reboot_pending=unknown reason=pkgbase_missing"
        return
    fi

    pkgbase="$(< "$pkgbase_file")"
    vmlinuz="/boot/vmlinuz-${pkgbase}"

    if [[ ! -f "$vmlinuz" ]]; then
        add_row "Reboot pending" "INFO ℹ (vmlinuz not found)"
        ((INFO_COUNT++))
        log "HEALTH reboot_pending=unknown reason=vmlinuz_missing"
        return
    fi

    boot_time=$(( $(date +%s) - $(awk '{print int($1)}' /proc/uptime) ))
    vmlinuz_mtime=$(stat -c %Y "$vmlinuz")

    if (( vmlinuz_mtime > boot_time )); then
        add_row "Reboot pending" "WARN ⚠ (kernel updated since last boot)"
        ((WARNINGS++))
        log "HEALTH reboot_pending=YES"
    else
        add_row "Reboot pending" "PASS ✔ (running kernel is current)"
        log "HEALTH reboot_pending=NO"
    fi
}

check_previous_boot() {
    if ! journalctl -b -1 -n 1 &>/dev/null; then
        add_row "Previous session shutdown" "INFO ℹ (no previous boot record)"
        log "HEALTH previous_boot=INFO no_record"
        return
    fi

    local journal_unclean fsck_recovery last_shutdown
    journal_unclean="$(journalctl -b 0 -u systemd-journald --no-pager 2>/dev/null | grep -im 1 "corrupted or uncleanly shut down" || true)"
    fsck_recovery="$(journalctl -b 0 -u "systemd-fsck*" --no-pager 2>/dev/null | grep -im 1 -E "recovering journal|dirty bit is set" || true)"
    last_shutdown="$(journalctl -b -1 -n 50 --no-pager 2>/dev/null | grep -m 1 -E "systemd-shutdown|Reached target (System Reboot|System Power Off|System Shutdown)" || true)"

    if [[ -n "$journal_unclean" || -n "$fsck_recovery" || -z "$last_shutdown" ]]; then
        add_row "Previous session shutdown" "WARN ⚠ (unclean shutdown / crash detected)"
        ((WARNINGS++))
        log "HEALTH previous_boot=WARN unclean=YES"
        {
            echo "### PREVIOUS BOOT / SHUTDOWN INTEGRITY"
            if [[ -z "$last_shutdown" ]]; then
                echo "Warning: Previous boot (-1) ended abruptly without a clean systemd shutdown sequence."
            fi
            if [[ -n "$journal_unclean" ]]; then
                echo "Journald notice: $journal_unclean"
            fi
            if [[ -n "$fsck_recovery" ]]; then
                echo "Filesystem recovery on boot: $fsck_recovery"
            fi
            echo ""
        } >> "$LOG_FILE"
    else
        add_row "Previous session shutdown" "PASS ✔ (clean shutdown)"
        log "HEALTH previous_boot=PASS"
    fi
}

check_gpu() {
    local vga_info drivers="" driver_list="" gpu_name="GPU"
    vga_info="$(lspci -k 2>/dev/null | grep -A 4 -iE 'VGA|3D|Display' || true)"

    if [[ -z "$vga_info" ]]; then
        add_row "GPU runtime" "INFO ℹ (No GPU detected)"
        log "HEALTH gpu=not_detected"
        return
    fi

    drivers="$(printf '%s\n' "$vga_info" | grep 'Kernel driver in use:' | awk '{print $5}' | sort -u || true)"
    driver_list="$(echo $drivers | tr '\n' ' ')"

    if [[ "$driver_list" == *"nvidia"* ]]; then
        if command -v nvidia-smi &>/dev/null; then
            local gpu_temp
            gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
            gpu_temp="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -n1)"
            add_row "GPU runtime (NVIDIA)" "PASS ✔ (${gpu_name:-GPU} | ${gpu_temp}°C)"
            log "HEALTH gpu=NVIDIA driver=nvidia"
        else
            add_row "GPU runtime (NVIDIA)" "WARN ⚠ (nvidia-smi missing)"
            ((WARNINGS++))
            log "HEALTH gpu=NVIDIA driver=nvidia-smi_missing"
        fi
    elif [[ -n "$drivers" ]]; then
        add_row "GPU runtime" "PASS ✔ (Drivers: $driver_list)"
        log "HEALTH gpu=PASS drivers=$driver_list"
    else
        add_row "GPU runtime" "WARN ⚠ (No kernel driver in use)"
        ((WARNINGS++))
        log "HEALTH gpu=WARN no_kernel_driver"
    fi
}

check_gpu_errors() {
    local xorg_log="/var/log/Xorg.0.log"
    [[ ! -f "$xorg_log" && -f "$HOME/.local/share/xorg/Xorg.0.log" ]] && xorg_log="$HOME/.local/share/xorg/Xorg.0.log"

    local fliplock_count=0
    if [[ -f "$xorg_log" ]]; then
        fliplock_count="$(grep -a -c "Failed to request fliplock" "$xorg_log" 2>/dev/null || true)"
        fliplock_count="${fliplock_count:-0}"
    fi

    local nv_xid
    nv_xid="$(journalctl -b 0 -k --no-pager 2>/dev/null | grep -im 1 "NVRM: Xid" || true)"

    if [[ -n "$nv_xid" ]]; then
        add_row "GPU errors & lockups" "WARN ⚠ (NVIDIA Xid error in dmesg)"
        ((WARNINGS++))
        log "HEALTH gpu_errors=WARN xid=YES"
        {
            echo "### GPU HARDWARE / DRIVER ERRORS"
            echo "NVIDIA Xid error detected in kernel log: $nv_xid"
            echo ""
        } >> "$LOG_FILE"
    elif (( fliplock_count > 0 )); then
        add_row "GPU errors & lockups" "WARN ⚠ ($fliplock_count fliplock failures in Xorg)"
        ((WARNINGS++))
        log "HEALTH gpu_errors=WARN fliplock_count=$fliplock_count"
        {
            echo "### GPU HARDWARE / DRIVER ERRORS"
            echo "Xorg fliplock failures detected ($fliplock_count occurrences in $xorg_log)."
            echo "This indicates display buffer flip stalls between driver and display server."
            echo ""
        } >> "$LOG_FILE"
    else
        add_row "GPU errors & lockups" "PASS ✔ (no Xid or fliplock stalls)"
        log "HEALTH gpu_errors=PASS"
    fi
}

check_dkms() {
    if ! command -v dkms &>/dev/null; then
        add_row "DKMS" "INFO ℹ (not installed)"
        ((INFO_COUNT++))
        log "HEALTH dkms=not_installed"
        return
    fi

    DKMS_TEXT="$(dkms status 2>&1 || true)"
    printf '%s\n' "$DKMS_TEXT" > "$RUN_RAW/dkms-status.txt"

    if printf '%s\n' "$DKMS_TEXT" | grep -qiE 'broken|error'; then
        add_row "DKMS modules" "WARN ⚠ (review required)"
        ((WARNINGS++))
        log "HEALTH dkms=WARN status=broken_or_error"
    else
        add_row "DKMS modules" "PASS ✔"
        log "HEALTH dkms=PASS"
    fi
}

check_temperature() {
    if ! command -v sensors &>/dev/null; then
        add_row "CPU temperature" "INFO ℹ (lm_sensors unavailable)"
        ((INFO_COUNT++))
        log "HEALTH cpu_temperature=unavailable"
        return
    fi

    local sensors_out
    sensors_out="$(sensors 2>&1 || true)"
    printf '%s\n' "$sensors_out" > "$RUN_RAW/sensors.txt"

    local cpu_temp
    cpu_temp="$(printf '%s\n' "$sensors_out" |
        grep -iE 'Package id 0|Tctl|Core 0|temp1' |
        grep -oE '[+-]?[0-9]+([.][0-9]+)?°C' |
        head -n1)"

    if [[ -n "$cpu_temp" ]]; then
        local temp_int="${cpu_temp%%.*}"
        temp_int="${temp_int//[^0-9]/}"

        if [[ -n "$temp_int" ]] && (( 10#${temp_int:-0} > 85 )); then
            add_row "CPU temperature" "WARN ⚠ ($cpu_temp)"
            ((WARNINGS++))
            log "HEALTH cpu_temperature=WARN value=$cpu_temp"
        else
            add_row "CPU temperature" "PASS ✔ ($cpu_temp)"
            log "HEALTH cpu_temperature=PASS value=$cpu_temp"
        fi
    else
        add_row "CPU temperature" "INFO ℹ (not detected)"
        ((INFO_COUNT++))
        log "HEALTH cpu_temperature=not_detected"
    fi
}

check_smart() {
    if ! command -v smartctl &>/dev/null; then
        add_row "SMART disk health" "INFO ℹ (smartmontools not installed)"
        ((INFO_COUNT++))
        log "HEALTH smart=not_installed"
        return
    fi

    local -a disks=()
    while IFS= read -r dev; do
        disks+=("$dev")
    done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1 !~ /^(zram|loop)/ {print "/dev/"$1}')

    if [[ ${#disks[@]} -eq 0 ]]; then
        add_row "SMART disk health" "INFO ℹ (no disks detected)"
        ((INFO_COUNT++))
        log "HEALTH smart=no_disks"
        return
    fi

    local failed=0 passed=0 no_perm=0 total="${#disks[@]}"
    for dev in "${disks[@]}"; do
        local result
        result="$(sudo -n smartctl -H "$dev" 2>&1 || smartctl -H "$dev" 2>&1 || true)"
        if printf '%s\n' "$result" | grep -qiE 'PASSED|test result: ok'; then
            (( passed++ ))
        elif printf '%s\n' "$result" | grep -qiE 'FAILED!'; then
            (( failed++ ))
        elif printf '%s\n' "$result" | grep -qiE 'Permission denied|password is required'; then
            (( no_perm++ ))
        fi
    done

    if (( failed > 0 )); then
        add_row "SMART disk health" "FAIL ✖ ($failed/$total disk(s) failed)"
        ((ERRORS++))
        log "HEALTH smart=FAIL failed=$failed"
    elif (( no_perm == total )); then
        add_row "SMART disk health" "INFO ℹ (root required)"
        ((INFO_COUNT++))
        log "HEALTH smart=INFO root_required"
    else
        add_row "SMART disk health" "PASS ✔ ($passed/$total OK)"
        log "HEALTH smart=PASS passed=$passed"
    fi
}

check_fstrim() {
    if ! command -v systemctl &>/dev/null; then
        return
    fi

    local status
    status="$(systemctl is-active fstrim.timer 2>/dev/null || true)"

    if [[ "$status" == "active" ]]; then
        add_row "SSD/NVMe TRIM timer" "PASS ✔ (active)"
        log "HEALTH fstrim=PASS active=YES"
    else
        add_row "SSD/NVMe TRIM timer" "WARN ⚠ (inactive)"
        ((WARNINGS++))
        log "HEALTH fstrim=WARN active=NO"
    fi
}

check_root_space() {
    local usage
    usage="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"

    if [[ -z "$usage" ]]; then
        add_row "Root disk space" "WARN ⚠ (unable to read)"
        ((WARNINGS++))
        log "HEALTH root_space=WARN unreadable"
    elif (( usage >= 90 )); then
        add_row "Root disk space" "FAIL ✖ (${usage}%)"
        ((ERRORS++))
        log "HEALTH root_space=FAIL usage=${usage}%"
    elif (( usage >= 80 )); then
        add_row "Root disk space" "WARN ⚠ (${usage}%)"
        ((WARNINGS++))
        log "HEALTH root_space=WARN usage=${usage}%"
    else
        add_row "Root disk space" "PASS ✔ (${usage}%)"
        log "HEALTH root_space=PASS usage=${usage}%"
    fi
}

check_failed_services() {
    FAILED_SERVICES="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | sed '/^$/d')"

    if [[ -z "$FAILED_SERVICES" ]]; then
        add_row "Systemd failed (system)" "PASS ✔"
        log "HEALTH systemd_failed=0"
    else
        local count first_svc
        count="$(printf '%s\n' "$FAILED_SERVICES" | wc -l)"
        first_svc="$(head -n1 <<< "$FAILED_SERVICES")"
        add_row "Systemd failed (system)" "WARN ⚠ ($count failed)"
        ((WARNINGS++))
        log "HEALTH systemd_failed=WARN count=$count"
        {
            echo "### FAILED SYSTEMD UNITS (SYSTEM)"
            systemctl --failed --no-legend --plain 2>&1
        } >> "$LOG_FILE"
    fi

    FAILED_USER_SERVICES="$(systemctl --user --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | sed '/^$/d')"

    if [[ -z "$FAILED_USER_SERVICES" ]]; then
        add_row "Systemd failed (user)" "PASS ✔"
        log "HEALTH systemd_user_failed=0"
    else
        local count
        count="$(printf '%s\n' "$FAILED_USER_SERVICES" | wc -l)"
        add_row "Systemd failed (user)" "WARN ⚠ ($count failed)"
        ((WARNINGS++))
        log "HEALTH systemd_user_failed=WARN count=$count"
        {
            echo "### FAILED SYSTEMD UNITS (USER)"
            systemctl --user --failed --no-legend --plain 2>&1
        } >> "$LOG_FILE"
    fi
}

check_sysrq() {
    local sysrq_val="?"
    if [[ -f /proc/sys/kernel/sysrq ]]; then
        sysrq_val="$(< /proc/sys/kernel/sysrq)"
    fi

    if [[ "$sysrq_val" == "1" ]]; then
        add_row "Magic SysRq keys" "PASS ✔ (full emergency control enabled)"
        log "HEALTH sysrq=PASS val=1"
    elif [[ "$sysrq_val" == "0" ]]; then
        add_row "Magic SysRq keys" "WARN ⚠ (disabled: no emergency recovery)"
        ((WARNINGS++))
        log "HEALTH sysrq=WARN val=0"
    else
        add_row "Magic SysRq keys" "WARN ⚠ (restricted: val=$sysrq_val, REISUB disabled)"
        ((WARNINGS++))
        log "HEALTH sysrq=WARN val=$sysrq_val"
        {
            echo "### MAGIC SYSRQ RESTRICTION"
            echo "Current /proc/sys/kernel/sysrq value: $sysrq_val"
            echo "Emergency recovery (REISUB) and display unlock (Alt+SysRq+K) are disabled."
            echo "To enable emergency protection: echo 'kernel.sysrq = 1' | sudo tee /etc/sysctl.d/99-sysrq.conf"
            echo ""
        } >> "$LOG_FILE"
    fi
}

check_pacman_lock() {
    if [[ ! -e /var/lib/pacman/db.lck ]]; then
        add_row "Pacman DB lock" "PASS ✔"
        log "HEALTH pacman_lock=PASS absent"
        return
    fi

    if (sudo -n fuser /var/lib/pacman/db.lck 2>/dev/null || fuser /var/lib/pacman/db.lck 2>/dev/null || pgrep -x pacman &>/dev/null); then
        add_row "Pacman DB lock" "INFO ℹ (pacman is using it)"
        ((INFO_COUNT++))
        log "HEALTH pacman_lock=ACTIVE"
    else
        add_row "Pacman DB lock" "WARN ⚠ (stale lock)"
        ((WARNINGS++))
        log "HEALTH pacman_lock=WARN stale"
    fi
}

check_package_integrity() {
    if [[ "${SKIP_INTEGRITY:-0}" == "1" ]]; then
        add_row "Package file integrity" "INFO ℹ (skipped via config)"
        log "HEALTH package_integrity=SKIPPED"
        return
    fi

    local integrity_file="$RUN_RAW/pacman-integrity.txt"
    spinner "Checking package file integrity (pacman -Qk)..." \
        bash -c 'sudo -n pacman -Qk > "$1" 2>&1 || pacman -Qk > "$1" 2>&1 || true' _ "$integrity_file"
    PACMAN_INTEGRITY_TEXT="$(cat "$integrity_file" 2>/dev/null || true)"

    local problems
    problems="$(printf '%s\n' "$PACMAN_INTEGRITY_TEXT" |
        grep -v 'Permission denied' |
        grep -E 'warning:|missing files|No such file|not found' |
        grep -vE '0 missing files' || true)"

    if [[ -z "$problems" ]]; then
        add_row "Package file integrity" "PASS ✔"
        log "HEALTH package_integrity=PASS"
    else
        add_row "Package file integrity" "WARN ⚠ (review log)"
        ((WARNINGS++))
        log "HEALTH package_integrity=WARN"
        {
            echo "### PACMAN PACKAGE INTEGRITY"
            printf '%s\n' "$problems"
        } >> "$LOG_FILE"
    fi
}

check_pacnew() {
    PACNEWS="$(find /etc -type f -name '*.pacnew' 2>/dev/null || true)"

    if [[ -z "$PACNEWS" ]]; then
        add_row ".pacnew configuration files" "PASS ✔"
        log "HEALTH pacnew=0"
    else
        local count
        count="$(printf '%s\n' "$PACNEWS" | wc -l)"
        add_row ".pacnew configuration files" "WARN ⚠ ($count)"
        ((WARNINGS++))
        log "HEALTH pacnew=WARN count=$count"
        {
            echo "### PACNEW FILES"
            printf '%s\n' "$PACNEWS"
        } >> "$LOG_FILE"
    fi
}

check_dns() {
    if ! command -v dig &>/dev/null; then
        add_row "System DNS" "INFO ℹ (dig not installed)"
        ((INFO_COUNT++))
        log "HEALTH dns=dig_missing"
        return
    fi

    local test_host="${DNS_TEST_HOST:-archlinux.org}"
    local dig_cmd=(dig)
    if [[ -n "${DNS_TEST_SERVER:-}" ]]; then
        dig_cmd+=("@${DNS_TEST_SERVER}")
    fi
    dig_cmd+=("$test_host" "+time=2" "+tries=1")

    local dig_out qtime_num
    dig_out="$("${dig_cmd[@]}" 2>&1)"
    printf '%s\n' "$dig_out" > "$RUN_RAW/dig-test.txt"

    if ! printf '%s\n' "$dig_out" | grep -q 'status: NOERROR'; then
        add_row "System DNS" "WARN ⚠ (query failed or NOERROR not received)"
        ((WARNINGS++))
        log "HEALTH dns=WARN resolution_failed host=$test_host"
        return
    fi

    qtime_num="$(printf '%s\n' "$dig_out" | grep -oE 'Query time: [0-9]+' | grep -oE '[0-9]+')"
    qtime_num="${qtime_num:-?}"

    local server_note=""
    [[ -n "${DNS_TEST_SERVER:-}" ]] && server_note=" @${DNS_TEST_SERVER}"
    add_row "System DNS" "PASS ✔ (${qtime_num}ms${server_note})"
    log "HEALTH dns=PASS qtime=${qtime_num}ms host=$test_host"
}

check_updates() {
    if ! command -v checkupdates &>/dev/null; then
        add_row "Available updates" "INFO ℹ (pacman-contrib not installed)"
        ((INFO_COUNT++))
        log "HEALTH updates=missing_pacman-contrib"
        return
    fi

    local update_file="$RUN_RAW/checkupdates.txt"

    spinner "Checking for available updates..." \
        bash -c 'checkupdates > "$1" 2>/dev/null || true' _ "$update_file"

    UPDATES_TEXT="$(cat "$update_file" 2>/dev/null || true)"

    {
        echo "### AVAILABLE UPDATES"
        if [[ -n "$UPDATES_TEXT" ]]; then
            printf '%s\n' "$UPDATES_TEXT"
        else
            echo "No updates reported by checkupdates."
        fi
    } >> "$LOG_FILE"

    local count
    count="$(printf '%s\n' "$UPDATES_TEXT" | sed '/^$/d' | wc -l)"

    if (( count == 0 )); then
        add_row "Available updates" "PASS ✔ (none)"
        log "HEALTH updates=0"
    else
        local sensitive
        sensitive="$(printf '%s\n' "$UPDATES_TEXT" |
            grep -iE '^(linux|nvidia|amdgpu|mesa|dkms|systemd|glibc|dracut|xorg)' || true)"

        if [[ -n "$sensitive" ]]; then
            add_row "Available updates" "WARN ⚠ ($count; core components included)"
            ((WARNINGS++))
            log "HEALTH updates=WARN count=$count sensitive_core_updates=YES"
        else
            add_row "Available updates" "INFO ℹ ($count)"
            ((INFO_COUNT++))
            log "HEALTH updates=$count sensitive_core_updates=NO"
        fi
    fi
}

check_mirrorlist_age() {
    local arch_file="/etc/pacman.d/mirrorlist"
    local distro_file="/etc/pacman.d/endeavouros-mirrorlist"
    local now arch_days="?" distro_days="?"
    now=$(date +%s)

    if [[ -f "$arch_file" ]]; then
        local arch_mtime
        arch_mtime="$(stat -c %Y "$arch_file" 2>/dev/null || echo 0)"
        if (( arch_mtime > 0 )); then
            arch_days=$(( (now - arch_mtime) / 86400 ))
        fi
    fi

    if [[ -f "$distro_file" ]]; then
        local distro_mtime
        distro_mtime="$(stat -c %Y "$distro_file" 2>/dev/null || echo 0)"
        if (( distro_mtime > 0 )); then
            distro_days=$(( (now - distro_mtime) / 86400 ))
        fi
    fi

    if [[ "$arch_days" == "?" && "$distro_days" == "?" ]]; then
        add_row "Mirrorlist age" "WARN ⚠ (mirrorlists missing)"
        ((WARNINGS++))
        log "HEALTH mirrorlist_age=WARN missing_both"
        return
    fi

    local max_days=0
    [[ "$arch_days" =~ ^[0-9]+$ ]] && (( arch_days > max_days )) && max_days=$arch_days
    [[ "$distro_days" =~ ^[0-9]+$ ]] && (( distro_days > max_days )) && max_days=$distro_days

    local status_label=""
    if [[ -f "$distro_file" ]]; then
        status_label="Arch: ${arch_days}d │ Distro: ${distro_days}d"
    else
        status_label="Arch: ${arch_days}d"
    fi

    if (( max_days > 90 )); then
        add_row "Mirrorlist age" "WARN ⚠ ($status_label)"
        ((WARNINGS++))
        log "HEALTH mirrorlist_age=WARN arch_days=$arch_days distro_days=$distro_days max_days=$max_days"
    elif (( max_days > 45 )); then
        add_row "Mirrorlist age" "INFO ℹ ($status_label)"
        ((INFO_COUNT++))
        log "HEALTH mirrorlist_age=INFO arch_days=$arch_days distro_days=$distro_days"
    else
        add_row "Mirrorlist age" "PASS ✔ ($status_label)"
        log "HEALTH mirrorlist_age=PASS arch_days=$arch_days distro_days=$distro_days"
    fi
}

check_arch_news() {
    if ! command -v curl &>/dev/null; then
        return
    fi

    local rss_data item_title item_date
    rss_data="$(curl -fsS --max-time 3 https://archlinux.org/feeds/news/ 2>/dev/null || true)"

    if [[ -z "$rss_data" ]]; then
        log "HEALTH arch_news=UNAVAILABLE (network/timeout)"
        return
    fi

    item_title="$(printf '%s' "$rss_data" | awk -v RS='</?item>' 'NR==2' | grep -m 1 -oP '(?<=<title>).*?(?=</title>)' || true)"
    item_date="$(printf '%s' "$rss_data" | awk -v RS='</?item>' 'NR==2' | grep -m 1 -oP '(?<=<pubDate>).*?(?=</pubDate>)' || true)"

    if [[ -n "$item_title" ]]; then
        item_title="$(sed 's/&gt;/>/g; s/&lt;/</g; s/&amp;/\&/g; s/&quot;/"/g' <<< "$item_title")"
        if printf '%s' "$item_title" | grep -qi 'manual intervention'; then
            local pkg
            pkg="$(printf '%s' "$item_title" | awk '{print $1}')"
            if pacman -Q "$pkg" &>/dev/null; then
                add_row "Arch News (Latest)" "WARN ⚠ (manual intervention: $pkg)"
                ((WARNINGS++))
                log "HEALTH arch_news=WARN manual_intervention=YES affected=YES package=$pkg title=\"$item_title\""
            else
                add_row "Arch News (Latest)" "PASS ✔ (not affected: $pkg)"
                log "HEALTH arch_news=PASS manual_intervention=YES affected=NO package=$pkg title=\"$item_title\""
            fi
        else
            local short_title="$item_title"
            if (( ${#short_title} > 30 )); then
                short_title="${short_title:0:29}…"
            fi
            add_row "Arch News (Latest)" "PASS ✔ ($short_title)"
            log "HEALTH arch_news=PASS title=\"$item_title\""
        fi
    fi
}

check_arch_audit() {
    if ! command -v arch-audit &>/dev/null; then
        add_row "Arch security audit" "INFO ℹ (arch-audit unavailable)"
        ((INFO_COUNT++))
        log "HEALTH arch_audit=not_installed"
        return
    fi

    local act_file="$RUN_RAW/arch-audit-actionable.txt"
    local all_file="$RUN_RAW/arch-audit-tracker.txt"

    spinner "Checking security advisories (arch-audit)..." \
        bash -c 'arch-audit -u -c > "$1" 2>&1 || true; arch-audit -c > "$2" 2>&1 || true' _ "$act_file" "$all_file"

    ARCH_AUDIT_ACTIONABLE="$(cat "$act_file" 2>/dev/null || true)"
    ARCH_AUDIT_ALL="$(cat "$all_file" 2>/dev/null || true)"
    ARCH_AUDIT_TEXT="$ARCH_AUDIT_ALL"
    printf '%s\n' "$ARCH_AUDIT_ALL" > "$RUN_RAW/arch-audit.txt"

    if [[ "$ARCH_AUDIT_ALL" =~ (Error:|failed to) ]]; then
        add_row "Arch security audit" "INFO ℹ (tracker unreachable)"
        ((INFO_COUNT++))
        log "HEALTH arch_audit=INFO offline=YES"
        return
    fi

    local act_count=0 act_high=0
    if [[ -n "$ARCH_AUDIT_ACTIONABLE" ]]; then
        act_count="$(printf '%s\n' "$ARCH_AUDIT_ACTIONABLE" | sed '/^$/d' | wc -l)"
        act_high="$(printf '%s\n' "$ARCH_AUDIT_ACTIONABLE" | grep -ic 'High risk' || true)"
    fi
    ARCH_AUDIT_ACTIONABLE_COUNT="$act_count"

    local open_count=0 open_high=0 open_med=0
    if [[ -n "$ARCH_AUDIT_ALL" ]]; then
        open_count="$(printf '%s\n' "$ARCH_AUDIT_ALL" | sed '/^$/d' | wc -l)"
        open_high="$(printf '%s\n' "$ARCH_AUDIT_ALL" | grep -ic 'High risk' || true)"
        open_med="$(printf '%s\n' "$ARCH_AUDIT_ALL" | grep -ic 'Medium risk' || true)"
    fi
    ARCH_AUDIT_TRACKER_COUNT="$open_count"

    local aur_count=0
    if command -v pacman &>/dev/null; then
        pacman -Qm > "$RUN_RAW/foreign-packages.txt" 2>/dev/null || true
        aur_count="$(wc -l < "$RUN_RAW/foreign-packages.txt" 2>/dev/null || echo 0)"
    fi

    if (( act_count > 0 )); then
        if (( act_high > 0 )); then
            add_row "Arch security audit" "WARN ⚠ ($act_high actionable High risk)"
        else
            add_row "Arch security audit" "WARN ⚠ ($act_count actionable update(s))"
        fi
        ((WARNINGS++))
        log "HEALTH arch_audit=WARN actionable=$act_count actionable_high=$act_high tracker_open=$open_count"
    else
        add_row "Arch security audit" "PASS ✔ (0 actionable; $open_count tracker backlog)"
        log "HEALTH arch_audit=PASS actionable=0 tracker_open=$open_count tracker_high=$open_high"
    fi

    {
        echo "### ARCH SECURITY AUDIT"
        echo "Actionable updates in repositories: $act_count"
        echo "Arch Security Tracker open advisories: $open_count (High: $open_high, Medium: $open_med)"
        echo "Foreign (AUR) packages detected: $aur_count (arch-audit covers official repos only)"
        echo ""
        if (( act_count > 0 )); then
            echo "ACTIONABLE SECURITY UPDATES AVAILABLE IN REPOS:"
            printf '%s\n' "$ARCH_AUDIT_ACTIONABLE"
            echo ""
            echo "Recommendation: Run 'sudo pacman -Syu' (or distro update helper) to apply security updates."
            echo ""
        else
            echo "No pending security package upgrades found in official repositories."
            echo ""
        fi

        if (( open_count > 0 )); then
            echo "ARCH SECURITY TRACKER OPEN ADVISORIES (INFORMATIONAL / TRACKER BACKLOG):"
            echo "Note: Advisories where no 'Fixed' version is recorded on security.archlinux.org"
            echo "remain open indefinitely. On an updated rolling release, these are typically"
            echo "upstream/tracker bookkeeping backlog (e.g. 5.15 LTS kernel CVEs on 6.18 LTS,"
            echo "OpenSSL 1.1.1 issues on OpenSSL 3.x, pam 1.7.0 on 1.7.2) rather than live vulnerabilities."
            echo ""
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                local p ver note=""
                p="$(echo "$line" | awk '{print $1}')"
                ver="$(pacman -Q "$p" 2>/dev/null | awk '{print $2}' || echo 'unknown')"
                if [[ "$p" =~ ^linux && "$line" =~ CVE-202[0-3] ]]; then
                    note=" [stale advisory: targets older kernel series]"
                elif [[ "$p" == "openssl" && "$line" =~ CVE-2022-2068 ]]; then
                    note=" [stale advisory: CVE-2022-2068 affected OpenSSL 1.1.1 branch]"
                elif [[ "$p" == "pam" && "$line" =~ CVE-2025-6020 ]]; then
                    note=" [upstream fixed in 1.7.1; unclosed tracker ticket]"
                elif [[ "$p" == "djvulibre" && "$line" =~ CVE-2025-53367 ]]; then
                    note=" [upstream fixed in 3.5.29; unclosed tracker ticket]"
                elif [[ "$p" == "libxml2" && "$line" =~ CVE-2025- ]]; then
                    note=" [upstream fixed in 2.14.5+/2.15.x; unclosed tracker ticket]"
                elif [[ "$p" == "cpio" && "$line" =~ CVE-2021-38185 ]]; then
                    note=" [upstream fixed in 2.14; unclosed tracker ticket]"
                elif [[ "$p" == "grub" && "$line" =~ CVE-202[1-2] ]]; then
                    note=" [stale advisory: targets GRUB 2.06; unclosed tracker ticket]"
                fi
                echo "  • $p ($ver): ${line#*is affected by }${note}"
            done <<< "$ARCH_AUDIT_ALL"
            echo ""
        fi

        if (( aur_count > 0 )); then
            echo "AUR / FOREIGN PACKAGES NOTICE:"
            echo "Official-repo arch-audit does not track foreign / AUR packages."
            echo "Detected $aur_count foreign package(s) on host (see $RUN_RAW/foreign-packages.txt)."
            echo "Audit and update foreign packages via your AUR helper (yay/paru)."
            echo ""
        fi
    } >> "$LOG_FILE"
}

generate_summary_json() {
    local running_k drivers=""
    running_k="$(uname -r 2>/dev/null || echo 'unknown')"

    local vga_info
    vga_info="$(lspci -k 2>/dev/null | grep -A 4 -iE 'VGA|3D|Display' || true)"
    if [[ -n "$vga_info" ]]; then
        drivers="$(printf '%s\n' "$vga_info" | grep 'Kernel driver in use:' | awk '{print $5}' | sort -u | tr '\n' ' ' | sed 's/ $//' || true)"
    fi

    local status_str="ALL_CLEAR"
    if (( ERRORS > 0 )); then
        status_str="ACTION_REQUIRED"
    elif (( WARNINGS > 0 )); then
        status_str="REVIEW_WARNINGS"
    fi

    local warn_list_json="[]"
    if (( WARNINGS > 0 || ERRORS > 0 )); then
        warn_list_json="$(grep -E '^HEALTH .*=(WARN|FAIL)' "$LOG_FILE" 2>/dev/null |
            awk '{print $2}' | cut -d= -f1 | sort -u | jq -R . | jq -s . 2>/dev/null || echo '[]')"
    fi

    local aur_pkg_count=0
    if [[ -f "$RUN_RAW/foreign-packages.txt" ]]; then
        aur_pkg_count="$(wc -l < "$RUN_RAW/foreign-packages.txt" 2>/dev/null || echo 0)"
    fi

    if command -v jq &>/dev/null; then
        jq -n \
            --arg ts "$(date --iso-8601=seconds)" \
            --arg run_id "$RUN_ID" \
            --arg status "$status_str" \
            --argjson errors "$ERRORS" \
            --argjson warnings "$WARNINGS" \
            --argjson flagged "$warn_list_json" \
            --arg kernel "$running_k" \
            --arg drivers "$drivers" \
            --argjson sec_actionable "${ARCH_AUDIT_ACTIONABLE_COUNT:-0}" \
            --argjson sec_tracker "${ARCH_AUDIT_TRACKER_COUNT:-0}" \
            --argjson aur_pkgs "$aur_pkg_count" \
            '{
                timestamp: $ts,
                run_id: $run_id,
                status: $status,
                counts: {errors: $errors, warnings: $warnings},
                flagged: $flagged,
                kernel: $kernel,
                gpu: {drivers_in_use: $drivers},
                security: {
                    actionable_fixes: $sec_actionable,
                    tracker_open: $sec_tracker,
                    aur_packages: $aur_pkgs
                }
            }' > "$SUMMARY_FILE" 2>/dev/null || true
    else
        echo '{"status": "'$status_str'", "errors": '$ERRORS', "warnings": '$WARNINGS'}' > "$SUMMARY_FILE"
    fi
}

run_health_check() {
    section "SYSTEM HEALTH AUDIT"

    AUDIT_TABLE=""
    AUDIT_TABLE_BOOT=""
    AUDIT_TABLE_HW=""
    AUDIT_TABLE_SYS=""
    AUDIT_TABLE_NET=""
    AUDIT_TABLE_OTHER=""
    FAILED_SERVICES=""
    FAILED_USER_SERVICES=""
    ERRORS=0
    WARNINGS=0
    INFO_COUNT=0

    collect_system_snapshot

    check_kernel
    check_initramfs "$(uname -r)"
    check_efi_mount
    check_reboot_pending
    check_previous_boot

    check_gpu
    check_gpu_errors
    check_dkms
    check_temperature
    check_smart
    check_fstrim

    check_root_space
    check_failed_services
    check_sysrq
    check_pacman_lock
    check_package_integrity
    check_pacnew

    check_dns
    check_updates
    check_mirrorlist_age
    check_arch_news
    check_arch_audit

    log ""
    log "### END OF REPORT"
    log "Summary: errors=$ERRORS warnings=$WARNINGS info=$INFO_COUNT"

    refresh_state_snapshot
    generate_summary_json

    render_audit_section "BOOT & CORE OS" "$AUDIT_TABLE_BOOT"
    render_audit_section "HARDWARE & DRIVERS" "$AUDIT_TABLE_HW"
    render_audit_section "SYSTEM HEALTH & SERVICES" "$AUDIT_TABLE_SYS"
    render_audit_section "NETWORK & UPDATES" "$AUDIT_TABLE_NET"
    if [[ -n "$AUDIT_TABLE_OTHER" ]]; then
        render_audit_section "OTHER CHECKS" "$AUDIT_TABLE_OTHER"
    fi

    echo ""
    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        if (( ERRORS == 0 && WARNINGS == 0 )); then
            gum style \
                --foreground 82 \
                --border double \
                --align center \
                --width 68 \
                "SYSTEM HEALTH: ALL CLEAR ✔"
        elif (( ERRORS == 0 )); then
            gum style \
                --foreground 214 \
                --border double \
                --align center \
                --width 68 \
                "SYSTEM HEALTH: REVIEW WARNINGS ⚠"
        else
            gum style \
                --foreground 196 \
                --border double \
                --align center \
                --width 68 \
                "SYSTEM HEALTH: ACTION REQUIRED ✖"
        fi

        echo ""
        gum style --foreground 244 \
            "Report: $LOG_FILE"
    else
        if (( ERRORS == 0 && WARNINGS == 0 )); then
            echo "SYSTEM HEALTH: ALL CLEAR ✔"
        elif (( ERRORS == 0 )); then
            echo "SYSTEM HEALTH: REVIEW WARNINGS ⚠"
        else
            echo "SYSTEM HEALTH: ACTION REQUIRED ✖"
        fi
        echo "Report: $LOG_FILE"
    fi
}

show_report() {
    section "LATEST REPORT"

    if [[ -s "$LOG_FILE" ]]; then
        if command -v less &>/dev/null; then
            less -R "$LOG_FILE"
        else
            cat "$LOG_FILE"
        fi
    else
        warn "No report exists yet."
    fi
}

show_ai_prompt() {
    section "AI AGENT HANDOFF"

    local intro="The following prompt can be pasted into your AI coding assistant (Goose, Claude, ChatGPT, etc.):"
    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        gum style --foreground 81 "$intro"
    else
        echo "$intro"
    fi

    cat <<EOF

Read the System Health state summary at:
$SUMMARY_FILE

Additional system snapshot details at:
$STATE_SNAPSHOT

Detailed logs and health findings:
$LOG_FILE

Analyze the report conservatively. Prioritize system boot stability and core Arch packages. Do NOT execute system-breaking commands without asking first.
EOF
}

live_monitor() {
    section "LIVE MONITOR"

    if command -v btop &>/dev/null; then
        btop
    elif command -v glances &>/dev/null; then
        glances
    else
        warn "Neither btop nor glances found."
        if gum confirm "Install btop?"; then
            sudo pacman -S --needed --noconfirm btop && btop
        else
            pause_screen
        fi
    fi
}

# ------------------------------------------------------------------------------
# Non-interactive execution entry points
# ------------------------------------------------------------------------------

if [[ "$ACTION" == "maintenance" ]]; then
    run_maintenance "Safe Maintenance"
    run_health_check
    if (( ERRORS > 0 )); then
        exit 1
    elif (( WARNINGS > 0 )); then
        exit 2
    else
        exit 0
    fi
fi

if [[ "$ACTION" == "audit" ]]; then
    run_health_check
    if (( ERRORS > 0 )); then
        exit 1
    elif (( WARNINGS > 0 )); then
        exit 2
    else
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# Main menu
# ------------------------------------------------------------------------------

while true; do
    ui_title

    MODE="$(
        gum choose \
            --header "Select action:" \
            "1. System Health Audit (Read-Only)" \
            "2. AI Agent Handoff & Summary" \
            "3. View Latest Audit Report" \
            "4. Safe Maintenance & Health Audit" \
            "5. Deep Clean (Trash & Browser Caches)" \
            "6. Live System Monitor" \
            "7. Exit"
    )"

    case "$MODE" in
        "1. System Health Audit (Read-Only)")
            ui_screen "System Health Audit"
            run_health_check
            pause_screen
            ;;
        "2. AI Agent Handoff & Summary")
            ui_screen "AI Agent Handoff"
            show_ai_prompt
            pause_screen
            ;;
        "3. View Latest Audit Report")
            ui_screen "Latest Audit Report"
            show_report
            pause_screen
            ;;
        "4. Safe Maintenance & Health Audit")
            ui_screen "Safe Maintenance & Health Audit"
            run_maintenance "Safe Maintenance"
            run_health_check
            pause_screen
            ;;
        "5. Deep Clean (Trash & Browser Caches)")
            ui_screen "Deep Clean"
            gum style --foreground 214 \
                "Deep clean empties Desktop Trash, browser caches (cache2), and coredumps."
            if gum confirm "Continue with deep clean?"; then
                run_maintenance "Deep Clean"
                run_health_check
            else
                info "Deep clean cancelled — nothing was changed."
            fi
            pause_screen
            ;;
        "6. Live System Monitor")
            ui_screen "Live System Monitor"
            live_monitor
            ;;
        "7. Exit")
            clear
            exit 0
            ;;
    esac
done
