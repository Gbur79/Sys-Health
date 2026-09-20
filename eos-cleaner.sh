#!/usr/bin/env bash
# ==============================================================================
# EOS Cleaner & System Health
# Safe maintenance + detailed diagnostics + AI-friendly report
# EndeavourOS / Arch Linux
# ==============================================================================

set -o pipefail

VERSION="2.0"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/eos-cleaner"
LOG_FILE="$STATE_DIR/eos-cleaner.log"
RAW_DIR="$STATE_DIR/runs"

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
ERRORS=0
WARNINGS=0
INFO_COUNT=0

FAILED_SERVICES=""
PACNEWS=""
ORPHAN_NOTE="Orphan package detection handled dynamically."
UPDATES_TEXT=""
ARCH_AUDIT_TEXT=""
PACMAN_INTEGRITY_TEXT=""
DKMS_TEXT=""
NVIDIA_SMI_TEXT=""
SENSORS_TEXT=""

add_row() {
    AUDIT_TABLE+="$1 | $2\n"
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
    local normal="/boot/initramfs-${running}.img"
    local fallback="/boot/initramfs-${running}-fallback.img"

    if [[ -f "$normal" ]]; then
        if [[ -f "$fallback" ]]; then
            add_row "Initramfs" "PASS ✔ (normal + fallback)"
            log "HEALTH initramfs=PASS normal=present fallback=present"
        else
            add_row "Initramfs" "WARN ⚠ (normal present, fallback missing)"
            ((WARNINGS++))
            log "HEALTH initramfs=WARN normal=present fallback=missing"
        fi
    else
        add_row "Initramfs" "FAIL ✖"
        ((ERRORS++))
        log "HEALTH initramfs=FAIL normal_missing=$normal"
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

    NVIDIA_SMI_TEXT="$(nvidia-smi 2>&1 || true)"
    printf '%s\n' "$NVIDIA_SMI_TEXT" > "$RUN_RAW/nvidia-smi.txt"

    if printf '%s\n' "$NVIDIA_SMI_TEXT" | grep -q 'NVIDIA-SMI'; then
        local gpu driver
        gpu="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
        driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1)"
        add_row "NVIDIA runtime" "PASS ✔ (${gpu:-GPU} / ${driver:-driver unknown})"
        log "HEALTH nvidia=PASS gpu=${gpu:-unknown} driver=${driver:-unknown}"
    else
        add_row "NVIDIA runtime" "FAIL ✖"
        ((ERRORS++))
        log "HEALTH nvidia=FAIL"
    fi

    if lsmod | grep -q '^nouveau'; then
        add_row "NVIDIA nouveau module" "WARN ⚠ (loaded)"
        ((WARNINGS++))
        log "HEALTH nouveau=WARN loaded"
    else
        log "HEALTH nouveau=not_loaded"
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
        log "HEALTH dkms=WARN"
    else
        add_row "DKMS modules" "PASS ✔"
        log "HEALTH dkms=PASS"
    fi
}

check_failed_services() {
    FAILED_SERVICES="$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | sed '/^$/d')"

    if [[ -z "$FAILED_SERVICES" ]]; then
        add_row "Systemd failed units" "PASS ✔"
        log "HEALTH systemd_failed=0"
    else
        local count
        count="$(printf '%s\n' "$FAILED_SERVICES" | wc -l)"
        add_row "Systemd failed units" "WARN ⚠ ($count)"
        ((WARNINGS++))
        log "HEALTH systemd_failed=$count"
        {
            echo "### FAILED SYSTEMD UNITS"
            systemctl --failed --no-legend --plain 2>&1
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
        log "HEALTH pacnew=$count"
        {
            echo "### PACNEW FILES"
            printf '%s\n' "$PACNEWS"
        } >> "$LOG_FILE"
    fi
}

check_package_integrity() {
    PACMAN_INTEGRITY_TEXT="$(pacman -Qk 2>&1 || true)"
    printf '%s\n' "$PACMAN_INTEGRITY_TEXT" > "$RUN_RAW/pacman-integrity.txt"

    local problems
    problems="$(printf '%s\n' "$PACMAN_INTEGRITY_TEXT" | grep -E 'warning:|missing files|No such file|not found' | grep -vE '0 missing files' || true)"

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

    SENSORS_TEXT="$(sensors 2>&1 || true)"
    printf '%s\n' "$SENSORS_TEXT" > "$RUN_RAW/sensors.txt"

    local temp
    temp="$(printf '%s\n' "$SENSORS_TEXT" |
        grep -iE 'Package id 0|Tctl|Core 0' |
        grep -oE '[+-]?[0-9]+([.][0-9]+)?°C' |
        head -n1)"

    if [[ -n "$temp" ]]; then
        add_row "CPU temperature" "PASS ✔ ($temp)"
        log "HEALTH cpu_temperature=PASS value=$temp"
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
            log "HEALTH updates=$count sensitive_core_updates=YES"
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

    {
        echo "### ARCH-AUDIT"
        printf '%s\n' "$ARCH_AUDIT_TEXT"
    } >> "$LOG_FILE"
}

# ------------------------------------------------------------------------------
# Full audit
# ------------------------------------------------------------------------------

run_health_check() {
    section "SYSTEM HEALTH AUDIT"

    AUDIT_TABLE=""
    ERRORS=0
    WARNINGS=0
    INFO_COUNT=0

    collect_system_snapshot

    check_kernel
    check_initramfs "$(uname -r)"
    check_root_space
    check_nvidia
    check_pacman_lock
    check_dkms
    check_failed_services
    check_pacnew
    check_package_integrity
    check_temperature
    check_updates
    check_arch_audit

    log ""
    log "### END OF REPORT"
    log "Summary: errors=$ERRORS warnings=$WARNINGS info=$INFO_COUNT"

    echo -e "$AUDIT_TABLE" |
        gum table \
            -p \
            -c "Component,Status" \
            -s "|" \
            --border normal

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

# ------------------------------------------------------------------------------
# Report / AI Agent helpers
# ------------------------------------------------------------------------------

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

Read the EOS Cleaner report at:
$LOG_FILE

Analyze the report conservatively.

Important guidelines:
- EndeavourOS / Arch Linux environment
- Stability is more important than aggressive cleanup
- Do NOT remove orphan packages automatically
- Before any repair, explain what is wrong, why the proposed action is appropriate,
  and what could be affected
- Prefer reversible changes
- Pay particular attention to kernel, initramfs, NVIDIA, DKMS, systemd failures,
  pacman integrity, .pacnew files and security audit findings

First diagnose. Then propose commands. Wait for user approval before destructive
or system-level changes.
EOF
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
            "Exit"
    )"

    case "$MODE" in
        "Standard Clean & Health")
            ui_title
            run_maintenance "$MODE"
            run_health_check
            pause_screen
            ;;
        "Deep Clean & Health")
            ui_title
            run_maintenance "$MODE"
            run_health_check
            pause_screen
            ;;
        "Health Check Only")
            ui_title
            run_health_check
            pause_screen
            ;;
        "View Last Report")
            ui_title
            show_report
            pause_screen
            ;;
        "AI Agent Handoff")
            ui_title
            show_ai_prompt
            pause_screen
            ;;
        "Exit")
            clear
            exit 0
            ;;
    esac
done
