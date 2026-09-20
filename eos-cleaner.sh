#!/usr/bin/env bash
# ==============================================================================
# EOS Cleaner & System Health v2.2
# Safe maintenance + detailed diagnostics + AI Agent-friendly report
# EndeavourOS / Arch Linux
# ==============================================================================

set -o pipefail

VERSION="2.2"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/eos-cleaner"
LOG_FILE="$STATE_DIR/eos-cleaner.log"
SUMMARY_FILE="$STATE_DIR/summary.json"
STATE_SNAPSHOT="$STATE_DIR/eos-software-state.txt"
RAW_DIR="$STATE_DIR/runs"

# Optional: Gateway/Router IP for DNS checks (auto-detected if blank)
GATEWAY_IP="${GATEWAY_IP:-}"

mkdir -p "$STATE_DIR" "$RAW_DIR" 2>/dev/null || true

# ------------------------------------------------------------------------------
# Safety / environment
# ------------------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "Please run this script as your normal user. sudo will be requested when needed."
    exit 1
fi

if ! command -v gum &>/dev/null; then
    echo "gum is required. Installing it..."
    sudo pacman -S --needed gum || exit 1
fi

RUN_ID="$(date '+%Y%m%d-%H%M%S')"
RUN_RAW="$RAW_DIR/$RUN_ID"
mkdir -p "$RUN_RAW"

PREVIOUS_RUN_SUMMARY=""
if [[ -s "$LOG_FILE" ]]; then
    PREVIOUS_RUN_SUMMARY="$(grep '^Summary:' "$LOG_FILE" | tail -n1)"
fi

: > "$LOG_FILE"

# Keep sudo credentials alive while this script is running.
sudo -v || exit 1
(
    while true; do
        sudo -n true
        sleep 45
        kill -0 "$$" 2>/dev/null || exit
    done
) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT

# ------------------------------------------------------------------------------
# UI
# ------------------------------------------------------------------------------

ui_title() {
    clear
    if command -v figlet &>/dev/null && command -v lolcat &>/dev/null; then
        figlet -f standard "EOS SYSTEM" | lolcat
    else
        gum style \
            --foreground 214 \
            --border double \
            --align center \
            --width 68 \
            "ENDEAVOUROS SYSTEM"
    fi

    gum style \
        --foreground 244 \
        --align center \
        --width 68 \
        "Maintenance • Health • Diagnostics  |  v$VERSION"

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
        "EOS SYSTEM  ›  $1"
    echo ""
}

section() {
    echo ""
    gum style \
        --foreground 214 \
        --border normal \
        --padding "0 1" \
        "$1"
}

ok()   { gum style --foreground 82  "✔ $1"; }
warn() { gum style --foreground 214 "⚠ $1"; }
fail() { gum style --foreground 196 "✖ $1"; }
info() { gum style --foreground 81  "ℹ $1"; }

spinner() {
    local title="$1"
    shift
    gum spin --spinner dot --title "$title" -- "$@"
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
ORPHAN_NOTE="Orphan package detection handled dynamically."
UPDATES_TEXT=""
ARCH_AUDIT_TEXT=""
PACMAN_INTEGRITY_TEXT=""
DKMS_TEXT=""
NVIDIA_SMI_TEXT=""
SENSORS_TEXT=""

add_row() {
    local comp="$1"
    local clean_status="${2//|/-}"
    local sec="${3:-}"

    if [[ -z "$sec" ]]; then
        case "$comp" in
            "Kernel & modules"|"Initramfs"*|"EFI partition"*|"Reboot pending")
                sec="BOOT"
                ;;
            "NVIDIA"*|"DKMS"*|"CPU temperature"|"SMART disk health"|"SSD/NVMe TRIM timer")
                sec="HW"
                ;;
            "Root disk space"|"Systemd failed"*|"Pacman DB lock"|"Package file integrity"|".pacnew"*)
                sec="SYS"
                ;;
            "Gateway DNS"|"Available updates"|"Arch News"*|"Arch security audit"|"Mirrorlist age"*)
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
}

# ------------------------------------------------------------------------------
# System snapshot
# ------------------------------------------------------------------------------

collect_system_snapshot() {
    log "============================================================"
    log "EOS CLEANER REPORT"
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
            echo '=== EOS SOFTWARE STATE SNAPSHOT ==='
            echo \"Generated on: ${ts}\"
            echo ''
            echo '--- 1. Kernel Information ---'
            uname -a
            echo ''
            echo '--- 2. Installed Linux Kernels & Headers ---'
            pacman -Q 2>/dev/null | grep -E '^linux'
            echo ''
            echo '--- 3. NVIDIA Packages & Drivers ---'
            pacman -Q 2>/dev/null | grep -iE 'nvidia|libva-nvidia|vulkan-nouveau'
            echo ''
            echo '--- 4. DKMS Status ---'
            dkms status 2>/dev/null || echo '(dkms not available)'
            echo ''
            echo '--- 5. Loaded GPU Kernel Modules ---'
            lsmod 2>/dev/null | grep -E '^nvidia|^nouveau|^drm'
            echo ''
            echo '--- 6. GPU Hardware & Kernel Driver in Use ---'
            lspci -k 2>/dev/null | grep -A3 -iE 'VGA|3D|Display'
            echo ''
            echo '--- 7. Dracut Configuration Files ---'
            ls -la /etc/dracut.conf.d/ 2>/dev/null
            cat /etc/dracut.conf.d/*.conf 2>/dev/null
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
        spinner "Cleaning unused AUR build/cache data..." yay -Sc --noconfirm
        ok "AUR cache cleanup completed."
        log "MAINTENANCE aur_cache=cleaned"
    elif command -v paru &>/dev/null; then
        spinner "Cleaning unused AUR build/cache data..." paru -Sc --noconfirm
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

    if [[ "$mode" == "Deep Clean & Health" ]]; then
        section "DEEP CLEAN"

        rm -rf -- \
            "$HOME/.local/share/Trash/files/"* \
            "$HOME/.local/share/Trash/info/"* 2>/dev/null || true
        ok "Desktop trash cleaned."
        log "MAINTENANCE trash=cleaned"

        if [[ -d "$HOME/.cache/mozilla/firefox" ]]; then
            spinner "Cleaning Firefox cache..." \
                bash -c 'find "$HOME/.cache/mozilla/firefox/" -type d -name "cache2" -exec rm -rf -- {}/* \; 2>/dev/null || true'
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
        add_row "Initramfs ($pkgbase)" "FAIL ✖ (missing: $normal)"
        ((ERRORS++))
        log "HEALTH initramfs=FAIL normal_missing=$normal pkgbase=$pkgbase"
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

check_nvidia() {
    if ! command -v nvidia-smi &>/dev/null; then
        info "NVIDIA runtime not detected or nvidia-smi unavailable."
        log "HEALTH nvidia=not_applicable"
        return
    fi

    local nvidia_out gpu driver gpu_temp
    nvidia_out="$(nvidia-smi 2>&1 || true)"

    if printf '%s\n' "$nvidia_out" | grep -q 'NVIDIA-SMI'; then
        gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
        driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
        gpu_temp="$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -n1)"

        if [[ -n "$gpu_temp" ]]; then
            add_row "NVIDIA runtime" "PASS ✔ (${gpu:-GPU} | ${gpu_temp}°C)"
            printf '%s\n' "$nvidia_out" > "$RUN_RAW/nvidia-smi.txt"
        else
            add_row "NVIDIA runtime" "PASS ✔ (${gpu:-GPU} / ${driver:-driver unknown})"
        fi
    else
        add_row "NVIDIA runtime" "FAIL ✖"
        ((ERRORS++))
        log "HEALTH nvidia=FAIL"
        {
            echo "### ERROR: NVIDIA GPU FAILURE"
            printf '%s\n' "$nvidia_out"
        } >> "$LOG_FILE"
    fi

    if lsmod | grep -q '^nouveau'; then
        add_row "NVIDIA nouveau module" "WARN ⚠ (loaded)"
        ((WARNINGS++))
        log "HEALTH nouveau=WARN loaded"
    else
        log "HEALTH nouveau=not_loaded"
    fi
}

check_gateway_dns() {
    local target="$GATEWAY_IP"

    if [[ -z "$target" ]]; then
        target="$(ip route show default 2>/dev/null |
            awk '/default/ {for (i=1;i<=NF;i++) if ($i=="via") print $(i+1)}' |
            head -n1)"
    fi
    target="${target:-1.1.1.1}"

    if ! command -v dig &>/dev/null; then
        add_row "Gateway DNS" "INFO ℹ (dig not installed)"
        ((INFO_COUNT++))
        log "HEALTH dns_gateway=dig_missing"
        return
    fi

    local dig_out qtime_num
    dig_out="$(dig "@$target" archlinux.org +time=2 +tries=1 2>&1)"
    printf '%s\n' "$dig_out" > "$RUN_RAW/dig-gateway.txt"

    if ! printf '%s\n' "$dig_out" | grep -q 'status: NOERROR'; then
        add_row "Gateway DNS" "WARN ⚠ ($target unreachable or query failed)"
        ((WARNINGS++))
        log "HEALTH dns_gateway=WARN target=$target"
        return
    fi

    qtime_num="$(printf '%s\n' "$dig_out" | grep -oE 'Query time: [0-9]+' | grep -oE '[0-9]+')"
    qtime_num="${qtime_num:-?}"

    add_row "Gateway DNS" "PASS ✔ (${qtime_num}ms via $target)"
    log "HEALTH dns_gateway=PASS target=$target qtime=${qtime_num}ms"
}

check_efi_mount() {
    local efi_mnt
    efi_mnt="$(findmnt --real -n -o TARGET,FSTYPE /boot/efi 2>/dev/null || true)"

    if [[ -z "$efi_mnt" ]]; then
        add_row "EFI partition (/boot/efi)" "FAIL ✖ (not mounted)"
        ((ERRORS++))
        log "HEALTH efi=FAIL mounted=NO"
        return
    fi

    if ! printf '%s\n' "$efi_mnt" | grep -qi 'vfat'; then
        add_row "EFI partition (/boot/efi)" "WARN ⚠ (unexpected filesystem: $efi_mnt)"
        ((WARNINGS++))
        log "HEALTH efi=WARN fstype_not_vfat fstype=$efi_mnt"
        return
    fi

    local avail_mb
    avail_mb="$(df -BM /boot/efi 2>/dev/null | awk 'NR==2 {gsub("M","",$4); print $4}')"

    if [[ -n "$avail_mb" ]] && (( avail_mb < 30 )); then
        add_row "EFI partition (/boot/efi)" "WARN ⚠ (low free space: ${avail_mb}MB)"
        ((WARNINGS++))
        log "HEALTH efi=WARN low_space=${avail_mb}MB"
    else
        add_row "EFI partition (/boot/efi)" "PASS ✔ (mounted vfat, free: ${avail_mb:-?}MB)"
        log "HEALTH efi=PASS free_mb=${avail_mb:-unknown}"
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

    item_title="$(printf '%s' "$rss_data" | grep -m 1 -oP '(?<=<title>).*?(?=</title>)' | sed '1d' | head -n1 || true)"
    item_date="$(printf '%s' "$rss_data" | grep -m 1 -oP '(?<=<pubDate>).*?(?=</pubDate>)' | head -n1 || true)"

    if [[ -n "$item_title" ]]; then
        item_title="$(sed 's/&gt;/>/g; s/&lt;/</g; s/&amp;/\&/g; s/&quot;/"/g' <<< "$item_title")"
        printf 'Title: %s\nDate: %s\n' "$item_title" "$item_date" > "$RUN_RAW/latest-arch-news.txt"
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

check_pacman_lock() {
    if [[ ! -e /var/lib/pacman/db.lck ]]; then
        add_row "Pacman DB lock" "PASS ✔"
        log "HEALTH pacman_lock=PASS absent"
        return
    fi

    if fuser /var/lib/pacman/db.lck &>/dev/null; then
        add_row "Pacman DB lock" "INFO ℹ (pacman is using it)"
        ((INFO_COUNT++))
        log "HEALTH pacman_lock=ACTIVE"
    else
        add_row "Pacman DB lock" "WARN ⚠ (stale lock)"
        ((WARNINGS++))
        log "HEALTH pacman_lock=WARN stale"
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

check_package_integrity() {
    PACMAN_INTEGRITY_TEXT="$(sudo pacman -Qk 2>&1 || true)"
    printf '%s\n' "$PACMAN_INTEGRITY_TEXT" > "$RUN_RAW/pacman-integrity.txt"

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
        add_row "CPU temperature" "PASS ✔ ($cpu_temp)"
        log "HEALTH cpu_temperature=PASS value=$cpu_temp"
    else
        add_row "CPU temperature" "INFO ℹ (not detected)"
        ((INFO_COUNT++))
        log "HEALTH cpu_temperature=not_detected"
    fi
}

check_updates() {
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
            grep -iE '(^|[[:space:]])(linux|linux-headers|nvidia|nvidia-utils|lib32-nvidia|dkms|systemd|glibc|dracut|mesa|xorg)([[:space:]]|$)' || true)"

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

check_arch_audit() {
    if ! command -v arch-audit &>/dev/null; then
        add_row "Arch security audit" "INFO ℹ (arch-audit unavailable)"
        ((INFO_COUNT++))
        log "HEALTH arch_audit=not_installed"
        return
    fi

    ARCH_AUDIT_TEXT="$(arch-audit 2>&1 || true)"
    printf '%s\n' "$ARCH_AUDIT_TEXT" > "$RUN_RAW/arch-audit.txt"

    local high
    high="$(printf '%s\n' "$ARCH_AUDIT_TEXT" | grep -ic 'High risk' || true)"

    if (( high > 0 )); then
        add_row "Arch security audit" "WARN ⚠ ($high high-risk entries)"
        ((WARNINGS++))
        log "HEALTH arch_audit=WARN high_risk=$high"
    else
        add_row "Arch security audit" "PASS ✔"
        log "HEALTH arch_audit=PASS"
    fi
}

check_mirrorlist_age() {
    local arch_file="/etc/pacman.d/mirrorlist"
    local eos_file="/etc/pacman.d/endeavouros-mirrorlist"
    local now arch_days="?" eos_days="?"
    now=$(date +%s)

    if [[ -f "$arch_file" ]]; then
        local arch_mtime
        arch_mtime="$(stat -c %Y "$arch_file" 2>/dev/null || echo 0)"
        if (( arch_mtime > 0 )); then
            arch_days=$(( (now - arch_mtime) / 86400 ))
        fi
    fi

    if [[ -f "$eos_file" ]]; then
        local eos_mtime
        eos_mtime="$(stat -c %Y "$eos_file" 2>/dev/null || echo 0)"
        if (( eos_mtime > 0 )); then
            eos_days=$(( (now - eos_mtime) / 86400 ))
        fi
    fi

    if [[ "$arch_days" == "?" && "$eos_days" == "?" ]]; then
        add_row "Mirrorlist age" "WARN ⚠ (mirrorlists missing)"
        ((WARNINGS++))
        log "HEALTH mirrorlist_age=WARN missing_both"
        return
    fi

    add_row "Mirrorlist age" "PASS ✔ (Arch: ${arch_days}d │ EOS: ${eos_days}d)"
    log "HEALTH mirrorlist_age=PASS arch_days=$arch_days eos_days=$eos_days"
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
    done < <(lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk" {print "/dev/"$1}')

    if [[ ${#disks[@]} -eq 0 ]]; then
        add_row "SMART disk health" "INFO ℹ (no disks detected)"
        ((INFO_COUNT++))
        log "HEALTH smart=no_disks"
        return
    fi

    local failed=0 passed=0 total="${#disks[@]}"
    for dev in "${disks[@]}"; do
        local result
        result="$(sudo smartctl -H "$dev" 2>&1 || true)"
        if printf '%s\n' "$result" | grep -qiE 'PASSED|test result: ok'; then
            (( passed++ ))
        elif printf '%s\n' "$result" | grep -qiE 'FAILED!'; then
            (( failed++ ))
        fi
    done

    if (( failed > 0 )); then
        add_row "SMART disk health" "FAIL ✖ ($failed/$total disk(s) failed)"
        ((ERRORS++))
        log "HEALTH smart=FAIL failed=$failed"
    else
        add_row "SMART disk health" "PASS ✔ ($passed/$total OK)"
        log "HEALTH smart=PASS passed=$passed"
    fi
}

generate_summary_json() {
    local running_k gpu_name driver_ver gpu_t
    running_k="$(uname -r 2>/dev/null || echo 'unknown')"
    gpu_name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 || echo 'unknown')"
    driver_ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || echo 'unknown')"

    local status_str="ALL_CLEAR"
    if (( ERRORS > 0 )); then
        status_str="ACTION_REQUIRED"
    elif (( WARNINGS > 0 )); then
        status_str="REVIEW_WARNINGS"
    fi

    jq -n \
        --arg ts "$(date --iso-8601=seconds)" \
        --arg run_id "$RUN_ID" \
        --arg status "$status_str" \
        --argjson errors "$ERRORS" \
        --argjson warnings "$WARNINGS" \
        --arg kernel "$running_k" \
        --arg gpu "$gpu_name" \
        --arg driver "$driver_ver" \
        '{
            timestamp: $ts,
            run_id: $run_id,
            status: $status,
            counts: {errors: $errors, warnings: $warnings},
            kernel: $kernel,
            nvidia: {gpu: $gpu, driver: $driver}
        }' > "$SUMMARY_FILE" 2>/dev/null || true
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

    check_nvidia
    check_dkms
    check_temperature
    check_smart
    check_fstrim

    check_root_space
    check_failed_services
    check_pacman_lock
    check_package_integrity
    check_pacnew

    check_gateway_dns
    check_updates
    check_mirrorlist_age
    check_arch_news
    check_arch_audit

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

    cat <<EOF
$(gum style --foreground 81 "The following prompt can be pasted into your AI coding assistant:")

Read the EOS Cleaner state summary at:
$SUMMARY_FILE

Additional system snapshot details at:
$STATE_SNAPSHOT

Detailed error logs (if any warnings exist) are available at:
$LOG_FILE

Analyze the report conservatively and suggest solutions. Do NOT execute system-breaking commands without asking first.
EOF
}

live_monitor() {
    section "LIVE MONITOR"

    if command -v btop &>/dev/null; then
        exec btop
    elif command -v glances &>/dev/null; then
        exec glances
    else
        warn "Neither btop nor glances found."
        if gum confirm "Install btop?"; then
            sudo pacman -S --needed --noconfirm btop && exec btop
        fi
    fi
}

# ------------------------------------------------------------------------------
# Main menu
# ------------------------------------------------------------------------------

while true; do
    ui_title

    MODE="$(
        gum choose \
            --header "What would you like to do?" \
            "Standard Clean & Health" \
            "Deep Clean & Health" \
            "Health Check Only" \
            "View Last Report" \
            "AI Agent Handoff" \
            "Live Monitor" \
            "Exit"
    )"

    case "$MODE" in
        "Standard Clean & Health")
            ui_screen "Standard Clean & Health"
            run_maintenance "$MODE"
            run_health_check
            pause_screen
            ;;
        "Deep Clean & Health")
            ui_screen "Deep Clean & Health"
            gum style --foreground 214 \
                "Deep clean also empties Trash, browser caches, and coredumps."
            if gum confirm "Continue with deep clean?"; then
                run_maintenance "$MODE"
                run_health_check
            else
                info "Deep clean cancelled — nothing was changed."
            fi
            pause_screen
            ;;
        "Health Check Only")
            ui_screen "Health Check Only"
            run_health_check
            pause_screen
            ;;
        "View Last Report")
            ui_screen "View Last Report"
            show_report
            pause_screen
            ;;
        "AI Agent Handoff")
            ui_screen "AI Agent Handoff"
            show_ai_prompt
            pause_screen
            ;;
        "Live Monitor")
            ui_screen "Live Monitor"
            live_monitor
            ;;
        "Exit")
            clear
            exit 0
            ;;
    esac
done
