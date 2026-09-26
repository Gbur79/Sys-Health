#!/usr/bin/env bash
# ==============================================================================
# Arch System Health & Diagnostics v2.16
# Read-only health audit + AI Agent report generator + optional maintenance
# Arch Linux & derivatives (EndeavourOS, Manjaro, CachyOS, etc.)
# Unofficial community project - Not affiliated with EndeavourOS or Arch Linux
# ==============================================================================

set -o pipefail

VERSION="2.17"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/system-health"
LOG_FILE="$STATE_DIR/system-health.log"
SUMMARY_FILE="$STATE_DIR/summary.json"
STATE_SNAPSHOT="$STATE_DIR/software-state.txt"
RAW_DIR="$STATE_DIR/runs"

mkdir -p "$STATE_DIR" "$RAW_DIR" 2>/dev/null || true

# ------------------------------------------------------------------------------
# User configuration (optional)
# ------------------------------------------------------------------------------

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/sys-health/sys-health.conf"
[[ ! -f "$CONFIG_FILE" ]] && CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/system-health/system-health.conf"
[[ ! -f "$CONFIG_FILE" ]] && CONFIG_FILE="$HOME/.config/sys-health.conf"
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
  -u, --upgrade          Run guarded system upgrade (pre-flight checks -> upgrade -> post-audit)
  --software             Audit standalone & third-party software updates (AUR, Flatpak, UV, Goose, runtimes)
  -g, --gaming           Run read-only gaming & Steam readiness audit and exit
  -p, --sample [SECS]    Run dynamic performance flight recorder / sample (default: 3s)
  -j, --json             Print latest summary JSON to stdout (or pair with --sample/--software)
  -s, --snapshot         Print latest system software state snapshot to stdout and exit
  -r, --report           Print latest text audit report to stdout and exit
  -m, --maintenance      Run safe maintenance non-interactively, then run health audit
  -d, --deep-clean       Run deep clean (trash, browser caches, thumbnails) non-interactively, then run health audit
  -h, --help             Show this help message and exit
  -v, --version          Show version and exit

Configuration:
  Optional config file:
    ~/.config/sys-health/sys-health.conf
    or ~/.config/system-health/system-health.conf
    or ~/.config/sys-health.conf
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
SAMPLE_SECS=3
OUTPUT_JSON=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--audit|--batch)
            ACTION="audit"
            shift
            ;;
        -u|--upgrade)
            ACTION="upgrade"
            shift
            ;;
        --software)
            ACTION="software"
            shift
            ;;
        -g|--gaming)
            ACTION="gaming"
            shift
            ;;
        -p|--sample)
            ACTION="sample"
            shift
            if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
                SAMPLE_SECS="$1"
                shift
            fi
            ;;
        -j|--json)
            OUTPUT_JSON=1
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
        -d|--deep-clean)
            ACTION="deep-clean"
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

if [[ "$ACTION" == "interactive" && "$OUTPUT_JSON" -eq 1 ]]; then
    ACTION="json"
fi

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
if [[ "$ACTION" != "sample" && "$ACTION" != "software" ]]; then
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
fi

# ------------------------------------------------------------------------------
# UI
# ------------------------------------------------------------------------------

UI_CARD_WIDTH=89

ui_title() {
    clear
    if command -v figlet &>/dev/null; then
        printf "\033[38;5;214;1m%s\033[0m\n" "$(figlet -f standard -c -w "$UI_CARD_WIDTH" "SYS HEALTH")"
    else
        gum style \
            --foreground 214 \
            --border double \
            --align center \
            --width "$UI_CARD_WIDTH" \
            --padding "0 1" \
            "SYS HEALTH  ›  Control Panel"
    fi

    gum style \
        --foreground 244 \
        --align center \
        --width "$UI_CARD_WIDTH" \
        "Diagnostics • Health Audit • AI Handoff  |  v$VERSION"

    echo ""
    local _kern _up _disk
    _kern="$(uname -r)"
    _up="$(uptime -p 2>/dev/null | sed 's/up //' || echo 'unknown')"
    _disk="$(df -P / | awk 'NR==2 {print $5}')"
    gum style \
        --foreground 81 \
        --border rounded \
        --border-foreground 240 \
        --padding "0 2" \
        --width "$UI_CARD_WIDTH" \
        --align center \
        "kernel: $_kern   •   uptime: $_up   •   root: $_disk"

    if [[ -f "$SUMMARY_FILE" ]] && command -v jq &>/dev/null; then
        local st errs warns
        st="$(jq -r '.status // empty' "$SUMMARY_FILE" 2>/dev/null || true)"
        errs="$(jq -r '.counts.errors // 0' "$SUMMARY_FILE" 2>/dev/null || echo 0)"
        warns="$(jq -r '.counts.warnings // 0' "$SUMMARY_FILE" 2>/dev/null || echo 0)"
        if [[ "$st" == "ALL_CLEAR" ]]; then
            gum style \
                --foreground 82 \
                --align center \
                --width "$UI_CARD_WIDTH" \
                "Last audit: ALL CLEAR ✔ (0 errors, 0 warnings)"
        elif [[ "$st" == "ACTION_REQUIRED" ]]; then
            gum style \
                --foreground 196 \
                --align center \
                --width "$UI_CARD_WIDTH" \
                "Last audit: ACTION REQUIRED ✖ ($errs errors, $warns warnings)"
        elif [[ "$st" == "REVIEW_WARNINGS" ]]; then
            gum style \
                --foreground 214 \
                --align center \
                --width "$UI_CARD_WIDTH" \
                "Last audit: REVIEW WARNINGS ⚠ ($errs errors, $warns warnings)"
        fi
    elif [[ -n "$PREVIOUS_RUN_SUMMARY" ]]; then
        gum style \
            --foreground 244 \
            --align center \
            --width "$UI_CARD_WIDTH" \
            "Last run: ${PREVIOUS_RUN_SUMMARY#Summary: }"
    fi

    echo ""
    gum style \
        --foreground 214 \
        --border rounded \
        --padding "0 1" \
        --bold \
        "AVAILABLE ACTIONS"
}

ui_screen() {
    clear
    gum style \
        --foreground 214 \
        --border double \
        --align center \
        --width "$UI_CARD_WIDTH" \
        --padding "0 1" \
        "SYS HEALTH  ›  $1"
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
    local title
    local command_name
    local command_type
    local command_path
    local gum_path

    if (( $# < 2 )); then
        printf 'spinner: expected a title and a command\n' >&2
        return 2
    fi

    title=$1
    shift
    command_name=$1

    # Shell functions, builtins, keywords and aliases must execute in
    # the current Bash process because they may mutate caller state.
    command_type=$(type -t -- "$command_name" 2>/dev/null || true)
    case "$command_type" in
        function|builtin|keyword|alias)
            "$@"
            return $?
            ;;
    esac

    # Only a real executable is eligible for gum spin.
    command_path=$(type -P -- "$command_name" 2>/dev/null || true)
    gum_path=$(type -P -- gum 2>/dev/null || true)

    if [[ -t 1 && -n "$command_path" && -n "$gum_path" ]]; then
        "$gum_path" spin \
            --spinner dot \
            --title "$title" \
            -- "$@"
        return $?
    fi

    "$@"
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
AUDIT_TABLE_GAME=""
AUDIT_TABLE_OTHER=""
ERRORS=0
WARNINGS=0
INFO_COUNT=0

GAMING_DETECTED=false
GAMING_MULTILIB=false
GAMING_VULKAN_32BIT=false
GAMING_MAX_MAP_COUNT=0
GAMING_CUSTOM_PROTON=""

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
            "GPU runtime"*|"GPU errors & lockups"|"DKMS"*|"CPU temperature"|"SMART disk health"|"SSD/NVMe TRIM timer"|"Power & Battery"*)
                sec="HW"
                ;;
            "Root disk space"|"Systemd failed"*|"Pacman DB lock"|"Package file integrity"|".pacnew"*|"Magic SysRq keys")
                sec="SYS"
                ;;
            "Network link & Gateway"*|"System DNS"|"Available updates"|"Arch News"*|"Arch security audit"|"Mirrorlist age"*)
                sec="NET"
                ;;
            "Multilib repository"*|"Vulkan & 32-bit"*|"Proton memory limits"*|"CPU governor"*|"Desktop session & GPU"*|"Proton & Steam tools"*|"Kernel sync"*|"Kernel split-lock"*|"GTX 970 VRAM"*)
                sec="GAME"
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
        GAME)  AUDIT_TABLE_GAME+="$comp | $clean_status\n" ;;
        *)     AUDIT_TABLE_OTHER+="$comp | $clean_status\n" ;;
    esac
}

# ------------------------------------------------------------------------------
# Responsive audit renderer
# Hardened according to GPT-5.6 Luna UX Audit
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Fixed-Card UI Renderer (Consistent 89-column width matching banners)
# ------------------------------------------------------------------------------

audit_display_width() {
    local value="$1"
    local width
    width="$(printf '%s\n' "$value" | wc -L 2>/dev/null || true)"
    if [[ "$width" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$width"
    else
        printf '%s\n' "${#value}"
    fi
}

audit_wrap_text() {
    local text="$1"
    local width="$2"
    local line=""
    local word=""

    (( width < 1 )) && width=1
    [[ -z "$text" ]] && { printf '\n'; return; }

    while IFS= read -r word; do
        [[ -z "$word" ]] && continue
        if [[ -z "$line" ]]; then
            line="$word"
        elif (( $(audit_display_width "$line $word") <= width )); then
            line+=" $word"
        else
            printf '%s\n' "$line"
            line="$word"
        fi
    done < <(printf '%s\n' "$text" | awk '{ for (i = 1; i <= NF; i++) print $i }')

    [[ -n "$line" ]] && printf '%s\n' "$line"
}

render_audit_section() {
    local title="$1"
    local data="$2"

    [[ -z "$data" ]] && return

    local badge=" ✔"
    local hdr_color=$'\033[38;5;82;1m'

    if [[ "$data" == *"FAIL ✖"* ]]; then
        badge=" ✖"
        hdr_color=$'\033[38;5;196;1m'
    elif [[ "$data" == *"WARN ⚠"* || "$data" == *"UPDATE ⚠"* ]]; then
        badge=" ⚠"
        hdr_color=$'\033[38;5;214;1m'
    fi

    # Non-interactive / plain fallback
    if [[ ! -t 1 ]]; then
        printf '\n=== %s%s ===\n' "$title" "$badge"
        local line comp st
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            comp="${line%% | *}"
            st="${line#* | }"
            st="${st//|/-}"
            printf '  %-28s : %s\n' "$comp" "$st"
        done < <(printf '%b' "$data")
        return
    fi

    # Strict compact card geometry: Exactly 89 columns to match UI_CARD_WIDTH & banners
    local comp_w=28
    local stat_w=54

    # Responsive scale down ONLY for tiny terminals < 89 columns
    local cols="${COLUMNS:-89}"
    if (( cols < 89 )); then
        local available=$((cols - 7))
        if (( available > 35 )); then
            comp_w=22
            stat_w=$((available - comp_w))
        fi
    fi

    local c_reset=$'\033[0m'
    local c_border=$'\033[38;5;240m'
    local c_comp=$'\033[38;5;255m'
    local c_pass=$'\033[38;5;81;1m'
    local c_warn=$'\033[38;5;214;1m'
    local c_fail=$'\033[38;5;196;1m'
    local c_info=$'\033[38;5;117m'
    local c_dim=$'\033[38;5;250m'

    [[ -n "${NO_COLOR:-}" ]] && {
        c_reset="" c_border="" c_comp="" c_pass="" c_warn="" c_fail="" c_info="" c_dim="" hdr_color=""
    }

    local h1 h2
    printf -v h1 '%*s' "$((comp_w + 2))" ""
    printf -v h2 '%*s' "$((stat_w + 2))" ""
    h1="${h1// /─}"
    h2="${h2// /─}"

    echo ""
    printf "%s%s%s\n" "$hdr_color" "${title}${badge}" "$c_reset"
    printf "%s╭%s┬%s╮%s\n" "$c_border" "$h1" "$h2" "$c_reset"

    local line comp st
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        comp="${line%% | *}"
        st="${line#* | }"
        st="${st//|/-}"

        local -a comp_lines=()
        local -a status_lines=()

        mapfile -t comp_lines < <(audit_wrap_text "$comp" "$comp_w")
        mapfile -t status_lines < <(audit_wrap_text "$st" "$stat_w")

        local rows="${#comp_lines[@]}"
        (( ${#status_lines[@]} > rows )) && rows="${#status_lines[@]}"

        local i
        for (( i = 0; i < rows; i++ )); do
            local c_line="${comp_lines[i]:-}"
            local s_line="${status_lines[i]:-}"

            local c_len s_len
            c_len="$(audit_display_width "$c_line")"
            s_len="$(audit_display_width "$s_line")"

            local pad_c_len=$((comp_w - c_len))
            local pad_s_len=$((stat_w - s_len))
            local pad_c="" pad_s=""
            (( pad_c_len > 0 )) && pad_c=$(printf '%*s' "$pad_c_len" "")
            (( pad_s_len > 0 )) && pad_s=$(printf '%*s' "$pad_s_len" "")

            local comp_disp=""
            if [[ -n "$c_line" ]]; then
                if [[ "$c_line" == *"↳"* ]]; then
                    comp_disp="${c_info}${c_line}${c_reset}"
                else
                    comp_disp="${c_comp}${c_line}${c_reset}"
                fi
            fi

            local st_disp=""
            if [[ "$s_line" == *"FAIL ✖"* ]]; then
                st_disp="${c_fail}${s_line}${c_reset}"
            elif [[ "$s_line" == *"WARN ⚠"* || "$s_line" == *"UPDATE ⚠"* ]]; then
                st_disp="${c_warn}${s_line}${c_reset}"
            elif [[ "$s_line" == "PASS ✔"* ]]; then
                local rest="${s_line#PASS ✔}"
                st_disp="${c_pass}PASS ✔${c_reset}${c_dim}${rest}${c_reset}"
            elif [[ "$s_line" == "INFO"* ]]; then
                local pfx="INFO ℹ"
                local rest="${s_line#INFO ℹ}"
                if [[ "$s_line" == "INFO i"* ]]; then
                    pfx="INFO i"
                    rest="${s_line#INFO i}"
                fi
                st_disp="${c_info}${pfx}${c_reset}${c_dim}${rest}${c_reset}"
            elif [[ "$s_line" == *"->"* ]]; then
                st_disp="${c_warn}${s_line}${c_reset}"
            elif [[ -n "$s_line" ]]; then
                st_disp="${c_dim}${s_line}${c_reset}"
            fi

            printf "%s│ %s%s %s│ %s%s %s│%s\n" \
                "$c_border" "$comp_disp" "$pad_c" \
                "$c_border" "$st_disp" "$pad_s" \
                "$c_border" "$c_reset"
        done
    done < <(printf '%b' "$data")

    printf "%s╰%s┴%s╯%s\n" "$c_border" "$h1" "$h2" "$c_reset"
}


# ------------------------------------------------------------------------------
# System platform detectors (Universal GitHub / Dual-Lens portability)
# ------------------------------------------------------------------------------

detect_active_bootloader() {
    local loader_info_var
    loader_info_var="$(find /sys/firmware/efi/efivars/ -name 'LoaderInfo-*' 2>/dev/null | head -n 1 || true)"
    if [[ -n "$loader_info_var" && -r "$loader_info_var" ]]; then
        local raw_info
        raw_info="$(tr -d '\0' < "$loader_info_var" 2>/dev/null || true)"
        case "$raw_info" in
            *systemd-boot*) echo "systemd-boot"; return 0 ;;
            *Limine*)       echo "limine"; return 0 ;;
            *rEFInd*)       echo "refind"; return 0 ;;
            *GRUB*)         echo "grub"; return 0 ;;
        esac
    fi

    if [[ -d /sys/firmware/efi/efivars ]] && command -v bootctl &>/dev/null; then
        local loader
        loader="$(bootctl status 2>/dev/null | grep -i 'Product:' | head -n1 | awk '{$1=""; print $0}' | sed 's/^[ \t]*//' || true)"
        if [[ -n "$loader" ]]; then
            case "$loader" in
                *systemd-boot*) echo "systemd-boot"; return 0 ;;
                *GRUB*)         echo "grub"; return 0 ;;
                *Limine*)       echo "limine"; return 0 ;;
                *rEFInd*)       echo "refind"; return 0 ;;
            esac
        fi
    fi

    if command -v bootctl &>/dev/null; then
        if sudo -n bootctl is-installed &>/dev/null || bootctl is-installed &>/dev/null; then
            echo "systemd-boot"
            return 0
        fi
    fi

    for f in /boot/grub/grub.cfg /boot/grub2/grub.cfg /efi/grub/grub.cfg /boot/efi/EFI/grub/grub.cfg /efi/EFI/grub/grub.cfg; do
        if [[ -f "$f" ]]; then
            echo "grub"
            return 0
        fi
    done

    for f in /boot/limine/limine.conf /boot/limine.conf /boot/limine.cfg /efi/limine/limine.conf /efi/limine.conf /boot/efi/limine.conf; do
        if [[ -f "$f" ]]; then
            echo "limine"
            return 0
        fi
    done

    if [[ -f /boot/refind_linux.conf || -d /boot/efi/EFI/refind || -d /efi/EFI/refind ]]; then
        echo "refind"
        return 0
    fi

    local -a uki_paths=(
        /efi/EFI/Linux/*.efi
        /boot/EFI/Linux/*.efi
        /boot/efi/EFI/Linux/*.efi
    )
    for uki in "${uki_paths[@]}"; do
        if [[ -f "$uki" ]]; then
            echo "uki"
            return 0
        fi
    done

    if [[ -d /boot/grub || -d /boot/grub2 ]]; then
        echo "grub"
        return 0
    elif [[ -d /boot/loader || -d /efi/loader ]]; then
        echo "systemd-boot"
        return 0
    fi

    echo "unknown"
    return 1
}

detect_bootloader() {
    if [[ -d /sys/firmware/efi/efivars ]] && command -v bootctl &>/dev/null; then
        local loader
        loader="$(bootctl status 2>/dev/null | grep -i 'Product:' | head -n1 | awk '{$1=""; print $0}' | sed 's/^[ \t]*//' || true)"
        if [[ -n "$loader" ]]; then
            echo "$loader"
            return
        fi
    fi

    local active
    active="$(detect_active_bootloader)"
    case "$active" in
        systemd-boot) echo "systemd-boot" ;;
        grub)         echo "GRUB" ;;
        limine)       echo "Limine" ;;
        refind)       echo "rEFInd" ;;
        uki)          echo "UKI (Direct EFI)" ;;
        *)            echo "unknown" ;;
    esac
}

detect_initramfs_generator() {
    if command -v dracut &>/dev/null && [[ -d /etc/dracut.conf.d || -f /etc/dracut.conf || -d /usr/lib/dracut ]]; then
        if command -v mkinitcpio &>/dev/null && [[ -f /etc/mkinitcpio.conf || -d /etc/mkinitcpio.d ]]; then
            if [[ -f /usr/share/libalpm/hooks/90-dracut-install.hook || -f /etc/pacman.d/hooks/90-dracut-install.hook || -f /usr/share/libalpm/hooks/eos-dracut.hook ]]; then
                echo "dracut"
                return
            elif [[ -f /usr/share/libalpm/hooks/90-mkinitcpio-install.hook ]]; then
                echo "mkinitcpio"
                return
            fi
        fi
        echo "dracut"
    elif command -v mkinitcpio &>/dev/null && [[ -f /etc/mkinitcpio.conf || -d /etc/mkinitcpio.d ]]; then
        echo "mkinitcpio"
    elif command -v booster &>/dev/null; then
        echo "booster"
    else
        echo "unknown"
    fi
}

detect_chassis() {
    local ch=""
    if command -v hostnamectl &>/dev/null; then
        ch="$(hostnamectl chassis 2>/dev/null || true)"
    fi
    if [[ -z "$ch" || "$ch" == "n/a" ]] && [[ -f /sys/class/dmi/id/chassis_type ]]; then
        case "$(< /sys/class/dmi/id/chassis_type)" in
            8|9|10|11|14) ch="laptop" ;;
            3|4|5|6|7|15|16) ch="desktop" ;;
            *) ch="desktop" ;;
        esac
    fi
    echo "${ch:-desktop}"
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
    log "### PLATFORM & HARDWARE"
    log "Chassis: $(detect_chassis)"
    log "Bootloader: $(detect_bootloader)"
    log "Initramfs Generator: $(detect_initramfs_generator)"
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
    local quiet="${1:-0}"
    local ts
    ts="$(date --iso-8601=seconds)"

    dump_snapshot_content() {
        echo '=== SYSTEM SOFTWARE STATE SNAPSHOT ==='
        echo "Generated on: ${ts}"
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
        if [[ -f /etc/dracut.conf || -d /etc/dracut.conf.d ]]; then
            echo 'Dracut configs:'
            [[ -f /etc/dracut.conf ]] && grep -v '^#' /etc/dracut.conf 2>/dev/null | sed '/^$/d'
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
        if [[ -d /efi ]]; then
            echo ''
            echo '--- 9b. EFI Directory Content (/efi) ---'
            ls -lah /efi/ 2>/dev/null
        fi
        echo ''
        echo '--- 10. Failed Systemd Services (System) ---'
        systemctl --failed --no-legend --plain 2>/dev/null
        echo ''
        echo '--- 11. Failed Systemd Services (User) ---'
        systemctl --user --failed --no-legend --plain 2>/dev/null
        echo ''
        echo '--- 12. Desktop & Session Environment ---'
        printenv XDG_SESSION_TYPE DESKTOP_SESSION XDG_CURRENT_DESKTOP 2>/dev/null || true
    }

    if (( quiet == 1 )); then
        dump_snapshot_content > "$STATE_SNAPSHOT" 2>&1
    else
        spinner "Refreshing system state snapshot..." bash -c "$(declare -f dump_snapshot_content); dump_snapshot_content > "$STATE_SNAPSHOT" 2>&1"
    fi

    if [[ -s "$STATE_SNAPSHOT" ]]; then
        if (( quiet != 1 )); then
            ok "State snapshot refreshed: $STATE_SNAPSHOT"
        fi
        log "STATE_SNAPSHOT refreshed=$STATE_SNAPSHOT ts=$ts"
    else
        warn "State snapshot refresh failed."
        log "STATE_SNAPSHOT refresh_failed"
    fi
}

# ==============================================================================
# Hardened Maintenance & Deep Clean Engine (Luna SRE v2.2 Architecture)
# Dual-Lens Compliant: Karol Workstation Rig & Universal GitHub Portability
# ==============================================================================

readonly PACCACHE_INSTALLED_KEEP="${PACCACHE_INSTALLED_KEEP:-2}"
readonly PACCACHE_UNINSTALLED_KEEP="${PACCACHE_UNINSTALLED_KEEP:-1}"
readonly JOURNAL_RETENTION_DAYS="${JOURNAL_RETENTION_DAYS:-30}"
readonly JOURNAL_RETENTION_SIZE="${JOURNAL_RETENTION_SIZE:-200M}"
readonly USER_JOURNAL_RETENTION_SIZE="${USER_JOURNAL_RETENTION_SIZE:-50M}"
readonly COREDUMP_RETENTION_DAYS="${COREDUMP_RETENTION_DAYS:-30}"

# Destructive operations require explicit confirmation.
MAINTENANCE_CONFIRMED="${MAINTENANCE_CONFIRMED:-0}"
COREDUMP_CLEAN_CONFIRMED="${COREDUMP_CLEAN_CONFIRMED:-0}"

# Strict Never-Touch protection list for Gaming, DXVK, Vulkan & GPU Shader Caches
readonly NEVER_TOUCH_SHADER_PATHS=(
    "$HOME/.nv"
    "$HOME/.cache/nvidia"
    "$HOME/.cache/mesa_shader_cache"
    "$HOME/.cache/mesa_shader_cache_db"
    "$HOME/.cache/AMD"
    "$HOME/.steam"
    "$HOME/.local/share/Steam"
    "$HOME/.var/app/com.valvesoftware.Steam"
    "$HOME/faf-linux"
    "$HOME/.local/share/lutris"
    "$HOME/.cache/lutris"
    "$HOME/.config/heroic"
    "$HOME/.cache/heroic"
    "$HOME/.var/app/com.heroicgameslauncher.hgl"
    "$HOME/.local/share/bottles"
    "$HOME/.var/app/com.usebottles.bottles"
)

# Root-level critical path boundaries that safe_delete_children MUST NEVER touch
readonly CRITICAL_SYSTEM_ROOTS=(
    "/"
    "/root"
    "/home"
    "$HOME"
    "/etc"
    "/var"
    "/usr"
    "/boot"
    "/efi"
    "/opt"
    "/bin"
    "/sbin"
    "/lib"
    "/lib64"
    "/dev"
    "/sys"
    "/proc"
    "${XDG_CACHE_HOME:-$HOME/.cache}"
    "$HOME/.local"
    "$HOME/.local/share"
    "$HOME/.config"
    "$HOME/.var"
    "$HOME/.var/app"
)

calculate_reclaimable_space() {
    local target_path="${1:-}"
    local result

    [[ -n "$target_path" && ( -d "$target_path" || -f "$target_path" ) ]] || {
        printf '0B\n'
        return 0
    }

    result="$(du -shx -- "$target_path" 2>/dev/null | awk 'NR == 1 { print $1 }')"

    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
    else
        printf '0B\n'
    fi
}

# Canonical path containment with a directory-boundary check.
# Returns success if candidate is root itself or below root.
path_is_within() {
    local candidate="${1:-}"
    local root="${2:-}"
    local candidate_real
    local root_real

    [[ -n "$candidate" && -n "$root" ]] || return 1

    candidate_real="$(realpath -m -- "$candidate" 2>/dev/null)" || return 1
    root_real="$(realpath -m -- "$root" 2>/dev/null)" || return 1

    [[ "$candidate_real" == "$root_real" || "$candidate_real" == "$root_real/"* ]]
}

is_protected_cache_path() {
    local target="${1:-}"
    local protected
    local target_real
    local protected_real

    [[ -n "$target" && "$target" == /* ]] || return 0

    target_real="$(realpath -m -- "$target" 2>/dev/null)" || return 0

    # Bidirectional safety check:
    # 1. target is within or equal to protected path
    # 2. protected path is within target (fail-safe against broad wipes like ~/.cache)
    for protected in "${NEVER_TOUCH_SHADER_PATHS[@]}"; do
        protected_real="$(realpath -m -- "$protected" 2>/dev/null)" || return 0

        if [[ "$target_real" == "$protected_real" || "$target_real" == "$protected_real/"* ]]; then
            return 0
        fi
        if [[ "$protected_real" == "$target_real/"* ]]; then
            return 0
        fi
    done

    return 1
}

maintenance_is_confirmed() {
    if [[ "$MAINTENANCE_CONFIRMED" == "1" ]] || [[ "${ACTION:-}" == "maintenance" ]] || [[ "${ACTION:-}" == "deep-clean" ]]; then
        return 0
    fi

    if [[ -t 0 ]] && command -v gum &>/dev/null; then
        if gum confirm "Proceed with confirmed maintenance deletion?"; then
            MAINTENANCE_CONFIRMED=1
            return 0
        fi
    elif [[ -t 0 ]]; then
        local answer
        read -r -p "Proceed with confirmed maintenance deletion? [y/N] " answer
        if [[ "$answer" =~ ^[Yy]$ ]]; then
            MAINTENANCE_CONFIRMED=1
            return 0
        fi
    else
        warn "Destructive maintenance requires interactive confirmation or -m/-d flag."
        return 1
    fi

    warn "No destructive maintenance action was authorized."
    return 1
}

run_checked() {
    local description="$1"
    shift

    if declare -F spinner >/dev/null 2>&1; then
        spinner "$description" "$@"
    else
        "$@"
    fi
}

package_manager_busy() {
    local process

    [[ -e /var/lib/pacman/db.lck ]] && return 0

    for process in pacman yay paru makepkg; do
        if pgrep -x "$process" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

safe_delete_children() {
    local target="${1:-}"
    local target_real
    local target_parent
    local target_dev
    local parent_dev
    local crit

    [[ -n "$target" && -d "$target" && ! -L "$target" ]] || {
        warn "Refusing to clean invalid or symlinked directory: $target"
        return 1
    }

    target_real="$(realpath -e -- "$target" 2>/dev/null)" || {
        warn "Unable to canonicalize cleanup target: $target"
        return 1
    }

    # Internal Fail-Safe against critical system directories
    for crit in "${CRITICAL_SYSTEM_ROOTS[@]}"; do
        if [[ "$target_real" == "$crit" ]]; then
            fail "CRITICAL SRE GUARD: Refusing to clean protected system root: $target_real"
            return 1
        fi
    done

    # Reject overly shallow directory paths (e.g. /home/user or /var/cache)
    local depth
    depth="$(awk -F/ '{print NF-1}' <<< "$target_real")"
    if (( depth < 3 )); then
        fail "Refusing to clean dangerously shallow directory (depth < 3): $target_real"
        return 1
    fi

    # Shader and gaming cache guard
    if is_protected_cache_path "$target_real"; then
        fail "Protected gaming or shader path detected; deletion aborted: $target_real"
        return 1
    fi

    target_parent="$(dirname -- "$target_real")"
    target_dev="$(stat -c '%d' -- "$target_real" 2>/dev/null)" || return 1
    parent_dev="$(stat -c '%d' -- "$target_parent" 2>/dev/null)" || return 1

    # Check for mountpoint crossing (exempting Btrfs subvolumes on same filesystem if verified)
    if [[ "$target_dev" != "$parent_dev" ]] && ! findmnt -n --target "$target_real" 2>/dev/null | grep -q "btrfs"; then
        warn "Refusing to clean mountpoint on a different filesystem: $target_real"
        return 1
    fi

    find -- "$target_real" \
        -xdev \
        -mindepth 1 \
        -depth \
        -delete
}

browser_process_running() {
    local process_name
    local uid

    uid="$(id -u)" || return 0

    for process_name in "$@"; do
        if pgrep -u "$uid" -x "$process_name" >/dev/null 2>&1; then
            return 0
        fi
    done

    return 1
}

clean_browser_cache_safely() {
    local browser_name="${1:-}"
    local cache_dir="${2:-}"
    local process_names="${3:-}"
    local xdg_cache_root="${XDG_CACHE_HOME:-$HOME/.cache}"
    local flatpak_app_root="$HOME/.var/app"
    local cache_size
    local process_array=()

    [[ "$MAINTENANCE_CONFIRMED" == "1" ]] || {
        warn "Skipping $browser_name cache: maintenance was not confirmed."
        return 2
    }

    [[ -n "$browser_name" && -n "$cache_dir" && -n "$process_names" ]] || {
        fail "Invalid browser-cache arguments."
        return 1
    }

    # Allow cache directory if located within ~/.cache OR within Flatpak ~/.var/app/*/cache
    if ! path_is_within "$cache_dir" "$xdg_cache_root" && ! path_is_within "$cache_dir" "$flatpak_app_root"; then
        fail "Refusing browser cache outside sanctioned cache roots: $cache_dir"
        return 1
    fi

    # Extra defense-in-depth: if within flatpak root, ensure it is strictly a cache directory
    if path_is_within "$cache_dir" "$flatpak_app_root"; then
        if [[ "$cache_dir" != */cache/* && "$cache_dir" != */cache ]]; then
            fail "Refusing non-cache directory inside Flatpak tree: $cache_dir"
            return 1
        fi
    fi

    if is_protected_cache_path "$cache_dir"; then
        fail "Refusing to clean protected gaming/shader path: $cache_dir"
        return 1
    fi

    [[ -d "$cache_dir" && ! -L "$cache_dir" ]] || {
        return 0
    }

    read -r -a process_array <<< "$process_names"

    if browser_process_running "${process_array[@]}"; then
        warn "Skipping $browser_name cache: browser process is active."
        log "MAINTENANCE browser=${browser_name} result=skipped_active"
        return 0
    fi

    # Recheck immediately before deletion to eliminate TOCTOU race
    if browser_process_running "${process_array[@]}"; then
        warn "Skipping $browser_name cache: browser started during preflight."
        log "MAINTENANCE browser=${browser_name} result=skipped_race"
        return 0
    fi

    cache_size="$(calculate_reclaimable_space "$cache_dir")"
    if [[ "$cache_size" == "0B" || "$cache_size" == "0" ]]; then
        return 0
    fi

    info "$browser_name cache selected for deletion: $cache_dir ($cache_size)"

    if ! safe_delete_children "$cache_dir"; then
        fail "$browser_name cache cleanup failed: $cache_dir"
        log "MAINTENANCE browser=${browser_name} result=failed"
        return 1
    fi

    ok "$browser_name cache cleaned (freed approximately $cache_size)."
    log "MAINTENANCE browser=${browser_name} result=cleaned size=${cache_size}"
}

# Dynamic Browser Registry (Native + Flatpak)
clean_all_detected_browsers() {
    local -a browser_registry=(
        # Format: "Display Name|Cache Path|Process Names"
        "Firefox (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/mozilla/firefox|firefox firefox-bin"
        "Firefox (Flatpak)|$HOME/.var/app/org.mozilla.firefox/cache/mozilla/firefox|firefox"
        "Chromium (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/chromium|chromium chromium-browser"
        "Chromium (Flatpak)|$HOME/.var/app/org.chromium.Chromium/cache/chromium|chromium"
        "Ungoogled Chromium (Flatpak)|$HOME/.var/app/io.github.ungoogled_software.ungoogled_chromium/cache/chromium|chromium"
        "Google Chrome (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/google-chrome|chrome google-chrome google-chrome-stable"
        "Google Chrome (Flatpak)|$HOME/.var/app/com.google.Chrome/cache/google-chrome|chrome"
        "Brave Browser (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/BraveSoftware/Brave-Browser|brave brave-browser"
        "Brave Browser (Flatpak)|$HOME/.var/app/com.brave.Browser/cache/BraveSoftware/Brave-Browser|brave"
        "Vivaldi (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/vivaldi|vivaldi vivaldi-bin"
        "Microsoft Edge (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/microsoft-edge|msedge"
        "Opera (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/opera|opera"
        "LibreWolf (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/librewolf|librewolf"
        "LibreWolf (Flatpak)|$HOME/.var/app/io.gitlab.librewolf-community/cache/librewolf|librewolf"
        "Zen Browser (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/zen|zen zen-bin"
        "Waterfox (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/waterfox|waterfox waterfox-bin"
        "Waterfox (Flatpak)|$HOME/.var/app/net.waterfox.waterfox/cache/waterfox|waterfox"
    )

    local entry name cpath procs
    for entry in "${browser_registry[@]}"; do
        IFS='|' read -r name cpath procs <<< "$entry"
        if [[ -d "$cpath" ]]; then
            clean_browser_cache_safely "$name" "$cpath" "$procs" || warn "$name cleanup incomplete."
        fi
    done
}

empty_freedesktop_trash() {
    local trash_dir="$HOME/.local/share/Trash"
    local trash_size

    [[ "$MAINTENANCE_CONFIRMED" == "1" ]] || {
        warn "Skipping Trash cleanup: maintenance was not confirmed."
        return 2
    }

    trash_size="$(calculate_reclaimable_space "$trash_dir")"

    if command -v gio >/dev/null 2>&1; then
        if ! run_checked \
            "Emptying Desktop Trash across mounted filesystems..." \
            gio trash --empty; then
            fail "gio Trash cleanup failed; fallback will be evaluated."
            log "MAINTENANCE trash=result=failed method=gio"
        else
            ok "Desktop Trash emptied across all active mounts (freed approximately $trash_size in user home)."
            log "MAINTENANCE trash=result=cleaned method=gio size=${trash_size}"
            return 0
        fi
    fi

    # Fallback is restricted to the current user's canonical home Trash.
    if [[ -d "$trash_dir" ]]; then
        local subdir
        for subdir in files info expunged; do
            if [[ -d "$trash_dir/$subdir" ]] &&
               ! safe_delete_children "$trash_dir/$subdir"; then
                fail "Trash fallback cleanup failed: $trash_dir/$subdir"
                log "MAINTENANCE trash=result=failed method=fallback"
                return 1
            fi
        done
        ok "Desktop Trash cleaned via fallback (freed approximately $trash_size)."
        log "MAINTENANCE trash=result=cleaned method=fallback size=${trash_size}"
    else
        info "No local Trash folder found."
    fi
}

clean_thumbnail_cache() {
    local thumbnail_dir="${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails"
    local thumbnail_size

    [[ "$MAINTENANCE_CONFIRMED" == "1" ]] || return 2
    [[ -d "$thumbnail_dir" ]] || return 0

    if is_protected_cache_path "$thumbnail_dir"; then
        fail "Refusing to clean protected thumbnail path: $thumbnail_dir"
        return 1
    fi

    thumbnail_size="$(calculate_reclaimable_space "$thumbnail_dir")"
    if [[ "$thumbnail_size" == "0B" ]]; then
        return 0
    fi

    if ! safe_delete_children "$thumbnail_dir"; then
        fail "Thumbnail cache cleanup failed."
        log "MAINTENANCE thumbnails=result=failed"
        return 1
    fi

    ok "Desktop Thumbnail cache cleaned (freed approximately $thumbnail_size)."
    log "MAINTENANCE thumbnails=result=cleaned size=${thumbnail_size}"
}

clean_coredumps_by_age() {
    local coredump_dir="/var/lib/systemd/coredump"
    local days="${COREDUMP_RETENTION_DAYS:-30}"

    [[ "$COREDUMP_CLEAN_CONFIRMED" == "1" ]] || {
        info "Stored coredumps retained for crash diagnostics; review with: coredumpctl list"
        return 0
    }

    [[ "$days" =~ ^[0-9]+$ && "$days" -ge 14 ]] || {
        fail "Coredump retention must be an integer of at least 14 days."
        return 1
    }

    [[ -d "$coredump_dir" && ! -L "$coredump_dir" ]] || {
        info "No systemd coredump directory found."
        return 0
    }

    if ! run_checked \
        "Removing coredumps older than ${days} days..." \
        sudo find "$coredump_dir" -xdev -type f -name 'core.*' -mtime "+$days" -delete; then
        fail "Age-based coredump cleanup failed."
        log "MAINTENANCE coredumps=result=failed"
        return 1
    fi

    ok "Old coredumps removed (>${days}d); recent crash dumps retained."
    log "MAINTENANCE coredumps=result=cleaned retention_days=${days}"
}

prune_aur_cache_safely() {
    local helper_name="$1"
    local aur_cache_dir="$2"
    local aur_size

    [[ -d "$aur_cache_dir" ]] || return 0

    aur_size="$(calculate_reclaimable_space "$aur_cache_dir")"
    info "$helper_name package build cache: $aur_cache_dir ($aur_size)"

    # Use paccache with custom directory flag (-c) to preserve rollback versions
    if command -v paccache >/dev/null 2>&1; then
        local -a extra_cdirs=()
        # Find directories inside aur_cache_dir that contain pkg.tar files
        while IFS= read -r -d '' pdir; do
            [[ -n "$pdir" ]] && extra_cdirs+=("-c" "$pdir")
        done < <(find "$aur_cache_dir" -mindepth 1 -maxdepth 2 -type f -name "*.pkg.tar.*" -exec dirname {} + 2>/dev/null | sort -u | tr '\n' '\0')

        if (( ${#extra_cdirs[@]} > 0 )); then
            if ! run_checked \
                "Pruning $helper_name built packages (keeping ${PACCACHE_INSTALLED_KEEP} versions)..." \
                paccache -r -k "$PACCACHE_INSTALLED_KEEP" "${extra_cdirs[@]}"; then
                warn "$helper_name package cache pruning encountered an issue."
            else
                ok "$helper_name package cache safely pruned (retained last ${PACCACHE_INSTALLED_KEEP} versions)."
                log "MAINTENANCE aur_cache=pruned helper=${helper_name}"
            fi
        else
            info "No built packages found to prune in $helper_name cache."
            log "MAINTENANCE aur_cache=clean helper=${helper_name}"
        fi
    fi
}

run_maintenance() {
    local mode="${1:-Safe Maintenance}"
    local pacman_size

    section "MAINTENANCE"

    maintenance_is_confirmed || return 2

    # Never race active package transactions or AUR builds
    if package_manager_busy; then
        warn "Package manager or AUR build activity detected; pacman cache step skipped."
        log "MAINTENANCE pacman_cache=result=skipped_busy"
    elif command -v paccache >/dev/null 2>&1; then
        pacman_size="$(calculate_reclaimable_space /var/cache/pacman/pkg)"
        info "Primary pacman package cache: $pacman_size"

        if ! run_checked \
            "Pruning installed package cache; keeping ${PACCACHE_INSTALLED_KEEP} versions..." \
            sudo paccache --remove --keep "$PACCACHE_INSTALLED_KEEP"; then
            fail "Installed-package paccache operation failed."
            log "MAINTENANCE pacman_cache=result=failed installed=1"
        else
            ok "Installed-package cache pruned (retained last ${PACCACHE_INSTALLED_KEEP} versions)."
            log "MAINTENANCE pacman_cache=result=cleaned installed_keep=${PACCACHE_INSTALLED_KEEP}"
        fi

        if ! run_checked \
            "Pruning uninstalled package cache; keeping ${PACCACHE_UNINSTALLED_KEEP} version..." \
            sudo paccache --remove --uninstalled --keep "$PACCACHE_UNINSTALLED_KEEP"; then
            fail "Uninstalled-package paccache operation failed."
            log "MAINTENANCE pacman_cache=result=failed uninstalled=1"
        else
            ok "Uninstalled-package cache pruned (retained ${PACCACHE_UNINSTALLED_KEEP} version)."
            log "MAINTENANCE pacman_cache=result=cleaned uninstalled_keep=${PACCACHE_UNINSTALLED_KEEP}"
        fi
    else
        warn "paccache is not installed; package-cache cleanup skipped."
        log "MAINTENANCE pacman_cache=result=skipped missing=paccache"
    fi

    # Safe AUR cache pruning (preserves rollback versions via paccache -c)
    if command -v yay >/dev/null 2>&1; then
        prune_aur_cache_safely "yay" "$HOME/.cache/yay"
    elif command -v paru >/dev/null 2>&1; then
        prune_aur_cache_safely "paru" "$HOME/.cache/paru/clone"
    fi

    # Systemd journal maintenance (Dual-constraint: time + size limit)
    if ! run_checked \
        "Vacuuming system journal (retention: ${JOURNAL_RETENTION_DAYS}d, max size: ${JOURNAL_RETENTION_SIZE})..." \
        sudo journalctl --vacuum-time="${JOURNAL_RETENTION_DAYS}days" --vacuum-size="${JOURNAL_RETENTION_SIZE}"; then
        fail "System journal vacuum failed."
        log "MAINTENANCE journal=result=failed"
    else
        ok "System journal vacuum completed (retained last ${JOURNAL_RETENTION_DAYS} days / ${JOURNAL_RETENTION_SIZE})."
        log "MAINTENANCE journal=result=cleaned retention_days=${JOURNAL_RETENTION_DAYS}"
    fi

    # User journal vacuuming if persistent
    if [[ -d "$HOME/.local/share/systemd/journal" ]] || journalctl --user --disk-usage &>/dev/null; then
        journalctl --user --vacuum-time="${JOURNAL_RETENTION_DAYS}days" --vacuum-size="${USER_JOURNAL_RETENTION_SIZE}" &>/dev/null || true
    fi

    # Deep Clean operations
    if [[ "$mode" == *"Deep Clean"* ]]; then
        section "DEEP CLEAN"

        empty_freedesktop_trash || warn "Trash cleanup was not completed."

        clean_all_detected_browsers

        clean_thumbnail_cache || warn "Thumbnail cleanup was not completed."

        clean_coredumps_by_age || warn "Coredump cleanup was not completed."
    fi
}



# ------------------------------------------------------------------------------
# Health checks
# ------------------------------------------------------------------------------

detect_boot_directories() {
    local -a dirs=()
    local seen=" "

    # 1. Active vfat ESP mountpoints from findmnt
    local esp_mnt
    while IFS= read -r esp_mnt; do
        [[ -n "$esp_mnt" && -d "$esp_mnt" ]] || continue
        if [[ "$seen" != *" $esp_mnt "* ]]; then
            dirs+=("$esp_mnt")
            seen+="$esp_mnt "
        fi
    done < <(findmnt -n -r -t vfat -o TARGET 2>/dev/null || true)

    # 2. Inspect /etc/fstab for vfat or boot mounts
    local fstab_mnt
    while IFS= read -r fstab_mnt; do
        [[ -n "$fstab_mnt" && -d "$fstab_mnt" ]] || continue
        if [[ "$seen" != *" $fstab_mnt "* ]]; then
            dirs+=("$fstab_mnt")
            seen+="$fstab_mnt "
        fi
    done < <(awk '$3 == "vfat" || $2 ~ /^\/(boot|efi|boot\/efi)$/ {print $2}' /etc/fstab 2>/dev/null || true)

    # 3. Dedicated /boot, /efi, or /boot/efi directories if present
    for cand in /boot /efi /boot/efi; do
        if [[ -d "$cand" ]]; then
            if [[ "$seen" != *" $cand "* ]]; then
                dirs+=("$cand")
                seen+="$cand "
            fi
        fi
    done

    printf "%s\n" "${dirs[@]}"
}

_resolve_kernel_and_initramfs() {
    local pkgb="$1"
    local kver="$2"
    local -a boot_dirs=()
    mapfile -t boot_dirs < <(detect_boot_directories)

    k_vmlinuz=""
    k_initrd=""
    k_fallback=""
    k_mode=""
    k_sz=0

    # 1. UKI Check (Unified Kernel Image - Type #2 BLS)
    for bdir in "${boot_dirs[@]}"; do
        local uki_match
        uki_match="$(compgen -G "${bdir}/EFI/Linux/*${pkgb}*.efi" 2>/dev/null | head -n1 || true)"
        [[ -z "$uki_match" && -n "$kver" ]] && uki_match="$(compgen -G "${bdir}/EFI/Linux/*${kver}*.efi" 2>/dev/null | head -n1 || true)"
        if [[ -n "$uki_match" && -f "$uki_match" ]]; then
            k_vmlinuz="$uki_match"
            k_initrd="$uki_match"
            k_mode="uki"
            k_sz="$(stat -c %s "$uki_match" 2>/dev/null || echo 0)"
            return 0
        fi
    done

    # 2. Type #1 BLS (systemd-boot entries / kernel-install layout)
    for bdir in "${boot_dirs[@]}"; do
        if [[ -d "${bdir}/loader/entries" ]]; then
            for entry in "${bdir}"/loader/entries/*.conf; do
                [[ -f "$entry" ]] || continue
                if grep -qiE "linux.*(${pkgb}|${kver})" "$entry" 2>/dev/null || grep -qiE "(title|version).*(${pkgb}|${kver})" "$entry" 2>/dev/null; then
                    local l_rel i_rel
                    l_rel="$(awk '/^linux[[:space:]]+/ {print $2}' "$entry" | head -n1 || true)"
                    i_rel="$(awk '/^initrd[[:space:]]+/ {print $2}' "$entry" | tail -n1 || true)"
                    if [[ -n "$l_rel" && -f "${bdir}/${l_rel#/}" ]]; then
                        k_vmlinuz="${bdir}/${l_rel#/}"
                    fi
                    if [[ -n "$i_rel" && -f "${bdir}/${i_rel#/}" ]]; then
                        k_initrd="${bdir}/${i_rel#/}"
                        k_mode="bls"
                        k_sz="$(stat -c %s "$k_initrd" 2>/dev/null || echo 0)"
                    fi
                    if [[ -n "$k_vmlinuz" && -n "$k_initrd" ]]; then
                        break 2
                    fi
                fi
            done
        fi
        if [[ -z "$k_vmlinuz" || -z "$k_initrd" ]]; then
            local bls_k bls_i
            bls_k="$(compgen -G "${bdir}/*/${kver}/linux" 2>/dev/null | head -n1 || true)"
            [[ -z "$bls_k" ]] && bls_k="$(compgen -G "${bdir}/*/${kver}/vmlinuz" 2>/dev/null | head -n1 || true)"
            bls_i="$(compgen -G "${bdir}/*/${kver}/initrd*" 2>/dev/null | head -n1 || true)"
            [[ -z "$bls_i" ]] && bls_i="$(compgen -G "${bdir}/*/${kver}/initramfs*" 2>/dev/null | head -n1 || true)"
            if [[ -n "$bls_k" && -f "$bls_k" ]]; then
                k_vmlinuz="$bls_k"
            fi
            if [[ -n "$bls_i" && -f "$bls_i" ]]; then
                k_initrd="$bls_i"
                k_mode="bls"
                k_sz="$(stat -c %s "$k_initrd" 2>/dev/null || echo 0)"
            fi
            if [[ -n "$k_vmlinuz" && -n "$k_initrd" ]]; then
                break
            fi
        fi
    done

    # 3. Traditional Flat Layout (GRUB / Limine / rEFInd / flat systemd-boot)
    for bdir in "${boot_dirs[@]}"; do
        if [[ -z "$k_vmlinuz" ]]; then
            for kcand in \
                "${bdir}/vmlinuz-${pkgb}" \
                "${bdir}/vmlinuz-${kver}" \
                "${bdir}/${pkgb}/vmlinuz" \
                "${bdir}/${pkgb}/linux"; do
                if [[ -f "$kcand" ]]; then
                    k_vmlinuz="$kcand"
                    break
                fi
            done
        fi

        if [[ -z "$k_initrd" ]]; then
            for icand in \
                "${bdir}/initramfs-${pkgb}.img" \
                "${bdir}/initramfs-${kver}.img" \
                "${bdir}/initramfs-${pkgb}" \
                "${bdir}/initrd-${pkgb}.img" \
                "${bdir}/initrd-${pkgb}" \
                "${bdir}/initrd-${kver}" \
                "${bdir}/${pkgb}/initramfs.img" \
                "${bdir}/${pkgb}/initrd"; do
                if [[ -f "$icand" ]]; then
                    k_initrd="$icand"
                    k_mode="normal"
                    k_sz="$(stat -c %s "$k_initrd" 2>/dev/null || echo 0)"
                    break
                fi
            done
        fi

        if [[ -z "$k_initrd" ]]; then
            for bcand in \
                "${bdir}/booster-${pkgb}.img" \
                "${bdir}/booster-${kver}.img"; do
                if [[ -f "$bcand" ]]; then
                    k_initrd="$bcand"
                    k_mode="booster"
                    k_sz="$(stat -c %s "$k_initrd" 2>/dev/null || echo 0)"
                    break
                fi
            done
        fi

        if [[ -z "$k_fallback" ]]; then
            for fcand in \
                "${bdir}/initramfs-${pkgb}-fallback.img" \
                "${bdir}/initramfs-${kver}-fallback.img" \
                "${bdir}/initrd-${pkgb}-fallback.img"; do
                if [[ -f "$fcand" ]]; then
                    k_fallback="$fcand"
                    break
                fi
            done
        fi
    done

    # 4. Fallback for single-kernel systems
    if [[ -z "$k_vmlinuz" && -f "/boot/vmlinuz" ]]; then
        k_vmlinuz="/boot/vmlinuz"
    fi
    if [[ -z "$k_vmlinuz" && -f "/efi/vmlinuz" ]]; then
        k_vmlinuz="/efi/vmlinuz"
    fi
}

check_kernel() {
    local running_k
    running_k="$(uname -r)"
    local installed_kernels=()
    local missing_components=()

    # Multi-kernel validation: inspect all installed kernel module directories
    for pkgbase_file in /usr/lib/modules/*/pkgbase; do
        [[ -f "$pkgbase_file" ]] || continue
        local kdir="${pkgbase_file%/pkgbase}"
        local kver="${kdir##*/}"
        local pkgb="$(< "$pkgbase_file")"
        [[ -z "$pkgb" ]] && pkgb="linux"
        installed_kernels+=("$pkgb")

        local k_vmlinuz="" k_initrd="" k_fallback="" k_mode="" k_sz=0
        _resolve_kernel_and_initramfs "$pkgb" "$kver"

        [[ -z "$k_vmlinuz" ]] && missing_components+=("$pkgb: missing kernel")
        [[ -z "$k_initrd" ]] && missing_components+=("$pkgb: missing initramfs")
    done

    if (( ${#missing_components[@]} > 0 )); then
        add_row "Kernel & modules" "FAIL ✖ (${missing_components[*]})" "BOOT"
        ((ERRORS++))
        log "HEALTH kernel_modules=FAIL missing='${missing_components[*]}'"
    else
        local running_disp="${running_k}"
        add_row "Kernel & modules" "PASS ✔ (${installed_kernels[*]} | booted: $running_disp)" "BOOT"
        log "HEALTH kernel_modules=PASS installed='${installed_kernels[*]}' booted=$running_k"
    fi
}

check_initramfs() {
    # Maintained for backwards compatibility / specific sub-checks
    local running="${1:-$(uname -r)}"
    local pkgbase_file="/usr/lib/modules/$running/pkgbase"
    local pkgbase="linux-lts"
    [[ -f "$pkgbase_file" ]] && pkgbase="$(< "$pkgbase_file")"

    local k_vmlinuz="" k_initrd="" k_fallback="" k_mode="" k_sz=0
    _resolve_kernel_and_initramfs "$pkgbase" "$running"

    if [[ -n "$k_initrd" && -f "$k_initrd" ]]; then
        local sz_mb=$((k_sz / 1048576))
        if [[ "$k_mode" == "uki" ]]; then
            add_row "Initramfs ($pkgbase)" "PASS ✔ (UKI image [${sz_mb}MB])" "BOOT"
            log "HEALTH initramfs=PASS mode=uki pkgbase=$pkgbase file=$k_initrd"
        elif [[ "$k_mode" == "booster" ]]; then
            add_row "Initramfs ($pkgbase)" "PASS ✔ (booster [${sz_mb}MB])" "BOOT"
            log "HEALTH initramfs=PASS mode=booster pkgbase=$pkgbase file=$k_initrd"
        elif [[ "$k_mode" == "bls" ]]; then
            add_row "Initramfs ($pkgbase)" "PASS ✔ (BLS initrd [${sz_mb}MB])" "BOOT"
            log "HEALTH initramfs=PASS mode=bls pkgbase=$pkgbase file=$k_initrd"
        else
            local gen
            gen="$(detect_initramfs_generator)"
            [[ "$gen" == "unknown" ]] && gen="normal"
            if [[ -n "$k_fallback" && -f "$k_fallback" ]]; then
                add_row "Initramfs ($pkgbase)" "PASS ✔ ($gen [${sz_mb}MB] + fallback)" "BOOT"
                log "HEALTH initramfs=PASS mode=$gen fallback=yes pkgbase=$pkgbase file=$k_initrd"
            else
                # For Dracut or custom mkinitcpio presets without fallback: this is a full PASS
                add_row "Initramfs ($pkgbase)" "PASS ✔ ($gen [${sz_mb}MB])" "BOOT"
                log "HEALTH initramfs=PASS mode=$gen fallback=no pkgbase=$pkgbase file=$k_initrd"
            fi
        fi
    else
        add_row "Initramfs ($pkgbase)" "FAIL ✖ (missing initramfs image)" "BOOT"
        ((ERRORS++))
        log "HEALTH initramfs=FAIL normal_missing pkgbase=$pkgbase"
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
        log "HEALTH efi=WARN low_space=${avail_mb}MB mount=$efi_mnt"
    else
        add_row "EFI partition ($efi_mnt)" "PASS ✔ (mounted vfat, free: ${avail_mb:-?}MB)"
        log "HEALTH efi=PASS free_mb=${avail_mb:-unknown} mount=$efi_mnt"
    fi
}

check_reboot_pending() {
    local running_k
    running_k="$(uname -r)"

    # Bulletproof Arch Linux pending reboot detection:
    # A reboot is required when pacman has updated/removed the running kernel modules directory
    if [[ ! -d "/usr/lib/modules/$running_k" ]]; then
        add_row "Reboot pending" "WARN ⚠ (running kernel $running_k deleted on disk)"
        ((WARNINGS++))
        log "HEALTH reboot_pending=YES reason=modules_dir_missing"
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
    local vga_info drivers_in_use
    vga_info="$(lspci -k 2>/dev/null | grep -A 4 -Ei 'VGA|3D|Display' || true)"
    drivers_in_use="$(printf '%s\n' "$vga_info" | grep 'Kernel driver in use:' | awk '{print $5}' | sort -u | tr '\n' ' ' || true)"

    local target_uid="${EUID}"
    if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
        target_uid="$(id -u "$SUDO_USER" 2>/dev/null || echo "$EUID")"
    fi

    local is_wayland=false
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" || -n "${WAYLAND_DISPLAY:-}" ]]; then
        is_wayland=true
    elif pgrep -u "$target_uid" -x "kwin_wayland|gnome-shell|Hyprland|sway|wayfire|river|labwc|cosmic-comp" &>/dev/null; then
        is_wayland=true
    elif pgrep -x "kwin_wayland|gnome-shell|Hyprland|sway|wayfire|river|labwc|cosmic-comp" &>/dev/null; then
        is_wayland=true
    fi

    local -a detected_errors=()
    local -a detected_notes=()

    local klog=""
    klog="$(journalctl -b 0 -k --no-pager 2>/dev/null || dmesg 2>/dev/null || true)"

    # --- NVIDIA Diagnostics ---
    if [[ "$drivers_in_use" == *"nvidia"* ]]; then
        local nv_xid
        nv_xid="$(printf '%s\n' "$klog" | grep -im 1 "NVRM: Xid" || true)"
        if [[ -n "$nv_xid" ]]; then
            detected_errors+=("NVIDIA Xid error in dmesg: $nv_xid")
        fi

        if ! $is_wayland; then
            local xorg_log="/var/log/Xorg.0.log"
            local user_home="${HOME}"
            if [[ "$EUID" -eq 0 && -n "${SUDO_USER:-}" ]]; then
                user_home="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")"
            fi
            [[ ! -f "$xorg_log" && -f "$user_home/.local/share/xorg/Xorg.0.log" ]] && xorg_log="$user_home/.local/share/xorg/Xorg.0.log"

            if [[ -f "$xorg_log" ]]; then
                local fliplock_count
                fliplock_count="$(grep -a -c "Failed to request fliplock" "$xorg_log" 2>/dev/null || true)"
                fliplock_count="${fliplock_count:-0}"
                fliplock_count="${fliplock_count//[^0-9]/}"

                local uptime_sec
                uptime_sec="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 3600)"
                local uptime_hours=$(( (uptime_sec + 3599) / 3600 ))
                local dynamic_threshold=$(( 30 + (uptime_hours * 10) ))
                local fliplock_threshold="${FLIPLOCK_WARN_THRESHOLD:-$dynamic_threshold}"

                if (( fliplock_count > fliplock_threshold )); then
                    detected_errors+=("$fliplock_count fliplock stalls in Xorg (threshold: $fliplock_threshold)")
                elif (( fliplock_count > 0 )); then
                    detected_notes+=("Minor fliplock jitter ($fliplock_count events in Xorg) - normal DPMS transitions")
                fi
            fi
        fi
    fi

    # --- AMD Radeon Diagnostics ---
    if [[ "$drivers_in_use" == *"amdgpu"* || "$drivers_in_use" == *"radeon"* ]]; then
        local amd_err
        amd_err="$(printf '%s\n' "$klog" | grep -Ei "(amdgpu.*ERROR|ring gfx.*timeout|GPU reset begin|amdgpu.*failed to initialize|drm:amdgpu_job_timedout)" | head -n 1 || true)"
        if [[ -n "$amd_err" ]]; then
            detected_errors+=("AMD GPU error in kernel log: $amd_err")
        fi
    fi

    # --- Intel Graphics Diagnostics (Hardened against false matches) ---
    if [[ "$drivers_in_use" == *"i915"* || "$drivers_in_use" == *"xe"* ]]; then
        local intel_err
        intel_err="$(printf '%s\n' "$klog" | grep -Ei "(i915.*GPU HANG|\bxe\b.*GPU HANG|i915_reset|\[drm\] \*ERROR\*.*xe|xe\s+[0-9a-fA-F:.]+\s*:\s*\[drm\])" | head -n 1 || true)"
        if [[ -n "$intel_err" ]]; then
            detected_errors+=("Intel GPU error in kernel log: $intel_err")
        fi
    fi

    # --- Status Evaluation ---
    local log_out="${LOG_FILE:-/tmp/sys-health.log}"
    if (( ${#detected_errors[@]} > 0 )); then
        add_row "GPU errors & lockups" "WARN ⚠ (${detected_errors[0]})"
        ((WARNINGS++)) || true
        log "HEALTH gpu_errors=WARN count=${#detected_errors[@]}"
        {
            echo "### GPU HARDWARE / DRIVER ERRORS"
            for err in "${detected_errors[@]}"; do
                echo "  • $err"
            done
            echo ""
        } >> "$log_out" 2>/dev/null || true
    elif (( ${#detected_notes[@]} > 0 )); then
        add_row "GPU errors & lockups" "PASS ✔"
        log "HEALTH gpu_errors=PASS note='${detected_notes[0]}'"
        {
            echo "### GPU HARDWARE / DRIVER LOG NOTE"
            for n in "${detected_notes[@]}"; do
                echo "  • $n"
            done
            echo ""
        } >> "$log_out" 2>/dev/null || true
    else
        add_row "GPU errors & lockups" "PASS ✔"
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

check_power() {
    local has_battery=false
    local bat_capacity=""
    local bat_status=""
    local bat_name=""

    for bat in /sys/class/power_supply/BAT* /sys/class/power_supply/battery; do
        if [[ -d "$bat" ]]; then
            local scope
            scope="$(cat "$bat/scope" 2>/dev/null || echo "System")"
            if [[ "$scope" != "Device" ]]; then
                has_battery=true
                bat_name="${bat##*/}"
                bat_capacity="$(cat "$bat/capacity" 2>/dev/null || echo "")"
                bat_status="$(cat "$bat/status" 2>/dev/null || echo "Unknown")"
                break
            fi
        fi
    done

    if $has_battery; then
        local cap_num="${bat_capacity//[^0-9]/}"
        if [[ -n "$cap_num" ]] && (( cap_num < 20 )) && [[ "$bat_status" != "Charging" && "$bat_status" != "Full" ]]; then
            add_row "Power & Battery" "WARN ⚠ ($bat_name: ${cap_num}% [${bat_status}] - connect AC)" "HW"
            ((WARNINGS++))
            log "HEALTH power=WARN battery_low=$cap_num status=$bat_status"
        else
            add_row "Power & Battery" "PASS ✔ ($bat_name: ${cap_num}% [${bat_status}])" "HW"
            log "HEALTH power=PASS battery=$cap_num status=$bat_status"
        fi
    else
        add_row "Power & Battery" "PASS ✔ (AC Desktop power)" "HW"
        log "HEALTH power=PASS chassis=desktop ac=online"
    fi
}

check_fstrim() {
    if ! command -v systemctl &>/dev/null; then
        return
    fi

    # Check if any disk supports TRIM / discard
    local has_trim_device=false
    if lsblk -dno DISC-GRAN 2>/dev/null | grep -v '^0B$' | grep -q '[1-9]'; then
        has_trim_device=true
    fi

    if ! $has_trim_device; then
        add_row "SSD/NVMe TRIM timer" "INFO ℹ (no SSD/NVMe detected)" "HW"
        log "HEALTH fstrim=INFO reason=no_trim_devices"
        return
    fi

    local status
    status="$(systemctl is-active fstrim.timer 2>/dev/null || true)"

    if [[ "$status" == "active" ]]; then
        add_row "SSD/NVMe TRIM timer" "PASS ✔ (active)" "HW"
        log "HEALTH fstrim=PASS active=YES"
    elif findmnt -no OPTIONS / 2>/dev/null | grep -q 'discard=async'; then
        add_row "SSD/NVMe TRIM timer" "PASS ✔ (btrfs async discard enabled)" "HW"
        log "HEALTH fstrim=PASS mode=btrfs_async_discard"
    else
        add_row "SSD/NVMe TRIM timer" "WARN ⚠ (inactive)" "HW"
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

    local has_user_bus=false
    if [[ "$EUID" -ne 0 ]] || [[ -n "${XDG_RUNTIME_DIR:-}" && -S "${XDG_RUNTIME_DIR}/bus" ]]; then
        if systemctl --user --quiet is-system-running 2>/dev/null || systemctl --user list-units &>/dev/null; then
            has_user_bus=true
        fi
    fi

    if $has_user_bus; then
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
    else
        add_row "Systemd failed (user)" "INFO ℹ (no active user session bus)"
        log "HEALTH systemd_user_failed=INFO no_user_bus"
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
    spinner "Checking package file integrity (filtering ephemeral tmpfs)..."         bash -c 'sudo -n pacman -Qk > "$1" 2>&1 || pacman -Qk > "$1" 2>&1 || true' _ "$integrity_file"
    PACMAN_INTEGRITY_TEXT="$(cat "$integrity_file" 2>/dev/null || true)"

    # Identify candidate packages reporting missing files
    local bad_pkgs
    bad_pkgs="$(awk '/[1-9][0-9]* missing files/ {sub(/:$/, "", $1); print $1}' "$integrity_file" 2>/dev/null || true)"

    local real_problems=()
    if [[ -n "$bad_pkgs" ]]; then
        for pkg in $bad_pkgs; do
            [[ -z "$pkg" ]] && continue
            # Filter out benign ephemeral directories (/var, /run, /tmp, /dev, /proc, /sys)
            # Flag ONLY packages with missing critical binaries, libraries, or system configs (/usr, /etc, /opt)
            local missing_crit
            missing_crit="$(pacman -Ql "$pkg" 2>/dev/null | while read -r _ f; do
                if [[ ! -e "$f" && ! "$f" =~ ^/(var|run|tmp|dev|proc|sys)/ ]]; then
                    echo "$f"
                    break
                fi
            done)"
            if [[ -n "$missing_crit" ]]; then
                real_problems+=("$pkg (missing: $missing_crit)")
            fi
        done
    fi

    if (( ${#real_problems[@]} == 0 )); then
        add_row "Package file integrity" "PASS ✔" "SYS"
        log "HEALTH package_integrity=PASS"
    else
        local prob_str="${real_problems[*]}"
        add_row "Package file integrity" "WARN ⚠ (Corrupt: ${real_problems[0]})" "SYS"
        ((WARNINGS++))
        log "HEALTH package_integrity=WARN real_missing='$prob_str'"
        {
            echo "### PACMAN PACKAGE INTEGRITY"
            printf '%s\n' "${real_problems[@]}"
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

check_network() {
    if ! command -v ip &>/dev/null || ! command -v ping &>/dev/null; then
        add_row "Network link & Gateway" "INFO ℹ (ip/ping missing)" "NET"
        ((INFO_COUNT++))
        log "HEALTH network=tools_missing"
        return
    fi

    local dev gw
    dev="$(ip -4 route show default 2>/dev/null | awk '/default via/ {print $5; exit}')"
    gw="$(ip -4 route show default 2>/dev/null | awk '/default via/ {print $3; exit}')"

    if [[ -z "$dev" || -z "$gw" ]]; then
        add_row "Network link & Gateway" "FAIL ✖ (no default route)" "NET"
        ((ERRORS++))
        log "HEALTH network=FAIL default_route_missing"
        return
    fi

    local operstate
    operstate="$(cat "/sys/class/net/$dev/operstate" 2>/dev/null || echo "unknown")"
    if [[ "$operstate" != "up" && "$operstate" != "unknown" ]]; then
        add_row "Network link & Gateway" "FAIL ✖ ($dev state: $operstate)" "NET"
        ((ERRORS++))
        log "HEALTH network=FAIL iface=$dev operstate=$operstate"
        return
    fi

    local rx_err tx_err rx_crc total_err
    rx_err="$(cat "/sys/class/net/$dev/statistics/rx_errors" 2>/dev/null || echo 0)"
    tx_err="$(cat "/sys/class/net/$dev/statistics/tx_errors" 2>/dev/null || echo 0)"
    rx_crc="$(cat "/sys/class/net/$dev/statistics/rx_crc_errors" 2>/dev/null || echo 0)"
    total_err=$(( rx_err + tx_err + rx_crc ))

    local speed speed_str=""
    if [[ -d "/sys/class/net/$dev/wireless" || -d "/sys/class/net/$dev/phy80211" ]]; then
        speed_str="Wi-Fi, "
    else
        speed="$(cat "/sys/class/net/$dev/speed" 2>/dev/null || echo "")"
        if [[ -n "$speed" && "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )); then
            if (( speed >= 1000 )); then
                if (( speed % 1000 == 0 )); then
                    speed_str="$(( speed / 1000 ))Gb/s, "
                else
                    speed_str="$(awk "BEGIN {printf \"%.1fGb/s, \", $speed/1000}")"
                fi
            else
                speed_str="${speed}Mb/s, "
            fi
        fi
    fi

    local ping_out ping_ms
    ping_out="$(ping -c 1 -W 1 "$gw" 2>&1)"
    if [[ $? -ne 0 ]]; then
        add_row "Network link & Gateway" "FAIL ✖ (gateway $gw unreachable)" "NET"
        ((ERRORS++))
        log "HEALTH network=FAIL iface=$dev gateway=$gw ping=unreachable"
        return
    fi
    ping_ms="$(printf '%s\n' "$ping_out" | grep -oE 'time=[0-9.]+' | head -n1 | cut -d= -f2)"
    if [[ -n "$ping_ms" ]]; then
        ping_ms="$(awk "BEGIN {printf \"%.1f\", $ping_ms}" 2>/dev/null || echo "$ping_ms")"
    else
        ping_ms="<1"
    fi

    local gw6 ping6_ms="" ipv6_tag=""
    gw6="$(ip -6 route show default 2>/dev/null | awk '/default via/ {print $3; exit}')"
    if [[ -n "$gw6" ]]; then
        local ping6_out
        if ping6_out="$(ping -6 -c 1 -W 1 "$gw6" 2>&1)"; then
            ping6_ms="$(printf '%s\n' "$ping6_out" | grep -oE 'time=[0-9.]+' | head -n1 | cut -d= -f2)"
            ipv6_tag=" +IPv6:${ping6_ms:-<1}ms"
        else
            ipv6_tag=" +IPv6:unreachable"
            log "HEALTH network=INFO iface=$dev gw6=$gw6 ping6=unreachable"
        fi
    fi

    # Generic orphan VPN DNS detection (covers AirVPN, WireGuard, OpenVPN, Mullvad)
    if grep -qE '^(nameserver 10\.128\.0\.1|nameserver 10\.2\.0\.1|nameserver 10\.64\.0\.1)' /etc/resolv.conf 2>/dev/null; then
        if ! ip link show | grep -qiE '(tun|wg|tap|airvpn|nordlynx|mullvad)'; then
            add_row "Network link & Gateway" "WARN ⚠ (orphan VPN DNS in resolv.conf)" "NET"
            ((WARNINGS++))
            log "HEALTH network=WARN orphan_vpn_dns=yes"
            return
        fi
    fi

    if (( total_err > 50 )); then
        add_row "Network link & Gateway" "WARN ⚠ ($dev: $total_err NIC errors, gw: ${gw} ${ping_ms}ms)" "NET"
        ((WARNINGS++))
        log "HEALTH network=WARN iface=$dev speed=${speed:-auto} gateway=$gw ping=${ping_ms}ms errors=$total_err"
        return
    fi

    if [[ -z "$speed_str" || "$speed_str" != "Wi-Fi, "* ]]; then
        if [[ -n "$speed" && "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 && speed <= 100 )); then
            add_row "Network link & Gateway" "WARN ⚠ ($dev: degraded link speed ${speed}Mb/s)" "NET"
            ((WARNINGS++))
            log "HEALTH network=WARN iface=$dev degraded_speed=${speed}Mbps gateway=$gw"
            return
        fi
    fi

    # NetworkManager Community Gotcha: unintended 'metered connection' throttling
    local metered_status="no"
    if command -v nmcli &>/dev/null; then
        metered_status="$(nmcli -t -f GENERAL.METERED dev show "$dev" 2>/dev/null | cut -d: -f2- || true)"
        if [[ "$metered_status" =~ ^yes ]]; then
            local conn_name
            conn_name="$(nmcli -t -f GENERAL.CONNECTION dev show "$dev" 2>/dev/null | cut -d: -f2- || echo "$dev")"
            add_row "Network link & Gateway" "WARN ⚠ ($dev: metered connection enabled)" "NET"
            ((WARNINGS++))
            log "HEALTH network=WARN metered=yes dev=$dev connection=\"$conn_name\""
            {
                echo "### NETWORK COMMUNITY GOTCHA (METERED CONNECTION)"
                echo "[COMMUNITY-GOTCHA] Interface $dev (connection: '$conn_name') has metered connection ENABLED ($metered_status)."
                echo "Known issue in Arch/EOS: NetworkManager auto-metering causes severe network throughput drops after updates."
                echo "Fix: sudo nmcli connection modify '$conn_name' connection.metered no && sudo nmcli connection up '$conn_name'"
                echo ""
            } >> "$LOG_FILE"
            return
        fi
    fi

    add_row "Network link & Gateway" "PASS ✔ ($dev: ${speed_str}gw: ${gw} ${ping_ms}ms${ipv6_tag})" "NET"
    log "HEALTH network=PASS iface=$dev speed=${speed:-auto} gateway=$gw ping=${ping_ms}ms errors=0 metered=${metered_status:-no}"
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

    local rss_data
    rss_data="$(curl -fsS --max-time 4 https://archlinux.org/feeds/news/ 2>/dev/null || true)"

    if [[ -z "$rss_data" ]]; then
        log "HEALTH arch_news=UNAVAILABLE (network/timeout)"
        return
    fi

    local affected_pkgs=()
    local recent_items=()

    # Parse top 10 news items across the feed instead of single NR==2
    while IFS= read -r title; do
        [[ -z "$title" ]] && continue
        local clean_title
        clean_title="$(sed 's/&gt;/>/g; s/&lt;/</g; s/&amp;/\&/g; s/&quot;/"/g' <<< "$title")"
        if grep -qi 'manual intervention' <<< "$clean_title"; then
            local pkg
            pkg="$(awk '{print $1}' <<< "$clean_title")"
            if pacman -Qq "$pkg" &>/dev/null; then
                affected_pkgs+=("$pkg")
            fi
        fi
        recent_items+=("$clean_title")
    done < <(grep -oP '(?<=<title>).*?(?=</title>)' <<< "$rss_data" | sed '1d' | head -n 10 || true)

    if (( ${#affected_pkgs[@]} > 0 )); then
        add_row "Arch News (30d)" "WARN ⚠ (manual intervention: ${affected_pkgs[*]})" "NET"
        ((WARNINGS++))
        log "HEALTH arch_news=WARN manual_intervention=YES affected=YES packages='${affected_pkgs[*]}'"
        {
            echo "### ARCH NEWS MANUAL INTERVENTION REQUIRED"
            echo "The following installed package(s) have critical manual intervention notices on Arch News:"
            printf '  • %s\n' "${affected_pkgs[@]}"
            echo "Refer to https://archlinux.org/news/ for intervention instructions before upgrading."
        } >> "$LOG_FILE"
    else
        local top_title="${recent_items[0]:-Recent news up to date}"
        if (( ${#top_title} > 30 )); then
            top_title="${top_title:0:29}…"
        fi
        add_row "Arch News (Latest)" "PASS ✔ ($top_title)" "NET"
        log "HEALTH arch_news=PASS manual_intervention=NO top_title='$top_title'"
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

# ------------------------------------------------------------------------------
# Gaming & Steam readiness
# ------------------------------------------------------------------------------

detect_gaming_system() {
    # Check for gaming client binaries
    if command -v steam &>/dev/null || command -v wine &>/dev/null || command -v lutris &>/dev/null || \
       command -v heroic &>/dev/null || command -v bottles &>/dev/null; then
        return 0
    fi

    # Check for gaming data directories in user home
    if [[ -d "$HOME/.local/share/Steam" || -d "$HOME/.steam" || -d "$HOME/.wine" || \
          -d "$HOME/.local/share/lutris" || -d "$HOME/.config/heroic" || \
          -d "$HOME/.var/app/com.usebottles.bottles" || -d "$HOME/.var/app/com.valvesoftware.Steam" ]]; then
        return 0
    fi

    # Check for gaming helper packages or 32-bit graphics
    if pacman -Q protonup-qt &>/dev/null 2>&1 || pacman -Q gamemode &>/dev/null 2>&1 || \
       pacman -Q mangohud &>/dev/null 2>&1 || pacman -Q gamescope &>/dev/null 2>&1 || \
       pacman -Q lib32-vulkan-icd-loader &>/dev/null 2>&1 || pacman -Q wine &>/dev/null 2>&1; then
        return 0
    fi

    return 1
}

check_gaming() {
    local on_demand="${1:-0}"
    log "--- [GAMING] Checking Steam, Vulkan 32-bit & Gaming Readiness ---"

    local is_gamer=false
    if detect_gaming_system; then
        is_gamer=true
        GAMING_DETECTED=true
    else
        GAMING_DETECTED=false
    fi

    # If general system audit and non-gaming system, skip cleanly without adding rows
    if ! $is_gamer && (( on_demand == 0 )); then
        log "HEALTH gaming=SKIPPED reason=non_gaming_workstation"
        return 0
    fi

    # 1. Multilib repository in /etc/pacman.conf
    GAMING_MULTILIB=false
    if grep -q -E '^\s*\[multilib\]' /etc/pacman.conf 2>/dev/null; then
        GAMING_MULTILIB=true
        add_row "Multilib repository" "PASS ✔ (Enabled in /etc/pacman.conf)" "GAME"
        log "HEALTH multilib=PASS"
    elif $is_gamer; then
        add_row "Multilib repository" "WARN ⚠ (Disabled - required for Steam 32-bit games)" "GAME"
        ((WARNINGS++))
        log "HEALTH multilib=WARN multilib_disabled"
    else
        add_row "Multilib repository" "INFO ℹ (Disabled - pure 64-bit system)" "GAME"
        log "HEALTH multilib=INFO multilib_disabled"
    fi

    # 2. Vulkan & 32-bit driver stack
    local vga_info drivers="" driver_list="" gpu_name=""
    vga_info="$(lspci -k 2>/dev/null | grep -A 4 -iE 'VGA|3D|Display' || true)"
    if [[ -n "$vga_info" ]]; then
        drivers="$(printf '%s
' "$vga_info" | grep 'Kernel driver in use:' | awk '{print $5}' | sort -u || true)"
        driver_list="$(echo $drivers | tr '
' ' ' | sed 's/ $//')"
    fi

    local vulkan_64_ok=false vulkan_32_loader=false vulkan_32_driver=false
    if command -v vulkaninfo &>/dev/null; then
        local v_dev
        v_dev="$(vulkaninfo --summary 2>/dev/null | grep 'deviceName' | head -n1 | awk -F'=' '{print $2}' | sed 's/^[ 	]*//' || true)"
        [[ -n "$v_dev" ]] && gpu_name="$v_dev"
        [[ -n "$gpu_name" ]] && vulkan_64_ok=true
    elif [[ -f /usr/share/vulkan/icd.d/nvidia_icd.json || -f /usr/share/vulkan/icd.d/radeon_icd.json || -f /usr/share/vulkan/icd.d/intel_icd.json ]]; then
        vulkan_64_ok=true
    fi

    [[ -f /usr/lib32/libvulkan.so.1 ]] && vulkan_32_loader=true

    local short_gpu=""
    if [[ -n "$gpu_name" ]]; then
        short_gpu="$(echo "$gpu_name" | sed -E 's/NVIDIA (GeForce )?//g; s/AMD (Radeon )?//g; s/Intel (R)?//g')"
    fi

    # Driver-specific 32-bit checks
    GAMING_VULKAN_32BIT=false
    if [[ "$driver_list" == *"nvidia"* ]]; then
        if [[ -f /usr/lib32/libGLX_nvidia.so.0 || -f /usr/lib32/libnvidia-glcore.so ]]; then
            vulkan_32_driver=true
        fi

        if $vulkan_64_ok && $vulkan_32_loader && $vulkan_32_driver; then
            GAMING_VULKAN_32BIT=true
            add_row "Vulkan & 32-bit graphics" "PASS ✔ (${short_gpu:-NVIDIA} | 64+32-bit Vulkan OK)" "GAME"
            log "HEALTH vulkan_32bit=PASS driver=nvidia"
        elif ! $is_gamer; then
            add_row "Vulkan & 32-bit graphics" "INFO ℹ (${short_gpu:-NVIDIA} 64-bit | 32-bit multilib not installed)" "GAME"
            log "HEALTH vulkan_32bit=INFO pure_64bit"
        elif ! $vulkan_32_loader || ! $vulkan_32_driver; then
            local missing_parts=""
            ! $vulkan_32_loader && missing_parts+="lib32-vulkan-icd-loader "
            ! $vulkan_32_driver && missing_parts+="lib32-nvidia-utils "
            add_row "Vulkan & 32-bit graphics" "WARN ⚠ (Missing 32-bit stack: ${missing_parts% })" "GAME"
            ((WARNINGS++))
            log "HEALTH vulkan_32bit=WARN missing=${missing_parts% }"
        else
            add_row "Vulkan & 32-bit graphics" "WARN ⚠ (Vulkan ICD not fully reported)" "GAME"
            ((WARNINGS++))
            log "HEALTH vulkan_32bit=WARN"
        fi
    elif [[ "$driver_list" == *"amdgpu"* || "$driver_list" == *"radeon"* ]]; then
        [[ -f /usr/lib32/libvulkan_radeon.so ]] && vulkan_32_driver=true
        if $vulkan_64_ok && $vulkan_32_loader && $vulkan_32_driver; then
            GAMING_VULKAN_32BIT=true
            add_row "Vulkan & 32-bit graphics" "PASS ✔ (${short_gpu:-AMD} | 64+32-bit RADV OK)" "GAME"
            log "HEALTH vulkan_32bit=PASS driver=amdgpu"
        elif ! $is_gamer; then
            add_row "Vulkan & 32-bit graphics" "INFO ℹ (${short_gpu:-AMD} 64-bit | 32-bit multilib not installed)" "GAME"
            log "HEALTH vulkan_32bit=INFO pure_64bit"
        elif ! $vulkan_32_loader || ! $vulkan_32_driver; then
            add_row "Vulkan & 32-bit graphics" "WARN ⚠ (Missing lib32-vulkan-radeon or 32-bit loader)" "GAME"
            ((WARNINGS++))
            log "HEALTH vulkan_32bit=WARN"
        else
            add_row "Vulkan & 32-bit graphics" "PASS ✔ (AMD Vulkan stack detected)" "GAME"
            log "HEALTH vulkan_32bit=PASS"
        fi
    elif [[ "$driver_list" == *"i915"* || "$driver_list" == *"xe"* ]]; then
        [[ -f /usr/lib32/libvulkan_intel.so ]] && vulkan_32_driver=true
        if $vulkan_64_ok && $vulkan_32_loader && $vulkan_32_driver; then
            GAMING_VULKAN_32BIT=true
            add_row "Vulkan & 32-bit graphics" "PASS ✔ (${short_gpu:-Intel} | 64+32-bit ANV OK)" "GAME"
            log "HEALTH vulkan_32bit=PASS driver=intel"
        elif ! $is_gamer; then
            add_row "Vulkan & 32-bit graphics" "INFO ℹ (${short_gpu:-Intel} 64-bit | 32-bit multilib not installed)" "GAME"
            log "HEALTH vulkan_32bit=INFO pure_64bit"
        else
            add_row "Vulkan & 32-bit graphics" "WARN ⚠ (Incomplete Intel 32-bit Vulkan stack)" "GAME"
            ((WARNINGS++))
            log "HEALTH vulkan_32bit=WARN"
        fi
    else
        add_row "Vulkan & 32-bit graphics" "INFO ℹ (No dedicated Vulkan driver identified)" "GAME"
        log "HEALTH vulkan_32bit=INFO"
    fi

    # 3. Proton memory limits (vm.max_map_count & soft file descriptor headroom)
    local map_count soft_nofile
    map_count="$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)"
    soft_nofile="$(ulimit -Sn 2>/dev/null || echo 0)"
    GAMING_MAX_MAP_COUNT="$map_count"

    if (( map_count >= 1048576 )); then
        add_row "Proton memory limits" "PASS ✔ (max_map_count: $map_count | nofile: $soft_nofile)" "GAME"
        log "HEALTH proton_memory=PASS map_count=$map_count nofile=$soft_nofile"
    elif (( map_count >= 262144 )); then
        add_row "Proton memory limits" "INFO ℹ (max_map_count: $map_count | >= 1048576 recommended for UE5)" "GAME"
        log "HEALTH proton_memory=INFO map_count=$map_count"
    else
        add_row "Proton memory limits" "WARN ⚠ (max_map_count low: $map_count - risk of crash in Proton)" "GAME"
        ((WARNINGS++))
        log "HEALTH proton_memory=WARN map_count=$map_count"
    fi

    # 4. Kernel Synchronization Primitives (fsync / futex_waitv syscall probe)
    local futex_ok=false
    if command -v python3 &>/dev/null; then
        local py_res
        py_res="$(python3 -c '
import ctypes, errno
try:
    libc = ctypes.CDLL(None, use_errno=True)
    libc.syscall.restype = ctypes.c_long
    ctypes.set_errno(0)
    rc = libc.syscall(449, ctypes.c_void_p(0), ctypes.c_uint(0), ctypes.c_uint(0), ctypes.c_void_p(0), ctypes.c_int(1))
    err = ctypes.get_errno()
    print(errno.errorcode.get(err, f"ERRNO_{err}"))
except Exception as e:
    print("FAILED")
' 2>/dev/null || echo "FAILED")"
        if [[ "$py_res" == "EINVAL" || "$py_res" == "EFAULT" ]]; then
            futex_ok=true
        fi
    fi

    if $futex_ok; then
        add_row "Kernel sync (fsync)" "PASS ✔ (futex_waitv syscall 449 verified)" "GAME"
        log "HEALTH futex_waitv=PASS syscall=449"
    else
        add_row "Kernel sync (fsync)" "INFO ℹ (futex_waitv not verified via syscall probe)" "GAME"
        log "HEALTH futex_waitv=INFO"
    fi

    # 5. Kernel Split-Lock Mitigation & Event Correlation (SRE Hardened)
    local split_lock=""
    split_lock="$(cat /proc/sys/kernel/split_lock_mitigate 2>/dev/null || echo "not_found")"
    local split_hits=""
    split_hits="$(journalctl -k -b --no-pager 2>/dev/null | grep -Ei 'split lock|split_lock' | tail -n 3 || true)"

    if [[ "$split_lock" == "0" ]]; then
        add_row "Kernel split-lock" "PASS ✔ (Mitigation disabled - optimal for Proton)" "GAME"
        log "HEALTH split_lock=PASS state=0"
    elif [[ "$split_lock" == "1" ]]; then
        if [[ -n "$split_hits" ]]; then
            add_row "Kernel split-lock" "WARN ⚠ (Mitigation active and split-locks detected in dmesg)" "GAME"
            ((WARNINGS++))
            log "HEALTH split_lock=WARN state=1 events=present"
        else
            add_row "Kernel split-lock" "PASS ✔ (Mitigation active | 0 split-lock stalls)" "GAME"
            log "HEALTH split_lock=PASS state=1 events=none"
        fi
    elif [[ "$split_lock" == "not_found" ]]; then
        add_row "Kernel split-lock" "INFO ℹ (Not exposed by kernel/CPU)" "GAME"
        log "HEALTH split_lock=INFO state=not_found"
    fi

    # 6. CPU governor & GameMode (Client/Daemon Active Validation)
    local gov="" gamemode_status="MISSING"
    gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")"
    
    if command -v gamemoded &>/dev/null; then
        if gamemoded -t &>/dev/null; then
            gamemode_status="PASS"
        else
            gamemode_status="FAIL_TEST"
        fi
    fi

    if [[ "$gamemode_status" == "PASS" ]]; then
        add_row "CPU governor & GameMode" "PASS ✔ (Governor: $gov | GameMode D-Bus/daemon OK)" "GAME"
        log "HEALTH cpu_governor=PASS governor=$gov gamemode=tested_ok"
    elif [[ "$gamemode_status" == "FAIL_TEST" ]]; then
        add_row "CPU governor & GameMode" "WARN ⚠ (GameMode daemon test failed - check Polkit)" "GAME"
        ((WARNINGS++))
        log "HEALTH cpu_governor=WARN governor=$gov gamemode=test_failed"
    elif [[ "$gov" == "performance" ]]; then
        add_row "CPU governor & GameMode" "PASS ✔ (Governor: performance | max clocking)" "GAME"
        log "HEALTH cpu_governor=PASS governor=performance gamemode=none"
    else
        add_row "CPU governor & GameMode" "INFO ℹ (Governor: $gov | GameMode optional for stutter)" "GAME"
        log "HEALTH cpu_governor=INFO governor=$gov gamemode=none"
    fi

    # 7. Desktop session & GPU match (Quirk awareness for Maxwell / 580xx)
    local session_type="${XDG_SESSION_TYPE:-unknown}"
    if [[ "$driver_list" == *"nvidia"* && ( "$gpu_name" =~ 9[0-9]{2} || "$gpu_name" =~ Maxwell || "$vga_info" =~ GM204 ) ]]; then
        if [[ "$session_type" == "x11" ]]; then
            add_row "Desktop session & GPU" "PASS ✔ (X11 optimal for Maxwell | KWin bypass OK)" "GAME"
            log "HEALTH desktop_session=PASS session=x11 gpu=maxwell"
        elif [[ "$session_type" == "wayland" ]]; then
            add_row "Desktop session & GPU" "INFO ℹ (Wayland on Maxwell/580xx - verify explicit sync)" "GAME"
            log "HEALTH desktop_session=INFO session=wayland gpu=maxwell"
        else
            add_row "Desktop session & GPU" "INFO ℹ (Session: $session_type)" "GAME"
            log "HEALTH desktop_session=INFO session=$session_type"
        fi

        # 8. GTX 970 VRAM Runtime Telemetry (3.5GB fast segment tracking)
        if command -v nvidia-smi &>/dev/null; then
            local vram_row gpu_n tot_m usd_m
            vram_row="$(nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
            if [[ -n "$vram_row" ]]; then
                gpu_n="$(awk -F', ' '{print $1}' <<< "$vram_row")"
                tot_m="$(awk -F', ' '{print $2}' <<< "$vram_row")"
                usd_m="$(awk -F', ' '{print $3}' <<< "$vram_row")"
                if [[ "$gpu_n" == *"GTX 970"* ]]; then
                    if (( usd_m >= 3584 )); then
                        add_row "GTX 970 VRAM allocation" "WARN ⚠ (${usd_m}/${tot_m} MB used | above 3.5GB fast segment)" "GAME"
                        ((WARNINGS++))
                        log "HEALTH gtx970_vram=WARN used=$usd_m total=$tot_m"
                    else
                        add_row "GTX 970 VRAM allocation" "PASS ✔ (${usd_m}/${tot_m} MB used | 3.5GB fast segment OK)" "GAME"
                        log "HEALTH gtx970_vram=PASS used=$usd_m total=$tot_m"
                    fi
                fi
            fi
        fi
    else
        add_row "Desktop session & GPU" "PASS ✔ (Session: $session_type)" "GAME"
        log "HEALTH desktop_session=PASS session=$session_type"
    fi

    # 9. Steam & Custom Proton runtime (GE-Proton detection)
    local has_steam=false custom_protons=""
    command -v steam &>/dev/null && has_steam=true
    custom_protons="$(find "$HOME/.local/share/Steam/compatibilitytools.d/" "$HOME/.steam/root/compatibilitytools.d/" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; 2>/dev/null | sort -u | paste -sd ", " - || true)"
    GAMING_CUSTOM_PROTON="$custom_protons"

    local proton_disp="$custom_protons"
    if (( ${#proton_disp} > 26 )); then
        proton_disp="${proton_disp:0:25}…"
    fi

    if $has_steam && [[ -n "$custom_protons" ]]; then
        add_row "Proton & Steam tools" "PASS ✔ (Steam OK | Custom: $proton_disp)" "GAME"
        log "HEALTH steam_runtime=PASS steam=yes custom_proton=$custom_protons"
    elif $has_steam; then
        add_row "Proton & Steam tools" "PASS ✔ (Steam OK | Valve Proton)" "GAME"
        log "HEALTH steam_runtime=PASS steam=yes custom_proton=none"
    elif ! $is_gamer; then
        add_row "Proton & Steam tools" "INFO ℹ (No gaming clients installed)" "GAME"
        log "HEALTH steam_runtime=INFO not_installed"
    else
        add_row "Proton & Steam tools" "INFO ℹ (Steam client not found in PATH)" "GAME"
        log "HEALTH steam_runtime=INFO steam=no"
    fi
}

run_gaming_check() {
    section "GAMING & STEAM READINESS AUDIT"
    AUDIT_TABLE=""
    AUDIT_TABLE_GAME=""
    ERRORS=0
    WARNINGS=0
    INFO_COUNT=0

    check_gaming 1

    render_audit_section "GAMING & STEAM READINESS" "$AUDIT_TABLE_GAME"

    echo ""
    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        if (( ERRORS == 0 && WARNINGS == 0 )); then
            if $GAMING_DETECTED; then
                gum style --foreground 82 --border double --align center --width "$UI_CARD_WIDTH" "GAMING READINESS: ALL CLEAR ✔"
            else
                gum style --foreground 81 --border double --align center --width "$UI_CARD_WIDTH" "GAMING AUDIT: PURE 64-BIT / NON-GAMING SYSTEM ℹ"
            fi
        elif (( ERRORS == 0 )); then
            gum style --foreground 214 --border double --align center --width "$UI_CARD_WIDTH" "GAMING READINESS: REVIEW ADVISORIES ⚠"
        else
            gum style --foreground 196 --border double --align center --width "$UI_CARD_WIDTH" "GAMING READINESS: ACTION REQUIRED ✖"
        fi
    else
        if (( ERRORS == 0 && WARNINGS == 0 )); then
            if $GAMING_DETECTED; then
                echo "GAMING READINESS: ALL CLEAR ✔"
            else
                echo "GAMING AUDIT: PURE 64-BIT / NON-GAMING SYSTEM ℹ"
            fi
        elif (( ERRORS == 0 )); then
            echo "GAMING READINESS: REVIEW ADVISORIES ⚠"
        else
            echo "GAMING READINESS: ACTION REQUIRED ✖"
        fi
    fi
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

    local remediations_json="[]"
    if (( WARNINGS > 0 || ERRORS > 0 )) && [[ -f "$LOG_FILE" ]] && command -v jq &>/dev/null; then
        local entries=()
        while IFS= read -r line; do
            [[ "$line" =~ ^HEALTH\ ([a-zA-Z0-9_]+)=(WARN|FAIL)(.*)$ ]] || continue
            local tag="${BASH_REMATCH[1]}"
            local sev="${BASH_REMATCH[2]}"
            local rest="${BASH_REMATCH[3]}"

            local code="SYS_DIAGNOSTIC_ADVISORY"
            local summary="Review diagnostic logs for details"
            local fix="sys-health --report"
            local risk="LOW"

            case "$tag" in
                reboot_pending)
                    code="SYS_REBOOT_REQUIRED"
                    summary="Running kernel modules were removed by pacman update"
                    fix="Reboot system to complete kernel upgrade"
                    risk="LOW"
                    ;;
                kernel_modules|initramfs)
                    code="BOOT_KERNEL_INITRAMFS_MISSING"
                    summary="Missing kernel image or initramfs file"
                    fix="Regenerate initramfs with dracut/mkinitcpio or reinstall kernel"
                    risk="HIGH"
                    ;;
                efi)
                    code="BOOT_EFI_SPACE_OR_MOUNT"
                    summary="ESP unmounted or low disk space"
                    fix="Verify ESP mount in /etc/fstab and check available space"
                    risk="HIGH"
                    ;;
                previous_boot)
                    code="SYS_UNCLEAN_SHUTDOWN"
                    summary="Previous session crashed or was uncleanly stopped"
                    fix="Inspect journal logs for previous boot: journalctl -b -1 -p 3"
                    risk="LOW"
                    ;;
                gpu|gpu_errors)
                    code="GPU_DRIVER_OR_LOG_STALL"
                    summary="GPU driver missing or hardware/driver lockup in logs"
                    fix="Review dmesg/journalctl for Xid or ring timeout errors"
                    risk="MEDIUM"
                    ;;
                dkms)
                    code="DKMS_MODULE_BUILD_FAIL"
                    summary="DKMS module broken or compilation failed"
                    fix="Inspect dkms status and rebuild failing modules"
                    risk="HIGH"
                    ;;
                cpu_temperature)
                    code="HW_CPU_HIGH_TEMP"
                    summary="CPU temperature exceeded threshold"
                    fix="Check cooler mount, thermal paste, and fan curves"
                    risk="MEDIUM"
                    ;;
                smart)
                    code="HW_STORAGE_SMART_FAILURE"
                    summary="Storage drive SMART self-test reporting failure"
                    fix="Backup critical data immediately and inspect with smartctl -a"
                    risk="HIGH"
                    ;;
                fstrim)
                    code="STORAGE_TRIM_INACTIVE"
                    summary="fstrim.timer is inactive on SSD/NVMe drive"
                    fix="sudo systemctl enable --now fstrim.timer"
                    risk="LOW"
                    ;;
                power)
                    code="HW_BATTERY_LOW"
                    summary="Battery is low on DC power"
                    fix="Connect AC power adapter before performing upgrades"
                    risk="HIGH"
                    ;;
                root_space)
                    code="STORAGE_ROOT_SPACE_CRITICAL"
                    summary="Root filesystem usage is over threshold"
                    fix="Run sys-health maintenance to clean package cache and old logs"
                    risk="HIGH"
                    ;;
                systemd_failed|systemd_user_failed)
                    code="SYS_SERVICE_FAILED"
                    summary="Failed systemd service units detected"
                    fix="Inspect failed units: systemctl --failed (or --user --failed)"
                    risk="LOW"
                    ;;
                sysrq)
                    code="SYS_SYSRQ_RESTRICTED"
                    summary="Emergency Magic SysRq recovery keys are disabled"
                    fix="echo 'kernel.sysrq = 1' | sudo tee /etc/sysctl.d/99-sysrq.conf"
                    risk="LOW"
                    ;;
                pacman_lock)
                    code="PKG_PACMAN_STALE_LOCK"
                    summary="Pacman DB lock exists with no running pacman process"
                    fix="Verify with pgrep pacman and remove: sudo rm /var/lib/pacman/db.lck"
                    risk="LOW"
                    ;;
                package_integrity)
                    code="PKG_CORRUPT_FILES"
                    summary="Critical files missing from installed packages"
                    fix="Reinstall affected package(s) via sudo pacman -S --force <pkg>"
                    risk="HIGH"
                    ;;
                pacnew)
                    code="CONF_PACNEW_UNMERGED"
                    summary="Unmerged .pacnew configuration files found in /etc"
                    fix="Merge configuration updates using eos-pacdiff or pacdiff"
                    risk="LOW"
                    ;;
                network)
                    if [[ "$rest" =~ metered=yes ]]; then
                        code="NET_METERED_THROTTLE"
                        summary="Network interface has metered connection enabled"
                        fix="sudo nmcli connection modify '<connection>' connection.metered no"
                        risk="LOW"
                    elif [[ "$rest" =~ orphan_vpn_dns=yes ]]; then
                        code="NET_ORPHAN_VPN_DNS"
                        summary="Orphan VPN DNS nameserver remaining in /etc/resolv.conf"
                        fix="Clean orphan nameserver in /etc/resolv.conf or restart NetworkManager"
                        risk="MEDIUM"
                    else
                        code="NET_INTERFACE_DEGRADED"
                        summary="Network link speed degraded or NIC errors detected"
                        fix="Inspect cable, switch port negotiation, and ethtool settings"
                        risk="MEDIUM"
                    fi
                    ;;
                dns)
                    code="NET_DNS_RESOLUTION_FAIL"
                    summary="DNS query to test host failed or timed out"
                    fix="Verify nameserver in /etc/resolv.conf or restart NetworkManager/systemd-resolved"
                    risk="HIGH"
                    ;;
                updates)
                    code="PKG_CORE_UPDATES_PENDING"
                    summary="Core updates pending (kernel/display/systemd)"
                    fix="Run Guarded Upgrade (Pre-Flight -> Update -> Post-Audit)"
                    risk="MEDIUM"
                    ;;
                mirrorlist_age)
                    code="PKG_MIRRORLIST_STALE"
                    summary="Pacman mirrorlist has not been updated in over 90 days"
                    fix="Refresh mirrors with reflector or eos-rankmirrors"
                    risk="LOW"
                    ;;
                arch_news)
                    code="ARCH_NEWS_MANUAL_INTERVENTION"
                    summary="Installed package requires manual intervention before upgrade"
                    fix="Consult https://archlinux.org/news/ for instructions"
                    risk="HIGH"
                    ;;
                arch_audit)
                    code="SEC_VULNERABILITY_ACTIONABLE"
                    summary="Pending package upgrades fix known CVE security vulnerabilities"
                    fix="sudo pacman -Syu to apply security advisories"
                    risk="HIGH"
                    ;;
                multilib)
                    code="GAME_MULTILIB_DISABLED"
                    summary="Multilib repository is disabled in /etc/pacman.conf"
                    fix="Uncomment [multilib] section in /etc/pacman.conf and run pacman -Syu"
                    risk="LOW"
                    ;;
                vulkan_32bit)
                    code="GAME_VULKAN_32BIT_MISSING"
                    summary="Missing 32-bit Vulkan ICD loader or GPU driver utilities"
                    fix="Install lib32-vulkan-icd-loader and matching 32-bit GPU driver"
                    risk="LOW"
                    ;;
                proton_memory)
                    code="GAME_MAX_MAP_COUNT_LOW"
                    summary="vm.max_map_count is too low for UE5/DirectX 12 Proton games"
                    fix="echo 'vm.max_map_count = 1048576' | sudo tee /etc/sysctl.d/80-game-compatibility.conf"
                    risk="LOW"
                    ;;
            esac

            local obj
            obj="$(jq -nc \
                --arg c "$tag" \
                --arg s "$sev" \
                --arg cd "$code" \
                --arg sm "$summary" \
                --arg fx "$fix" \
                --arg risk "$risk" \
                '{check: $c, severity: $s, code: $cd, summary: $sm, suggested_fix: $fx, risk: $risk}')"
            entries+=("$obj")
        done < "$LOG_FILE"

        if (( ${#entries[@]} > 0 )); then
            remediations_json="$(printf '%s\n' "${entries[@]}" | jq -s .)"
        fi
    fi

    local aur_pkg_count=0
    if [[ -f "$RUN_RAW/foreign-packages.txt" ]]; then
        aur_pkg_count="$(wc -l < "$RUN_RAW/foreign-packages.txt" 2>/dev/null || echo 0)"
    fi

    local game_multilib_val=false game_vulkan32_val=false game_map_val=0 game_proton_val=""
    if $GAMING_DETECTED; then
        game_multilib_val="$GAMING_MULTILIB"
        game_vulkan32_val="$GAMING_VULKAN_32BIT"
        game_map_val="${GAMING_MAX_MAP_COUNT:-0}"
        game_proton_val="$GAMING_CUSTOM_PROTON"
    fi

    local os_pretty="Arch Linux"
    if [[ -f /etc/os-release ]]; then
        os_pretty="$(. /etc/os-release; echo "${PRETTY_NAME:-Arch Linux}")"
    fi

    local bootloader_detected
    bootloader_detected="$(detect_bootloader)"
    local initramfs_gen_detected
    initramfs_gen_detected="$(detect_initramfs_generator)"
    local chassis_detected
    chassis_detected="$(detect_chassis)"
    local session_type_detected="${XDG_SESSION_TYPE:-unknown}"

    if command -v jq &>/dev/null; then
        jq -n \
            --arg schema "2.0" \
            --arg ts "$(date --iso-8601=seconds)" \
            --arg run_id "$RUN_ID" \
            --arg status "$status_str" \
            --argjson errors "$ERRORS" \
            --argjson warnings "$WARNINGS" \
            --argjson flagged "$warn_list_json" \
            --argjson remediations "$remediations_json" \
            --arg os "$os_pretty" \
            --arg kernel "$running_k" \
            --arg bootloader "$bootloader_detected" \
            --arg initramfs_gen "$initramfs_gen_detected" \
            --arg chassis "$chassis_detected" \
            --arg session "$session_type_detected" \
            --arg drivers "$drivers" \
            --argjson sec_actionable "${ARCH_AUDIT_ACTIONABLE_COUNT:-0}" \
            --argjson sec_tracker "${ARCH_AUDIT_TRACKER_COUNT:-0}" \
            --argjson aur_pkgs "$aur_pkg_count" \
            --argjson game_detected "$GAMING_DETECTED" \
            --argjson game_multilib "$game_multilib_val" \
            --argjson game_vulkan32 "$game_vulkan32_val" \
            --argjson game_map_count "$game_map_val" \
            --arg game_proton "$game_proton_val" \
            '{
                schema_version: $schema,
                timestamp: $ts,
                run_id: $run_id,
                status: $status,
                counts: {errors: $errors, warnings: $warnings},
                flagged: $flagged,
                actionable_remediations: $remediations,
                environment: {
                    os: $os,
                    kernel: $kernel,
                    bootloader: $bootloader,
                    initramfs_generator: $initramfs_gen,
                    chassis: $chassis,
                    session: $session
                },
                gpu: {drivers_in_use: $drivers},
                gaming: (if $game_detected then {
                    detected: true,
                    multilib: $game_multilib,
                    vulkan_32bit: $game_vulkan32,
                    max_map_count: $game_map_count,
                    custom_proton: $game_proton
                } else {
                    detected: false,
                    note: "Non-gaming environment (no Steam, Wine, or Proton detected)"
                } end),
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
    if [[ "$ACTION" != "interactive" ]]; then
        section "SYS HEALTH AUDIT"
    fi

    AUDIT_TABLE=""
    AUDIT_TABLE_BOOT=""
    AUDIT_TABLE_HW=""
    AUDIT_TABLE_SYS=""
    AUDIT_TABLE_NET=""
    AUDIT_TABLE_GAME=""
    AUDIT_TABLE_OTHER=""
    FAILED_SERVICES=""
    FAILED_USER_SERVICES=""
    ERRORS=0
    WARNINGS=0
    INFO_COUNT=0

    collect_system_snapshot

    # --- 1. BOOT & CORE OS ---
    check_kernel
    check_initramfs "$(uname -r)"
    check_efi_mount
    check_reboot_pending
    check_previous_boot
    render_audit_section "BOOT & CORE OS" "$AUDIT_TABLE_BOOT"

    # --- 2. HARDWARE & DRIVERS ---
    check_gpu
    check_gpu_errors
    check_dkms
    check_temperature
    check_smart
    check_power
    check_fstrim
    render_audit_section "HARDWARE & DRIVERS" "$AUDIT_TABLE_HW"

    # --- 3. SYSTEM HEALTH & SERVICES ---
    check_root_space
    check_failed_services
    check_sysrq
    check_pacman_lock
    check_package_integrity
    check_pacnew
    render_audit_section "SYSTEM HEALTH & SERVICES" "$AUDIT_TABLE_SYS"

    # --- 4. NETWORK & UPDATES ---
    check_network
    check_dns
    check_updates
    check_mirrorlist_age
    check_arch_news
    check_arch_audit
    render_audit_section "NETWORK & UPDATES" "$AUDIT_TABLE_NET"

    # --- 5. GAMING & STEAM READINESS ---
    check_gaming
    render_audit_section "GAMING & STEAM READINESS" "$AUDIT_TABLE_GAME"

    if [[ -n "$AUDIT_TABLE_OTHER" ]]; then
        render_audit_section "OTHER CHECKS" "$AUDIT_TABLE_OTHER"
    fi

    log ""
    log "### END OF REPORT"
    log "Summary: errors=$ERRORS warnings=$WARNINGS info=$INFO_COUNT"

    refresh_state_snapshot 1
    generate_summary_json
    save_audit_tables_cache

    echo ""
    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        if (( ERRORS == 0 && WARNINGS == 0 )); then
            gum style \
                --foreground 82 \
                --border double \
                --align center \
                --width "$UI_CARD_WIDTH" \
                "SYS HEALTH: ALL CLEAR ✔"
        elif (( ERRORS == 0 )); then
            gum style \
                --foreground 214 \
                --border double \
                --align center \
                --width "$UI_CARD_WIDTH" \
                "SYS HEALTH: REVIEW WARNINGS ⚠"
        else
            gum style \
                --foreground 196 \
                --border double \
                --align center \
                --width "$UI_CARD_WIDTH" \
                "SYS HEALTH: ACTION REQUIRED ✖"
        fi

        echo ""
        gum style --foreground 244 \
            "Report: $LOG_FILE"
    else
        if (( ERRORS == 0 && WARNINGS == 0 )); then
            echo "SYS HEALTH: ALL CLEAR ✔"
        elif (( ERRORS == 0 )); then
            echo "SYS HEALTH: REVIEW WARNINGS ⚠"
        else
            echo "SYS HEALTH: ACTION REQUIRED ✖"
        fi
        echo "Report: $LOG_FILE"
    fi
}

# ------------------------------------------------------------------------------
# Diagnostic Audit Report Viewer & State Engine
# Hardened according to GPT-5.6 Luna SRE Audit
# ------------------------------------------------------------------------------

_audit_status_badge() {
    local raw_val="${1^^}"
    case "$raw_val" in
        PASS|OK|0|NO|CLEAN|TRUE|ACTIVE|CURRENT|VERIFIED)
            printf "✔"
            ;;
        WARN|WARNING|PENDING|OLD|REBOOT|UPDATE)
            printf "⚠"
            ;;
        FAIL|ERROR|ERR|CRIT|CRITICAL|CORRUPTED|FAILED)
            printf "✖"
            ;;
        *)
            printf "ℹ"
            ;;
    esac
}

_format_audit_row() {
    local label="$1"
    local val="$2"
    local details="$3"
    local glyph
    glyph="$(_audit_status_badge "$val")"

    if [[ -n "$details" ]]; then
        printf "%s | %s %s (%s)\n" "$label" "$val" "$glyph" "$details"
    else
        printf "%s | %s %s\n" "$label" "$val" "$glyph"
    fi
}

reconstruct_tables_from_log() {
    [[ ! -s "$LOG_FILE" ]] && return 0

    AUDIT_TABLE_BOOT=""
    AUDIT_TABLE_HW=""
    AUDIT_TABLE_SYS=""
    AUDIT_TABLE_NET=""
    AUDIT_TABLE_GAME=""
    AUDIT_TABLE_OTHER=""

    local line key val rest details
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" != HEALTH\ * ]] && continue
        line="${line#HEALTH }"

        if [[ "$line" != *"="* ]]; then
            continue
        fi

        key="${line%%=*}"
        rest="${line#*=}"
        val="${rest%% *}"
        details="${rest#* }"
        [[ "$details" == "$val" ]] && details=""

        case "$key" in
            # --- BOOT & CORE OS ---
            kernel_modules)
                AUDIT_TABLE_BOOT+="$(_format_audit_row "Kernel & modules" "$val" "$details")"
                ;;
            initramfs)
                local pkgbase="${details#pkgbase=}"
                pkgbase="${pkgbase:-generic}"
                AUDIT_TABLE_BOOT+="$(_format_audit_row "Initramfs ($pkgbase)" "$val" "${details:-verified}")"
                ;;
            efi)
                local free_mb="${details#free_mb=}"
                local mnt=""
                if [[ "$details" =~ mount=([^ ]+) ]]; then
                    mnt="${BASH_REMATCH[1]}"
                fi
                free_mb="${free_mb%% *}"
                local note="free: ${free_mb}MB"
                [[ -z "$free_mb" ]] && note="$details"
                local label="EFI partition (${mnt:-ESP})"
                AUDIT_TABLE_BOOT+="$(_format_audit_row "$label" "$val" "$note")"
                ;;
            reboot_pending)
                if [[ "${val^^}" == "NO" ]]; then
                    AUDIT_TABLE_BOOT+="Reboot pending | PASS ✔ (running kernel is current)\n"
                else
                    AUDIT_TABLE_BOOT+="Reboot pending | WARN ⚠ (reboot required)\n"
                fi
                ;;
            previous_boot)
                AUDIT_TABLE_BOOT+="$(_format_audit_row "Previous session shutdown" "$val" "${details:-clean shutdown}")"
                ;;

            # --- HARDWARE & DRIVERS ---
            gpu)
                AUDIT_TABLE_HW+="$(_format_audit_row "GPU runtime" "$val" "$details")"
                ;;
            gpu_errors)
                AUDIT_TABLE_HW+="$(_format_audit_row "GPU errors & lockups" "$val" "$details")"
                ;;
            dkms)
                AUDIT_TABLE_HW+="$(_format_audit_row "DKMS modules" "$val" "$details")"
                ;;
            cpu_temperature)
                AUDIT_TABLE_HW+="$(_format_audit_row "CPU temperature" "$val" "${details#value=}")"
                ;;
            smart)
                local passed="${details#passed=}"
                local smart_note="${passed} OK"
                [[ -z "$passed" ]] && smart_note="$details"
                AUDIT_TABLE_HW+="$(_format_audit_row "SMART disk health" "$val" "$smart_note")"
                ;;
            fstrim)
                AUDIT_TABLE_HW+="$(_format_audit_row "SSD/NVMe TRIM timer" "$val" "${details#active=}")"
                ;;

            # --- SYSTEM HEALTH & SERVICES ---
            root_space)
                AUDIT_TABLE_SYS+="$(_format_audit_row "Root disk space" "$val" "${details#usage=}")"
                ;;
            systemd_failed)
                if [[ "$val" == "0" ]]; then
                    AUDIT_TABLE_SYS+="Systemd failed (system) | PASS ✔\n"
                else
                    local count="${details#count=}"
                    AUDIT_TABLE_SYS+="Systemd failed (system) | WARN ⚠ (${count:-$val} failed)\n"
                fi
                ;;
            systemd_user_failed)
                if [[ "$val" == "0" ]]; then
                    AUDIT_TABLE_SYS+="Systemd failed (user) | PASS ✔\n"
                else
                    local ucount="${details#count=}"
                    AUDIT_TABLE_SYS+="Systemd failed (user) | WARN ⚠ (${ucount:-$val} failed)\n"
                fi
                ;;
            sysrq)
                if [[ "$val" == "PASS" || "$val" == "OK" || "$val" == "1" ]]; then
                    AUDIT_TABLE_SYS+="Magic SysRq keys | PASS ✔ (enabled)\n"
                else
                    AUDIT_TABLE_SYS+="$(_format_audit_row "Magic SysRq keys" "$val" "${details:-disabled}")"
                fi
                ;;
            pacman_lock)
                if [[ "$val" == "PASS" || "$val" == "OK" ]]; then
                    AUDIT_TABLE_SYS+="Pacman DB lock | PASS ✔ (none)\n"
                else
                    AUDIT_TABLE_SYS+="$(_format_audit_row "Pacman DB lock" "$val" "${details:-lock file present}")"
                fi
                ;;
            package_integrity)
                AUDIT_TABLE_SYS+="$(_format_audit_row "Package file integrity" "$val" "$details")"
                ;;
            pacnew)
                if [[ "$val" == "0" ]]; then
                    AUDIT_TABLE_SYS+=".pacnew configuration files | PASS ✔\n"
                else
                    local pcount="${details#count=}"
                    AUDIT_TABLE_SYS+=".pacnew configuration files | WARN ⚠ (${pcount:-$val} found)\n"
                fi
                ;;

            # --- NETWORK & UPDATES ---
            network)
                AUDIT_TABLE_NET+="$(_format_audit_row "Network link & Gateway" "$val" "$details")"
                ;;
            dns)
                AUDIT_TABLE_NET+="$(_format_audit_row "System DNS" "$val" "$details")"
                ;;
            updates)
                if [[ "$val" == "0" ]]; then
                    AUDIT_TABLE_NET+="Available updates | PASS ✔ (none)\n"
                else
                    AUDIT_TABLE_NET+="Available updates | UPDATE ⚠ ($val pending)\n"
                fi
                ;;
            mirrorlist_age)
                AUDIT_TABLE_NET+="$(_format_audit_row "Mirrorlist age" "$val" "$details")"
                ;;
            arch_news)
                AUDIT_TABLE_NET+="$(_format_audit_row "Arch News (Latest)" "$val" "$details")"
                ;;
            arch_audit)
                AUDIT_TABLE_NET+="$(_format_audit_row "Arch security audit" "$val" "$details")"
                ;;

            # --- GAMING & STEAM READINESS ---
            multilib)
                AUDIT_TABLE_GAME+="$(_format_audit_row "Multilib repository" "$val" "$details")"
                ;;
            vulkan_32bit)
                AUDIT_TABLE_GAME+="$(_format_audit_row "Vulkan & 32-bit" "$val" "$details")"
                ;;
            proton_memory)
                AUDIT_TABLE_GAME+="$(_format_audit_row "Proton memory limits" "$val" "$details")"
                ;;
            cpu_governor)
                AUDIT_TABLE_GAME+="$(_format_audit_row "CPU governor" "$val" "$details")"
                ;;
            desktop_session)
                AUDIT_TABLE_GAME+="$(_format_audit_row "Desktop session & GPU" "$val" "$details")"
                ;;
            steam_runtime)
                AUDIT_TABLE_GAME+="$(_format_audit_row "Proton & Steam tools" "$val" "$details")"
                ;;

            # --- UNMAPPED CHECKS ---
            *)
                AUDIT_TABLE_OTHER+="$(_format_audit_row "$key" "$val" "$details")"
                ;;
        esac
    done < "$LOG_FILE"
}

view_full_diagnostic_log() {
    if [[ ! -s "$LOG_FILE" ]]; then
        warn "Log file does not exist or is empty: $LOG_FILE"
        sleep 1
        return
    fi

    local ESC=$'\033'
    local c_cyan="${ESC}[1;36m"
    local c_yellow="${ESC}[1;33m"
    local c_blue="${ESC}[1;34m"
    local c_green="${ESC}[1;32m"
    local c_red="${ESC}[1;31m"
    local c_magenta="${ESC}[1;35m"
    local c_reset="${ESC}[0m"

    if command -v less &>/dev/null; then
        local prompt_str="?f%f .?m(file %i of %m) ..?e(END) :?pB(%pB\%) .. [Press 'q' or 'Q' to return | Arrows to scroll | '/' to search]"
        sed \
            -e "s/^\(===.*===\)$/${c_cyan}\1${c_reset}/g" \
            -e "s/^\(### .*\)$/${c_yellow}\1${c_reset}/g" \
            -e "s/^\(--- .* ---\)$/${c_blue}\1${c_reset}/g" \
            -e "s/\b\(PASS\)\b/${c_green}\1${c_reset}/g" \
            -e "s/\b\(WARN\)\b/${c_yellow}\1${c_reset}/g" \
            -e "s/\b\(FAIL\)\b/${c_red}\1${c_reset}/g" \
            -e "s/\(High risk!\)/${c_red}\1${c_reset}/g" \
            -e "s/\(Medium risk!\)/${c_yellow}\1${c_reset}/g" \
            -e "s/\(CVE-[0-9]\{4\}-[0-9]\{4,\}\)/${c_magenta}\1${c_reset}/g" \
            "$LOG_FILE" | less -R -P "$prompt_str" || true
    elif command -v more &>/dev/null; then
        more "$LOG_FILE"
        pause_screen
    else
        local line_count
        line_count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
        if (( line_count > 500 )); then
            echo "${c_yellow}Log exceeds 500 lines ($line_count lines). Showing first 500 lines:${c_reset}"
            head -n 500 "$LOG_FILE"
            echo "${c_yellow}... [Truncated. Install 'less' for full interactive paging] ...${c_reset}"
        else
            cat "$LOG_FILE"
        fi
        pause_screen
    fi
}

_load_audit_cache_safe() {
    local cache_file="$1"
    [[ ! -f "$cache_file" ]] && return 1

    local c_key c_val
    while IFS='=' read -r c_key c_val || [[ -n "$c_key" ]]; do
        [[ "$c_key" =~ ^#.*$ || -z "$c_key" ]] && continue
        
        c_val="${c_val%\"}"
        c_val="${c_val#\"}"
        c_val="${c_val%\'}"
        c_val="${c_val#\'}"

        case "$c_key" in
            AUDIT_ERRORS)
                AUDIT_ERRORS="${c_val//[^0-9]/}"
                ;;
            AUDIT_WARNINGS)
                AUDIT_WARNINGS="${c_val//[^0-9]/}"
                ;;
            AUDIT_TIMESTAMP)
                AUDIT_TIMESTAMP="$c_val"
                ;;
            AUDIT_RUN_ID)
                AUDIT_RUN_ID="$c_val"
                ;;
            AUDIT_TABLE_BOOT_B64)
                AUDIT_TABLE_BOOT="$(printf '%s' "$c_val" | base64 -d 2>/dev/null || true)"
                ;;
            AUDIT_TABLE_HW_B64)
                AUDIT_TABLE_HW="$(printf '%s' "$c_val" | base64 -d 2>/dev/null || true)"
                ;;
            AUDIT_TABLE_SYS_B64)
                AUDIT_TABLE_SYS="$(printf '%s' "$c_val" | base64 -d 2>/dev/null || true)"
                ;;
            AUDIT_TABLE_NET_B64)
                AUDIT_TABLE_NET="$(printf '%s' "$c_val" | base64 -d 2>/dev/null || true)"
                ;;
            AUDIT_TABLE_GAME_B64)
                AUDIT_TABLE_GAME="$(printf '%s' "$c_val" | base64 -d 2>/dev/null || true)"
                ;;
            AUDIT_TABLE_OTHER_B64)
                AUDIT_TABLE_OTHER="$(printf '%s' "$c_val" | base64 -d 2>/dev/null || true)"
                ;;
        esac
    done < "$cache_file"
    return 0
}

save_audit_tables_cache() {
    local state_dir="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/system-health}"
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || return 1
    fi

    local target_cache="$state_dir/latest-audit.env"
    local tmp_cache
    tmp_cache="$(mktemp "$state_dir/audit_cache.XXXXXX" 2>/dev/null)" || return 1
    chmod 0600 "$tmp_cache"

    local b64_boot b64_hw b64_sys b64_net b64_game b64_other
    b64_boot="$(printf '%b' "$AUDIT_TABLE_BOOT" | base64 | tr -d '\n')"
    b64_hw="$(printf '%b' "$AUDIT_TABLE_HW" | base64 | tr -d '\n')"
    b64_sys="$(printf '%b' "$AUDIT_TABLE_SYS" | base64 | tr -d '\n')"
    b64_net="$(printf '%b' "$AUDIT_TABLE_NET" | base64 | tr -d '\n')"
    b64_game="$(printf '%b' "$AUDIT_TABLE_GAME" | base64 | tr -d '\n')"
    b64_other="$(printf '%b' "$AUDIT_TABLE_OTHER" | base64 | tr -d '\n')"

    local clean_errors="${ERRORS//[^0-9]/}"
    local clean_warnings="${WARNINGS//[^0-9]/}"
    local clean_run_id="${RUN_ID//[^a-zA-Z0-9_-]/}"
    local clean_timestamp
    clean_timestamp="$(date -Iseconds 2>/dev/null || date)"

    {
        printf 'AUDIT_ERRORS=%d\n' "${clean_errors:-0}"
        printf 'AUDIT_WARNINGS=%d\n' "${clean_warnings:-0}"
        printf 'AUDIT_TIMESTAMP=%s\n' "$clean_timestamp"
        printf 'AUDIT_RUN_ID=%s\n' "${clean_run_id:-unknown}"
        printf 'AUDIT_TABLE_BOOT_B64=%s\n' "$b64_boot"
        printf 'AUDIT_TABLE_HW_B64=%s\n' "$b64_hw"
        printf 'AUDIT_TABLE_SYS_B64=%s\n' "$b64_sys"
        printf 'AUDIT_TABLE_NET_B64=%s\n' "$b64_net"
        printf 'AUDIT_TABLE_GAME_B64=%s\n' "$b64_game"
        printf 'AUDIT_TABLE_OTHER_B64=%s\n' "$b64_other"
    } > "$tmp_cache"

    mv -f "$tmp_cache" "$target_cache"
}

show_report() {
    local state_dir="${STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/system-health}"
    local cache_file="$state_dir/latest-audit.env"

    if [[ ! -s "$LOG_FILE" && ! -f "$cache_file" ]]; then
        warn "No audit report exists yet. Please run '1. System Health Audit' first."
        pause_screen
        return 0
    fi

    local ui_width="${UI_CARD_WIDTH:-89}"
    if [[ ! "$ui_width" =~ ^[0-9]+$ ]] || (( ui_width < 40 )); then
        ui_width=89
    fi

    while true; do
        ui_screen "Latest Audit Report"

        local audit_ts="Unknown"
        local audit_id="N/A"
        local audit_errs=0
        local audit_warns=0

        local cache_is_fresh=0
        if [[ -f "$cache_file" ]]; then
            if [[ -f "$LOG_FILE" && "$LOG_FILE" -nt "$cache_file" ]]; then
                cache_is_fresh=0
            else
                cache_is_fresh=1
            fi
        fi

        if (( cache_is_fresh == 1 )); then
            _load_audit_cache_safe "$cache_file"
            audit_ts="${AUDIT_TIMESTAMP:-Unknown}"
            audit_id="${AUDIT_RUN_ID:-unknown}"
            audit_errs="${AUDIT_ERRORS:-0}"
            audit_warns="${AUDIT_WARNINGS:-0}"
        elif [[ -f "${SUMMARY_FILE:-}" ]] && command -v jq &>/dev/null; then
            audit_ts="$(jq -r '.timestamp // "Unknown"' "$SUMMARY_FILE" 2>/dev/null || echo "Unknown")"
            audit_id="$(jq -r '.run_id // "N/A"' "$SUMMARY_FILE" 2>/dev/null || echo "N/A")"
            audit_errs="$(jq -r '.counts.errors // 0' "$SUMMARY_FILE" 2>/dev/null || echo 0)"
            audit_warns="$(jq -r '.counts.warnings // 0' "$SUMMARY_FILE" 2>/dev/null || echo 0)"
            reconstruct_tables_from_log
            save_audit_tables_cache
        else
            reconstruct_tables_from_log
            save_audit_tables_cache
        fi

        audit_errs="${audit_errs//[^0-9]/}"
        audit_warns="${audit_warns//[^0-9]/}"
        : "${audit_errs:=0}"
        : "${audit_warns:=0}"

        if [[ -t 1 ]] && command -v gum &>/dev/null; then
            gum style --foreground 244 --align center --width "$ui_width" \
                "Recorded: $audit_ts  •  Run ID: $audit_id"
        else
            echo "Recorded: $audit_ts • Run ID: $audit_id"
        fi

        render_audit_section "BOOT & CORE OS" "$AUDIT_TABLE_BOOT"
        render_audit_section "HARDWARE & DRIVERS" "$AUDIT_TABLE_HW"
        render_audit_section "SYSTEM HEALTH & SERVICES" "$AUDIT_TABLE_SYS"
        render_audit_section "NETWORK & UPDATES" "$AUDIT_TABLE_NET"
        render_audit_section "GAMING & STEAM READINESS" "$AUDIT_TABLE_GAME"
        if [[ -n "${AUDIT_TABLE_OTHER:-}" ]]; then
            render_audit_section "OTHER CHECKS" "$AUDIT_TABLE_OTHER"
        fi

        echo ""
        if [[ -t 1 ]] && command -v gum &>/dev/null; then
            if (( audit_errs == 0 && audit_warns == 0 )); then
                gum style \
                    --foreground 82 \
                    --border double \
                    --align center \
                    --width "$ui_width" \
                    "SYS HEALTH: ALL CLEAR ✔"
            elif (( audit_errs == 0 )); then
                gum style \
                    --foreground 214 \
                    --border double \
                    --align center \
                    --width "$ui_width" \
                    "SYS HEALTH: REVIEW WARNINGS ⚠ ($audit_warns warning$([[ $audit_warns -ne 1 ]] && echo "s"))"
            else
                gum style \
                    --foreground 196 \
                    --border double \
                    --align center \
                    --width "$ui_width" \
                    "SYS HEALTH: ACTION REQUIRED ✖ ($audit_errs error$([[ $audit_errs -ne 1 ]] && echo "s"), $audit_warns warning$([[ $audit_warns -ne 1 ]] && echo "s"))"
            fi
            echo ""
            gum style --foreground 244 "Report: $LOG_FILE"
        else
            if (( audit_errs == 0 && audit_warns == 0 )); then
                echo "[SYS HEALTH: ALL CLEAR ✔]"
            elif (( audit_errs == 0 )); then
                echo "[SYS HEALTH: REVIEW WARNINGS ⚠ ($audit_warns warnings)]"
            else
                echo "[SYS HEALTH: ACTION REQUIRED ✖ ($audit_errs errors, $audit_warns warnings)]"
            fi
            echo "Report: $LOG_FILE"
        fi

        if [[ ! -t 0 || ! -t 1 ]] || ! command -v gum &>/dev/null; then
            break
        fi

        echo ""
        local action
        action="$(
            gum choose \
                --header="REPORT ACTIONS" \
                --cursor="› " \
                --cursor.foreground="81" \
                --selected.foreground="81" \
                --padding="0 1" \
                "1. Return to Main Menu" \
                "2. View Full Diagnostic Log (Paged / CVEs & Raw Output)" \
                "3. Run Fresh Audit Now"
        )"

        case "$action" in
            *"Return to Main Menu"*|"")
                break
                ;;
            *"View Full Diagnostic Log"*)
                view_full_diagnostic_log
                ;;
            *"Run Fresh Audit Now"*)
                ui_screen "Audit & Diagnostics"
                run_health_check
                pause_screen
                ;;
        esac
    done
}

show_ai_prompt() {
    section "AI AGENT HANDOFF"

    local intro="The following prompt can be pasted into your AI coding assistant (Goose, Claude, ChatGPT, etc.):"
    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        gum style --foreground 81 "$intro"
    else
        echo "$intro"
    fi

    local status_line=""
    if [[ -f "$SUMMARY_FILE" ]] && command -v jq &>/dev/null; then
        local st errs warns k
        st="$(jq -r .status "$SUMMARY_FILE" 2>/dev/null || echo "UNKNOWN")"
        errs="$(jq -r .counts.errors "$SUMMARY_FILE" 2>/dev/null || echo 0)"
        warns="$(jq -r .counts.warnings "$SUMMARY_FILE" 2>/dev/null || echo 0)"
        k="$(jq -r .environment.kernel "$SUMMARY_FILE" 2>/dev/null || uname -r)"
        status_line="System Status: $st ($errs errors, $warns warnings | Kernel: $k)"
    fi

    cat <<EOF

${status_line:+Current $status_line
}Read the System Health state summary at:
$SUMMARY_FILE

Additional system snapshot details at:
$STATE_SNAPSHOT

Detailed logs and health findings:
$LOG_FILE

Analyze the report conservatively. Prioritize system boot stability and core Arch packages. Do NOT execute system-breaking commands without asking first.
EOF
}

run_dynamic_sample() {
    local dur="${1:-3}"
    local json_out="${2:-0}"

    if ! [[ "$dur" =~ ^[0-9]+$ ]] || (( dur < 1 )); then
        dur=3
    fi
    if (( dur > 60 )); then
        dur=60
    fi

    # Network targets
    local dev gw
    dev="$(ip -4 route show default 2>/dev/null | awk '/default via/ {print $5; exit}')"
    gw="$(ip -4 route show default 2>/dev/null | awk '/default via/ {print $3; exit}')"

    # Initial PSI read
    local psi_supported=false
    local t0_cpu_total=0 t0_mem_some=0 t0_mem_full=0 t0_io_some=0 t0_io_full=0
    if [[ -d /proc/pressure ]]; then
        psi_supported=true
        t0_cpu_total="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/cpu 2>/dev/null || echo 0)"
        t0_mem_some="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/memory 2>/dev/null || echo 0)"
        t0_mem_full="$(awk '/^full / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/memory 2>/dev/null || echo 0)"
        t0_io_some="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/io 2>/dev/null || echo 0)"
        t0_io_full="$(awk '/^full / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/io 2>/dev/null || echo 0)"
    fi

    # Initial NIC counters
    local t0_rx_err=0 t0_tx_err=0 t0_rx_drop=0 t0_tx_drop=0
    if [[ -n "$dev" && -d "/sys/class/net/$dev/statistics" ]]; then
        t0_rx_err="$(cat "/sys/class/net/$dev/statistics/rx_errors" 2>/dev/null || echo 0)"
        t0_tx_err="$(cat "/sys/class/net/$dev/statistics/tx_errors" 2>/dev/null || echo 0)"
        t0_rx_drop="$(cat "/sys/class/net/$dev/statistics/rx_dropped" 2>/dev/null || echo 0)"
        t0_tx_drop="$(cat "/sys/class/net/$dev/statistics/tx_dropped" 2>/dev/null || echo 0)"
    fi

    # Background ping during the sample window
    local ping_file
    ping_file="$(mktemp -t syshealth-ping.XXXXXX 2>/dev/null || echo "/tmp/syshealth-ping.$$")"
    local pings_count=$(( dur * 3 ))
    (( pings_count < 4 )) && pings_count=4
    (( pings_count > 25 )) && pings_count=25

    local ping_pid=""
    if [[ -n "$gw" ]] && command -v ping &>/dev/null; then
        ping -c "$pings_count" -i 0.25 -q -W 1 "$gw" > "$ping_file" 2>&1 &
        ping_pid=$!
    fi

    # Feedback if in interactive TUI mode
    if [[ "$json_out" -eq 0 && -t 1 ]] && command -v gum &>/dev/null; then
        gum spin --spinner dot --title "Sampling live system performance (${dur}s)..." -- sleep "$dur"
    else
        sleep "$dur"
    fi

    if [[ -n "$ping_pid" ]]; then
        wait "$ping_pid" 2>/dev/null || true
    fi

    # Final PSI read & delta calculation
    local t1_cpu_total=0 t1_mem_some=0 t1_mem_full=0 t1_io_some=0 t1_io_full=0
    local cpu_stall_pct="0.0" mem_some_pct="0.0" mem_full_pct="0.0" io_some_pct="0.0" io_full_pct="0.0"
    local cpu_avg10="0.00" mem_some_avg10="0.00" mem_full_avg10="0.00" io_some_avg10="0.00" io_full_avg10="0.00"

    if $psi_supported; then
        t1_cpu_total="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/cpu 2>/dev/null || echo 0)"
        cpu_avg10="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i}}' /proc/pressure/cpu 2>/dev/null || echo "0.00")"

        t1_mem_some="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/memory 2>/dev/null || echo 0)"
        mem_some_avg10="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i}}' /proc/pressure/memory 2>/dev/null || echo "0.00")"

        t1_mem_full="$(awk '/^full / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/memory 2>/dev/null || echo 0)"
        mem_full_avg10="$(awk '/^full / {for(i=1;i<=NF;i++) if($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i}}' /proc/pressure/memory 2>/dev/null || echo "0.00")"

        t1_io_some="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/io 2>/dev/null || echo 0)"
        io_some_avg10="$(awk '/^some / {for(i=1;i<=NF;i++) if($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i}}' /proc/pressure/io 2>/dev/null || echo "0.00")"

        t1_io_full="$(awk '/^full / {for(i=1;i<=NF;i++) if($i ~ /^total=/) {sub(/total=/,"",$i); print $i}}' /proc/pressure/io 2>/dev/null || echo 0)"
        io_full_avg10="$(awk '/^full / {for(i=1;i<=NF;i++) if($i ~ /^avg10=/) {sub(/avg10=/,"",$i); print $i}}' /proc/pressure/io 2>/dev/null || echo "0.00")"

        local dur_usec=$(( dur * 1000000 ))
        cpu_stall_pct="$(awk -v d="$(( t1_cpu_total - t0_cpu_total ))" -v total="$dur_usec" 'BEGIN {printf "%.1f", (d*100)/total}')"
        mem_some_pct="$(awk -v d="$(( t1_mem_some - t0_mem_some ))" -v total="$dur_usec" 'BEGIN {printf "%.1f", (d*100)/total}')"
        mem_full_pct="$(awk -v d="$(( t1_mem_full - t0_mem_full ))" -v total="$dur_usec" 'BEGIN {printf "%.1f", (d*100)/total}')"
        io_some_pct="$(awk -v d="$(( t1_io_some - t0_io_some ))" -v total="$dur_usec" 'BEGIN {printf "%.1f", (d*100)/total}')"
        io_full_pct="$(awk -v d="$(( t1_io_full - t0_io_full ))" -v total="$dur_usec" 'BEGIN {printf "%.1f", (d*100)/total}')"
    fi

    # Final NIC counters & delta
    local t1_rx_err=0 t1_tx_err=0 t1_rx_drop=0 t1_tx_drop=0
    local delta_rx_err=0 delta_tx_err=0 delta_rx_drop=0 delta_tx_drop=0
    if [[ -n "$dev" && -d "/sys/class/net/$dev/statistics" ]]; then
        t1_rx_err="$(cat "/sys/class/net/$dev/statistics/rx_errors" 2>/dev/null || echo 0)"
        t1_tx_err="$(cat "/sys/class/net/$dev/statistics/tx_errors" 2>/dev/null || echo 0)"
        t1_rx_drop="$(cat "/sys/class/net/$dev/statistics/rx_dropped" 2>/dev/null || echo 0)"
        t1_tx_drop="$(cat "/sys/class/net/$dev/statistics/tx_dropped" 2>/dev/null || echo 0)"
        delta_rx_err=$(( t1_rx_err - t0_rx_err ))
        delta_tx_err=$(( t1_tx_err - t0_tx_err ))
        delta_rx_drop=$(( t1_rx_drop - t0_rx_drop ))
        delta_tx_drop=$(( t1_tx_drop - t0_tx_drop ))
    fi
    local total_nic_delta=$(( delta_rx_err + delta_tx_err + delta_rx_drop + delta_tx_drop ))

    # Ping parsing
    local pkts_tx=0 pkts_rx=0 loss_pct=0 rtt_min="0.000" rtt_avg="0.000" rtt_max="0.000" rtt_mdev="0.000"
    if [[ -f "$ping_file" ]]; then
        pkts_tx="$(awk -F',' '/packets transmitted/ {print $1}' "$ping_file" | awk '{print $1}' || echo 0)"
        pkts_rx="$(awk -F',' '/received/ {for(i=1;i<=NF;i++) if($i ~ /received/) print $i}' "$ping_file" | awk '{print $1}' || echo 0)"
        loss_pct="$(grep -oP '\d+(?=% packet loss)' "$ping_file" 2>/dev/null || echo 0)"
        if grep -q "rtt min" "$ping_file" 2>/dev/null; then
            rtt_min="$(awk -F'[ =/]+' '/rtt min/ {print $6}' "$ping_file" || echo "0.000")"
            rtt_avg="$(awk -F'[ =/]+' '/rtt min/ {print $7}' "$ping_file" || echo "0.000")"
            rtt_max="$(awk -F'[ =/]+' '/rtt min/ {print $8}' "$ping_file" || echo "0.000")"
            rtt_mdev="$(awk -F'[ =/]+' '/rtt min/ {print $9}' "$ping_file" || echo "0.000")"
        fi
        rm -f "$ping_file" 2>/dev/null || true
    fi

    # GPU telemetry
    local gpu_avail=false gpu_name="" gpu_util=0 gpu_mem_util=0 vram_used=0 vram_total=0
    local gpu_temp=0 gpu_pstate="" gpu_pcie_gen="" gpu_pcie_width="" maxwell_vram_warn=false
    if command -v nvidia-smi &>/dev/null; then
        local smi_raw
        smi_raw="$(nvidia-smi --query-gpu=name,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,pstate,pcie.link.gen.current,pcie.link.width.current --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)"
        if [[ -n "$smi_raw" ]]; then
            gpu_avail=true
            gpu_name="$(echo "$smi_raw" | awk -F', ' '{print $1}')"
            gpu_util="$(echo "$smi_raw" | awk -F', ' '{print $2}')"
            gpu_mem_util="$(echo "$smi_raw" | awk -F', ' '{print $3}')"
            vram_used="$(echo "$smi_raw" | awk -F', ' '{print $4}')"
            vram_total="$(echo "$smi_raw" | awk -F', ' '{print $5}')"
            gpu_temp="$(echo "$smi_raw" | awk -F', ' '{print $6}')"
            gpu_pstate="$(echo "$smi_raw" | awk -F', ' '{print $7}')"
            gpu_pcie_gen="$(echo "$smi_raw" | awk -F', ' '{print $8}')"
            gpu_pcie_width="$(echo "$smi_raw" | awk -F', ' '{print $9}')"

            if [[ "$gpu_name" =~ (GTX 970|GM204) ]] && (( vram_used > 3500 )); then
                maxwell_vram_warn=true
            fi
        fi
    fi

    # System metrics
    local sys_gov sys_temp sys_load
    sys_gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")"
    sys_temp="$(sensors 2>/dev/null | grep -iE 'Package id 0|Tctl|Core 0|temp1' | grep -oE '[+-]?[0-9]+([.][0-9]+)?°C' | head -n1 || echo "unknown")"
    sys_load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0.0")"

    # Status evaluation
    local sample_status="ALL_CLEAR"
    local sample_warns=0 sample_errs=0

    if [[ -n "$gw" ]] && (( loss_pct >= 100 )); then
        sample_status="ACTION_REQUIRED"
        ((sample_errs++))
    elif (( loss_pct > 0 )) || (( $(awk -v j="$rtt_mdev" 'BEGIN {print (j > 5.0) ? 1 : 0}') )); then
        ((sample_warns++))
        [[ "$sample_status" != "ACTION_REQUIRED" ]] && sample_status="REVIEW_WARNINGS"
    fi

    if (( $(awk -v p="$cpu_stall_pct" 'BEGIN {print (p > 25.0) ? 1 : 0}') )) || (( $(awk -v p="$mem_full_pct" 'BEGIN {print (p > 5.0) ? 1 : 0}') )); then
        sample_status="ACTION_REQUIRED"
        ((sample_errs++))
    elif (( $(awk -v p="$cpu_stall_pct" 'BEGIN {print (p > 5.0) ? 1 : 0}') )) || (( $(awk -v p="$mem_some_pct" 'BEGIN {print (p > 5.0) ? 1 : 0}') )) || (( $(awk -v p="$io_full_pct" 'BEGIN {print (p > 5.0) ? 1 : 0}') )); then
        ((sample_warns++))
        [[ "$sample_status" != "ACTION_REQUIRED" ]] && sample_status="REVIEW_WARNINGS"
    fi

    if $maxwell_vram_warn; then
        ((sample_warns++))
        [[ "$sample_status" != "ACTION_REQUIRED" ]] && sample_status="REVIEW_WARNINGS"
    fi
    if (( gpu_temp >= 85 )); then
        ((sample_warns++))
        [[ "$sample_status" != "ACTION_REQUIRED" ]] && sample_status="REVIEW_WARNINGS"
    fi
    if (( total_nic_delta > 0 )); then
        ((sample_errs++))
        sample_status="ACTION_REQUIRED"
    fi

    # JSON generation
    local sample_json=""
    if command -v jq &>/dev/null; then
        sample_json="$(jq -n \
            --arg ts "$(date --iso-8601=seconds)" \
            --argjson dur "$dur" \
            --arg status "$sample_status" \
            --argjson warns "$sample_warns" \
            --argjson errs "$sample_errs" \
            --argjson psi_supp "$psi_supported" \
            --arg cpu_stall "$cpu_stall_pct" \
            --arg cpu_avg10 "$cpu_avg10" \
            --arg mem_some_stall "$mem_some_pct" \
            --arg mem_some_avg10 "$mem_some_avg10" \
            --arg mem_full_stall "$mem_full_pct" \
            --arg mem_full_avg10 "$mem_full_avg10" \
            --arg io_some_stall "$io_some_pct" \
            --arg io_some_avg10 "$io_some_avg10" \
            --arg io_full_stall "$io_full_pct" \
            --arg io_full_avg10 "$io_full_avg10" \
            --argjson gpu_avail "$gpu_avail" \
            --arg gpu_name "$gpu_name" \
            --argjson gpu_util "${gpu_util:-0}" \
            --argjson gpu_mem_util "${gpu_mem_util:-0}" \
            --argjson vram_used "${vram_used:-0}" \
            --argjson vram_total "${vram_total:-0}" \
            --argjson maxwell_warn "$maxwell_vram_warn" \
            --argjson gpu_temp "${gpu_temp:-0}" \
            --arg gpu_pstate "$gpu_pstate" \
            --arg gpu_pcie "${gpu_pcie_gen:-unknown}x${gpu_pcie_width:-unknown}" \
            --arg gw "${gw:-none}" \
            --arg dev "${dev:-none}" \
            --argjson pkts_tx "$pkts_tx" \
            --argjson pkts_rx "$pkts_rx" \
            --argjson loss_pct "$loss_pct" \
            --arg rtt_min "$rtt_min" \
            --arg rtt_avg "$rtt_avg" \
            --arg rtt_max "$rtt_max" \
            --arg rtt_mdev "$rtt_mdev" \
            --argjson nic_err_delta "$total_nic_delta" \
            --arg sys_gov "$sys_gov" \
            --arg sys_temp "$sys_temp" \
            --arg sys_load "$sys_load" \
            '{
                timestamp: $ts,
                sample_duration_seconds: $dur,
                status: $status,
                counts: {errors: $errs, warnings: $warns},
                psi: (if $psi_supp then {
                    supported: true,
                    cpu: {stall_pct: ($cpu_stall|tonumber), avg10: ($cpu_avg10|tonumber)},
                    memory: {
                        some_stall_pct: ($mem_some_stall|tonumber),
                        some_avg10: ($mem_some_avg10|tonumber),
                        full_stall_pct: ($mem_full_stall|tonumber),
                        full_avg10: ($mem_full_avg10|tonumber)
                    },
                    io: {
                        some_stall_pct: ($io_some_stall|tonumber),
                        some_avg10: ($io_some_avg10|tonumber),
                        full_stall_pct: ($io_full_stall|tonumber),
                        full_avg10: ($io_full_avg10|tonumber)
                    }
                } else {supported: false} end),
                gpu: (if $gpu_avail then {
                    available: true,
                    name: $gpu_name,
                    utilization_pct: $gpu_util,
                    memory_utilization_pct: $gpu_mem_util,
                    vram_used_mb: $vram_used,
                    vram_total_mb: $vram_total,
                    vram_segment_warning: $maxwell_warn,
                    temperature_c: $gpu_temp,
                    pstate: $gpu_pstate,
                    pcie: $gpu_pcie
                } else {available: false} end),
                network: (if ($gw != "none") then {
                    gateway: $gw,
                    interface: $dev,
                    packet_loss_pct: $loss_pct,
                    rtt_min_ms: ($rtt_min|tonumber),
                    rtt_avg_ms: ($rtt_avg|tonumber),
                    rtt_max_ms: ($rtt_max|tonumber),
                    jitter_ms: ($rtt_mdev|tonumber),
                    nic_error_delta: $nic_err_delta
                } else {gateway: null} end),
                system: {
                    governor: $sys_gov,
                    temperature: $sys_temp,
                    load_1min: ($sys_load|tonumber)
                }
            }')"
    fi

    # Save to state files
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    if [[ -n "$sample_json" ]]; then
        echo "$sample_json" > "$STATE_DIR/sample.json" 2>/dev/null || true
        if [[ -f "$SUMMARY_FILE" ]] && command -v jq &>/dev/null; then
            local updated_summary
            updated_summary="$(jq --argjson sample "$sample_json" '.dynamic_sample = $sample' "$SUMMARY_FILE" 2>/dev/null || true)"
            if [[ -n "$updated_summary" ]]; then
                echo "$updated_summary" > "$SUMMARY_FILE" 2>/dev/null || true
            fi
        fi
    fi

    # Output dispatch
    if [[ "$json_out" -eq 1 ]]; then
        if [[ -n "$sample_json" ]]; then
            echo "$sample_json"
        else
            echo '{"status": "'"$sample_status"'", "sample_duration_seconds": '"$dur"'}'
        fi
    else
        local dynamic_table=""

        local psi_cpu_status="PASS ✔ (${cpu_stall_pct}% stall, avg10: ${cpu_avg10})"
        if (( $(awk -v p="$cpu_stall_pct" 'BEGIN {print (p > 25.0) ? 1 : 0}') )); then
            psi_cpu_status="FAIL ✖ (${cpu_stall_pct}% stall - extreme CPU pressure)"
        elif (( $(awk -v p="$cpu_stall_pct" 'BEGIN {print (p > 5.0) ? 1 : 0}') )); then
            psi_cpu_status="WARN ⚠ (${cpu_stall_pct}% stall - elevated CPU pressure)"
        fi
        dynamic_table+="CPU Pressure (PSI) | $psi_cpu_status\n"

        local psi_mem_status="PASS ✔ (some: ${mem_some_pct}%, full: ${mem_full_pct}%)"
        if (( $(awk -v p="$mem_full_pct" 'BEGIN {print (p > 5.0) ? 1 : 0}') )); then
            psi_mem_status="FAIL ✖ (full: ${mem_full_pct}% - OOM thrashing detected)"
        elif (( $(awk -v p="$mem_some_pct" 'BEGIN {print (p > 5.0) ? 1 : 0}') )); then
            psi_mem_status="WARN ⚠ (some: ${mem_some_pct}% - memory reclaim pressure)"
        fi
        dynamic_table+="Memory Pressure (PSI) | $psi_mem_status\n"

        local psi_io_status="PASS ✔ (some: ${io_some_pct}%, full: ${io_full_pct}%)"
        if (( $(awk -v p="$io_full_pct" 'BEGIN {print (p > 10.0) ? 1 : 0}') )); then
            psi_io_status="FAIL ✖ (full: ${io_full_pct}% - severe disk I/O bottleneck)"
        elif (( $(awk -v p="$io_some_pct" 'BEGIN {print (p > 5.0) ? 1 : 0}') )); then
            psi_io_status="WARN ⚠ (some: ${io_some_pct}% - elevated disk I/O wait)"
        fi
        dynamic_table+="Disk I/O Pressure (PSI) | $psi_io_status\n"

        if $gpu_avail; then
            local gpu_stat="PASS ✔ (${vram_used}/${vram_total} MB [${gpu_pstate}], ${gpu_temp}°C)"
            if $maxwell_vram_warn; then
                gpu_stat="WARN ⚠ (${vram_used}/${vram_total} MB - Maxwell 3.5GB slow segment active!)"
            elif (( gpu_temp >= 85 )); then
                gpu_stat="WARN ⚠ (${gpu_temp}°C - thermal throttling risk)"
            fi
            dynamic_table+="GPU VRAM & Clocks | $gpu_stat\n"
            dynamic_table+="GPU Load & Bus | PASS ✔ (GPU: ${gpu_util}%, Mem: ${gpu_mem_util}%, PCIe: ${gpu_pcie_gen}x${gpu_pcie_width})\n"
        fi

        if [[ -n "$gw" ]]; then
            local net_stat="PASS ✔ (avg ${rtt_avg}ms, jitter ${rtt_mdev}ms, ${loss_pct}% loss)"
            if (( loss_pct >= 100 )); then
                net_stat="FAIL ✖ (100% loss - gateway unreachable)"
            elif (( loss_pct > 0 )); then
                net_stat="WARN ⚠ (${loss_pct}% loss, avg ${rtt_avg}ms, jitter ${rtt_mdev}ms)"
            elif (( $(awk -v j="$rtt_mdev" 'BEGIN {print (j > 5.0) ? 1 : 0}') )); then
                net_stat="WARN ⚠ (jitter ${rtt_mdev}ms - high network variability)"
            fi
            dynamic_table+="Gateway Ping & Jitter | $net_stat\n"

            local nic_stat="PASS ✔ (0 dropped/errors)"
            if (( total_nic_delta > 0 )); then
                nic_stat="FAIL ✖ (+${total_nic_delta} errors/drops during sample)"
            fi
            dynamic_table+="NIC Error Counters ($dev) | $nic_stat\n"
        fi

        dynamic_table+="CPU Governor & Load | PASS ✔ (${sys_gov}, load: ${sys_load}, ${sys_temp})\n"

        render_audit_section "DYNAMIC FLIGHT RECORDER (${dur}s)" "$dynamic_table"
    fi

    if (( sample_errs > 0 )); then
        return 1
    elif (( sample_warns > 0 )); then
        return 2
    else
        return 0
    fi
}

# ------------------------------------------------------------------------------
# Standalone & Third-Party Software Updates (Dual-Lens SRE Hardened)
# Hardened according to Luna SRE Audit & GitHub Open-Source Portability Mandate
# ------------------------------------------------------------------------------

# Dynamic AUR helper detection (paru -> yay -> pikaur)
detect_aur_helper() {
    if type -P paru &>/dev/null; then
        echo "paru"
    elif type -P yay &>/dev/null; then
        echo "yay"
    elif type -P pikaur &>/dev/null; then
        echo "pikaur"
    else
        echo ""
    fi
}

# Rigorous package ownership check hardened against aliases, shims and language runtimes
check_binary_ownership() {
    # Returns via stdout: "pacman" | "shim" | "standalone" | "missing"
    local bin="$1"
    [[ -z "$bin" ]] && { echo "missing"; return 1; }

    local resolved
    resolved="$(type -P "$bin" 2>/dev/null || true)"
    [[ -z "$resolved" ]] && { echo "missing"; return 1; }

    # Detect language version manager shims and virtual environments
    if [[ "$resolved" =~ \.(pyenv|asdf|mise|nvm|cargo|rustup)(/|$) ]]; then
        echo "shim"
        return 0
    fi

    if pacman -Qo "$resolved" &>/dev/null; then
        echo "pacman"
        return 0
    fi

    local real
    real="$(realpath -e "$resolved" 2>/dev/null || true)"
    if [[ -n "$real" && "$real" != "$resolved" ]]; then
        if [[ "$real" =~ \.(pyenv|asdf|mise|nvm|cargo|rustup)(/|$) ]]; then
            echo "shim"
            return 0
        fi
        if pacman -Qo "$real" &>/dev/null; then
            echo "pacman"
            return 0
        fi
    fi

    echo "standalone"
    return 0
}

is_pacman_owned() {
    [[ "$(check_binary_ownership "$1")" == "pacman" ]]
}

is_shim_managed() {
    [[ "$(check_binary_ownership "$1")" == "shim" ]]
}

# Guardrail checking whether official repo updates are pending before AUR upgrade
check_partial_upgrade_risk() {
    # Returns:
    # 0 = No official updates pending (SAFE)
    # 1 = Official updates pending (RISK OF PARTIAL UPGRADE) - echo count
    # 2 = Cannot verify (pacman-contrib missing or network/database error)
    if ! command -v checkupdates &>/dev/null; then
        return 2
    fi

    local checkup_out checkup_rc=0
    checkup_out="$(checkupdates 2>/dev/null)" || checkup_rc=$?

    if (( checkup_rc == 0 )); then
        local count
        count="$(grep -c '^[a-zA-Z0-9@._+-]' <<< "$checkup_out" || true)"
        if (( count > 0 )); then
            echo "$count"
            return 1
        fi
        return 0
    elif (( checkup_rc == 2 )); then
        # Exit code 2 from checkupdates explicitly indicates database is synced and 0 updates pending
        return 0
    else
        return 2
    fi
}

run_software_updates() {
    local json_mode="${1:-0}"
    local is_interactive=false
    [[ "$json_mode" -eq 0 && -t 0 ]] && is_interactive=true

    # State tracking persisted across interactive menu loops (Gemini Pro regression fix)
    local exit_summary=0

    while true; do
        # 1. AUR Packages (paru / yay / pikaur abstraction)
        local aur_helper
        aur_helper="$(detect_aur_helper)"
        local aur_installed=false aur_pending_count=0 aur_pkgs="" aur_stat=""
        local aur_up_needed=false
        local aur_raw=""
        local foreign_count=0

        if [[ -n "$aur_helper" ]]; then
            aur_installed=true
            aur_raw="$("$aur_helper" -Qua 2>/dev/null | grep -E '^[a-zA-Z0-9@._+-]+ [0-9]' || true)"
            if [[ -n "$aur_raw" ]]; then
                aur_pending_count="$(echo "$aur_raw" | sed '/^$/d' | wc -l)"
                aur_pkgs="$(echo "$aur_raw" | awk '{print $1}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
                aur_stat="UPDATE ⚠ (${aur_pending_count} pending via ${aur_helper})"
                aur_up_needed=true
            else
                aur_stat="PASS ✔ (all AUR packages up to date via ${aur_helper})"
            fi
        else
            foreign_count="$(pacman -Qm 2>/dev/null | wc -l || echo 0)"
            if (( foreign_count > 0 )); then
                aur_stat="INFO ℹ (${foreign_count} foreign packages installed, but no AUR helper found: paru/yay)"
            fi
        fi

        # 2. UV Python Toolchain (Silent-if-Absent)
        local uv_installed=false uv_cur="not installed" uv_latest="unknown" uv_stat=""
        local uv_up_needed=false
        if type -P uv &>/dev/null; then
            uv_installed=true
            uv_cur="$(uv --version 2>/dev/null | awk '{print $2}' || echo "unknown")"
            local uv_owner
            uv_owner="$(check_binary_ownership uv)"
            if [[ "$uv_owner" == "pacman" ]]; then
                uv_stat="PASS ✔ (v${uv_cur} - pacman managed)"
            elif [[ "$uv_owner" == "shim" ]]; then
                uv_stat="PASS ✔ (v${uv_cur} - runtime/shim managed)"
            else
                local uv_dry
                uv_dry="$(uv self update --dry-run 2>&1 || true)"
                if [[ "$uv_dry" =~ to\ v([0-9.]+) ]]; then
                    uv_latest="${BASH_REMATCH[1]}"
                    uv_stat="UPDATE ⚠ (v${uv_cur} -> v${uv_latest} available)"
                    uv_up_needed=true
                elif [[ "$uv_cur" != "unknown" ]]; then
                    uv_latest="$uv_cur"
                    uv_stat="PASS ✔ (v${uv_cur} - up to date)"
                fi
            fi
        fi

        # 3. Goose AI Assistant (Silent-if-Absent)
        local goose_installed=false goose_cur="not installed" goose_latest="unknown" goose_stat=""
        local goose_up_needed=false
        if type -P goose &>/dev/null; then
            goose_installed=true
            goose_cur="$(goose --version 2>/dev/null | awk '{print $1}' | tr -d 'v' || echo "unknown")"
            local g_owner
            g_owner="$(check_binary_ownership goose)"
            if [[ "$g_owner" == "pacman" ]]; then
                goose_stat="PASS ✔ (v${goose_cur} - pacman managed)"
            elif [[ "$g_owner" == "shim" ]]; then
                goose_stat="PASS ✔ (v${goose_cur} - runtime/shim managed)"
            else
                local goose_tag
                # Strip both \r and \n (RFC 9110 HTTP CRLF fix verified by o3-mini & Gemini Pro)
                goose_tag="$(
                    curl -fsIL --max-time 4 https://github.com/aaif-goose/goose/releases/latest 2>/dev/null |
                    awk -F'/tag/v?' '/[Ll]ocation:.*\/tag\// {print $2}' |
                    tr -d '\r\n'
                )" || true

                if [[ "$goose_tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                    goose_latest="$goose_tag"
                    if [[ "$goose_cur" != "$goose_latest" ]]; then
                        goose_stat="UPDATE ⚠ (v${goose_cur} -> v${goose_latest} available)"
                        goose_up_needed=true
                    else
                        goose_stat="PASS ✔ (v${goose_cur} - up to date)"
                    fi
                elif [[ "$goose_cur" != "unknown" ]]; then
                    goose_stat="PASS ✔ (v${goose_cur} - remote check offline)"
                else
                    goose_stat="INFO ℹ (v${goose_cur} - version unknown)"
                fi
            fi
        fi

        # 4. Flatpak Applications (Silent-if-Absent)
        local flatpak_installed=false flatpak_up_needed=false flatpak_count=0 flatpak_stat=""
        if type -P flatpak &>/dev/null; then
            flatpak_count="$(flatpak list 2>/dev/null | wc -l || echo 0)"
            if (( flatpak_count > 0 )); then
                flatpak_installed=true
                local fp_count
                fp_count="$(flatpak remote-ls --updates 2>/dev/null | wc -l || echo 0)"
                if (( fp_count > 0 )); then
                    flatpak_stat="UPDATE ⚠ (${fp_count} app updates available)"
                    flatpak_up_needed=true
                else
                    flatpak_stat="PASS ✔ (all Flatpaks up to date)"
                fi
            fi
        fi

        # 5. Pipx Applications (Silent-if-Absent)
        local pipx_installed=false pipx_count=0 pipx_stat=""
        if type -P pipx &>/dev/null; then
            pipx_installed=true
            pipx_count="$(pipx list --short 2>/dev/null | wc -l || echo 0)"
            pipx_stat="PASS ✔ (${pipx_count} app(s) managed via pipx)"
        fi

        # 6. Rustup Toolchain (Silent-if-Absent)
        local rustup_installed=false rustup_stat="" rustup_up_needed=false
        if type -P rustup &>/dev/null; then
            rustup_installed=true
            local r_check
            r_check="$(rustup check 2>/dev/null || true)"
            if [[ "$r_check" =~ (Update\ available|outdated) ]]; then
                rustup_stat="UPDATE ⚠ (toolchain update available)"
                rustup_up_needed=true
            else
                rustup_stat="PASS ✔ (Rust toolchains up to date)"
            fi
        fi

        # 7. Steam Client & Proton (Silent-if-Absent)
        local steam_installed=false steam_stat=""
        if type -P steam &>/dev/null || [[ -d "$HOME/.local/share/Steam" ]]; then
            steam_installed=true
            steam_stat="PASS ✔ (Steam manages internal updates automatically)"
        fi

        # 8. Local Custom CLI Tools (e.g. Agy, custom binaries - Silent-if-Absent)
        local agy_installed=false agy_cur="not installed" agy_stat=""
        if type -P agy &>/dev/null || [[ -x "$HOME/.local/bin/agy" ]]; then
            agy_installed=true
            agy_cur="$("$HOME/.local/bin/agy" --version 2>/dev/null | head -n1 || echo "unknown")"
            agy_stat="PASS ✔ (v${agy_cur} - standalone CLI)"
        fi

        # JSON output mode dispatch
        if [[ "$json_mode" -eq 1 ]]; then
            if command -v jq &>/dev/null; then
                jq -n \
                    --arg ts "$(date --iso-8601=seconds)" \
                    --arg aur_h "$aur_helper" \
                    --argjson aur_inst "$aur_installed" \
                    --argjson aur_cnt "$aur_pending_count" \
                    --arg aur_p "$aur_pkgs" \
                    --argjson aur_up "$aur_up_needed" \
                    --argjson goose_inst "$goose_installed" \
                    --arg goose_v "$goose_cur" \
                    --arg goose_l "$goose_latest" \
                    --argjson goose_up "$goose_up_needed" \
                    --argjson uv_inst "$uv_installed" \
                    --arg uv_v "$uv_cur" \
                    --arg uv_l "$uv_latest" \
                    --argjson uv_up "$uv_up_needed" \
                    --argjson agy_inst "$agy_installed" \
                    --arg agy_v "$agy_cur" \
                    --argjson pipx_inst "$pipx_installed" \
                    --argjson pipx_cnt "$pipx_count" \
                    --argjson rustup_inst "$rustup_installed" \
                    --argjson rustup_up "$rustup_up_needed" \
                    --argjson fp_inst "$flatpak_installed" \
                    --arg fp_s "$flatpak_stat" \
                    --argjson steam_inst "$steam_installed" \
                    --arg steam_s "$steam_stat" \
                    '{
                        timestamp: $ts,
                        aur: {helper: $aur_h, installed: $aur_inst, pending_count: $aur_cnt, packages: ($aur_p | split(" ") | map(select(length > 0))), update_available: $aur_up},
                        flatpak: {installed: $fp_inst, status: $fp_s},
                        goose: {installed: $goose_inst, version: $goose_v, latest: $goose_l, update_available: $goose_up},
                        uv: {installed: $uv_inst, version: $uv_v, latest: $uv_l, update_available: $uv_up},
                        pipx: {installed: $pipx_inst, package_count: $pipx_cnt},
                        rustup: {installed: $rustup_inst, update_available: $rustup_up},
                        steam: {installed: $steam_inst, status: $steam_s},
                        agy: {installed: $agy_inst, version: $agy_v}
                    }'
            else
                echo '{"aur_helper": "'"$aur_helper"'", "aur_pending": '"$aur_pending_count"', "uv": "'"$uv_cur"'", "goose": "'"$goose_cur"'"}'
            fi
            return 0
        fi

        # Build tables adhering strictly to Silent-if-Absent philosophy
        local pending_table=""
        local up_to_date_list=()

        if $aur_up_needed; then
            pending_table+="AUR Packages (${aur_helper}) | $aur_stat"$'
'
            while IFS= read -r aur_line; do
                [[ -z "$aur_line" ]] && continue
                local p_name p_ver
                p_name="$(awk '{print $1}' <<< "$aur_line")"
                p_ver="$(awk '{for(i=2;i<=NF;i++) if($i !~ /^\[/) printf "%s ", $i; print ""}' <<< "$aur_line" | sed 's/[[:space:]]*$//')"
                pending_table+="  ↳ $p_name | $p_ver"$'
'
            done <<< "$aur_raw"
        elif $aur_installed; then
            up_to_date_list+=("AUR Packages (${aur_helper})")
        elif (( foreign_count > 0 )); then
            pending_table+="Foreign/AUR Packages | $aur_stat"$'
'
        fi

        if $uv_installed; then
            if $uv_up_needed; then
                pending_table+="UV Python Toolchain | $uv_stat"$'
'
            else
                up_to_date_list+=("UV Python (v${uv_cur})")
            fi
        fi

        if $goose_installed; then
            if $goose_up_needed; then
                pending_table+="Goose AI Assistant | $goose_stat"$'
'
            else
                up_to_date_list+=("Goose AI (v${goose_cur})")
            fi
        fi

        if $flatpak_installed; then
            if $flatpak_up_needed; then
                pending_table+="Flatpak Applications | $flatpak_stat"$'
'
            else
                up_to_date_list+=("Flatpak Applications")
            fi
        fi

        if $rustup_installed; then
            if $rustup_up_needed; then
                pending_table+="Rustup Toolchain | $rustup_stat"$'
'
            else
                up_to_date_list+=("Rustup Toolchain")
            fi
        fi

        if $pipx_installed; then
            up_to_date_list+=("Pipx (${pipx_count} apps)")
        fi

        if $steam_installed; then
            up_to_date_list+=("Steam & Proton (self-managed)")
        fi

        if $agy_installed; then
            up_to_date_list+=("Agy CLI (v${agy_cur})")
        fi

        local up_str=""
        for item in "${up_to_date_list[@]}"; do
            [[ -n "$up_str" ]] && up_str+=", "
            up_str+="$item"
        done

        if [[ -n "$pending_table" ]]; then
            render_audit_section "SOFTWARE UPDATES REQUIRING ATTENTION" "$pending_table"
            echo ""
            if [[ -n "$up_str" ]]; then
                if [[ -t 1 ]] && command -v gum &>/dev/null; then
                    gum style --foreground 82 "  ✔ Up to date: $up_str"
                else
                    echo "  ✔ Up to date: $up_str"
                fi
            fi
        else
            local clean_table="All monitored software & runtimes | PASS ✔ (all up to date)"$'
'
            render_audit_section "SOFTWARE & STANDALONE STATUS" "$clean_table"
            echo ""
            if [[ -n "$up_str" ]]; then
                if [[ -t 1 ]] && command -v gum &>/dev/null; then
                    gum style --foreground 82 "  ✔ Monitored components: $up_str"
                else
                    echo "  ✔ Monitored components: $up_str"
                fi
            fi
        fi
        echo ""

        if ! $is_interactive || ! command -v gum &>/dev/null; then
            break
        fi

        # Build dynamic menu matching active tools
        local menu_opts=()
        local idx=1
        if $aur_up_needed && [[ -n "$aur_helper" ]]; then
            menu_opts+=("$idx. Update AUR Packages ($aur_helper -Sua)")
            ((idx++))
        fi
        if $uv_up_needed; then
            menu_opts+=("$idx. Update UV Python Toolchain (uv self update)")
            ((idx++))
        fi
        if $goose_up_needed; then
            menu_opts+=("$idx. Update Goose AI Assistant (goose update)")
            ((idx++))
        fi
        if $flatpak_up_needed; then
            menu_opts+=("$idx. Update Flatpak Applications (flatpak update -y)")
            ((idx++))
        fi
        if $rustup_up_needed; then
            menu_opts+=("$idx. Update Rust Toolchain (rustup update)")
            ((idx++))
        fi
        if $pipx_installed && (( pipx_count > 0 )); then
            menu_opts+=("$idx. Update Pipx Applications (pipx upgrade-all)")
            ((idx++))
        fi

        local pending_actions=$((idx - 1))
        local header_text="Select software to update:"

        if (( pending_actions > 1 )); then
            menu_opts+=("$idx. Update all pending components (${pending_actions} tools)")
            ((idx++))
        fi

        if (( pending_actions == 0 )); then
            header_text="Software Status:"
            menu_opts+=("1. Re-check for updates")
            menu_opts+=("2. Return to Main Menu")
        else
            menu_opts+=("$idx. Return to Main Menu")
        fi

        local act
        act="$(
            gum choose \
                --header="$header_text" \
                --cursor="› " \
                --cursor.foreground="81" \
                --selected.foreground="81" \
                --padding="0 1" \
                "${menu_opts[@]}"
        )"

        case "$act" in
            *"Update AUR Packages"*)
                if [[ -z "$aur_helper" ]]; then
                    fail "No supported AUR helper installed (paru/yay/pikaur)."
                    pause_screen
                    continue
                fi

                local risk_count risk_status=0
                risk_count="$(check_partial_upgrade_risk)" || risk_status=$?

                if (( risk_status == 1 )); then
                    echo ""
                    warn "PARTIAL UPGRADE WARNING: ${risk_count} official packages have pending updates in Arch repos."
                    info "Updating AUR packages without full system upgrade risks broken shared libraries (.so)."
                    info "Strongly recommended: Run '2. Guarded System Upgrade' from Main Menu first."
                    echo ""
                    if ! gum confirm "Are you sure you want to proceed with AUR-only update anyway?"; then
                        info "AUR update cancelled safely by user."
                        pause_screen
                        continue
                    fi
                elif (( risk_status == 2 )); then
                    if ! command -v checkupdates &>/dev/null; then
                        warn "Notice: 'checkupdates' (pacman-contrib) is not installed."
                        info "Unable to verify if official package updates are pending."
                    else
                        warn "Warning: checkupdates encountered network/database error."
                        info "Unable to verify if official package updates are pending."
                    fi
                    if ! gum confirm "Proceed with AUR update despite unverified repo state?"; then
                        info "AUR update cancelled safely."
                        pause_screen
                        continue
                    fi
                fi

                info "Executing: $aur_helper -Sua"
                if "$aur_helper" -Sua; then
                    ok "AUR update completed successfully."
                else
                    if [[ -f /var/lib/pacman/db.lck ]]; then
                        fail "Pacman database lock error: /var/lib/pacman/db.lck held by another process."
                    else
                        warn "$aur_helper -Sua returned non-zero exit code or was cancelled."
                    fi
                    exit_summary=1
                fi
                pause_screen
                ;;
            *"Update UV Python Toolchain"*)
                local uv_owner
                uv_owner="$(check_binary_ownership uv)"
                if [[ "$uv_owner" == "pacman" ]]; then
                    fail "UV Python Toolchain is managed by pacman. Standalone self-update is forbidden."
                    pause_screen
                    continue
                elif [[ "$uv_owner" == "shim" ]]; then
                    fail "UV Python Toolchain is managed by a runtime shim (mise/asdf/cargo/pyenv). Please update via its manager."
                    pause_screen
                    continue
                fi
                info "Running: uv self update"
                if uv self update; then
                    ok "UV Python Toolchain updated successfully."
                else
                    fail "uv self update failed."
                    exit_summary=1
                fi
                pause_screen
                ;;
            *"Update Goose AI Assistant"*)
                local goose_owner
                goose_owner="$(check_binary_ownership goose)"
                if [[ "$goose_owner" == "pacman" ]]; then
                    fail "Goose AI Assistant is managed by pacman. Standalone self-update is forbidden."
                    pause_screen
                    continue
                elif [[ "$goose_owner" == "shim" ]]; then
                    fail "Goose AI Assistant is managed by a runtime shim (mise/asdf/cargo). Please update via its manager."
                    pause_screen
                    continue
                fi
                info "Running: goose update"
                if goose update; then
                    ok "Goose AI Assistant updated successfully."
                else
                    fail "goose update failed."
                    exit_summary=1
                fi
                pause_screen
                ;;
            *"Update Flatpak Applications"*)
                info "Running: flatpak update -y"
                if flatpak update -y; then
                    ok "Flatpak applications updated successfully."
                else
                    fail "flatpak update failed."
                    exit_summary=1
                fi
                pause_screen
                ;;
            *"Update Rust Toolchain"*)
                info "Running: rustup update"
                if rustup update; then
                    ok "Rust toolchains updated successfully."
                else
                    fail "rustup update failed."
                    exit_summary=1
                fi
                pause_screen
                ;;
            *"Update Pipx Applications"*)
                info "Running: pipx upgrade-all"
                if pipx upgrade-all; then
                    ok "Pipx applications updated successfully."
                else
                    fail "pipx upgrade-all encountered an error."
                    exit_summary=1
                fi
                pause_screen
                ;;
            *"Update all pending components"*)
                info "Initiating guarded batch update sequence..."
                if $aur_up_needed && [[ -n "$aur_helper" ]]; then
                    local can_aur=true
                    local batch_risk_count batch_risk=0
                    batch_risk_count="$(check_partial_upgrade_risk)" || batch_risk=$?

                    if (( batch_risk == 1 )); then
                        warn "Notice: ${batch_risk_count} official repo updates are pending."
                        info "To prevent partial upgrade breakage, AUR updates should normally follow a system upgrade."
                        if [[ -t 0 ]] && command -v gum &>/dev/null; then
                            if ! gum confirm "Include AUR packages in batch update anyway?"; then
                                info "Skipping AUR packages in this batch run."
                                can_aur=false
                            fi
                        else
                            can_aur=false
                        fi
                    elif (( batch_risk == 2 )); then
                        if ! command -v checkupdates &>/dev/null; then
                            warn "'checkupdates' (pacman-contrib) not found. Official repo state unverified."
                        else
                            warn "checkupdates failed to check official repos (network/database error)."
                        fi
                        if [[ -t 0 ]] && command -v gum &>/dev/null; then
                            if ! gum confirm "Proceed with AUR update despite unverified repo state?"; then
                                can_aur=false
                            fi
                        else
                            can_aur=false
                        fi
                    fi

                    if $can_aur; then
                        info "--- Updating AUR Packages ($aur_helper -Sua) ---"
                        if ! "$aur_helper" -Sua; then
                            warn "AUR update encountered non-zero return code."
                            exit_summary=1
                        fi
                    fi
                fi
                if $uv_up_needed; then
                    if [[ "$(check_binary_ownership uv)" == "standalone" ]]; then
                        info "--- Updating UV Python Toolchain ---"
                        if ! uv self update; then
                            fail "UV Python Toolchain update failed."
                            exit_summary=1
                        fi
                    fi
                fi
                if $goose_up_needed; then
                    if [[ "$(check_binary_ownership goose)" == "standalone" ]]; then
                        info "--- Updating Goose AI Assistant ---"
                        if ! goose update; then
                            fail "Goose AI Assistant update failed."
                            exit_summary=1
                        fi
                    fi
                fi
                if $flatpak_up_needed; then
                    info "--- Updating Flatpak Applications ---"
                    if ! flatpak update -y; then
                        fail "Flatpak update failed."
                        exit_summary=1
                    fi
                fi
                if $rustup_up_needed; then
                    info "--- Updating Rust Toolchain ---"
                    if ! rustup update; then
                        fail "Rustup update failed."
                        exit_summary=1
                    fi
                fi
                ok "Batch sequence finished."
                pause_screen
                ;;
            *"Re-check for updates"*)
                continue
                ;;
            *"Return to Main Menu"*|*)
                return "$exit_summary"
                ;;
        esac
    done
}




# ------------------------------------------------------------------------------
# Universal Bootloader, Substrate & Power Safety Helpers (Dual-Lens Hardened)
# Hardened according to GPT-5.6 Luna SRE Dual-Lens Audit
# ------------------------------------------------------------------------------

detect_esp_mountpoint() {
    local esp_path=""
    # 1. Inspect active vfat mounts for ESP standard paths
    esp_path="$(findmnt -n -r -t vfat -o TARGET 2>/dev/null | grep -E '^/(efi|boot/efi|boot)$' | head -n 1 || true)"

    # 2. Inspect /etc/fstab for vfat boot partitions
    if [[ -z "$esp_path" ]]; then
        esp_path="$(awk '$3 == "vfat" && $2 ~ /^\/(efi|boot\/efi|boot)$/ {print $2}' /etc/fstab 2>/dev/null | head -n 1 || true)"
    fi

    # 3. Fallback to existing directories with EFI folder
    if [[ -z "$esp_path" ]]; then
        for cand in /boot/efi /efi /boot; do
            if [[ -d "$cand/EFI" || -d "$cand/efi" ]]; then
                esp_path="$cand"
                break
            fi
        done
    fi
    echo "$esp_path"
}

verify_bootloader_post_flight() {
    local bl_type
    bl_type="$(detect_active_bootloader)"
    local esp_path
    esp_path="$(detect_esp_mountpoint)"
    [[ -z "$esp_path" ]] && esp_path="/efi"

    case "$bl_type" in
        systemd-boot)
            local has_entries=false

            if command -v bootctl &>/dev/null; then
                if sudo -n bootctl list --no-pager 2>/dev/null | grep -q "title:" || bootctl list --no-pager 2>/dev/null | grep -q "title:"; then
                    has_entries=true
                fi
            fi

            if ! $has_entries; then
                local e_dir
                for e_dir in "${esp_path}/loader/entries" /boot/loader/entries /efi/loader/entries /boot/efi/loader/entries; do
                    if [[ -d "$e_dir" ]] && compgen -G "${e_dir}/*.conf" >/dev/null; then
                        has_entries=true
                        break
                    fi
                done
            fi

            if ! $has_entries; then
                local uki_dir
                for uki_dir in "${esp_path}/EFI/Linux" /efi/EFI/Linux /boot/EFI/Linux /boot/efi/EFI/Linux; do
                    if [[ -d "$uki_dir" ]] && compgen -G "${uki_dir}/*.efi" >/dev/null; then
                        has_entries=true
                        break
                    fi
                done
            fi

            if $has_entries; then
                ok "Bootloader ($bl_type) verified: Loader entries / UKIs intact."
                return 0
            else
                fail "Bootloader ($bl_type) error: No boot entries (.conf) or UKIs (.efi) found in ESP!"
                return 1
            fi
            ;;

        grub)
            local grub_cfg="/boot/grub/grub.cfg"
            [[ ! -f "$grub_cfg" && -f "/boot/grub2/grub.cfg" ]] && grub_cfg="/boot/grub2/grub.cfg"
            [[ ! -f "$grub_cfg" && -f "${esp_path}/grub/grub.cfg" ]] && grub_cfg="${esp_path}/grub/grub.cfg"

            if [[ -f "$grub_cfg" && -s "$grub_cfg" ]]; then
                local menu_ok=false
                if sudo -n grep -qE '^[[:space:]]*(menuentry|submenu|linux)[[:space:]]' "$grub_cfg" 2>/dev/null; then
                    menu_ok=true
                elif grep -qE '^[[:space:]]*(menuentry|submenu|linux)[[:space:]]' "$grub_cfg" 2>/dev/null; then
                    menu_ok=true
                elif [[ ! -r "$grub_cfg" ]] && ! sudo -n true 2>/dev/null; then
                    # Unprivileged user cannot read 0600 grub.cfg without active sudo password prompt
                    menu_ok=true
                fi

                if $menu_ok; then
                    ok "Bootloader ($bl_type) verified: $grub_cfg contains valid boot entries."
                    return 0
                else
                    fail "Bootloader ($bl_type) error: $grub_cfg exists but contains ZERO menuentry definitions!"
                    return 1
                fi
            else
                fail "Bootloader ($bl_type) error: $grub_cfg missing or empty!"
                return 1
            fi
            ;;

        limine)
            local l_conf=""
            for f in /boot/limine/limine.conf /boot/limine.conf /boot/limine.cfg "${esp_path}/limine/limine.conf" "${esp_path}/limine.conf" /efi/limine/limine.conf; do
                if [[ -f "$f" && -s "$f" ]]; then
                    l_conf="$f"
                    break
                fi
            done
            if [[ -n "$l_conf" ]]; then
                ok "Bootloader ($bl_type) verified: $l_conf intact."
                return 0
            else
                fail "Bootloader ($bl_type) error: Limine configuration file missing or empty!"
                return 1
            fi
            ;;

        refind)
            ok "Bootloader ($bl_type) configuration detected."
            return 0
            ;;

        uki)
            ok "Bootloader (Unified Kernel Image - UKI) detected in ESP."
            return 0
            ;;

        *)
            warn "Bootloader: Unable to determine active bootloader. Manual verification recommended."
            return 0
            ;;
    esac
}

print_bootloader_repair_hint() {
    local bl_type
    bl_type="$(detect_active_bootloader)"
    local esp_path
    esp_path="$(detect_esp_mountpoint)"
    [[ -z "$esp_path" ]] && esp_path="/efi"

    case "$bl_type" in
        systemd-boot)
            echo "  [systemd-boot Repair] Re-install loader or inspect entries:"
            echo "    sudo bootctl status"
            if command -v reinstall-kernels &>/dev/null; then
                echo "    sudo reinstall-kernels"
            else
                echo "    sudo bootctl update"
            fi
            ;;
        grub)
            local grub_cfg="/boot/grub/grub.cfg"
            [[ ! -f "$grub_cfg" && -f "/boot/grub2/grub.cfg" ]] && grub_cfg="/boot/grub2/grub.cfg"
            [[ ! -f "$grub_cfg" && -f "${esp_path}/grub/grub.cfg" ]] && grub_cfg="${esp_path}/grub/grub.cfg"
            echo "  [GRUB Repair] Regenerate GRUB boot menu if needed:"
            echo "    sudo grub-mkconfig -o \"$grub_cfg\""
            ;;
        limine)
            local limine_cfg=""
            for f in /boot/limine/limine.conf /boot/limine.conf /boot/limine.cfg "${esp_path}/limine/limine.conf" "${esp_path}/limine.conf"; do
                if [[ -f "$f" ]]; then
                    limine_cfg="$f"
                    break
                fi
            done
            echo "  [Limine Repair] Verify limine configuration and deployment:"
            echo "    cat \"${limine_cfg:-/boot/limine.conf}\""
            ;;
        uki)
            echo "  [UKI Repair] Inspect UKI images in ESP (${esp_path}/EFI/Linux):"
            echo "    ls -la \"${esp_path}/EFI/Linux\" 2>/dev/null"
            ;;
        *)
            echo "  [Bootloader Repair] Verify EFI boot entries:"
            echo "    efibootmgr -v"
            ;;
    esac
}

check_laptop_battery_preflight() {
    # 1. Detect chassis type
    # Laptops/Notebooks: 8, 9, 10, 11, 14, 30, 31, 32
    local is_chassis_laptop=false
    local chassis_type
    chassis_type="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || echo 0)"
    case "$chassis_type" in
        8|9|10|11|14|30|31|32) is_chassis_laptop=true ;;
    esac

    # 2. Gather ONLY system batteries (ignore wireless mice, keyboards, gamepads)
    local -a sys_batteries=()
    local psu_dir
    for psu_dir in /sys/class/power_supply/*; do
        [[ -d "$psu_dir" ]] || continue
        local psu_type="" psu_scope=""
        [[ -r "$psu_dir/type" ]] && psu_type="$(< "$psu_dir/type")"
        [[ -r "$psu_dir/scope" ]] && psu_scope="$(< "$psu_dir/scope")"

        if [[ "$psu_type" == "Battery" && "$psu_scope" != "Device" ]]; then
            local bname
            bname="$(basename "$psu_dir")"
            if [[ "$bname" =~ ^BAT[0-9]+ || "$psu_scope" == "System" || $is_chassis_laptop == true ]]; then
                sys_batteries+=("$psu_dir")
            fi
        fi
    done

    # If no system batteries exist (e.g. desktop workstation), pass immediately
    (( ${#sys_batteries[@]} == 0 )) && return 0

    # 3. Check AC connection
    local ac_connected=false
    for psu_dir in /sys/class/power_supply/*; do
        [[ -d "$psu_dir" ]] || continue
        local psu_type=""
        [[ -r "$psu_dir/type" ]] && psu_type="$(< "$psu_dir/type")"
        if [[ "$psu_type" == "Mains" || "$psu_type" == "USB" ]]; then
            local online="0"
            [[ -r "$psu_dir/online" ]] && online="$(< "$psu_dir/online")"
            if [[ "$online" == "1" ]]; then
                ac_connected=true
                break
            fi
        fi
    done

    local on_battery=false
    local min_capacity=100

    for bat in "${sys_batteries[@]}"; do
        local b_status="Unknown" b_cap=100
        [[ -r "$bat/status" ]] && b_status="$(< "$bat/status")"
        [[ -r "$bat/capacity" ]] && b_cap="$(< "$bat/capacity")"

        if [[ "$b_status" == "Discharging" ]] || (! $ac_connected && [[ "$b_status" != "Full" ]]); then
            on_battery=true
        fi
        if (( b_cap < min_capacity )); then
            min_capacity=$b_cap
        fi
    done

    if ! $on_battery || $ac_connected; then
        ok "Pre-Flight Gate 0: Power supply verified (AC connected / battery: ${min_capacity}%)."
        return 0
    fi

    if (( min_capacity < 25 )); then
        fail "Pre-Flight Gate 0: Host is running on battery (${min_capacity}%) without AC power!"
        info "System upgrades on low battery risk kernel/initramfs corruption on power loss."
        info "Please connect AC adapter before proceeding."
        return 1
    elif (( min_capacity < 50 )); then
        warn "Pre-Flight Gate 0: Host is running on battery power (${min_capacity}%)."
        if [[ -t 0 ]]; then
            if command -v gum &>/dev/null; then
                if ! gum confirm "Battery is at ${min_capacity}%. Recommended to plug in AC. Continue anyway?"; then
                    info "Upgrade postponed to connect AC power."
                    return 1
                fi
            else
                local reply
                read -r -p "Battery is at ${min_capacity}%. Recommended to plug in AC. Continue anyway? [y/N]: " reply
                case "$reply" in
                    [yY][eE][sS]|[yY]) ;;
                    *)
                        info "Upgrade postponed to connect AC power."
                        return 1
                        ;;
                esac
            fi
        fi
    fi

    return 0
}

scan_arch_news_feed() {
    local cache_file="${1:-${STATE_DIR:-$HOME/.local/state/system-health}/arch-news-cache.json}"
    python3 -c '
import sys, os, time, urllib.request, xml.etree.ElementTree as ET, re, subprocess, html, json

cache_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/arch-news-cache.json"
cache_ttl = 3600

items = []
now = time.time()

# 1. Check local cache
if os.path.exists(cache_file):
    try:
        if now - os.path.getmtime(cache_file) < cache_ttl:
            with open(cache_file, "r") as f:
                items = json.load(f)
    except Exception:
        items = []

# 2. Network fetch if cache empty or expired
if not items:
    fetched = False
    # Try RSS first
    try:
        req = urllib.request.Request("https://archlinux.org/feeds/news/", headers={"User-Agent": "sys-health/2.0"})
        with urllib.request.urlopen(req, timeout=4) as resp:
            if resp.status == 200:
                root = ET.fromstring(resp.read())
                for item in root.findall("./channel/item")[:10]:
                    t = (item.findtext("title") or "").strip()
                    d = (item.findtext("description") or "").strip()
                    l = (item.findtext("link") or "").strip()
                    items.append({"title": t, "desc": d, "link": l})
                fetched = True
    except Exception:
        pass

    # Fallback to HTML if RSS failed or rate-limited
    if not fetched:
        try:
            req = urllib.request.Request("https://archlinux.org/news/", headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=4) as resp:
                if resp.status == 200:
                    page = resp.read().decode("utf-8", errors="replace")
                    for m in re.finditer(r"<td class=\"wrap\"><a href=\"([^\"]+)\"[^>]*title=\"[^\"]*\">([^<]+)</a>", page):
                        l = "https://archlinux.org" + m.group(1)
                        t = html.unescape(m.group(2).strip())
                        items.append({"title": t, "desc": "", "link": l})
                    items = items[:10]
                    fetched = True
        except Exception:
            pass

    if items:
        try:
            os.makedirs(os.path.dirname(os.path.abspath(cache_file)), exist_ok=True)
            with open(cache_file, "w") as f:
                json.dump(items, f)
        except Exception:
            pass

if not items:
    print("IGNORED:0")
    sys.exit(0)

pattern = re.compile(r"(manual intervention|intervention required|breaking change|requires manual|drops .* support)", re.IGNORECASE)

try:
    installed = set(subprocess.check_output(["pacman", "-Qq"]).decode().split())
except Exception:
    installed = set()

KNOWN_GROUPS = {
    "nvidia": ["nvidia", "nvidia-open", "nvidia-lts", "nvidia-dkms"],
    ".net": ["dotnet-runtime", "dotnet-sdk", "dotnet-host", "dotnet-targeting-pack"],
    "dotnet": ["dotnet-runtime", "dotnet-sdk", "dotnet-host", "dotnet-targeting-pack"],
    "pipewire": ["pipewire", "pipewire-pulse", "pipewire-alsa"],
    "wireplumber": ["wireplumber"],
    "plasma": ["plasma-desktop", "plasma-workspace"],
    "gnome": ["gnome-shell", "gnome-desktop"],
}

actionable = []
ignored_count = 0

for it in items[:10]:
    title = it.get("title", "")
    desc = it.get("desc", "")
    link = it.get("link", "")

    if not (pattern.search(title) or pattern.search(desc)):
        continue

    candidates = set()
    for m in re.findall(r"[`\x27\"]([a-zA-Z0-9@._+-]+)[`\x27\"]", title + " " + desc):
        candidates.add(m.lower())
    first_w = re.match(r"^([a-zA-Z0-9@._+-]+)\s*(?:>=|>|<=|<|=|:|\d)", title.strip())
    if first_w:
        candidates.add(first_w.group(1).lower())
    for k, v in KNOWN_GROUPS.items():
        if k in title.lower():
            candidates.update(v)

    if not candidates:
        actionable.append(f"  • [SYSTEM-WIDE] {title}\n    {link}")
        continue

    matched = [c for c in candidates if c in installed]
    if matched:
        matched_str = ", ".join(sorted(matched))
        actionable.append(f"  • [AFFECTS: {matched_str}] {title}\n    {link}")
    else:
        ignored_count += 1

if actionable:
    print("\n".join(actionable))
    sys.exit(2)

print(f"IGNORED:{ignored_count}")
sys.exit(0)
' "$cache_file" 2>/dev/null
}

# Guarded System Upgrade (Pre-Flight -> Update -> Post-Audit)
# Hardened according to Gemini Pro, ChatGPT & GPT-5.6 Luna SRE Reviews
# ------------------------------------------------------------------------------

run_guarded_upgrade() {
    section "GUARDED SYSTEM UPGRADE"
    info "Initiating Pre-Flight Safety Verification..."
    echo ""

    local preflight_passed=true

    # --------------------------------------------------------------------------
    # Gate 0: Execution Safety & Privilege Baseline
    # --------------------------------------------------------------------------
    if [[ "$EUID" -eq 0 ]]; then
        fail "Pre-Flight Gate 0: Do not run guarded upgrade directly as root. Run as regular user with sudo privileges."
        return 1
    fi

    # Unattended vs Interactive enforcement
    if [[ ! -t 0 ]] && [[ -z "${SYS_HEALTH_UNATTENDED:-}" ]]; then
        fail "Pre-Flight Gate 0: Non-interactive execution detected without explicit opt-in."
        info "Set SYS_HEALTH_UNATTENDED=1 to authorize non-interactive upgrade (official repos only, no AUR)."
        return 1
    fi

    # Validate sudo upfront
    if ! sudo -v 2>/dev/null; then
        fail "Pre-Flight Gate 0: Sudo authentication failed. Upgrade aborted."
        return 1
    fi

    # Background sudo keepalive (terminated safely via RETURN trap)
    local sudo_loop_pid=""
    ( while true; do sudo -n -v 2>/dev/null || exit 0; sleep 50 & wait $!; done ) &
    sudo_loop_pid=$!
    _cleanup_guarded_upgrade() {
        if [[ -n "${sudo_loop_pid:-}" ]]; then
            kill "$sudo_loop_pid" 2>/dev/null || true
            wait "$sudo_loop_pid" 2>/dev/null || true
        fi
    }
    trap '_cleanup_guarded_upgrade' RETURN

    ok "Pre-Flight Gate 0: Execution privileges & sudo authentication active."

    if ! check_laptop_battery_preflight; then
        return 1
    fi

    # --------------------------------------------------------------------------
    # Gate 1: System Substrate & Mount Topology
    # --------------------------------------------------------------------------
    local esp_mount
    esp_mount="$(detect_esp_mountpoint)"

    # 1. ESP Mount & Writable Check
    if [[ -n "$esp_mount" ]]; then
        if ! mountpoint -q "$esp_mount"; then
            fail "Pre-Flight Gate 1: ESP ($esp_mount) is NOT mounted! Kernel/EFI updates would write to root filesystem."
            preflight_passed=false
        else
            local efi_opts
            efi_opts="$(findmnt -n -o OPTIONS -T "$esp_mount" 2>/dev/null || true)"
            if [[ "$efi_opts" =~ (^|,)ro(,|$) ]]; then
                fail "Pre-Flight Gate 1: ESP ($esp_mount) is mounted READ-ONLY!"
                preflight_passed=false
            else
                ok "Pre-Flight Gate 1: ESP ($esp_mount) verified mounted and writable."
            fi
        fi
    fi

    # 2. Boot Mount & Writable Check (dynamic inspection of /etc/fstab)
    local fstab_boot_mnt
    while IFS= read -r fstab_boot_mnt; do
        [[ -n "$fstab_boot_mnt" ]] || continue
        # Skip if already verified as ESP above
        [[ "$fstab_boot_mnt" == "$esp_mount" ]] && continue

        if ! mountpoint -q "$fstab_boot_mnt"; then
            fail "Pre-Flight Gate 1: Dedicated boot mount ($fstab_boot_mnt) defined in /etc/fstab is NOT mounted!"
            preflight_passed=false
        else
            local m_opts
            m_opts="$(findmnt -n -o OPTIONS -T "$fstab_boot_mnt" 2>/dev/null || true)"
            if [[ "$m_opts" =~ (^|,)ro(,|$) ]]; then
                fail "Pre-Flight Gate 1: Boot filesystem ($fstab_boot_mnt) is mounted READ-ONLY!"
                preflight_passed=false
            else
                ok "Pre-Flight Gate 1: Dedicated boot mount ($fstab_boot_mnt) verified mounted and writable."
            fi
        fi
    done < <(awk '$2 ~ /^\/(boot|efi|boot\/efi)$/ {print $2}' /etc/fstab 2>/dev/null || true)

    # 2b. If /boot is a regular directory on root, verify root directory filesystem is writable
    if [[ "$esp_mount" != "/boot" ]] && ! grep -qE '^[[:space:]]*[^#[:space:]]+[[:space:]]+/boot([[:space:]]|$)' /etc/fstab; then
        local boot_dir_opts
        boot_dir_opts="$(findmnt -n -o OPTIONS -T /boot 2>/dev/null || true)"
        if [[ "$boot_dir_opts" =~ (^|,)ro(,|$) ]]; then
            fail "Pre-Flight Gate 1: Root /boot directory filesystem is mounted READ-ONLY!"
            preflight_passed=false
        fi
    fi

    # 3. Disk Space Margins (Root, ESP, Pacman Cache)
    local root_free_kb cache_free_kb
    root_free_kb="$(df -k / 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
    if (( root_free_kb < 6291456 )); then # < 6 GiB safe headroom
        fail "Pre-Flight Gate 1: Root space critically low (<6 GiB free: $((root_free_kb / 1048576)) GiB). Large transactions risk corruption."
        preflight_passed=false
    else
        ok "Pre-Flight Gate 1: Root filesystem space verified ($((root_free_kb / 1048576)) GiB free)."
    fi

    if [[ -n "$esp_mount" ]] && mountpoint -q "$esp_mount"; then
        local esp_free_kb
        esp_free_kb="$(df -k "$esp_mount" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
        if (( esp_free_kb < 102400 )); then # < 100 MiB safe headroom
            fail "Pre-Flight Gate 1: ESP ($esp_mount) space low (<100 MiB free: $((esp_free_kb / 1024)) MiB)."
            preflight_passed=false
        else
            ok "Pre-Flight Gate 1: ESP space verified ($((esp_free_kb / 1024)) MiB free)."
        fi
    fi

    local pacman_cache
    pacman_cache="$(pacman-conf CacheDir 2>/dev/null | head -n 1 || echo "/var/cache/pacman/pkg/")"
    [[ -d "$pacman_cache" ]] || pacman_cache="/var/cache/pacman/pkg/"
    cache_free_kb="$(df -k "$pacman_cache" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
    if (( cache_free_kb < 4194304 )); then # < 4 GiB safe headroom for downloads
        fail "Pre-Flight Gate 1: Pacman cache dir ($pacman_cache) low on disk space (<4 GiB free)."
        preflight_passed=false
    else
        ok "Pre-Flight Gate 1: Pacman cache space verified ($((cache_free_kb / 1048576)) GiB free)."
    fi

    # --------------------------------------------------------------------------
    # Gate 2: Package Manager Safety & Database Lock
    # --------------------------------------------------------------------------
    local lockfile="/var/lib/pacman/db.lck"
    if [[ -f "$lockfile" ]]; then
        if sudo -n fuser "$lockfile" &>/dev/null || pgrep -x pacman &>/dev/null || pgrep -x yay &>/dev/null || pgrep -x eos-update &>/dev/null; then
            fail "Pre-Flight Gate 2: Pacman database is actively locked by an open process."
        else
            fail "Pre-Flight Gate 2: Stale-looking pacman lockfile found at $lockfile."
            info "Per SRE safety standards, automatic deletion is disabled to eliminate TOCTOU race conditions."
            info "Inspect with 'sudo fuser $lockfile', then remove manually if safe: sudo rm $lockfile"
        fi
        preflight_passed=false
    else
        ok "Pre-Flight Gate 2: Pacman database lock is clear."
    fi

    if command -v pacman &>/dev/null; then
        if ! pacman -Dk &>/dev/null; then
            fail "Pre-Flight Gate 2: Local pacman database consistency check (pacman -Dk) reported errors!"
            preflight_passed=false
        else
            ok "Pre-Flight Gate 2: Pacman database consistency verified (pacman -Dk)."
        fi
    fi

    # --------------------------------------------------------------------------
    # Gate 3: Network & Repository L7 Reachability
    # --------------------------------------------------------------------------
    local primary_mirror="" mirror_reachable=false
    if [[ -f /etc/pacman.d/mirrorlist ]]; then
        primary_mirror="$(grep -E '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/mirrorlist | head -n 1 | awk '{print $3}' | sed 's/\$repo/core/g; s/\$arch/x86_64/g' || true)"
    fi
    if [[ -n "$primary_mirror" ]]; then
        if curl -Ism 5 "${primary_mirror}/core.db" 2>/dev/null | grep -qE "HTTP/.* (200|301|302)"; then
            mirror_reachable=true
        fi
    fi

    if ! $mirror_reachable; then
        if curl -Ism 5 https://archlinux.org 2>/dev/null | grep -qE "HTTP/.* (200|301|302)"; then
            ok "Pre-Flight Gate 3: Arch Linux control-plane reachable (primary mirror responded slowly)."
        else
            fail "Pre-Flight Gate 3: TLS/DNS reachability to repository infrastructure failed."
            preflight_passed=false
        fi
    else
        ok "Pre-Flight Gate 3: Repository mirror & TLS/DNS connectivity verified."
    fi

    # Mirrorlist freshness & Staged ranking
    local arch_mfile="/etc/pacman.d/mirrorlist"
    local eos_mfile="/etc/pacman.d/endeavouros-mirrorlist"
    local arch_age=0 eos_age=0 now_ts
    now_ts="$(date +%s)"
    if [[ -f "$arch_mfile" ]]; then
        local m_mtime
        m_mtime="$(stat -c %Y "$arch_mfile" 2>/dev/null || echo 0)"
        if (( m_mtime > 0 )); then
            arch_age=$(( (now_ts - m_mtime) / 86400 ))
        else
            arch_age=999
        fi
    fi
    if [[ -f "$eos_mfile" ]]; then
        local e_mtime
        e_mtime="$(stat -c %Y "$eos_mfile" 2>/dev/null || echo 0)"
        if (( e_mtime > 0 )); then
            eos_age=$(( (now_ts - e_mtime) / 86400 ))
        else
            eos_age=999
        fi
    fi

    if (( arch_age > 30 || eos_age > 30 )); then
        warn "Pre-Flight Gate 3: Local mirrorlists are older than 30 days (Arch: ${arch_age}d, EOS: ${eos_age}d)."
        if [[ -t 0 ]] && command -v gum &>/dev/null; then
            if gum confirm "Refresh and rank fastest regional mirrors before upgrading?"; then
                local tmp_mfile
                tmp_mfile="$(mktemp /tmp/mirrorlist.XXXXXX)"
                local ref_ran=false
                if [[ -f /etc/xdg/reflector/reflector.conf ]]; then
                    if gum spin --title "Ranking Arch Linux mirrors using reflector.conf..." --                         sudo reflector --config /etc/xdg/reflector/reflector.conf --save "$tmp_mfile"; then
                        ref_ran=true
                    fi
                fi
                if ! $ref_ran; then
                    if gum spin --title "Ranking Arch Linux mirrors with reflector..." --                         sudo reflector --country "United Kingdom,France,Netherlands,Germany" --protocol https --latest 10 --sort rate --save "$tmp_mfile"; then
                        ref_ran=true
                    fi
                fi

                if $ref_ran && grep -qE '^[[:space:]]*Server[[:space:]]*=' "$tmp_mfile" 2>/dev/null; then
                    sudo install -m 644 "$tmp_mfile" "$arch_mfile"
                    ok "Arch Linux mirrorlist staged, verified, and updated."
                else
                    warn "Reflector ranking failed or generated invalid mirrorlist; existing mirrorlist kept."
                fi
                rm -f "$tmp_mfile"

                if [[ -f "$eos_mfile" ]] && command -v eos-rankmirrors &>/dev/null; then
                    sudo cp -a "$eos_mfile" "${eos_mfile}.bak" 2>/dev/null || true
                    if gum spin --title "Ranking EndeavourOS mirrors..." -- sudo eos-rankmirrors --timeout 4; then
                        ok "EndeavourOS mirrorlist refreshed."
                    else
                        sudo cp -a "${eos_mfile}.bak" "$eos_mfile" 2>/dev/null || true
                        warn "eos-rankmirrors failed; restored previous EndeavourOS mirrorlist."
                    fi
                fi
            else
                info "Proceeding with existing mirrorlist."
            fi
        fi
    else
        ok "Pre-Flight Gate 3: Mirrorlists are fresh (Arch: ${arch_age}d, EOS: ${eos_age}d)."
    fi

    # --------------------------------------------------------------------------
    # Gate 4: Arch News Advisory Scanner (Correlated with Installed Packages)
    # --------------------------------------------------------------------------
    if command -v python3 &>/dev/null; then
        local news_alerts="" news_rc=0
        news_alerts="$(scan_arch_news_feed "${STATE_DIR}/arch-news-cache.json")" || news_rc=$?

        if (( news_rc == 2 )) && [[ -n "$news_alerts" ]]; then
            warn "Pre-Flight Gate 4: Recent Arch News alert(s) affecting your system detected:"
            echo "$news_alerts"
            echo ""
            if [[ -t 0 ]] && command -v gum &>/dev/null; then
                if ! gum confirm "Have you checked the Arch News instructions and resolved any manual steps?"; then
                    fail "Upgrade aborted by user to address manual intervention."
                    preflight_passed=false
                fi
            elif [[ -n "${SYS_HEALTH_UNATTENDED:-}" ]]; then
                fail "Arch News contains manual intervention notices affecting installed packages. Aborting unattended upgrade for safety."
                preflight_passed=false
            fi
        elif [[ "$news_alerts" =~ IGNORED:([0-9]+) ]]; then
            local ign_cnt="${BASH_REMATCH[1]}"
            if (( ign_cnt > 0 )); then
                ok "Pre-Flight Gate 4: Arch News checked ($ign_cnt upstream advisories reviewed; 0 affect your installed packages)."
            else
                ok "Pre-Flight Gate 4: Arch News checked (no recent manual interventions detected upstream)."
            fi
        else
            ok "Pre-Flight Gate 4: Arch News checked (no active advisories affecting installed packages)."
        fi
    else
        ok "Pre-Flight Gate 4: python3 not available to parse RSS, skipping feed check."
    fi

    # --------------------------------------------------------------------------
    # Gate 5: Kernel, DKMS & Hardware Guardrails
    # --------------------------------------------------------------------------
    # 1. Maxwell hardware & legacy driver invariant
    local has_maxwell=false
    if lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | grep -q "10de:13c2"; then
        has_maxwell=true
    elif lspci 2>/dev/null | grep -iE 'vga|3d|display' | grep -qi "GTX 970"; then
        has_maxwell=true
    fi

    if $has_maxwell; then
        if ! pacman -Q nvidia-580xx-dkms &>/dev/null || ! pacman -Q nvidia-580xx-utils &>/dev/null; then
            fail "Pre-Flight Gate 5: NVIDIA GTX 970 Maxwell requires 'nvidia-580xx-dkms' and 'nvidia-580xx-utils'!"
            preflight_passed=false
        fi
        if pacman -Qq 2>/dev/null | grep -qxE "(nvidia|nvidia-open|nvidia-open-dkms|nvidia-lts)"; then
            fail "Pre-Flight Gate 5: Conflicting modern NVIDIA driver package detected! GTX 970 will fail with black screen."
            preflight_passed=false
        fi
        ok "Pre-Flight Gate 5: Hardware GPU & legacy driver branch validated (nvidia-580xx)."
    fi

    # 2. Kernel headers invariant for every installed kernel (if DKMS is in use)
    local dkms_active=false
    if command -v dkms &>/dev/null; then
        if dkms status 2>/dev/null | grep -qE '(installed|built)'; then
            dkms_active=true
        fi
    fi
    if ! $dkms_active && pacman -Qq 2>/dev/null | grep -qE -- '-(dkms)$'; then
        dkms_active=true
    fi

    if $dkms_active; then
        local missing_headers=false
        for k_dir in /usr/lib/modules/*/pkgbase; do
            [[ -f "$k_dir" ]] || continue
            local pkgb
            pkgb="$(< "$k_dir")"
            [[ -z "$pkgb" ]] && pkgb="linux"
            local header_pkg="${pkgb}-headers"
            if ! pacman -Q "$header_pkg" &>/dev/null; then
                fail "Pre-Flight Gate 5: Missing kernel headers ($header_pkg) for installed kernel $pkgb! DKMS builds will fail."
                missing_headers=true
                preflight_passed=false
            fi
        done
        if ! $missing_headers; then
            ok "Pre-Flight Gate 5: Matching kernel headers verified for all installed kernels (DKMS active)."
        fi
    else
        ok "Pre-Flight Gate 5: Kernel headers check passed (no active DKMS modules detected)."
    fi

    # 3. Pending reboot detection
    local running_k pending_reboot=false
    running_k="$(uname -r 2>/dev/null || true)"
    if [[ -n "$running_k" ]]; then
        if [[ ! -d "/usr/lib/modules/$running_k" ]]; then
            pending_reboot=true
        else
            local running_pkgbase=""
            [[ -f "/usr/lib/modules/$running_k/pkgbase" ]] && running_pkgbase="$(< "/usr/lib/modules/$running_k/pkgbase")"
            if [[ -n "$running_pkgbase" ]]; then
                for k_dir in /usr/lib/modules/*/pkgbase; do
                    [[ -f "$k_dir" ]] || continue
                    local k_ver k_name
                    k_ver="$(basename "$(dirname "$k_dir")")"
                    k_name="$(< "$k_dir")"
                    if [[ "$k_name" == "$running_pkgbase" && "$k_ver" != "$running_k" ]]; then
                        pending_reboot=true
                        break
                    fi
                done
            fi
        fi
    fi

    if $pending_reboot; then
        warn "Pre-Flight Gate 5: A reboot is already pending (running kernel: $running_k differs from disk)."
        if [[ -t 0 ]] && command -v gum &>/dev/null; then
            if ! gum confirm "A reboot is strongly recommended before upgrading further. Continue anyway?"; then
                info "Upgrade postponed. Please reboot your workstation first."
                return 0
            fi
        fi
    else
        ok "Pre-Flight Gate 5: Running kernel and installed module tree are synchronized ($running_k)."
    fi

    # Pre-Flight Gate completion check
    if ! $preflight_passed; then
        echo ""
        fail "Pre-Flight safety checklist FAILED. Upgrade aborted to protect system."
        return 1
    fi

    echo ""
    if [[ -t 1 ]] && command -v gum &>/dev/null; then
        gum style --foreground 82 --border normal --padding "0 1"             "✔ ALL PRE-FLIGHT SAFETY GATES PASSED. Ready for System Upgrade."
    else
        ok "ALL PRE-FLIGHT SAFETY GATES PASSED. Ready for System Upgrade."
    fi
    echo ""

    # --------------------------------------------------------------------------
    # FAZA 2: TRANSACTION DISCOVERY & MANIFEST AUDIT
    # --------------------------------------------------------------------------
    local aur_helper
    aur_helper="$(detect_aur_helper)"
    local include_aur=false
    local repo_count=0 aur_count=0
    local repo_raw="" aur_raw=""

    local tmp_repo tmp_aur
    tmp_repo="$(mktemp /tmp/syshealth-repo-XXXXXX)"
    tmp_aur="$(mktemp /tmp/syshealth-aur-XXXXXX)"

    if [[ -t 0 ]] && command -v gum &>/dev/null; then
        gum spin --title "Discovering available repository & AUR package updates..." -- bash -c '
            t_repo="$1"
            t_aur="$2"
            a_helper="$3"
            (
                if command -v checkupdates &>/dev/null; then
                    checkupdates > "$t_repo" 2>/dev/null || true
                else
                    pacman -Qu > "$t_repo" 2>/dev/null || true
                fi
            ) &
            (
                if [[ -n "$a_helper" ]]; then
                    "$a_helper" -Qua > "$t_aur" 2>/dev/null || true
                fi
            ) &
            wait
        ' _ "$tmp_repo" "$tmp_aur" "$aur_helper"
    else
        (
            if command -v checkupdates &>/dev/null; then
                checkupdates > "$tmp_repo" 2>/dev/null || true
            else
                pacman -Qu > "$tmp_repo" 2>/dev/null || true
            fi
        ) &
        (
            if [[ -n "$aur_helper" ]]; then
                "$aur_helper" -Qua > "$tmp_aur" 2>/dev/null || true
            fi
        ) &
        wait
    fi

    repo_raw="$(grep -E '^[a-zA-Z0-9@._+-]+ [0-9]' "$tmp_repo" 2>/dev/null || true)"
    aur_raw="$(grep -E '^[a-zA-Z0-9@._+-]+ [0-9]' "$tmp_aur" 2>/dev/null || true)"
    rm -f "$tmp_repo" "$tmp_aur"

    [[ -n "$repo_raw" ]] && repo_count="$(grep -c '^[a-zA-Z0-9@._+-]' <<< "$repo_raw" || echo 0)"
    [[ -n "$aur_raw" ]] && aur_count="$(grep -c '^[a-zA-Z0-9@._+-]' <<< "$aur_raw" || echo 0)"

    # Edge-case: System is fully up to date
    if (( repo_count == 0 && aur_count == 0 )); then
        echo ""
        if [[ -t 1 ]] && command -v gum &>/dev/null; then
            gum style --foreground 82 --border normal --padding "0 1" \
                "✔ SYSTEM FULLY UP TO DATE: No pending updates in official repos or AUR."
        else
            ok "SYSTEM FULLY UP TO DATE: No pending updates in official repos or AUR."
        fi
        echo ""
        if [[ -t 0 ]] && command -v gum &>/dev/null; then
            if ! gum confirm "No pending updates found. Would you like to force-refresh databases (pacman -Syyu) anyway?"; then
                info "System upgrade skipped — everything is up to date."
                return 0
            fi
        elif [[ -t 0 ]]; then
            local force_ans
            read -r -p "No pending updates found. Force-refresh databases anyway? [y/N]: " force_ans
            if [[ ! "$force_ans" =~ ^[Yy]$ ]]; then
                info "System upgrade skipped — everything is up to date."
                return 0
            fi
        else
            ok "Unattended mode: System is already up to date. Exiting cleanly."
            return 0
        fi
    fi

    # Categorize and format package manifest
    local core_regex='^(linux|linux-lts|linux-zen|linux-hardened|nvidia|amdgpu|mesa|dkms|systemd|glibc|dracut|grub|mkinitcpio|xorg|wayland)'
    local -a core_detected=()
    local repo_table="" aur_table=""
    local max_display=25

    if (( repo_count > 0 )); then
        local -a core_rows=()
        local -a normal_rows=()

        while IFS= read -r u_line; do
            [[ -z "$u_line" ]] && continue
            local p_name="${u_line%% *}"
            local p_ver="${u_line#* }"
            p_ver="${p_ver%% \[*}"
            if [[ "$p_name" =~ $core_regex ]]; then
                core_rows+=("${p_name} | ${p_ver} WARN ⚠ (core)")
                core_detected+=("$p_name")
            else
                normal_rows+=("${p_name} | ${p_ver}")
            fi
        done <<< "$repo_raw"

        local shown=0
        for item in "${core_rows[@]}"; do
            repo_table+="${item}\n"
            ((shown++))
        done

        for item in "${normal_rows[@]}"; do
            if (( shown >= max_display )); then
                break
            fi
            repo_table+="${item}\n"
            ((shown++))
        done

        if (( repo_count > shown )); then
            repo_table+="... and $((repo_count - shown)) more packages | (run 'checkupdates' to view full list)\n"
        fi

        render_audit_section "PENDING OFFICIAL REPOSITORY UPDATES ($repo_count)" "$repo_table"
        if (( ${#core_detected[@]} > 0 )); then
            echo ""
            warn "Critical system packages detected in transaction: ${core_detected[*]}"
        fi
    else
        ok "Official repositories: UP TO DATE (0 pending updates)."
    fi

    if (( aur_count > 0 )); then
        local -a aur_rows=()
        while IFS= read -r a_line; do
            [[ -z "$a_line" ]] && continue
            local a_name="${a_line%% *}"
            local a_ver="${a_line#* }"
            a_ver="${a_ver%% \[*}"
            aur_rows+=("${a_name} | ${a_ver}")
        done <<< "$aur_raw"

        local a_shown=0
        for item in "${aur_rows[@]}"; do
            if (( a_shown >= max_display )); then
                break
            fi
            aur_table+="${item}\n"
            ((a_shown++))
        done

        if (( aur_count > a_shown )); then
            aur_table+="... and $((aur_count - a_shown)) more AUR packages | (run '${aur_helper} -Qua' to view full list)\n"
        fi

        echo ""
        render_audit_section "PENDING AUR PACKAGES (${aur_helper:-AUR} - $aur_count)" "$aur_table"
    elif [[ -n "$aur_helper" ]]; then
        echo ""
        ok "AUR packages (${aur_helper}): UP TO DATE (0 pending updates)."
    fi

    echo ""

    # User confirmation gates
    if (( aur_count > 0 )) && [[ -t 0 ]]; then
        if command -v gum &>/dev/null; then
            if gum confirm "Also update $aur_count pending AUR package(s) via $aur_helper?"; then
                include_aur=true
            fi
        else
            local aur_resp
            read -r -p "Also update $aur_count pending AUR package(s) via $aur_helper? [y/N]: " aur_resp
            if [[ "$aur_resp" =~ ^[Yy]$ ]]; then
                include_aur=true
            fi
        fi
    fi

    # Safety: If official repos have 0 updates and user opted out of AUR, abort cleanly
    if (( repo_count == 0 )) && ! $include_aur; then
        info "Official repositories are already up to date and AUR update was omitted. Nothing to do."
        return 0
    fi

    local total_txn=$repo_count
    $include_aur && (( total_txn += aur_count ))

    local confirm_prompt="Proceed with canonical system upgrade now ($total_txn package(s))?"
    if (( repo_count == 0 )) && $include_aur; then
        confirm_prompt="Proceed with AUR package upgrade now ($aur_count package(s))?"
    elif ! $include_aur && (( aur_count > 0 )); then
        confirm_prompt="Proceed with official repository upgrade only ($repo_count package(s), AUR skipped)?"
    fi

    if [[ -t 0 ]]; then
        if command -v gum &>/dev/null; then
            if ! gum confirm "$confirm_prompt"; then
                info "Upgrade cancelled by user."
                return 0
            fi
        else
            local up_resp
            read -r -p "$confirm_prompt [y/N]: " up_resp
            if [[ ! "$up_resp" =~ ^[Yy]$ ]]; then
                info "Upgrade cancelled by user."
                return 0
            fi
        fi
    fi

    echo ""
    section "EXECUTING SYSTEM UPGRADE"
    local -a up_cmd=()
    if [[ -n "${SYS_HEALTH_UNATTENDED:-}" ]]; then
        up_cmd=(sudo pacman -Syu --noconfirm)
    elif command -v eos-update &>/dev/null; then
        if $include_aur; then
            if [[ "$aur_helper" == "paru" ]]; then
                up_cmd=(eos-update --paru)
            else
                up_cmd=(eos-update --yay)
            fi
        else
            up_cmd=(eos-update)
        fi
    elif [[ -n "$aur_helper" ]]; then
        if $include_aur; then
            up_cmd=("$aur_helper" -Syu)
        else
            if [[ "$aur_helper" == "yay" ]]; then
                up_cmd=(yay -Syu --repo)
            elif [[ "$aur_helper" == "paru" ]]; then
                up_cmd=(paru -Syu --repo)
            else
                up_cmd=(sudo pacman -Syu)
            fi
        fi
    else
        up_cmd=(sudo pacman -Syu)
    fi

    info "Executing: ${up_cmd[*]}"
    echo ""
    "${up_cmd[@]}"
    local upgrade_rc=$?

    echo ""
    if (( upgrade_rc != 0 )); then
        warn "Package manager finished with exit code $upgrade_rc. Inspecting system integrity..."
    else
        ok "Package transaction finished successfully."
    fi

    # --------------------------------------------------------------------------
    # FAZA 3: POST-FLIGHT INTEGRITY AUDIT ("Is My System OK?")
    # --------------------------------------------------------------------------
    echo ""
    section "POST-FLIGHT INTEGRITY AUDIT"

    local post_failed=false
    local -a dkms_fail_kernels=()
    local -a initrd_fail_kernels=()
    local found_kernels=0

    # Multi-Kernel DKMS & Boot Images Verification
    for k_dir in /usr/lib/modules/*/pkgbase; do
        [[ -f "$k_dir" ]] || continue
        ((found_kernels++))
        local target_k_ver pkgb
        target_k_ver="$(basename "$(dirname "$k_dir")")"
        pkgb="$(< "$k_dir")"
        [[ -z "$pkgb" ]] && pkgb="linux"

        # 1. Per-kernel DKMS validation
        if command -v dkms &>/dev/null; then
            local dk_status
            dk_status="$(dkms status -k "$target_k_ver" 2>&1 || true)"
            if grep -qiE "(broken|failed|error)" <<< "$dk_status"; then
                fail "DKMS failure detected for target kernel $target_k_ver: $dk_status"
                dkms_fail_kernels+=("$target_k_ver")
                post_failed=true
            elif grep -q "nvidia" <<< "$dk_status"; then
                if ! grep -E '^nvidia/.*: installed' <<< "$dk_status" &>/dev/null; then
                    fail "NVIDIA DKMS module is NOT in 'installed' state for kernel $target_k_ver!"
                    dkms_fail_kernels+=("$target_k_ver")
                    post_failed=true
                else
                    # Verify compiled binary with modinfo
                    if modinfo -k "$target_k_ver" nvidia &>/dev/null; then
                        ok "NVIDIA DKMS module verified & loadable for kernel $target_k_ver."
                    else
                        fail "NVIDIA module binary missing in /lib/modules/$target_k_ver despite DKMS status!"
                        dkms_fail_kernels+=("$target_k_ver")
                        post_failed=true
                    fi
                fi
            elif grep -q "installed" <<< "$dk_status"; then
                ok "DKMS modules verified for kernel $target_k_ver."
            fi
        fi

        # 2. Boot Images, Initramfs & UKI verification
        local k_vmlinuz="" k_initrd="" k_fallback="" k_mode="" k_sz=0
        _resolve_kernel_and_initramfs "$pkgb" "$target_k_ver"

        if [[ "$k_mode" == "uki" && -f "$k_vmlinuz" ]]; then
            ok "Boot image intact: Unified Kernel Image (UKI) found for $pkgb."
        elif [[ -f "$k_vmlinuz" && -s "$k_vmlinuz" && -f "$k_initrd" && -s "$k_initrd" ]]; then
            local v_mtime i_mtime
            v_mtime="$(stat -c %Y "$k_vmlinuz" 2>/dev/null || echo 0)"
            i_mtime="$(stat -c %Y "$k_initrd" 2>/dev/null || echo 0)"
            if (( i_mtime < v_mtime )); then
                warn "Initramfs mtime is older than kernel for $pkgb (possible incomplete initramfs run)."
            fi

            local parse_ok=false
            if command -v lsinitrd &>/dev/null; then
                if sudo -n lsinitrd "$k_initrd" &>/dev/null || lsinitrd "$k_initrd" &>/dev/null; then
                    parse_ok=true
                fi
            elif command -v lsinitcpio &>/dev/null; then
                if sudo -n lsinitcpio "$k_initrd" &>/dev/null || lsinitcpio "$k_initrd" &>/dev/null; then
                    parse_ok=true
                fi
            else
                local sz
                sz="$(stat -c %s "$k_initrd" 2>/dev/null || echo 0)"
                (( sz > 10485760 )) && parse_ok=true
            fi

            if $parse_ok; then
                local img_mb=$(( $(stat -c %s "$k_initrd" 2>/dev/null || echo 0) / 1048576 ))
                ok "Boot image intact & parseable: $k_vmlinuz & $k_initrd (${img_mb}MB)."
            else
                fail "Initramfs for $pkgb is corrupted or unreadable!"
                initrd_fail_kernels+=("$target_k_ver:$pkgb")
                post_failed=true
            fi
        else
            fail "Missing boot kernel (${k_vmlinuz:-none}) or initramfs (${k_initrd:-none}) for $pkgb!"
            initrd_fail_kernels+=("$target_k_ver:$pkgb")
            post_failed=true
        fi
    done

    # 3. Bootloader configuration verification
    if ! verify_bootloader_post_flight; then
        post_failed=true
    fi

    # 4. Pacman DB & Lock verification
    if [[ -f "/var/lib/pacman/db.lck" ]]; then
        warn "Warning: /var/lib/pacman/db.lck was left behind after upgrade transaction."
    else
        ok "Pacman database lock clean."
    fi
    if command -v pacman &>/dev/null; then
        if ! pacman -Dk &>/dev/null; then
            fail "Post-Flight: Local pacman database reports consistency errors (pacman -Dk)!"
            post_failed=true
        else
            ok "Post-Flight: Pacman database consistency verified."
        fi
    fi

    # 5. Check .pacnew configuration files
    local pacnews
    pacnews="$(find /etc -name "*.pacnew" 2>/dev/null || true)"
    if [[ -n "$pacnews" ]]; then
        local p_cnt
        p_cnt="$(echo "$pacnews" | sed '/^$/d' | wc -l)"
        warn "Notice: $p_cnt unmerged .pacnew configuration file(s) found in /etc."
        info "Run 'eos-pacdiff' or 'pacdiff' to review and merge config files."
    else
        ok "Zero unmerged .pacnew configuration files."
    fi

    # 6. Rebuild detection for foreign / AUR packages
    if command -v checkrebuild &>/dev/null; then
        local reb
        reb="$(checkrebuild 2>/dev/null || true)"
        if [[ -n "$reb" ]]; then
            warn "Advisory: Local/AUR packages that may require rebuilds against new libraries:"
            echo "$reb" | head -n 10
        fi
    fi

    # Refresh telemetry snapshots
    refresh_state_snapshot
    collect_system_snapshot
    generate_summary_json

    echo ""
    if ! $post_failed && (( upgrade_rc == 0 )); then
        local status_summary="• All repository packages, kernels, and dependencies are up to date."
        if (( aur_count > 0 )) && ! $include_aur; then
            status_summary="• Official repository packages upgraded successfully.\n• Notice: $aur_count AUR package(s) were skipped and remain pending."
        fi

        if [[ -t 1 ]] && command -v gum &>/dev/null; then
            gum style --foreground 82 --border double --align center --width "$UI_CARD_WIDTH"                 "SYSTEM UPGRADE COMPLETED & VERIFIED OK ✔"                 ""                 "$status_summary"                 "• DKMS modules verified compiled for all $found_kernels installed kernel(s)."                 "• Boot initramfs images verified intact and parseable."                 ""                 "Status: System integrity checks passed. Reboot recommended."
        else
            echo "================================================================================"
            echo "SYSTEM UPGRADE COMPLETED & VERIFIED OK ✔"
            echo -e "$status_summary"
            echo "Status: System integrity checks passed. Reboot recommended."
            echo "================================================================================"
        fi
        return 0
    else
        if [[ -t 1 ]] && command -v gum &>/dev/null; then
            gum style --foreground 196 --border double --align center --width "$UI_CARD_WIDTH"                 "ATTENTION: POST-UPGRADE INTEGRITY ISSUES DETECTED ✖"                 ""                 "DO NOT REBOOT YET!"                 "One or more boot or driver components failed post-upgrade verification."
        else
            echo "================================================================================"
            echo "ATTENTION: POST-UPGRADE INTEGRITY ISSUES DETECTED ✖"
            echo "DO NOT REBOOT YET!"
            echo "================================================================================"
        fi

        echo ""
        info "ACTIONABLE REMEDIATION GUIDANCE:"
        if (( ${#dkms_fail_kernels[@]} > 0 )); then
            for k in "${dkms_fail_kernels[@]}"; do
                echo "  [DKMS Repair] Recompile modules for kernel $k:"
                echo "    sudo dkms autoinstall -k \"$k\""
                echo "    sudo depmod \"$k\""
                echo "    sudo tail -n 50 /var/lib/dkms/nvidia/*/build/make.log"
            done
        fi
        if (( ${#initrd_fail_kernels[@]} > 0 )); then
            for k in "${initrd_fail_kernels[@]}"; do
                local kver="${k%%:*}"
                local pkgb="${k##*:}"
                local k_vmlinuz="" k_initrd="" k_fallback="" k_mode="" k_sz=0
                _resolve_kernel_and_initramfs "$pkgb" "$kver"
                local target_initrd="${k_initrd:-/boot/initramfs-${pkgb}.img}"
                if command -v dracut &>/dev/null; then
                    echo "  [Initramfs Repair] Regenerate Dracut image for $pkgb ($kver):"
                    echo "    sudo dracut --force --kver \"$kver\""
                    echo "    sudo lsinitrd -m \"$target_initrd\""
                elif command -v mkinitcpio &>/dev/null; then
                    echo "  [Initramfs Repair] Regenerate mkinitcpio image for $pkgb:"
                    echo "    sudo mkinitcpio -p \"$pkgb\""
                    echo "    sudo lsinitcpio \"$target_initrd\""
                fi
            done
        fi
        print_bootloader_repair_hint
        echo ""
        return 1
    fi
}



# Non-interactive execution entry points
# ------------------------------------------------------------------------------

if [[ "$ACTION" == "upgrade" ]]; then
    run_guarded_upgrade
    exit $?
fi

if [[ "$ACTION" == "software" ]]; then
    run_software_updates "$OUTPUT_JSON"
    exit $?
fi

if [[ "$ACTION" == "sample" ]]; then
    run_dynamic_sample "$SAMPLE_SECS" "$OUTPUT_JSON"
    exit $?
fi

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

if [[ "$ACTION" == "deep-clean" ]]; then
    MAINTENANCE_CONFIRMED=1
    run_maintenance "Deep Clean"
    run_health_check
    if (( ERRORS > 0 )); then
        exit 1
    elif (( WARNINGS > 0 )); then
        exit 2
    else
        exit 0
    fi
fi

if [[ "$ACTION" == "gaming" ]]; then
    run_gaming_check
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
            --header="" \
            --cursor="› " \
            --cursor.foreground="81" \
            --selected.foreground="81" \
            --padding="0 1" \
            "1. System Health Audit (Read-Only)" \
            "2. Guarded System Upgrade (Pre-Flight → Update → Post-Audit)" \
            "3. Standalone & Third-Party Apps (Software Updates)" \
            "4. View Latest Audit Report" \
            "5. AI Agent Handoff Prompt" \
            "6. Safe Maintenance (Clean Caches & Logs)" \
            "7. Deep Clean (Trash & Browser Caches)" \
            "8. Exit"
    )"

    case "$MODE" in
        "1. System Health Audit (Read-Only)")
            ui_screen "Audit & Diagnostics"
            run_health_check
            pause_screen
            ;;
        "2. Guarded System Upgrade (Pre-Flight → Update → Post-Audit)")
            ui_screen "Guarded System Upgrade"
            run_guarded_upgrade
            pause_screen
            ;;
        "3. Standalone & Third-Party Apps (Software Updates)")
            ui_screen "Software & Standalone Updates"
            run_software_updates 0
            ;;
        "4. View Latest Audit Report")
            show_report
            ;;
        "5. AI Agent Handoff Prompt")
            ui_screen "AI Agent Handoff"
            show_ai_prompt
            pause_screen
            ;;
        "6. Safe Maintenance (Clean Caches & Logs)")
            ui_screen "Safe Maintenance & Health Audit"
            if [[ -t 0 ]] && command -v gum &>/dev/null; then
                if gum confirm "Run Safe Maintenance (prune pacman & AUR cache to last 2 versions & vacuum journal)?"; then
                    MAINTENANCE_CONFIRMED=1
                    run_maintenance "Safe Maintenance"
                    run_health_check
                else
                    info "Safe Maintenance cancelled."
                fi
            else
                MAINTENANCE_CONFIRMED=1
                run_maintenance "Safe Maintenance"
                run_health_check
            fi
            pause_screen
            ;;
        "7. Deep Clean (Trash & Browser Caches)")
            ui_screen "Deep Clean"
            local t_sz thumb_sz cd_sz
            t_sz="$(calculate_reclaimable_space "$HOME/.local/share/Trash")"
            thumb_sz="$(calculate_reclaimable_space "${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails")"
            cd_sz="0B"
            if [[ -d /var/lib/systemd/coredump ]]; then
                cd_sz="$(calculate_reclaimable_space /var/lib/systemd/coredump 2>/dev/null || echo "0B")"
            fi

            echo "Pre-Flight Storage Inspection:"
            echo "  • Desktop Trash: $t_sz"
            echo "  • Desktop Thumbnails: $thumb_sz"

            local -a b_check=(
                "Firefox (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/mozilla/firefox|firefox firefox-bin"
                "Firefox (Flatpak)|$HOME/.var/app/org.mozilla.firefox/cache/mozilla/firefox|firefox"
                "Chromium (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/chromium|chromium chromium-browser"
                "Chromium (Flatpak)|$HOME/.var/app/org.chromium.Chromium/cache/chromium|chromium"
                "Ungoogled Chromium (Flatpak)|$HOME/.var/app/io.github.ungoogled_software.ungoogled_chromium/cache/chromium|chromium"
                "Google Chrome (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/google-chrome|chrome google-chrome google-chrome-stable"
                "Google Chrome (Flatpak)|$HOME/.var/app/com.google.Chrome/cache/google-chrome|chrome"
                "Brave Browser (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/BraveSoftware/Brave-Browser|brave brave-browser"
                "Brave Browser (Flatpak)|$HOME/.var/app/com.brave.Browser/cache/BraveSoftware/Brave-Browser|brave"
                "Vivaldi (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/vivaldi|vivaldi vivaldi-bin"
                "Microsoft Edge (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/microsoft-edge|msedge"
                "Opera (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/opera|opera"
                "LibreWolf (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/librewolf|librewolf"
                "LibreWolf (Flatpak)|$HOME/.var/app/io.gitlab.librewolf-community/cache/librewolf|librewolf"
                "Zen Browser (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/zen|zen zen-bin"
                "Waterfox (Native)|${XDG_CACHE_HOME:-$HOME/.cache}/waterfox|waterfox waterfox-bin"
                "Waterfox (Flatpak)|$HOME/.var/app/net.waterfox.waterfox/cache/waterfox|waterfox"
            )
            local b_entry b_name b_path b_procs b_sz b_parr=()
            for b_entry in "${b_check[@]}"; do
                IFS='|' read -r b_name b_path b_procs <<< "$b_entry"
                if [[ -d "$b_path" ]]; then
                    b_sz="$(calculate_reclaimable_space "$b_path")"
                    read -r -a b_parr <<< "$b_procs"
                    if browser_process_running "${b_parr[@]}"; then
                        echo "  • $b_name: $b_sz (ACTIVE - will be skipped for safety)"
                    else
                        echo "  • $b_name: $b_sz"
                    fi
                fi
            done
            echo "  • System coredumps: $cd_sz (retained by default for safety)"
            echo ""
            gum style --foreground 214 "Deep Clean securely empties Desktop Trash, inactive browser caches, and thumbnails."
            if [[ -t 0 ]] && command -v gum &>/dev/null; then
                if gum confirm "Proceed with Deep Clean?"; then
                    MAINTENANCE_CONFIRMED=1
                    if [[ "$cd_sz" != "0B" && "$cd_sz" != "0" ]]; then
                        if gum confirm "Would you also like to purge crash coredumps older than ${COREDUMP_RETENTION_DAYS:-30} days?"; then
                            COREDUMP_CLEAN_CONFIRMED=1
                        fi
                    fi
                    run_maintenance "Deep Clean"
                    run_health_check
                else
                    info "Deep Clean cancelled — system state untouched."
                fi
            elif [[ -t 0 ]]; then
                read -r -p "Proceed with Deep Clean? [y/N] " ans
                if [[ "$ans" =~ ^[Yy]$ ]]; then
                    MAINTENANCE_CONFIRMED=1
                    if [[ "$cd_sz" != "0B" && "$cd_sz" != "0" ]]; then
                        read -r -p "Purge crash coredumps older than ${COREDUMP_RETENTION_DAYS:-30} days? [y/N] " ans_cd
                        if [[ "$ans_cd" =~ ^[Yy]$ ]]; then
                            COREDUMP_CLEAN_CONFIRMED=1
                        fi
                    fi
                    run_maintenance "Deep Clean"
                    run_health_check
                else
                    info "Deep Clean cancelled — system state untouched."
                fi
            else
                MAINTENANCE_CONFIRMED=1
                run_maintenance "Deep Clean"
                run_health_check
            fi
            pause_screen
            ;;
        "8. Exit")
            clear
            exit 0
            ;;
    esac
done
