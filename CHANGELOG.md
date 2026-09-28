# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [2.28] - 2026-09-28

### Fixed & Hardened (Terra EOS-SRE Architectural Audit - Boot & Core OS Health Checks)
- **Atomic Kernel & Initramfs Resolution (`_resolve_kernel_and_initramfs`)**:
  - Eliminated dangerous cross-filesystem and cross-entry coupling where a kernel on one boot root (e.g., `/boot`) could be paired with an initramfs on another (e.g., `/efi`), creating phantom boot configurations no bootloader entry could load.
  - Bound resolution into strictly indivisible records: BLS Type #1 entries require both kernel and initrd to resolve relative to the same entry root; traditional layouts require both artifacts to coexist under the identical boot directory; degraded fallback is restricted to a single candidate root.
  - Eliminated global variable leakage by explicitly localizing all loop and candidate variables (`bdir`, `u_cand`, `entry`, `l_rel`, `i_rel`, `cand_k`, `cand_i`, `cand_f`, `bls_k`, `bls_i`, `deg_k`, `deg_i`).
- **Fail-Closed Kernel Discovery & Modules Reconciliation (`check_kernel`)**:
  - Eliminated silent false `PASS` when `/usr/lib/modules/*/pkgbase` glob returns empty.
  - Added robust secondary directory scanning across `/usr/lib/modules/*` (reading `modules.dep` and package ownership via `pacman -Qqo`) and reconciliation against installed `linux*` packages from pacman.
  - Enforced fail-closed behavior: flags `FAIL ✖` if modules directories are unpopulated or no bootable kernels can be resolved.
- **Boot-Root Authority & Mountpoint Scope (`detect_boot_directories` & `check_efi_mount`)**:
  - Replaced unconstrained VFAT mount scanning (which captured unrelated external USB sticks, recovery media, and SD cards) with authoritative `bootctl -p` (ESP) and `bootctl -x` (XBOOTLDR) discovery.
  - Scoped filesystem and `fstab` discovery strictly to standard boot directories (`/boot`, `/efi`, `/boot/efi`, `/esp`).
  - Added non-numeric / unreadable capacity handling for `df` output in `check_efi_mount`, reporting `INFO ℹ` instead of falling through to a spurious `PASS`.
- **Initramfs Structural Integrity & Format Verification (`check_initramfs`)**:
  - Replaced unsafe default fallback to `linux-lts` with deterministic resolution based on running kernel suffix and `pacman -Qqo`, failing closed with `FAIL ✖` if pkgbase cannot be determined.
  - Added minimum payload validation (rejects truncated or 0-byte images < 1MB).
  - Implemented unprivileged-safe deep content verification: checks PE magic headers (`MZ`) for UKIs, and leverages `lsinitrd --size`, `lsinitcpio -a`, or `booster ls` (with passwordless sudo awareness when files are mode 0600) to ensure images are not corrupt.
- **Deterministic Previous-Boot Forensics (`check_previous_boot`)**:
  - Replaced unreliable heuristic (searching for shutdown markers in last 50 journal entries) with boot verification via `journalctl --list-boots`.
  - Added explicit kernel panic / OOPS detection (`journalctl -b -1 -k -p 0..2`), filesystem recovery alerts, and unclean journal markers.
  - Replaced false crash warnings with nuanced triage: flags `WARN ⚠` on positive crash/recovery evidence, `PASS ✔` on verified shutdown targets, and `INFO ℹ (inconclusive)` when shutdown markers are unrecorded but no faults occurred.
  - Enforced `LC_ALL=C` across all journal parsing to eliminate localization breakage.
- **Pending Reboot Detection Hardening (`check_reboot_pending`)**:
  - In addition to checking for the existence of `/usr/lib/modules/$running_k`, explicitly validates the integrity and presence of `modules.dep`, preventing false passes on partial or stale post-transaction directories.
- **Accurate Critical-Path .pacnew Detection (`_find_pacnew_files`)**:
  - Integrated official `pacdiff -o` for authoritative pacman database tracking, falling back to comprehensive scanning of `/etc` and all dynamically discovered boot roots.

---

## [2.27] - 2026-09-28

### Fixed & Hardened (Terra EOS-SRE Architectural Audit - System State Snapshot & Telemetry Engine)
- **Subshell Isolation, Timestamp Preservation & Injection Immunity (`refresh_state_snapshot` & `dump_software_state_snapshot`)**:
  - Resolved missing timestamp flaw in spinner execution mode: extracted snapshot generation into a dedicated top-level function (`dump_software_state_snapshot`) and safely passed timestamp and output destination via positional arguments (`"$1"`, `"$2"`), preventing subshell variable loss and unquoted shell string injection.
  - Eliminated global namespace pollution by removing nested function declarations inside callers.
  - Resolved Dracut glob stdin hang risk: replaced raw `cat /etc/dracut.conf.d/*.conf` (which hangs awaiting stdin if `nullglob` expands to empty) with verified file existence loops and structured file-boundary tags (`[:/path/file.conf:]`).
  - Implemented unambiguous diagnostic telemetry: replaced silent empty sections with explicit deterministic markers (`status=none`, `status=command_missing`, `status=permission_denied`, `status=unavailable`).
- **Universal Multi-Vendor Hardware & Initramfs Expansion**:
  - Expanded GPU package discovery across the Arch ecosystem to first-class Intel Xe, Arc, and Iris graphics stacks (`intel-media-driver`, `vpl-gpu-rt`, `libva-intel-driver`, `intel-compute-runtime`, `vulkan-intel`).
  - Added native configuration discovery for the `booster` initramfs generator (`/etc/booster.yaml`) alongside Dracut and Mkinitcpio.
  - Appended human-readable system uptime (`uptime -p`) to kernel telemetry for immediate reboot status verification.
- **Universal Boot & Storage Topology Discovery**:
  - Replaced restrictive `findmnt -t vfat` with flat list inspection (`findmnt --real -l`), capturing root filesystems (`/`), boot partitions (`/boot`), and ESPs regardless of filesystem type (`ext4`, `btrfs`, `xfs`, `vfat`).
  - Dynamically detects ESP mountpoints across `/boot/efi`, `/efi`, and `/boot`, surfacing permission-denied states transparently when run unprivileged.
- **Multi-User D-Bus Context Resolution**:
  - Hardened user-space systemd unit query (`systemctl --user --failed`) to resolve active desktop user sessions (`SUDO_USER` / human UIDs >= 1000) when executed with root privileges, preventing failure or erroneous inspection of root's user manager.
- **Documentation & Audit Terminology Reconciliation (`README.md`)**:
  - Aligned README sections 6 and 7 with v2.26 SRE orphan triage architecture, eliminating outdated claims of immediate purge safety and reconciling package cache retention policies.

## [2.26] - 2026-09-28

### Fixed & Hardened (Terra EOS-SRE Architectural Audit - Orphan Package Triage & Safety Engine)
- **Dependency Classification & Optional-Only Reachability (`triage_orphan_packages`)**:
  - Resolved critical architectural flaw where Tier 2 (Yellow) was unreachable: partitioned candidates into strict orphans (`pacman -Qdtq`) and optional-only reverse dependencies (`pacman -Qdttq` set difference).
  - Replaced misleading "safe to purge", "protected", "pristine", and "zero-residue" claims with accurate SRE terminology ("strict unreferenced", "heuristically sensitive", "excluded from automatic selection"), recognizing pacman's inability to track external user scripts, compiled binaries, or manual workflows.
  - Added heuristically sensitive caution tags (kernel, bootloaders, drivers, firmware, audio stack, compiler toolchains); tagged packages are safely excluded from auto-pruning while remaining selectable for informed manual review.
- **Input Sanitization, Mutation Gates & Fail-Closed Safety**:
  - Validated all manual operator selections against the scanned candidate set in both Gum and non-Gum interactive paths, preventing accidental removal of core packages through typos.
  - Added pre-transaction read-only preview via `pacman -Rs --print` to display solver-calculated cascade removals before asking for final confirmation.
  - Switched deletion engine from destructive `-Rns` to `-Rs`, preserving modified user configurations with `.pacsave` backups.
  - Revalidated package candidate status and package manager lock/activity directly before mutating ALPM state, mitigating race conditions during interactive review.
  - Fixed pacman query error handling: distinguishes between clean zero-orphan queries (exit 1 with empty stderr) and actual database/lock failures (exit code propagation and stderr reporting).
  - Scoped all loop and user variables to `local` and pre-initialized associative array fields for `set -u` nounset resilience.
- **Honest & Separately Confirmed Cache Maintenance**:
  - Decoupled `paccache` uninstalled archive purging from package deletion: converted to an explicit, separately confirmed maintenance step with `paccache --dryrun --uninstalled --keep 0` preview.

## [2.25] - 2026-09-27

### Fixed & Hardened (Luna SRE Architectural Audit Priority 4 Remediation)
- **Universal Multi-Vendor Telemetry in Dynamic Flight Recorder (`run_dynamic_sample`)**:
  - Added native kernel sysfs fallback for AMD Radeon GPUs via `/sys/class/drm/card*/device/` (`gpu_busy_percent`, `mem_info_vram_used`, `mem_info_vram_total`, and GPU hwmon temperature), extending live sampling beyond NVIDIA rigs to AMD community users.
  - Implemented background ping process and temporary file lifecycle cleanup traps (`RETURN`, `INT`, `TERM`), preventing zombie ping processes and `/tmp` residues upon cancellation.
  - Hardened ping packet loss calculation (`awk -F'%' '{sub(/.*[ ,]/, "", $1); print $1+0}'`), resolving edge-case string misparsing that previously grabbed transmitted packet counts instead of actual loss.
  - Metric-aware gateway discovery with P2P VPN tunnel fallback (`1.1.1.1`) and multi-stage sysfs CPU temperature fallback (`coretemp`, `k10temp`, `zenpower`).

### Fixed & Hardened (Luna SRE Architectural Audit Priority 3 Remediation)
- **Multi-Route Metric Sorting & P2P Tunnel Tolerance (`check_network`)**:
  - Replaced crude single-line default route extraction with metric-aware evaluation (`awk ... | sort -n -k1,1`), accurately selecting the active primary route on multi-interface systems (e.g. wired Ethernet prioritized over Wi-Fi).
  - Added native support for point-to-point VPN and tunnel interfaces (`default dev wg0` / WireGuard, Tailscale, OpenVPN p2p) where no gateway IP exists, validating tunnel health via upstream DNS reachability instead of false route failures.
  - Contextualized NetworkManager metered connection detection: flags unintended throttling on wired Ethernet connections (`WARN ⚠`) while treating metered Wi-Fi or LTE modems as informative (`INFO ℹ`).
- **Universal Multi-User & Multi-Client Steam Detection (`detect_gaming_system` & `check_gaming`)**:
  - Dynamically resolves user home directory under `SUDO_USER` when run with elevated privileges, preventing false non-gaming classifications during administrative audits.
  - Expanded custom Proton runner discovery across native Steam (`compatibilitytools.d`), Flatpak Steam (`~/.var/app/com.valvesoftware.Steam/...`), and Heroic Games Launcher (`~/.config/heroic/tools/proton`).
  - Added robust kernel version fallback (`uname -r >= 5.16`) for `futex_waitv` (fsync) when Python3 is unavailable or restricted.
  - Added fallback GPU name resolution from `vga_info` when `vulkaninfo` is not installed.

### Fixed & Hardened (Luna SRE Architectural Audit Priority 2B Remediation)
- **Universal Locale & Grammar Independence in Package Integrity (`check_package_integrity`)**:
  - Enforced `LC_ALL=C` across all `pacman -Qk` subshell queries, preventing localized output (e.g. Polish `brakujący plik`, German `fehlende Datei`) from blinding the audit engine on non-English desktop installations.
  - Corrected grammatical regex to match singular `1 missing file` as well as plural `N missing files` (`/[1-9][0-9]* missing file/`).
  - Added non-root privilege boundary verification: avoids falsely reporting packages as corrupt when unprivileged users audit files located inside `0700 root:root` directories (`/etc/sudoers.d`, `/var/named`).
- **Snapshot & Nested Container Mount Filtering in Storage Audit (`check_root_space`)**:
  - Filtered out Btrfs snapshot trees (`/.snapshots`) and container engine storage (`/var/lib/docker`, `/var/lib/containers`) from active mount audits, eliminating performance stalls and false alerts on Snapper/Timeshift setups.
  - Sanitized percentage extraction with numeric awk accumulators (`awk 'NR==2 {gsub(/[^0-9]/,"",$5); print $5+0}'`), preventing arithmetic syntax errors.
- **Deep Configuration .pacnew Scanning (`_find_pacnew_files`)**:
  - Expanded search depth in `/etc` from 4 to 7, guaranteeing detection of nested system configurations (e.g. `/etc/systemd/system/*.service.d/*.pacnew`, `/etc/polkit-1/rules.d/`).
- **Comprehensive Process Lock Detection (`check_pacman_lock`)**:
  - Expanded process detection regex to include `pikaur`, `makepkg`, and `eos-update`. Added `lsof` fallback when `fuser` (`psmisc`) is not installed.

### Fixed & Hardened (Luna SRE Architectural Audit Priority 2A Remediation)
- **Immediate Root Privilege Guardrail in Standalone Hub (`run_software_updates`)**:
  - Enforced an upfront non-root execution barrier (`EUID == 0`) at the very top of `run_software_updates()`, completely blocking discovery probes (`yay -Qua`, `uv self update`, `goose update`) from ever executing under `sudo` or as root.
  - Prevents root-owned cache contamination in `/root/.cache` and eliminates user home directory permission hijacking.
- **Dynamic Pacman DBPath Standardization (`package_manager_busy` & Software Hub)**:
  - Replaced legacy static `/var/lib/pacman/db.lck` checks with dynamic runtime resolution via `pacman-conf DBPath`.
  - Expanded `package_manager_busy()` process detection to include `pikaur`, `pamac-daemon`, `packagekitd`, and `eos-update`.
- **Accurate Runtime Shim & Standalone Classifier (`check_binary_ownership`)**:
  - Refined regex pattern matching to target specific shim directories (`/shims/`, `/\.pyenv/`, `/\.asdf/`, `/\.nvm/`, `/mise/shims/`, `/\.rustup/toolchains/`), ensuring user-compiled tools installed via `cargo install` in `~/.cargo/bin` are accurately recognized as standalone binaries rather than shims.
- **Multi-Path Symlink Writability Assurance (`can_self_update_binary`)**:
  - Validates write permissions for both the canonical target file/directory and the symlink's parent directory (`link_dir`), ensuring in-place atomic self-updates succeed across complex symlink setups.
- **Graceful Local DB Fallback for Partial Upgrade Risk (`check_partial_upgrade_risk`)**:
  - Added fallback evaluation using `pacman -Qu` when `checkupdates` (`pacman-contrib`) is unavailable, enabling immediate partial upgrade risk detection even without optional contrib utilities.

### Fixed & Hardened (Luna SRE Architectural Audit Priority 1 Remediation)
- **Universal Multi-Kernel & UKI Resolution Hardening (`_resolve_kernel_and_initramfs`)**:
  - Implemented boundary-safe regex matching (`^(.*[-_])?${pkgb}([-_.][0-9].*)?$`) for Unified Kernel Images (`.efi`), eliminating substring collisions where `arch-linux-lts.efi` or `linux-zen.efi` falsely matched plain `linux`.
  - Added multi-candidate path scanning across `/EFI/Linux`, `/EFI/BOOT`, and boot roots.
  - Type #1 BLS: verified `linux` entry relative targets against all discovered candidate boot mountpoints rather than exclusively `${bdir}`.
  - Eliminated broad `/boot/vmlinuz` and `/efi/vmlinuz` fallbacks when multiple kernels are detected in `/usr/lib/modules/*/pkgbase`, preventing missing custom kernels from silently reporting false PASS.
- **Boot Mount Discovery & /etc/fstab Comment Filtering (`detect_boot_directories`)**:
  - Hardened `/etc/fstab` parsing to strictly exclude commented lines (`!/^[[:space:]]*#/`), preventing deactivated or historical mount targets from contaminating boot scans.
- **ESP Space Margins & Read-Only Protection (`check_efi_mount`)**:
  - Added direct read-only mount detection (`findmnt -o OPTIONS -T "$efi_mnt"`), logging `FAIL ✖ (mounted READ-ONLY!)` before upgrades attempt writes.
  - Harmonized space threshold grading with SRE guardrails: `< 50MB` triggers `FAIL ✖` (prevents aborted initramfs generation mid-upgrade) and `< 100MB` emits `WARN ⚠`.
- **Pre-Flight Power & USB-PD Universalism (`check_laptop_battery_preflight` - Gate 0)**:
  - Upgraded AC mains detection to dynamically accept modern USB-C Power Delivery and external power supply bricks (`type != "Battery"` with `online == 1`).
- **Arch News Network Resilience & Cache Hardening (`scan_arch_news_feed` - Gate 4)**:
  - Decoupled offline/unreachable states from the zero-manual-intervention pass (`IGNORED:0`). When upstream feeds are unreachable or timeout, emits explicit `UNREACHABLE` status handled as neutral `INFO ℹ` instead of falsely reporting 0 upstream advisories.
- **Rig-Bias Elimination in Hardware Upgrade Gates (`run_guarded_upgrade` - Gate 5)**:
  - Removed strict hardcoded requirement for `nvidia-580xx-dkms` on systems with Maxwell GPUs. If a community user runs modern open drivers (`nouveau` or NVK) or alternative branches on a Maxwell card, the gate no longer blocks upgrades, while still protecting proprietary 580xx users from black screens caused by official repo `nvidia` meta-package overwrites.
  - Expanded `core_regex` package classifier to include modern audio servers (`pipewire`, `wireplumber`), alternative initramfs generators (`booster`), and modern bootloaders (`systemd-boot`, `limine`, `refind`).
- **Temporary File Lifecycle & Trap Cleanup (`run_guarded_upgrade`)**:
  - Registered `tmp_repo` and `tmp_aur` in the function's `RETURN` cleanup trap (`_cleanup_guarded_upgrade`), ensuring zero `/tmp` orphan residues even upon Ctrl+C interruption.

### Fixed & Hardened (Luna SRE Architectural Audit 2.20 Remediation)
- **Elimination of Hybrid GPU Model-Driver Mismatch (`check_gpu` & `check_gpu_errors`)**:
  - Replaced crude single-line extraction with discrete PCI device block scanning (`lspci -k`).
  - Resolved fatal desynchronization on hybrid laptops (Intel/AMD iGPU + NVIDIA dGPU) where NVIDIA temperature was falsely assigned to an Intel GPU label.
  - Added multi-GPU enumeration displaying all active controllers and strictly flagging unmanaged/driverless secondary GPUs.
  - Hardened driver extraction in `check_gpu_errors` and `generate_summary_json` using multi-line `awk` block parsing.
- **Remediation of Partial-Permission False PASS Trap (`check_smart`)**:
  - Fixed logic trap where mixed setups (e.g. unprivileged SATA/NVMe alongside USB/VM disks) bypassed checks and yielded false `PASS ✔ (0/1 OK)`.
  - Disks in standby or returning I/O read errors are strictly flagged (`WARN ⚠`), eliminating silent drive degradation.
  - Added structured remediation codes in `generate_summary_json` (`HW_STORAGE_SMART_FAILURE` vs `HW_STORAGE_SMART_UNVERIFIED`).
- **Universal Multi-Socket & Die Thermal Aggregation (`check_temperature`)**:
  - Implemented dynamic MAX temperature discovery across all package IDs, dies (`Tctl`/`Tdie`), and chiplets (`Tccd*`), resolving blindspots on multi-socket and Threadripper systems.
  - Eliminated synthetic `.0°C` string formatting in sysfs fallbacks.
  - Added strict SRE threshold gating: introduced `FAIL ✖` and `HW_CPU_CRITICAL_OVERHEAT` for critical silicon overheating (> 90°C) and neutral `INFO ℹ` for offline 0°C sensors.
- **Multi-Disk SSD Discard Awareness (`check_fstrim`)**:
  - Eliminated monolithic root mount bias: scans all mounted filesystems across active storage disks when `fstrim.timer` is inactive.
  - Verified explicit `nodiscard` mount options on Btrfs to ensure accurate TRIM lifecycle validation on secondary SSD arrays.
- **Table Reconstruction Synchronization & Power Telemetry Gap (`reconstruct_tables_from_log`)**:
  - Added missing `power` case under Hardware & Drivers, preventing "Power & Battery" from spilling into a rogue `OTHER CHECKS` section in log viewers.
  - Preserved GPU driver telemetry and added structured decoding for uninstalled smartmontools and offline thermal sensors.

## [2.24] - 2026-09-27

### Fixed & Hardened (Luna SRE Architectural Audit 2.21/2.22 Remediation)
- **Elimination of Arithmetic Expansion Syntax Trap in Orphan Audit (`check_orphan_packages`)**:
  - Replaced defective `$(( ... | wc -l ))` construct with isolated standard command output parsing via `mktemp`.
  - Disentangled genuine 0-orphan states (`exit 1` without stderr) from ALPM DB lock contention or query corruption (`WARN ⚠` upon non-empty stderr).
  - Maintained 100% table reconstruction fidelity in `reconstruct_tables_from_log()`.
- **Elimination of Double-Zero Arithmetic Failure Trap (`awk` Server Counting)**:
  - Eliminated the `grep -c ... || echo 0` pattern across `refresh_and_rank_mirrors`, `check_mirrorlist_age`, and `run_guarded_upgrade` (Pre-Flight Gate 3 & Phase 1).
  - When `grep -c` matched zero lines, it emitted `0` and returned code 1, causing `echo 0` to append a second zero (`0\n0`), which broke subsequent bash arithmetic evaluation `(( val >= 3 ))`.
  - Migrated server and update counting to deterministic `awk` accumulators (`END { print count + 0 }`).
- **Primary Mirror Probe & Zero-Curl False Positive Remediation (`probe_primary_mirror`)**:
  - Eliminated artificial `HTTP 200` return code when `curl` was missing, ensuring systems without curl report `NA` probe status rather than falsely passing mirror health checks.
  - Added clean timeout bounds (`--connect-timeout 3 --max-time 4`) and decoupled probe execution from subshell fallback corruption.
- **Universal Mirrorlist Discovery Hardening (`discover_active_mirrorlists`)**:
  - Added `PACMAN_CONF` environment variable override support with dynamic directory resolution.
  - Hardened `Include` parsing with comment stripping and glob expansion.
  - Implemented deduplication via associative arrays and eliminated empty newline generation on unconfigured systems (preventing phantom array elements in `mapfile`).
- **Network Resolution & DNS Transport Integrity (`check_dns`)**:
  - Added regex sanitization for `DNS_TEST_HOST` and `DNS_TEST_SERVER` to prevent argument injection.
  - Added explicit `INFO ℹ` advisory when a custom server is requested but neither `dig` nor `drill` is installed, preventing misleading fallback claims.
  - Added `resolvectl` integration for modern systemd-resolved setups.
  - Updated `getent` fallback to explicitly state `(NSS resolution; DNS transport unverified)`, preventing false assumptions about upstream DNS transport health.
- **Atomic Orphan Safety & Multi-Cache Purge (`triage_orphan_packages`)**:
  - Enforced SRE cardinal safety standard: packages with missing or unparseable ALPM metadata are strictly classified as Tier 3 (Core & Toolchain Protected / Manual Review), eliminating accidental auto-purge risks.
  - Dynamic discovery of all configured `CacheDir` locations from `pacman-conf` during Zero-Residue Cache Purge.
  - Added privilege awareness (`EUID == 0` direct invocation vs `sudo` unprivileged).
- **User Session Audit Race Condition & Bus Isolation (`check_failed_services`)**:
  - Eliminated duplicate `systemctl --user` invocations between detection and logging, ensuring 100% telemetry consistency.
  - Enforced `--no-pager` across all systemd queries.
  - Verified D-Bus session bus existence prior to inspection and queried `id -un` instead of relying on mutable `$USER`.

## [2.23] - 2026-09-27

### Added & Hardened (Universal Bootloader & Kernel Synchronization Engine)
- **Universal Multi-Bootloader Synchronization Audit (`check_bootloader_sync` / `_boot_sync_audit`)**:
  - Implemented an intelligent, read-only audit engine in `BOOT & CORE OS` that cross-references all installed kernel families (`/usr/lib/modules/*/pkgbase`) directly against active bootloader configurations.
  - Resolves the **Silent Kernel-Bootloader Drift Trap**: In Arch Linux, kernel packages run ALPM hooks that compile DKMS modules and build initramfs via dracut/mkinitcpio, but Arch intentionally omits automatic `grub-mkconfig` hooks (avoiding lengthy `os-prober` multi-drive scanning delays). Users installing additional kernels (e.g. `linux-zen`) had valid kernel files on disk, yet bootloader menus lacked boot entries for them.
  - **Universal Ecosystem Support (Cardinal Dual-Lens Standard):**
    - **GRUB:** Dynamically scans `/boot/grub/grub.cfg`, `${esp}/grub/grub.cfg`, `/grub/grub.cfg`, and `grub2` paths across mounted partitions and `/etc/fstab`.
    - **systemd-boot:** Evaluates Type #1 entry files (`${esp}/loader/entries/*.conf`), live UEFI loader state (`bootctl --no-pager list`), and Type #2 standalone UKIs.
    - **Limine:** Parses active `limine.conf` and `limine.cfg` across boot and ESP paths.
    - **rEFInd:** Features dynamic auto-discovery awareness—checks static `refind_linux.conf` without generating false-positive desync warnings on installations leveraging rEFInd's dynamic kernel scanning.
    - **UKI (Unified Kernel Images):** Validates standalone `.efi` kernel binaries in `${esp}/EFI/Linux/`.
- **Non-Root Privilege Boundary & Zero False Alarms**:
  - Respects standard `0600 root:root` permissions on `/boot/grub/grub.cfg` without hanging on interactive password prompts.
  - Non-interactively verifies elevated read access via `sudo -n`. If unprivileged, emits a neutral advisory (`INFO ℹ (grub: grub.cfg permissions 0600; run with sudo to audit boot entries)`) rather than raising false `WARN` or `FAIL` alerts.
- **Boundary-Safe Kernel Regex Matching**:
  - Implemented strict boundary matching regex (`(vmlinuz-|initramfs-|initrd-|Linux[[:space:]]+)${base}([[:space:]/'".,)]|$)`) to eliminate substring collisions between related kernel variants (e.g. guaranteeing `linux-lts` or `linux-zen` does not trigger a false positive match for vanilla `linux`).
- **Structured Actionable Remediation (`BOOTLOADER_KERNEL_DESYNC`)**:
  - Integrates structured actionable remediation in both terminal reports and `summary.json` telemetry (`BOOTLOADER_KERNEL_DESYNC`), surfacing tailored recovery commands (e.g., `sudo grub-mkconfig -o /boot/grub/grub.cfg` or `reinstall-kernels`).

### Changed & Unified (Post-Flight Upgrade Verification)
- **Harmonized Post-Flight Bootloader Check (`verify_bootloader_post_flight`)**:
  - Replaced legacy static bootloader presence checks in Phase 3 of Guarded Upgrade with the unified `_boot_sync_audit 0` engine.
  - Guarantees that newly installed kernels are actively registered in bootloader menus before the user reboots.

---

## [2.22] - 2026-09-27

### Fixed & Hardened (Cardinal Mandate: Universalism & Mirror Resilience)
- **Elimination of Rig Bias in Mirror Ranking (`Pre-Flight Gate 3`)**:
  - Removed hardcoded European countries list (`--country "United Kingdom,France,Netherlands,Germany"`) that previously biased reflector ranking on non-European community installs.
  - Implemented 100% dynamic universalism: queries the 20 most recently synchronized HTTPS mirrors worldwide, benchmarks connection and download speeds, and ranks the 10 fastest (`--latest 20 --protocol https --sort rate --fastest 10`).
- **Reflector Python-Argparse Config Syntax Fix**:
  - Fixed a critical dormant syntax bug where `reflector --config /etc/xdg/reflector/reflector.conf` failed with `unrecognized arguments: --config`.
  - Replaced with standard Python-argparse file syntax (`reflector @"$ref_conf"`), enabling user-customized `reflector.conf` profiles to be correctly applied.
- **Dead Primary Mirror Trap & Forum Failure Remediation (EndeavourOS Threads #55583, #62289)**:
  - Eliminated the critical failure mode where a dead primary mirror (e.g. `mirror.f4st.host`) with fresh file timestamps silently passed Gate 3 and crashed or hung pacman transactions with 3102ms socket timeouts.
  - Upgraded Gate 3 to dynamically probe primary mirror HTTP status and TTFB latency (`curl`) on `core.db`, trigger smart mirror refresh prompts on dead mirrors, empty mirrorlists, or severe network throttling (> 800ms), and safely fail if no working fallback servers exist.
  - Added dynamic hardware architecture discovery (`uname -m`) for non-x86_64 systems instead of static strings.

### Added (Dynamic Mirrorlist Health & Atomic Ranking Engine)
- **Real-Time Mirrorlist Health & Latency Probe (`check_mirrorlist_age`)**:
  - Upgraded read-only audit check to evaluate active server redundancy and measure live TCP/TTFB round-trip latency to the primary Arch repository (`curl`).
  - Differentiates lightning-fast regional mirrors (< 150ms), acceptable continental mirrors (150-400ms), and sub-optimal / cross-continental mirrors (> 400ms - raises `INFO ℹ` advisory).
  - Flags dead primary mirrors (`WARN ⚠`) while verifying general internet reachability.
  - Dynamic discovery across all active `/etc/pacman.d/*mirrorlist*` topologies (Arch, EndeavourOS, CachyOS, Chaotic-AUR) with per-list server counts.
- **Universal, Atomic Mirror Ranking Engine (`refresh_and_rank_mirrors`)**:
  - Standalone engine supporting official `reflector`, AUR `rate-mirrors`, and distribution-specific `eos-rankmirrors`.
  - **Atomic Staging Gate:** Ranks to isolated temporary files (`mktemp`), validates server count (`>= 3`), verifies live HTTP 200 reachability of the primary mirror, and atomically installs via `install -m 644` with automated `.bak` backups and rollback safety.
- **CLI & TUI Integration**:
  - Added `--mirrors` command-line switch for standalone execution.
  - Added Option 3 ("Refresh & Rank Fastest Regional Mirrors") and updated Option 4 ("Complete Maintenance") in Main Menu Option 6 (Safe Maintenance & System Hygiene).

## [2.21] - 2026-09-27

### Fixed & Hardened (Zero-False-Alarm Policy: User Sessions & Encrypted DNS)
- **Transient Desktop App Filtering in User Session Audit (`check_failed_services`)**:
  - Excluded ephemeral XDG desktop application units (`app-*.service` and `app-*.scope`) from systemd user session failure evaluations across both unprivileged and root multi-seat audits.
  - Prioritizes core user daemon health (`pipewire`, `wireplumber`, `dunst`, `gpg-agent`) over safely closed or user-cancelled graphical windows (such as `yad` or `eos-welcome` exiting with code 1).
- **Encrypted & Cold-Cache DNS Fault Tolerance (`check_dns`)**:
  - Increased `dig` query fault tolerance from `+time=2 +tries=1` to `+time=3 +tries=2`.
  - Prevents false-positive `WARN` alarms caused by initial TLS negotiation latency / cold cache lookups on upstream encrypted resolvers (DoT/DoH via pfSense NextDNS CLI, Pi-hole, Unbound, AdGuard Home).

### Added & Hardened (Universal Orphan Triage & Zero-Residue Purge Engine)
- **Dynamic 3-Tier Orphan Safety Classifier (`triage_orphan_packages`)**:
  - Implemented an intelligent offline classifier analyzing unrequired packages (`pacman -Qtdq`) via batch local ALPM metadata queries (`LC_ALL=C pacman -Qi`):
    - 🟢 **Tier 1 (Safe Leaves):** Truly unrequired leaf packages (`Optional For: None`). Safe to purge automatically.
    - 🟡 **Tier 2 (Optional Dependencies):** Packages actively utilized as optional dependencies by installed software. Surfaces exact reverse dependencies (e.g. Dolphin, GIMP, VLC) to prevent silent feature loss.
    - 🔴 **Tier 3 (Core & Toolchain Safety Guard):** Regex blacklist preventing accidental deletion of kernel headers, firmware, GPU drivers, audio servers, fonts, and build toolchains (`base-devel`, `rust`, `cargo`, `go`, `gcc`, `make`, etc.).
- **Zero-Residue Cache Purge (Arch Wiki Maintenance Standard)**:
  - Automatically executes `paccache -c "$pacman_cache_dir" --remove --uninstalled --keep 0` immediately following orphan deinstallation (`pacman -Rns`) to eliminate dead `.pkg.tar.zst` archives while preserving rollback history for installed packages (`PACCACHE_INSTALLED_KEEP=2`).
- **Explicit Intent Protection (`pacman -D --asexplicit`)**:
  - Integrated interactive action allowing users to mark useful build tools or dependencies as explicitly installed, permanently resolving recurring orphan alerts for user tools.
- **Pre-Flight Gate 2 Orphan Advisory**:
  - Added passive informative advisory in `run_guarded_upgrade` warning users about pending orphans and stale AUR compilation risks before initiating system upgrades (100% Upstream Harmonization: zero false alarm FAIL/WARN).
- **Read-Only Audit & Table Reconstruction Fidelity**:
  - Added `check_orphan_packages()` under System Health & Services in `run_health_check` and updated `reconstruct_tables_from_log()` for 100% fidelity across report viewers.
- **CLI & TUI Integration**:
  - Added `-o, --orphans` command-line switch for standalone execution and interactive submenu under Option 6 (Safe Maintenance).

## [2.20] - 2026-09-26

### Fixed & Hardened (Universal Hardware & Drivers Audit Engine)
- **Universal CPU Temperature Detection & AMD Ryzen Prioritization:**
  - Hardened `check_temperature()` to prioritize dedicated CPU package and die sensors (`Package id 0`, `Tctl`, `Tdie`) over generic motherboard `temp1` diodes. Resolves inaccurate low readings on AMD Ryzen platforms where ACPI/Super I/O chips reported motherboard diode temps instead of true CPU temperature.
  - Implemented dual-stage native kernel sysfs fallback (`/sys/class/hwmon` matching `coretemp`, `k10temp`, `zenpower`, `cpu_thermal` and `/sys/class/thermal`), eliminating telemetry dropouts when `lm_sensors` is not installed.
- **Virtual Machine & Non-SMART Storage Awareness:**
  - Added detection for non-SMART devices (`Device does not support SMART` / virtual disks / USB thumb drives) in `check_smart()`.
  - Replaced confusing `PASS ✔ (0/1 OK)` outputs on KVM/QEMU virtio disks, VirtualBox disks, and USB-attached installations with clean `INFO ℹ (VM or non-SMART storage)` or capable-disk tallies (`PASS ✔ ($passed/$capable OK)`).
- **Multi-Vendor GPU Telemetry Democratization:**
  - Expanded `check_gpu()` to extract clean GPU model names from `lspci` for ALL hardware vendors (AMD RDNA/GCN, Intel Arc/Iris/Xe, and NVIDIA).
  - Gracefully handles hybrid laptop NVIDIA Optimus/PRIME power suspension (D3cold), preventing malformed `| °C` temperature strings when the discrete GPU is asleep.
- **Universal Btrfs Async & Filesystem Discard Awareness:**
  - Hardened `check_fstrim()` to recognize modern Btrfs in-kernel asynchronous discard defaults (`FSTYPE=btrfs`) and continuous mount discard options.
  - Prevents false-positive `WARN ⚠ (inactive)` warnings on installations where Btrfs manages SSD discard natively without requiring `fstrim.timer`.
- **Log Table Reconstruction Parser Hardening:**
  - Updated `reconstruct_tables_from_log()` with dedicated pattern extractors for new hardware telemetry keys (`gpu`, `smart`, `fstrim`), guaranteeing 100% formatted table fidelity across log viewers and `--report`.

## [2.19] - 2026-09-26

### Fixed & Hardened (Universal Community Network & Updates Audit Engine)
- **Case-Insensitive Arch News Package Matching:**
  - Resolved fatal community defect where capitalized package names in headlines (e.g. `Mkinitcpio >=42 requires manual intervention...`) caused `pacman -Qq` to fail lookups (`error: package 'Mkinitcpio' was not found`).
  - Added case normalization (`${pkg,,}`) and punctuation stripping, ensuring critical manual intervention warnings (`WARN ⚠`) are accurately triggered for any affected installed package.
- **Stealth Gateway & Firewall Fallback (Zero False Failures):**
  - Eliminated false `FAIL ✖ (gateway unreachable)` audits on networks where routers or firewalls drop ICMP echo requests to their LAN IP (e.g. stealth pfSense/OPNsense rules, enterprise Cisco/MikroTik, dormitories, public Wi-Fi).
  - Implemented dual-stage fallback: verifies gateway presence in kernel ARP neighbor tables (`ip neigh show`) and checks upstream internet ping (`1.1.1.1` / `9.9.9.9`), logging `PASS ✔ (... gw: <IP> (stealth ICMP OK))` when connectivity is healthy.
- **Dual-Stack & Pure IPv6 Network Support:**
  - Added automatic fallback to IPv6 default routes (`ip -6 route show default`) when no IPv4 default route is present, supporting modern pure IPv6 / NAT64 community network environments without flagging false route failures.
- **Reachability-Validated Orphan VPN DNS Checking:**
  - Hardened orphan VPN DNS detection to ping candidate nameservers before alerting, preventing false-positive `WARN ⚠` warnings on standard RFC1918 home subnets (e.g. `10.2.0.1` home routers or local Pi-holes).
- **Intelligent Degraded Ethernet Link Speed Detection:**
  - Replaced crude `<= 100Mb/s` warning with hardware-aware inspection via `ethtool`.
  - Flags degraded link speed (`WARN ⚠`) only when the interface negotiates at `<=100Mb/s` on a card verified to support Gigabit+ (`1000base`, `2500base`, `10000base`), avoiding false alarms on legacy 100M-only hardware while accurately detecting cable/switch pin failures.
- **Tool-Agnostic DNS Diagnostics Hierarchy:**
  - Expanded `check_dns()` beyond `bind-tools` (`dig`) to dynamically support `drill` (from `ldns`), `systemd-resolved`, and standard libc resolution via `getent ahosts`, eliminating test dropouts on minimal CLI installations.
- **Dynamic Distro-Agnostic Mirrorlist Inspection:**
  - Replaced hardcoded EndeavourOS mirrorlist file paths in `check_mirrorlist_age()` with dynamic discovery of all active `/etc/pacman.d/*mirrorlist*` files (filtering backups and pacnews).
  - Seamlessly audits mirror age across Arch Linux, EndeavourOS, CachyOS, and Chaotic-AUR repositories with prioritized Arch ordering (`Arch: Xd │ Distro: Yd │ CachyOS: Zd`).

## [2.18] - 2026-09-26

### Fixed & Hardened (Multi-User & Multi-Config System Health & Services)
- **EndeavourOS & Arch Community-Portability Principles Applied:**
  - **Universal Bootloader & Configuration .pacnew Scanning:** Implemented `_find_pacnew_files()` to scan both `/etc` and all active boot/ESP partitions (`/boot`, `/efi`, `/boot/efi`). Resolves community blindspots where bootloader config updates (e.g. `systemd-boot` `/loader/loader.conf.pacnew` or `limine` `/boot/limine.conf.pacnew`) were previously ignored.
  - **Upstream Magic SysRq Policy Harmonization:** Harmonized `check_sysrq` to recognize standard Arch Linux and systemd upstream security defaults (`16`, `176`, `22`) as `PASS ✔ (safe upstream default: val=...)`. Eliminates false-positive `WARN ⚠` review alerts for community users on clean installs, reserving warnings strictly for completely disabled (`val=0`) states.
  - **Dynamic Pacman DBPath Discovery:** Replaced static `/var/lib/pacman` paths in `check_pacman_lock()` and upgrade post-flight validation with runtime interrogation via `pacman-conf DBPath`, supporting custom user database locations.
- **Universal Multi-User Session Service Auditing:**
  - Hardened `check_failed_services()` to dynamically enumerate and audit all active systemd user managers (`user@*.service`) via `systemctl --user -M <UID>@ list-units --failed`.
  - When executed under `sudo` or as root (cron/maintenance/SSH), it no longer drops to `INFO (no active user session bus)`, but instead audits every active human or lingering background user on the system.
  - Accurately reports failed user unit counts per user account in log files (`### FAILED SYSTEMD UNITS (USER: <USER> / <UID>)`).
- **Dynamic Multi-Mount Storage Discovery:**
  - Expanded `check_root_space()` to inspect all critical storage mountpoints (`/`, `/home`, `/var`, etc.) dynamically via `mountpoint` probing and `findmnt` filesystem discovery.
  - Prevents silent failures where separate `/home` or `/var` partitions hit 100% capacity while `/` remained under threshold.
  - Dynamically highlights the worst-utilized mount in audit tables (e.g. `PASS ✔ (Max: /home 45%)` or `WARN ⚠ (/var at 85%)`), while maintaining single-partition backward compatibility on baseline rigs (`PASS ✔ (19%)`).
- **Pacman DB Lock Wrapper & Helper Awareness:**
  - Hardened `check_pacman_lock()` to recognize active AUR helpers and package daemons (`pacman`, `yay`, `paru`, `pamac-daemon`, `packagekitd`) via exact process name regex matching.
  - Eliminated false-positive `stale lock` warnings when unprivileged users audit the system while an AUR transaction or package daemon holds the lock file.
- **Modernized Remediation Guidance:**
  - Replaced obsolete pacman `--force` flag (removed in Pacman v5.2) with modern `sudo pacman -S --overwrite '*' <pkg>` in package integrity failure recommendations (`PKG_CORRUPT_FILES`).
  - Generalized storage remediation summary in recommendation engine from monolithic "Root filesystem" to "Filesystem usage is over threshold on critical partition".
- **Log Table Reconstruction Row Delimiter Fix:**
  - Fixed a formatting bug in `reconstruct_tables_from_log()` where command substitution `$(_format_audit_row ...)` stripped trailing newlines, causing consecutive audit rows in log reports to concatenate onto a single line.

## [2.17] - 2026-09-26

### Fixed & Hardened (Boot & Core OS Audit Engine)
- **Dynamic ESP & Boot Directory Topology Detection:**
  - Resolved user bug report: script assumed hardcoded `/boot` paths for kernels (`vmlinuz-*`) and initramfs (`initramfs-*.img`), causing complete audit failures on systems mounting the EFI System Partition at `/efi` (e.g., CachyOS, standard `systemd-boot`, and Type #1 BLS layouts).
  - Implemented dynamic boot directory resolution discovering active vfat mounts via `findmnt`, `/etc/fstab`, and candidate paths (`/efi`, `/boot/efi`, `/boot`).
  - Added full support for Type #1 Boot Loader Specification (BLS) entries (`/loader/entries/*.conf` and `<boot>/<entry-token>/<kver>/linux`), Type #2 Unified Kernel Images (`EFI/Linux/*.efi`), and flat layouts across multiple kernels (`linux-lts`, `linux-cachyos`, `linux-xanmod-*`, etc.).
- **Dracut & Alternative Initramfs Generator Support:**
  - Resolved user bug report: script failed to recognize Dracut initramfs images stored outside `/boot` and erroneously failed audits with `FAIL ✖ (missing fallback)`.
  - Dracut builds host-only images without separate fallback images by default. Missing fallback images are now properly classified as normal operation for Dracut systems and are never treated as fatal errors (`ERRORS++`).
  - Expanded `detect_initramfs_generator` to inspect `/etc/dracut.conf`, `/etc/dracut.conf.d`, `/usr/lib/dracut`, and active ALPM hooks, correctly distinguishing Dracut from mkinitcpio.
  - Dynamically formats the detected initramfs generator and image size in audit reports (e.g. `dracut [45MB]`).
- **Guarded System Upgrade (Option 2) Post-Flight Verification [RESOLVED]:**
  - Migrated post-flight kernel and initramfs integrity check from static `/boot/` paths to the dynamic `_resolve_kernel_and_initramfs()` engine.
  - Upgrades on installations mounting ESP at `/efi` or using BLS layout now correctly detect installed kernels and initramfs images without false-positive post-upgrade failure warnings.
  - Updated post-flight disaster recovery guidance to dynamically template the actual detected initramfs image path in `lsinitrd` / `lsinitcpio` inspection commands.
- **Guarded System Upgrade (Option 2) Pre-Flight Gate 1 [RESOLVED]:**
  - Eliminated hardcoded assumption that `/boot` must exist as a dedicated filesystem in `/etc/fstab`.
  - Implemented dynamic inspection of `/etc/fstab` for any partition targets matching `/boot`, `/efi`, or `/boot/efi`.
  - Intelligently skips duplicate checks if a partition was already verified as the ESP.
  - Dynamically verifies read-write status on whichever boot mounts exist without blocking upgrades on systems with unified root and `/efi` partitions.
- **Bootloader Detection Harmonization & Contextual Repair Hints [RESOLVED]:**
  - Harmonized `detect_bootloader()` with `detect_active_bootloader()`: performs multi-source probing via efivars (`LoaderInfo-*`), `bootctl status`, configuration file discovery, and UKI verification.
  - Contextualized `print_bootloader_repair_hint()`: dynamically paths GRUB configs (`/boot/grub/grub.cfg`, `/efi/grub/grub.cfg`), Limine configs, and UKI paths based on the active ESP path instead of hardcoded `/boot` paths.
- **Multi-User & Session Environment Adaptability [RESOLVED]:**
  - Hardened `check_failed_services()` for user systemd units: checks for a live user D-Bus session (`XDG_RUNTIME_DIR/bus` or `is-system-running`) before querying `systemctl --user`, outputting a clean `INFO ℹ` banner when run non-interactively or under root.
  - Enhanced Wayland compositor and Xorg log detection in `check_gpu_errors()` to track active user targets under `SUDO_USER` and check modern compositors (`labwc`, `cosmic-comp`, `river`, `Hyprland`, `kwin_wayland`, `gnome-shell`).
- **Software & Standalone Updates Multi-User Security Guardrails [RESOLVED]:**
  - Enforced strict non-root privilege boundary in `run_software_updates()`: explicitly blocks running standalone user updates (AUR via `yay`/`paru`, `uv self update`, `goose update`, `pipx`, `rustup`) as `root` or via `sudo`, completely eliminating the risk of root-owned file creation and permission hijacking in user home directories (`$HOME`).
  - Added binary writability verifications (`can_self_update_binary()`): checks write permissions for both the target binary and its parent directory before attempting in-place updates, preventing permission faults and partial writes when binaries are installed in shared locations like `/usr/local/bin`.
- **Safe Maintenance & Deep Clean Multiplatform Hardening [RESOLVED]:**
  - Replaced hardcoded pacman cache path with dynamic querying via `pacman-conf CacheDir` with graceful fallback to `/var/cache/pacman/pkg`.
  - Expanded AUR build cache pruning to iterate through all installed helpers (`yay`, `paru`, `pikaur`) rather than exclusively picking the first one found, and expanded `find` depth to 3 for complex build trees.
  - Hardened systemd journal maintenance against volatile RAM-only logging (`/run/log/journal`), cleanly reporting an informative skip notice instead of failing `journalctl --vacuum`.
  - Added Btrfs, ZFS, and tmpfs mount boundary tolerance in `safe_delete_children()` using `findmnt -o FSTYPE` to avoid false-positive aborts on nested subvolumes/datasets.
  - Dynamically resolved XDG standards in Deep Clean (`empty_freedesktop_trash` and `clean_thumbnail_cache`) using `${XDG_DATA_HOME:-$HOME/.local/share}/Trash` and `${XDG_CACHE_HOME:-$HOME/.cache}/thumbnails`, plus legacy `~/.thumbnails` detection.
  - Hardened shader & gaming cache never-touch guards (`get_never_touch_shader_paths()`) to dynamically protect custom `$XDG_CACHE_HOME` and `$XDG_DATA_HOME` locations against accidental purge.
  - Integrated Flatpak process detection in `browser_process_running()` querying `flatpak ps` to prevent race conditions during browser cache cleanup.
  - Implemented strict interactive root guardrail in Main Menu Option 7: blocks executing Deep Clean directly as `root` without `SUDO_USER` to prevent `/root` clutter and home directory permission corruption.
- **Audit View & Log Reconstruction Alignment:**
  - Corrected `reconstruct_tables_from_log` to dynamically display the actual mounted ESP path (e.g. `EFI partition (/efi)`) rather than hardcoding `(/boot/efi)`.
  - Added `/efi` to `CRITICAL_SYSTEM_ROOTS` to prevent path traversal during system maintenance/hygiene operations.
  - Included `/efi` directory enumerations in system diagnostic snapshots (`Section 9b`).
- **Remediation JSON Generator Fix:**
  - Fixed variable scoping typo in `generate_summary_json` where `$risk` caused jq compile failures during headless audits.

### Slated for Assessment (Downstream Multi-Environment Hardening)
- **Wayland / Headless GPU Diagnostics:**
  - *Current State:* Evaluates GPU lockups primarily via `journalctl -k` and Xorg logs.
  - *Focus:* Expand Wayland compositor session log analysis (`journalctl --user -u plasma-kwin_wayland -u gnome-shell`) for multi-user seat configurations.
  - *Status:* Slated for next session.

---

## [2.16] - 2026-09-25

### Added & Improved
- **Transparent Pre-Upgrade Package Manifest (Guarded Upgrade 2.0):**
  - Resolves blind upgrade confirmation in Guarded System Upgrade (Option 2) where pending packages were not displayed.
  - Actively discovers and formats explicit, high-density audit cards for all pending official repository packages (`checkupdates` / `pacman -Qu`) and AUR packages (`yay` / `paru` / `pikaur -Qua`) before operator prompts.
  - **Core Component Awareness & Early Alert:** Automatically classifies critical system infrastructure packages (kernels `linux*`, `nvidia*`, `mesa*`, `systemd*`, `glibc*`, `dracut*`, `grub*`, `mkinitcpio*`, `wayland*`, `xorg*`) with `[core]` tags and displays a prominent warning banner with component names.
  - **Intelligent Zero-Update Handling:** Detects when both official and AUR packages are fully up to date, displaying an all-clear confirmation and preventing redundant empty package transactions.
  - **Safe Pagination & Buffer Protection:** Caps displayed package rows at 25 items for large transactions with a helpful summary notice, ensuring terminal stability while always prioritizing core packages.

---

## [2.15] - 2026-09-25

### Added & Improved
- **Smart Arch News Correlator (Gate 4 2.0):**
  - Correlates upstream Arch News manual intervention alerts directly against locally installed packages (`pacman -Qq`).
  - Eliminates false positive alerts (e.g. `mkinitcpio` on Dracut systems, `kea`, `varnish`, `waydroid`, `dotnet-*`, or official `nvidia` 590+ drops on legacy `nvidia-580xx-dkms` rigs).
  - High-signal UX: Upstream advisories that do not affect the local system are transparently audited and summarized (`Pre-Flight Gate 4: Arch News checked (7 upstream advisories reviewed; 0 affect your installed packages)`) without interrupting the operator.
  - Interactive confirmation prompt (`gum confirm`) is now strictly reserved for cases where an advisory explicitly affects an installed package or is marked as a system-wide breaking change.
- **Upstream Resilience & Local Caching:**
  - Dual-endpoint failover: fetches from Arch News RSS (`/feeds/news/`) with automatic fallback to CDN-cached HTML table (`/news/`) if upstream rate-limiting (HTTP 429) is encountered.
  - Persistent 1-hour local cache at `$STATE_DIR/arch-news-cache.json` eliminates repetitive polling, speeds up pre-flight execution, and protects against Cloudflare/Nginx rate limits.
  - Non-destructive safety fallback: unclassified advisories where package candidates cannot be identified are flagged as `[SYSTEM-WIDE]` and retained for operator review.

---

## [2.14] - 2026-09-25

### Added
- **Universal Multi-Bootloader Support:** Dynamic detection and post-flight entry verification across `systemd-boot`, `GRUB`, `Limine`, `rEFInd`, and standalone `UKI` (Unified Kernel Images).
- **ESP & Mount Topology Gate:** Pre-flight inspection using `findmnt` and `/etc/fstab` validating that the EFI System Partition (`/efi`, `/boot/efi`, or `/boot`) is actively mounted and writable before package transactions start.
- **Bootloader Disaster Recovery Hints:** Context-sensitive CLI repair guidance (`bootctl status`, `grub-mkconfig`, `limine.conf`, `efibootmgr`) displayed automatically if bootloader inconsistencies are identified.
- **Laptop Battery Safety Guardrail (Gate 0):** Hardware ACPI power supply probe detecting battery capacity and charging status; prevents heavy kernel upgrades on discharging laptops below 25% battery.
- **Enhanced TUI Card Renderer & UX:** High-density report cards, formatted category summaries, and streamlined audit report view directly within the interactive menu.

---

## [2.13] - 2026-09-25

### Added
- **Multi-Kernel DKMS & Header Synchronization:** Verifies that matching headers and compiled kernel modules exist across all installed kernel series (`linux`, `linux-lts`, `linux-zen`).
- **Arch News RSS Human-Intervention Scraper:** Proactively parses the top 10 upstream Arch News items, matching advisories requiring manual operator intervention against locally installed packages (`pacman -Qq`).
- **Filtered Package Integrity Audit (`pacman -Qk`):** Intelligent path filtering that discards benign ephemeral files on `tmpfs` mounts (`/tmp`, `/var/run`, `/var/spool`), eliminating noisy false positives while strictly catching real binary/library corruption.
- **Kernel Futex2 / Fsync Probe:** Live userspace syscall probe testing `futex_waitv` (syscall 449) availability for low-latency Wine/Proton game synchronization.
- **Kernel Split-Lock Mitigation & Event Correlation:** Live detection of split-lock penalties and kernel stutter events (`journalctl -k`) impacting modern gaming performance.
- **SRE-Grade Maintenance Protections:**
  - Active browser process locks (`pgrep firefox`, `pgrep chromium`) preventing cache clearing during active sessions (protects SQLite WAL files and session restore).
  - Strict shader cache blacklist (`~/.nv`, `~/.cache/nvidia`, `~/.cache/mesa_shader_cache`, Steam shader pre-caches) to prevent post-maintenance stutter.
  - Emergency rollback package retention retaining at least 1 version of uninstalled packages (`paccache -u -k 1`).

---

## [2.12] - 2026-09-25

### Added
- **Guarded System Upgrade (3-Phase SRE Workflow):**
  - *Phase 1: Pre-Flight Safety Gates* (privileges, network TLS reachability, pacman database lock via `fuser`, disk margins, mirror freshness, Arch News, superseded kernel detection).
  - *Phase 2: Distribution Upgrade* (canonical pacman / yay / paru / eos-update execution).
  - *Phase 3: Post-Flight Integrity Verification* (multi-kernel module build validation, boot image parsing, `.pacnew` tracking).
- **Standalone & Third-Party Software Updates Hub:**
  - Dynamic discovery and 1-click updates for out-of-band software (`Goose AI Assistant`, `uv` Python toolchain, `AUR`, `Steam`, `Flatpak`).
  - Binary ownership guard (`is_pacman_owned`) preventing standalone tool updaters from overwriting distribution-managed packages.
  - Partial upgrade barrier warning against updating AUR packages when official repository updates are pending.

---

## [2.11] - 2026-09-25

### Added
- **Dynamic Performance Flight Recorder (`--sample [SECS]`):** Zero-sudo, live sampling engine measuring:
  - Linux Kernel Pressure Stall Information (`/proc/pressure/{cpu,memory,io}`) for microsecond task starvation metrics.
  - Live GPU utilization, clock states, thermals, and VRAM boundary tracking.
  - Local gateway ICMP round-trip latency (`min/avg/max/mdev`) and packet loss.
  - Unprivileged execution mode for background AI agent sampling without sudo prompts.

---

## [2.10] - 2026-09-24

### Added
- **Gaming & Steam Readiness Suite (`--gaming`):**
  - Multilib repository state audit.
  - 32-bit Vulkan ICD driver stack validation (`lib32-vulkan-icd-loader`, `lib32-nvidia-utils`, `lib32-vulkan-radeon`).
  - Virtual memory map limits (`vm.max_map_count >= 1048576`) and soft file descriptors.
  - GameMode daemon lifecycle verification (`gamemoded -t`).
  - GPU VRAM segment telemetry (highlighting the Maxwell 3.5GB boundary).
- **Silent Troubleshooting & Network Diagnostics:**
  - Detection of accidental NetworkManager "Metered Connection" flags throttling downloads.
  - Physical NIC hardware error counter monitoring (`rx_errors`, `tx_errors`, `rx_crc_errors`).
  - Ethernet link speed negotiation degradation detection (<= 100 Mbps warning on gigabit NICs).
  - Orphan VPN DNS resolver leak detection in `/etc/resolv.conf`.

---

## [2.9] - 2026-09-24

### Changed
- Standardized project naming and executable to `sys-health`.
- Unified telemetry state paths under `~/.local/state/system-health/` (`summary.json`, `system-health.log`, `software-state.txt`).
- Introduced JSON telemetry schema v2.0 for lightweight, zero-token-waste AI assistant integration.
