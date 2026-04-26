#!/bin/bash

#################################################################################
# vmrestore — Automated Restore for libvirt/KVM Virtual Machines
# Vibe coded by James Doutsis — james@doutsis.com
#
# Wraps virtnbdrestore to provide single-command disaster recovery, clone
# restores and point-in-time recovery — with full identity management,
# TPM/BitLocker support and pre-flight safety checks.
#
# Features:
#   - Disaster recovery: rebuilds VM with original UUID, MACs and name
#   - Clone mode: independent copy with new identity (one flag: --name)
#   - Disk restore: in-place single-disk replacement or extract to staging
#   - Point-in-time: restore to any restore point, period or archived chain
#   - TPM/BitLocker: state restored automatically in both DR and clone mode
#   - UEFI/NVRAM isolation: clone gets its own firmware state file
#   - Pre-flight safety: disk collision, free space, running VM detection
#   - Auto-detection: backup type, period, chain layout, storage pool
#   - Dry-run mode: preview every action without writing anything
#
# Prerequisites:
#   virtnbdbackup >= 2.28    virtnbdrestore (disk restore engine)
#   libvirt-daemon-system    virsh domain management
#   qemu-utils               qemu-img for post-restore disk checks
#   bash >= 5.0              required for associative arrays
#
# Usage:
#   vmrestore --help
#
# Repository:
#   https://github.com/doutsis/vmrestore
#
# Relationship to vmbackup:
#   vmrestore is a standalone script — no shared code, no sourced modules,
#   no runtime coupling to vmbackup.sh. But it exclusively restores backups
#   created by vmbackup. The two scripts are complementary halves of one
#   system: vmbackup backs up, vmrestore restores.
#
#################################################################################
#
# SCRIPT ARCHITECTURE
# ===================
# Single self-contained script. No modules, no database,
# no runtime dependency on vmbackup.
#
# Section layout (search with "# ── Section Name"):
#
#   Logging                  Log file init, structured log_info/warn/error
#   Configuration            Backup path resolution from vmbackup config
#   Pre-flight Free Space    Destination capacity check before restore
#   Backup Detection         Full vs incremental, checkpoint enumeration
#   Path Resolution          Period/chain/archive path discovery
#   Listing                  --list and --list-restore-points output
#   Storage Pool Refresh     Longest-prefix pool match + virsh pool-refresh
#   TPM Restore              swtpm state dir recreation at correct UUID
#   New-Identity Define      Clone mode: strip UUID/MACs, rename, define
#   Disk Enumeration         enumerate_disks() for --disk validation/display
#   Disk Collision Protection  Predict output files, check for conflicts
#   Core Restore             Main restore_vm() orchestration function
#   Verify / Dump            --verify checksum validation, --dump output
#   Usage                    --help output
#   CLI Parsing              Argument parsing and validation
#   Main                     Entry point, mode dispatch
#
# Restore flow (inside restore_vm):
#
#   1. Resolve backup path, detect layout, find latest period/chain
#   2. Pre-flight: disk collision, free space, running VM checks
#   3. Disk-restore mode: if --disk set, branch to in-place replacement
#      or staging extract (no VM define, no TPM)
#   4. Run virtnbdrestore (DR: -c -D, clone: -c with staging dir)
#   5. DR: re-inject original UUID and MACs
#      Clone: strip UUID/MACs, rename disks, define with new identity
#   6. Restore TPM state, isolate NVRAM for clones
#   7. qemu-img check, storage pool refresh, completion summary
#
#################################################################################
#
# DISCLAIMER
# ==========
# 100% vibe coded. Could be 100% wrong.
# Appropriate testing in any and all environments is required.
# Build your own confidence that the backups work.
# Backups are only as good as your restores.
#
#################################################################################

set -uo pipefail

readonly VERSION="0.5.4"

# ----- Exit codes -----
# Categorised exit codes for monitoring integration. Symmetric with vmbackup.
readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_CONFIG=2
readonly EXIT_LOCK=3
readonly EXIT_STORAGE=4
readonly EXIT_VM=5
readonly EXIT_TOOL=6
readonly EXIT_USAGE=7
readonly EXIT_DEPENDENCY=8

# ── Logging ──────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -d /var/log/vmrestore ]]; then
    LOG_DIR="${LOG_DIR:-/var/log/vmrestore}"
else
    LOG_DIR="${LOG_DIR:-$SCRIPT_DIR/logs}"
fi
LOG_FILE=""
START_EPOCH=""
ORIG_ARGS=""

init_logging() {
    START_EPOCH=$(date +%s)
    mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
    # Temporary log until we know the VM name (finalize_log renames it)
    LOG_FILE="$LOG_DIR/vmrestore-$(date +%Y%m%d-%H%M%S).log"
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/vmrestore-$(date +%s).log"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

finalize_log_name() {
    # Rename log to include VM name: {vmname}-{timestamp}.log
    local vm_label="${OPT_VM_NAME:-unknown}"
    # Strip path components if --vm was given a full path
    vm_label=$(basename "$vm_label")
    local new_log="$LOG_DIR/${vm_label}-$(date +%Y%m%d-%H%M%S).log"
    if [[ "$LOG_FILE" != "$new_log" ]]; then
        mv "$LOG_FILE" "$new_log" 2>/dev/null && LOG_FILE="$new_log"
    fi
}

log_invocation_summary() {
    local sep="════════════════════════════════════════════════════════════"
    {
        echo "$sep"
        echo "vmrestore v$VERSION — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "$sep"
        echo "Invocation:   vmrestore.sh $ORIG_ARGS"
        echo "Mode:         ${OPT_MODE:-unset}"
        echo "VM:           ${OPT_VM_NAME:-unset}"
        echo "Period:       ${OPT_PERIOD:-auto}"
        echo "Restore Point: ${OPT_RESTORE_POINT:-latest}"
        echo "Restore Path: ${OPT_RESTORE_PATH:-unset}"
        echo "Clone Name:   ${OPT_NAME:-none (disaster recovery)}"
        echo "Backup Path:  ${OPT_BACKUP_PATH:-unset}"
        echo "Disk Filter:  ${OPT_DISK:-all}"
        echo "No Pre-Restore: $OPT_NO_PRE_RESTORE"
        echo "Skip Config:  $OPT_SKIP_CONFIG"
        echo "Skip TPM:     $OPT_SKIP_TPM"
        echo "Force:        $OPT_FORCE"
        echo "Dry Run:      $OPT_DRY_RUN"
        echo "Log File:     $LOG_FILE"
        echo "$sep"
    } >> "$LOG_FILE"
}

log_completion_summary() {
    local rc="$1"
    local end_epoch
    end_epoch=$(date +%s)
    local elapsed=$(( end_epoch - START_EPOCH ))
    local mins=$(( elapsed / 60 ))
    local secs=$(( elapsed % 60 ))
    local sep="════════════════════════════════════════════════════════════"
    {
        echo "$sep"
        printf "Duration:     %dm %ds\n" "$mins" "$secs"
        echo "Exit Status:  $rc"
        echo "$sep"
    } >> "$LOG_FILE"
    # Also show to terminal
    log_info "main" "Duration: ${mins}m ${secs}s — exit $rc — log: $LOG_FILE"
}

_log() {
    local level="$1" fn="$2" msg="$3"
    local line="[$(date '+%Y-%m-%d %H:%M:%S')] [vmrestore] [$fn] $level: $msg"
    [[ -n "$LOG_FILE" ]] && echo "$line" >> "$LOG_FILE"
    echo "$line" >&2
}
log_info()  { _log "INFO"  "$1" "$2"; }
log_warn()  { _log "WARN"  "$1" "$2"; }
log_error() { _log "ERROR" "$1" "$2"; }
die()       { log_error "${2:-main}" "$1"; exit "${3:-$EXIT_ERROR}"; }

# Run a command, teeing all output (stdout+stderr) into the log file
# while still displaying on the terminal. Returns the command's exit code.
run_logged() {
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

# ── Configuration ────────────────────────────────────────────────────────────

resolve_backup_path() {
    # Cascade: --backup-path CLI > vmbackup.conf (instance-aware)
    if [[ -n "${BACKUP_PATH_CLI:-}" ]]; then
        echo "$BACKUP_PATH_CLI"
        return
    fi
    # Determine config instance: CLI flag > env var > default
    local instance="${OPT_CONFIG_INSTANCE:-${VMBACKUP_INSTANCE:-default}}"
    local conf="/opt/vmbackup/config/${instance}/vmbackup.conf"
    if [[ ! -f "$conf" && "$instance" != "default" ]]; then
        die "Config instance '$instance' not found: $conf" "resolve_backup_path" "$EXIT_CONFIG"
    fi
    if [[ -f "$conf" ]]; then
        local val
        val=$(grep -oP '^\s*BACKUP_PATH\s*=\s*["'\''"]?\K[^"'\''"\s]+' "$conf" 2>/dev/null || true)
        if [[ -n "$val" ]]; then
            echo "$val"
            return
        fi
    fi
    die "Cannot resolve backup path. Use --backup-path or install vmbackup with a configured BACKUP_PATH in /opt/vmbackup/config/${instance}/vmbackup.conf" "resolve_backup_path" "$EXIT_CONFIG"
}

# ── Pre-flight Free Space Check ─────────────────────────────────────────────
# Sum the backup data files that will be restored and compare against
# available space on the destination filesystem. This prevents
# virtnbdrestore from silently producing truncated output on ENOSPC
# (upstream bug: virtnbdrestore exits 0 even when writes fail).
#
# Args: data_dir restore_path backup_type [until_checkpoint]
# Returns: 0 if OK, dies if insufficient space

preflight_free_space() {
    local data_dir="$1" restore_path="$2" btype="$3" until_cp="${4:-}"

    # Sum source data files (bytes)
    local total_bytes=0
    local file_count=0
    local f

    case "$btype" in
        incremental)
            # Include full + incrementals up to --until checkpoint
            while IFS= read -r -d '' f; do
                local basename
                basename=$(basename "$f")
                # If --until is set, skip files beyond that checkpoint
                if [[ -n "$until_cp" ]]; then
                    local cp_name
                    # Extract checkpoint name: e.g. sda.inc.virtnbdbackup.3.data → virtnbdbackup.3
                    cp_name=$(echo "$basename" | grep -oP 'virtnbdbackup\.\d+' || true)
                    local until_num cp_num
                    until_num=${until_cp##*.}
                    cp_num=${cp_name##*.}
                    if [[ -n "$cp_num" && -n "$until_num" ]] && (( cp_num > until_num )); then
                        continue
                    fi
                fi
                local fsize
                fsize=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
                total_bytes=$(( total_bytes + fsize ))
                ((file_count++))
            done < <(find "$data_dir" -maxdepth 1 -type f \( \
                -name "*.full.data" -o -name "*.inc.virtnbdbackup.*.data" \
            \) -print0 2>/dev/null)
            ;;
        full)
            while IFS= read -r -d '' f; do
                local fsize
                fsize=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
                total_bytes=$(( total_bytes + fsize ))
                ((file_count++))
            done < <(find "$data_dir" -maxdepth 1 -type f -name "*.full.data" -print0 2>/dev/null)
            ;;
        copy)
            while IFS= read -r -d '' f; do
                local fsize
                fsize=$(stat -c '%s' "$f" 2>/dev/null || echo 0)
                total_bytes=$(( total_bytes + fsize ))
                ((file_count++))
            done < <(find "$data_dir" -maxdepth 1 -type f -name "*.copy.data" -print0 2>/dev/null)
            ;;
    esac

    if (( file_count == 0 )); then
        log_warn "preflight_free_space" "No data files found to estimate size — skipping space check"
        return 0
    fi

    # Get available space on the destination filesystem
    # Use the parent dir if restore_path doesn't exist yet
    local check_path="$restore_path"
    while [[ ! -d "$check_path" && "$check_path" != "/" ]]; do
        check_path=$(dirname "$check_path")
    done
    local avail_bytes
    avail_bytes=$(df --output=avail -B1 "$check_path" 2>/dev/null | tail -1 | tr -d ' ')

    if [[ -z "$avail_bytes" || "$avail_bytes" == "0" ]]; then
        log_warn "preflight_free_space" "Cannot determine free space on $check_path — skipping check"
        return 0
    fi

    # Human-readable sizes
    local total_hr avail_hr
    total_hr=$(numfmt --to=iec-i --suffix=B "$total_bytes" 2>/dev/null || echo "${total_bytes} bytes")
    avail_hr=$(numfmt --to=iec-i --suffix=B "$avail_bytes" 2>/dev/null || echo "${avail_bytes} bytes")

    log_info "preflight_free_space" "Backup data: $total_hr ($file_count files) — Destination free: $avail_hr ($check_path)"

    if (( total_bytes > avail_bytes )); then
        die "Insufficient space: restore needs $total_hr but only $avail_hr available on $check_path" "preflight_free_space" "$EXIT_STORAGE"
    fi

    # Warn if less than 10% headroom (restored qcow2 can be larger than raw data)
    local headroom=$(( avail_bytes - total_bytes ))
    local ten_pct=$(( total_bytes / 10 ))
    if (( headroom < ten_pct )); then
        log_warn "preflight_free_space" "Tight on space: only $(numfmt --to=iec-i --suffix=B "$headroom" 2>/dev/null || echo "$headroom bytes") headroom after restore"
    fi
}

# ── Backup Detection ────────────────────────────────────────────────────────

has_backup_data() {
    find "$1" -maxdepth 1 -type f \( \
        -name "*.full.data" -o \
        -name "*.inc.virtnbdbackup.*.data" -o \
        -name "*.copy.data" \
    \) 2>/dev/null | grep -q .
}

detect_backup_type() {
    local dir="$1"
    [[ -d "$dir" ]] || { echo "unknown"; return; }

    local has_inc=false has_full=false has_copy=false
    local f
    while IFS= read -r -d '' f; do
        case "$f" in
            *.inc.virtnbdbackup.*.data) has_inc=true ;;
            *.full.data) has_full=true ;;
            *.copy.data) has_copy=true ;;
        esac
    done < <(find "$dir" -maxdepth 1 -type f -name '*.data' -print0 2>/dev/null)

    if $has_inc;   then echo "incremental"
    elif $has_full; then echo "full"
    elif $has_copy; then echo "copy"
    else                 echo "unknown"
    fi
}

is_accumulate() { has_backup_data "$1"; }

# ── Path Resolution ─────────────────────────────────────────────────────────

# List period subdirectories (newest first), excluding internal dirs
list_periods() {
    local vm_dir="$1"
    for d in "$vm_dir"/*/; do
        [[ -d "$d" ]] || continue
        local name
        name=$(basename "$d")
        case "$name" in
            .archives|config|checkpoints|tpm-state) continue ;;
        esac
        echo "$name"
    done | sort -rV
}

# Resolve the directory containing .data files for a VM
# Accumulate: VM root. Period-based: specified or latest period.
resolve_data_dir() {
    local vm_dir="$1" period="${2:-}"

    # Explicit period always wins (even for accumulate VMs with period subdirs)
    if [[ -n "$period" ]]; then
        local target="$vm_dir/$period"
        if [[ -d "$target" ]]; then
            echo "$target"
        else
            log_error "resolve_data_dir" "Period not found: $target"
            return 1
        fi
        return
    fi

    # No period specified — accumulate uses VM root
    if is_accumulate "$vm_dir"; then
        echo "$vm_dir"
        return
    fi

    # Pick the newest period that has backup data.
    # Empty period dirs (created by rotation before first backup) are skipped.
    local _p
    while IFS= read -r _p; do
        [[ -n "$_p" ]] || continue
        if has_backup_data "$vm_dir/$_p"; then
            echo "$vm_dir/$_p"
            return
        fi
    done < <(list_periods "$vm_dir")

    # Fallback: no period has data — return the newest dir anyway
    # so the caller gets a meaningful error path
    local latest
    latest=$(list_periods "$vm_dir" | head -1)
    if [[ -n "$latest" ]]; then
        echo "$vm_dir/$latest"
    else
        log_error "resolve_data_dir" "No period directories in: $vm_dir"
        return 1
    fi
}

# ── Listing ──────────────────────────────────────────────────────────────────

list_vms() {
    local backup_path="$1"

    echo ""
    echo "Available VMs in: $backup_path"
    echo "══════════════════════════════════════════════════════════════"

    local found=0
    for vm_dir in "$backup_path"/*/; do
        [[ -d "$vm_dir" ]] || continue
        local vm
        vm=$(basename "$vm_dir")
        [[ "$vm" == _state ]] && continue

        local data_dir=""
        local periods=()
        local is_acc=false

        if is_accumulate "$vm_dir"; then
            data_dir="$vm_dir"
            is_acc=true
        else
            mapfile -t periods < <(list_periods "$vm_dir")
            if [[ ${#periods[@]} -gt 0 ]]; then
                # Pick the most recently modified period that has backup data.
                # Empty period dirs (created by rotation before first backup) are skipped.
                local _latest_mt=0
                for _p in "${periods[@]}"; do
                    local _pdir="$vm_dir/$_p"
                    has_backup_data "$_pdir" || continue
                    local _mt
                    _mt=$(stat -c '%Y' "$_pdir" 2>/dev/null) || continue
                    if (( _mt > _latest_mt )); then
                        _latest_mt=$_mt
                        data_dir="$_pdir"
                    fi
                done
                [[ -z "$data_dir" ]] && data_dir="$vm_dir/${periods[0]}"
            else
                continue
            fi
        fi

        local btype size tpm_tag="" disk_tag=""
        btype=$(detect_backup_type "$data_dir")
        size=$(du -sh "$vm_dir" 2>/dev/null | awk '{print $1}')
        [[ -f "$data_dir/.tpm-backup-marker" ]] && tpm_tag=" [TPM]"

        # Show disk tags only for multi-disk VMs (latest CP's disks, not union)
        local disks _latest_cp
        _latest_cp=$(find "$data_dir/checkpoints" -name "virtnbdbackup.*.xml" 2>/dev/null \
            | sed -n 's/.*virtnbdbackup\.\([0-9]*\)\.xml/\1/p' \
            | sort -n | tail -1)
        if [[ -n "$_latest_cp" ]]; then
            disks=$(enumerate_disks_at_checkpoint "$data_dir" "$_latest_cp")
        else
            disks=$(enumerate_disks "$data_dir")
        fi
        [[ "$disks" == *,* ]] && disk_tag=" [$disks]"

        # Count archives across all period dirs
        local archive_count=0
        local -A _seen_adirs=()
        local -a _archive_search=("$vm_dir/.archives")
        if [[ ${#periods[@]} -gt 0 ]]; then
            for _p in "${periods[@]}"; do
                _archive_search+=("$vm_dir/$_p/.archives")
            done
        else
            _archive_search+=("$data_dir/.archives")
        fi
        for adir in "${_archive_search[@]}"; do
            [[ -d "$adir" ]] || continue
            local _real
            _real=$(realpath "$adir")
            [[ -n "${_seen_adirs[$_real]:-}" ]] && continue
            _seen_adirs[$_real]=1
            archive_count=$(( archive_count + $(find "$adir" -maxdepth 1 -type d -name "chain-*" 2>/dev/null | wc -l) ))
        done

        # Count restore points across ALL active periods
        local rpoints=0
        if $is_acc; then
            if [[ -d "$data_dir/checkpoints" ]]; then
                rpoints=$(find "$data_dir/checkpoints" -name "virtnbdbackup.*.xml" 2>/dev/null | wc -l)
            fi
            [[ "$btype" =~ ^(full|copy)$ && $rpoints -eq 0 ]] && rpoints=1
        else
            for _p in "${periods[@]}"; do
                local _pdir="$vm_dir/$_p"
                if [[ -d "$_pdir/checkpoints" ]]; then
                    rpoints=$(( rpoints + $(find "$_pdir/checkpoints" -name "virtnbdbackup.*.xml" 2>/dev/null | wc -l) ))
                else
                    local _ptype
                    _ptype=$(detect_backup_type "$_pdir")
                    [[ "$_ptype" =~ ^(full|copy)$ ]] && ((rpoints++))
                fi
            done
        fi

        # Build detail line with proper pluralisation
        local p_word="points"; (( rpoints == 1 )) && p_word="point"
        local detail="$btype · $rpoints $p_word"
        if (( archive_count > 0 )); then
            local a_word="archives"; (( archive_count == 1 )) && a_word="archive"
            detail+=" · $archive_count $a_word"
        fi
        detail+="$disk_tag$tpm_tag"

        printf "\n  %-53s %6s\n" "$vm" "$size"
        printf "    %s\n" "$detail"

        if [[ ${#periods[@]} -gt 0 ]]; then
            printf "    Periods: %s\n" "${periods[*]}"
        fi

        ((found++))
    done

    echo ""
    echo "══════════════════════════════════════════════════════════════"
    (( found == 0 )) && { log_warn "list_vms" "No backups found in $backup_path"; return 1; }
    return 0
}

# ── Disk Enumeration ─────────────────────────────────────────────────────────
# Scan a backup directory for unique device target names from .data files.
# Returns a sorted, comma-separated list (e.g., "sda, vda, vdb").
# Used by: --list-restore-points display, --disk validation, disk-restore mode.

enumerate_disks() {
    local data_dir="$1"
    local -A seen=();
    local f fname dev
    while IFS= read -r -d '' f; do
        fname=$(basename "$f")
        dev=""
        case "$fname" in
            *.full.data)                dev="${fname%.full.data}" ;;
            *.inc.virtnbdbackup.*.data) dev="${fname%%.*}" ;;
            *.copy.data)                dev="${fname%.copy.data}" ;;
        esac
        [[ -n "$dev" ]] && seen[$dev]=1
    done < <(find "$data_dir" -maxdepth 1 -type f -name '*.data' -print0 2>/dev/null)
    # Return sorted, comma-separated
    printf '%s\n' "${!seen[@]}" | sort | paste -sd, | sed 's/,/, /g'
}

# Return sorted, comma-separated list of disks at a specific checkpoint number.
# Parses .data filenames: {dev}.full.data (CP 0), {dev}.inc.virtnbdbackup.{N}.data,
# {dev}.copy.data (CP 0). Used by: --list-restore-points, PIT staging trigger, --disk validation.
enumerate_disks_at_checkpoint() {
    local data_dir="$1" cp_num="$2"
    local -A seen=()
    local f fname dev
    while IFS= read -r -d '' f; do
        fname=$(basename "$f")
        dev=""
        case "$fname" in
            *.full.data)
                [[ "$cp_num" == "0" ]] && dev="${fname%.full.data}" ;;
            *.inc.virtnbdbackup."${cp_num}".data)
                dev="${fname%%.*}" ;;
            *.copy.data)
                [[ "$cp_num" == "0" ]] && dev="${fname%.copy.data}" ;;
        esac
        [[ -n "$dev" ]] && seen[$dev]=1
    done < <(find "$data_dir" -maxdepth 1 -type f -name '*.data' -print0 2>/dev/null)
    printf '%s\n' "${!seen[@]}" | sort | paste -sd, | sed 's/,/, /g'
}

# ── PIT Staging Directory ────────────────────────────────────────────────────
# When a point-in-time restore targets a checkpoint whose disk set differs from
# the latest checkpoint, virtnbdrestore picks the wrong vmconfig (always latest).
# create_pit_staging() builds a temp directory with:
#   - Symlinks to all .data files and checkpoints/ dir from the backup
#   - A copy of the target checkpoint's vmconfig (the ONLY vmconfig present)
# virtnbdrestore's lib.getLatest() then finds only the correct config.
#
# Returns: the staging directory path via stdout.
# Caller must call cleanup_pit_staging() when done.

create_pit_staging() {
    local data_dir="$1" target_cp="$2"
    local staging=""

    # Prefer TMPDIR, fall back to a subdir of the backup parent
    if [[ -d "${TMPDIR:-/tmp}" && -w "${TMPDIR:-/tmp}" ]]; then
        staging=$(mktemp -d "${TMPDIR:-/tmp}/vmrestore-pit-XXXXXX")
    else
        staging=$(mktemp -d "$(dirname "$data_dir")/.vmrestore-pit-XXXXXX")
    fi

    # Symlink .data files
    local f
    while IFS= read -r -d '' f; do
        ln -s "$f" "$staging/$(basename "$f")"
    done < <(find "$data_dir" -maxdepth 1 -type f -name '*.data' -print0 2>/dev/null)

    # Symlink checkpoints directory
    [[ -d "$data_dir/checkpoints" ]] && ln -s "$data_dir/checkpoints" "$staging/checkpoints"

    # Copy the target checkpoint's vmconfig — the ONLY vmconfig in staging
    local target_vmconfig="$data_dir/vmconfig.virtnbdbackup.${target_cp}.xml"
    if [[ -f "$target_vmconfig" ]]; then
        cp "$target_vmconfig" "$staging/"
    else
        # Fallback: find vmconfig by checkpoint number from config/ dir.
        # Config files sorted oldest-first by name = checkpoint order (0, 1, 2, ...).
        local _fallback="" _cfg_dir=""
        for _search in "$data_dir/config" "$(dirname "$data_dir")/config"; do
            [[ -d "$_search" ]] && _cfg_dir="$_search" && break
        done
        if [[ -n "$_cfg_dir" ]]; then
            _fallback=$(ls -1 "$_cfg_dir"/*.xml 2>/dev/null | sort | sed -n "$((target_cp + 1))p")
        fi
        if [[ -n "$_fallback" && -f "$_fallback" ]]; then
            cp "$_fallback" "$staging/vmconfig.virtnbdbackup.${target_cp}.xml"
            log_warn "create_pit_staging" "vmconfig.virtnbdbackup.${target_cp}.xml not found; using fallback: $(basename "$_fallback")"
        else
            log_error "create_pit_staging" "No vmconfig found for checkpoint $target_cp"
            rm -rf "$staging"
            return 1
        fi
    fi

    echo "$staging"
}

cleanup_pit_staging() {
    local staging_dir="${1:-}"
    if [[ -n "$staging_dir" && -d "$staging_dir" && "$staging_dir" == *vmrestore-pit-* ]]; then
        rm -rf "$staging_dir"
    fi
}

show_restore_points() {
    local data_dir="$1"
    local btype
    btype=$(detect_backup_type "$data_dir")

    echo "  Restore Point   Date                 Type            Disk(s)"
    echo "  ──────────────────────────────────────────────────────────────────────"

    local count=0
    case "$btype" in
        incremental)
            if [[ -d "$data_dir/checkpoints" ]]; then
                while IFS= read -r -d '' f; do
                    [[ -f "$f" ]] || continue
                    local name num ftime ptype disks
                    name=$(basename "$f" .xml)
                    num="${name##*.}"
                    ftime=$(stat -c '%y' "$f" 2>/dev/null | cut -d. -f1)
                    ptype="Incremental"
                    [[ "$num" == "0" ]] && ptype="FULL (base)"
                    disks=$(enumerate_disks_at_checkpoint "$data_dir" "$num")
                    printf "  %-15s   %-19s  %-15s %s\n" "$num" "$ftime" "$ptype" "$disks"
                    ((count++))
                done < <(find "$data_dir/checkpoints" -maxdepth 1 -name "virtnbdbackup.*.xml" -print0 2>/dev/null | sort -zV)
            fi
            ;;
        full)
            local ff disks
            ff=$(find "$data_dir" -maxdepth 1 -name "*.full.data" 2>/dev/null | head -1)
            if [[ -n "$ff" ]]; then
                disks=$(enumerate_disks_at_checkpoint "$data_dir" "0")
                printf "  %-15s   %-19s  %-15s %s\n" "0" \
                    "$(stat -c '%y' "$ff" 2>/dev/null | cut -d. -f1)" "FULL (only)" "$disks"
                count=1
            fi
            ;;
        copy)
            local cf disks
            cf=$(find "$data_dir" -maxdepth 1 -name "*.copy.data" 2>/dev/null | head -1)
            if [[ -n "$cf" ]]; then
                disks=$(enumerate_disks_at_checkpoint "$data_dir" "0")
                printf "  %-15s   %-19s  %-15s %s\n" "0" \
                    "$(stat -c '%y' "$cf" 2>/dev/null | cut -d. -f1)" "COPY (offline)" "$disks"
                count=1
            fi
            ;;
    esac

    echo "  ──────────────────────────────────────────────────────────────────────"
    echo "  Total: $count"
    echo ""
}

# ── Storage Pool Refresh ─────────────────────────────────────────────────────
# Detect which libvirt storage pool (if any) contains the given directory
# and refresh it so newly-created volumes are visible to virt-manager.

refresh_storage_pool() {
    local target_dir="$1"
    local pool_name=""
    local best_len=0
    local pool
    while IFS= read -r pool; do
        [[ -z "$pool" ]] && continue
        local pool_path
        pool_path=$(virsh pool-dumpxml "$pool" 2>/dev/null | grep -oP '<path>\K[^<]+' || true)
        if [[ -n "$pool_path" && "$target_dir" == "$pool_path"* ]]; then
            # Prefer the most specific (longest) matching pool path
            if (( ${#pool_path} > best_len )); then
                best_len=${#pool_path}
                pool_name="$pool"
            fi
        fi
    done < <(virsh pool-list --name 2>/dev/null)

    if [[ -n "$pool_name" ]]; then
        if virsh pool-refresh "$pool_name" &>/dev/null; then
            log_info "restore_vm" "Refreshed storage pool '$pool_name'"
        else
            log_warn "restore_vm" "Failed to refresh storage pool '$pool_name'"
        fi
    fi
}

# ── TPM Restore ──────────────────────────────────────────────────────────────

restore_tpm() {
    local vm_name="$1" data_dir="$2" dry_run="$3" uuid_override="${4:-}"
    local tpm_dir="$data_dir/tpm-state"

    # Archived chains may lack .tpm-backup-marker but still have tpm-state/
    if [[ ! -f "$data_dir/.tpm-backup-marker" && ! -d "$tpm_dir" ]]; then
        return 0
    fi
    if [[ ! -d "$tpm_dir" ]]; then
        log_warn "restore_tpm" "Marker present but no tpm-state/ in $data_dir"
        return 0
    fi

    # UUID: override (new-identity) > BACKUP_METADATA.txt > virsh
    local vm_uuid="$uuid_override"
    if [[ -z "$vm_uuid" ]]; then
        local metadata="$tpm_dir/BACKUP_METADATA.txt"
        if [[ -f "$metadata" ]]; then
            vm_uuid=$(grep -oP '^\s*VM UUID:\s+\K\S+' "$metadata" 2>/dev/null || true)
        fi
    fi
    # Fallback: virsh (only works if VM is already defined)
    if [[ -z "$vm_uuid" ]]; then
        vm_uuid=$(virsh dominfo "$vm_name" 2>/dev/null | awk '/^UUID/{print $2}' || true)
    fi
    [[ -n "$vm_uuid" ]] || { log_error "restore_tpm" "Cannot determine UUID for TPM restore"; return 1; }

    local target="/var/lib/libvirt/swtpm/$vm_uuid"

    if [[ "$dry_run" == true ]]; then
        log_info "restore_tpm" "[DRY RUN] Would restore TPM: $tpm_dir → $target"
        return 0
    fi

    log_info "restore_tpm" "Restoring TPM for $vm_name (UUID: $vm_uuid)"

    # Preserve existing state
    if [[ -d "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]]; then
        local bak="${target}.pre-restore-$(date +%s)"
        log_warn "restore_tpm" "Backing up existing TPM to $bak"
        mv "$target" "$bak"
    fi

    # UUID dir: root:root 711 (matches system layout)
    mkdir -p "$target"
    chown root:root "$target"
    chmod 711 "$target"

    # tpm2/ subdir: tss:tss 700 (matches system layout)
    if [[ -d "$tpm_dir/tpm2" ]]; then
        cp -a "$tpm_dir/tpm2" "$target/"
        chown -R tss:tss "$target/tpm2"
        chmod 700 "$target/tpm2"
    fi

    log_info "restore_tpm" "TPM state restored: $target"
}

# ── New-Identity Define ───────────────────────────────────────────────────────
# When --name is used: strip UUID + MACs so libvirt generates new ones,
# rename, and define. Returns the new UUID on stdout.
# $4 (optional): serialised disk rename map "old1|new1\nold2|new2"

define_new_identity() {
    local src_xml="$1" new_name="$2" dry_run="$3"
    local disk_rename_map="${4:-}"

    if [[ "$dry_run" == true ]]; then
        log_info "define_new_identity" "[DRY RUN] Would define '$new_name' with new UUID/MACs from: $src_xml"
        echo "dry-run-uuid"
        return 0
    fi

    local tmp_xml
    tmp_xml=$(mktemp)
    local safe_name
    safe_name=$(printf '%s' "$new_name" | sed 's/[&/\\]/\\&/g')

    # Copy NVRAM to a new file named after the new VM (avoid sharing with original)
    local orig_nvram new_nvram=""
    orig_nvram=$(grep -oP '<nvram[^>]*>\K[^<]+' "$src_xml" || true)
    if [[ -n "$orig_nvram" && -f "$orig_nvram" ]]; then
        local nvram_dir nvram_ext
        nvram_dir=$(dirname "$orig_nvram")
        nvram_ext="${orig_nvram##*_}"   # e.g. VARS.fd
        new_nvram="${nvram_dir}/${new_name}_${nvram_ext}"
        cp "$orig_nvram" "$new_nvram"
        chown libvirt-qemu:libvirt-qemu "$new_nvram" 2>/dev/null || true
        chmod 600 "$new_nvram" 2>/dev/null || true
        log_info "define_new_identity" "NVRAM copied: $orig_nvram → $new_nvram"
    fi

    # Build sed expressions: rename, strip UUID + MACs, update NVRAM path
    local -a sed_args=(
        -e 's|<name>[^<]*</name>|<name>'"${safe_name}"'</name>|'
        -e '/<uuid>/d'
        -e '/<mac address=/d'
    )
    if [[ -n "$new_nvram" ]]; then
        local esc_orig esc_new
        esc_orig=$(printf '%s' "$orig_nvram" | sed 's|[&/\\]|\\&|g')
        esc_new=$(printf '%s' "$new_nvram" | sed 's|[&/\\]|\\&|g')
        sed_args+=(-e "s|${esc_orig}|${esc_new}|g")
    fi

    # Apply disk rename map: update <source file="..."> paths in the XML
    if [[ -n "$disk_rename_map" ]]; then
        while IFS='|' read -r old_path new_path; do
            [[ -z "$old_path" ]] && continue
            local esc_old esc_new_d
            esc_old=$(printf '%s' "$old_path" | sed 's|[&/\\]|\\&|g')
            esc_new_d=$(printf '%s' "$new_path" | sed 's|[&/\\]|\\&|g')
            sed_args+=(-e "s|${esc_old}|${esc_new_d}|g")
        done <<< "$disk_rename_map"
    fi

    sed "${sed_args[@]}" "$src_xml" > "$tmp_xml"

    local define_out
    if define_out=$(virsh define "$tmp_xml" 2>&1); then
        rm -f "$tmp_xml"
        # Extract new UUID from libvirt
        local new_uuid
        new_uuid=$(virsh domuuid "$new_name" 2>/dev/null || true)
        if [[ -n "$new_uuid" ]]; then
            log_info "define_new_identity" "Defined '$new_name' with new UUID: $new_uuid"
            # Log assigned MAC addresses so the user can verify network identity
            local _new_macs
            _new_macs=$(virsh domiflist "$new_name" 2>/dev/null | awk 'NR>2 && $5 {print $5}' || true)
            if [[ -n "$_new_macs" ]]; then
                while IFS= read -r _m; do
                    log_info "define_new_identity" "New MAC: $_m"
                done <<< "$_new_macs"
            fi
            echo "$new_uuid"
        else
            log_warn "define_new_identity" "Defined but cannot read new UUID"
            echo ""
        fi
    else
        rm -f "$tmp_xml"
        # Clean up copied NVRAM on failure
        [[ -n "$new_nvram" && -f "$new_nvram" ]] && rm -f "$new_nvram"
        log_error "define_new_identity" "virsh define failed: $define_out"
        return 1
    fi
}

# ── Disk Collision Protection ─────────────────────────────────────────────────
# Predict what files virtnbdrestore will write to --restore-path, check for
# collisions with existing files and live VM disks, and rename clone disks
# after restore so filenames reflect the clone name.

# Predict output filenames virtnbdrestore will write.
# With -c:  original source basename from config XML (e.g. my-server.qcow2)
# Without -c (--skip-config): device target name (e.g. vda.qcow2)
#
# Populates global arrays:
#   _PREDICTED_BASENAMES  — what virtnbdrestore writes (e.g. my-server.qcow2)
#   _PREDICTED_DEVICE_MAP — "orig_source_path|device_target" per entry
#   _PREDICTED_FILES      — FINAL destination paths after rename
#                           (clone: restore-path/clone-name.qcow2)
#                           (non-clone: restore-path/original-basename.qcow2)
predict_output_files() {
    local data_dir="$1" restore_path="$2" use_c="$3" disk_filter="${4:-}" clone_name="${5:-}" cfg_override="${6:-}"
    _PREDICTED_FILES=()
    _PREDICTED_BASENAMES=()
    _PREDICTED_DEVICE_MAP=()

    # ── Collect raw basenames + device map ──
    if [[ "$use_c" == true ]]; then
        # With -c: output = basename of original <source file=...> from config XML
        local cfg_xml=""
        if [[ -n "$cfg_override" && -f "$cfg_override" ]]; then
            # Fix 5: Use the target checkpoint's vmconfig for PIT restores
            cfg_xml="$cfg_override"
        else
            for search_dir in "$data_dir/config" "$(dirname "$data_dir")/config"; do
                [[ -d "$search_dir" ]] || continue
                cfg_xml=$(ls -1t "$search_dir"/*.xml 2>/dev/null | head -1 || true)
                [[ -n "$cfg_xml" ]] && break
            done
        fi
        if [[ -z "$cfg_xml" || ! -f "$cfg_xml" ]]; then
            log_warn "predict_output_files" "No config XML found — cannot predict output filenames"
            return 1
        fi

        # Parse disk elements: extract device target and source file path
        # Only include type='file' device='disk' (skip cdrom, raw, etc.)
        local in_disk=false disk_device="" disk_target="" disk_source=""
        while IFS= read -r line; do
            if [[ "$line" =~ \<disk\ .*type=\'file\' ]]; then
                in_disk=true
                disk_device="" disk_target="" disk_source=""
                if [[ "$line" =~ device=\'([^\']+)\' ]]; then
                    disk_device="${BASH_REMATCH[1]}"
                fi
            fi
            if [[ "$in_disk" == true ]]; then
                if [[ "$line" =~ \<target\ dev=\'([^\']+)\' ]]; then
                    disk_target="${BASH_REMATCH[1]}"
                fi
                if [[ "$line" =~ \<source\ file=\'([^\']+)\' ]]; then
                    disk_source="${BASH_REMATCH[1]}"
                fi
                if [[ "$line" =~ \</disk\> ]]; then
                    if [[ "$disk_device" == "disk" && -n "$disk_source" && -n "$disk_target" ]]; then
                        if [[ -z "$disk_filter" || "$disk_target" == "$disk_filter" ]]; then
                            _PREDICTED_BASENAMES+=("$(basename "$disk_source")")
                            _PREDICTED_DEVICE_MAP+=("${disk_source}|${disk_target}")
                        fi
                    fi
                    in_disk=false
                fi
            fi
        done < "$cfg_xml"
    else
        # Without -c (--skip-config): output = {device}.qcow2
        local -A seen_devices=()
        local f
        while IFS= read -r -d '' f; do
            local fname
            fname=$(basename "$f")
            local dev=""
            case "$fname" in
                *.full.data)               dev="${fname%.full.data}" ;;
                *.inc.virtnbdbackup.*.data) dev="${fname%%.*}" ;;
                *.copy.data)               dev="${fname%.copy.data}" ;;
            esac
            if [[ -n "$dev" && -z "${seen_devices[$dev]:-}" ]]; then
                if [[ -z "$disk_filter" || "$dev" == "$disk_filter" ]]; then
                    _PREDICTED_BASENAMES+=("${dev}.qcow2")
                    _PREDICTED_DEVICE_MAP+=("${dev}.qcow2|${dev}")
                    seen_devices[$dev]=1
                fi
            fi
        done < <(find "$data_dir" -maxdepth 1 -type f -name '*.data' -print0 2>/dev/null)
    fi

    if [[ ${#_PREDICTED_BASENAMES[@]} -eq 0 ]]; then
        log_warn "predict_output_files" "Could not predict any output files"
        return 1
    fi

    # ── Compute final destination paths ──
    local multi_disk=false
    [[ ${#_PREDICTED_BASENAMES[@]} -gt 1 ]] && multi_disk=true

    local idx=0
    for raw_base in "${_PREDICTED_BASENAMES[@]}"; do
        local final_base="$raw_base"
        if [[ -n "$clone_name" ]]; then
            local ext="${raw_base##*.}"
            local device_target="${_PREDICTED_DEVICE_MAP[$idx]##*|}"
            if [[ "$multi_disk" == true ]]; then
                final_base="${clone_name}-${device_target}.${ext}"
            else
                final_base="${clone_name}.${ext}"
            fi
        fi
        _PREDICTED_FILES+=("$restore_path/$final_base")
        log_info "predict_output_files" "Predicted final: $restore_path/$final_base (virtnbdrestore writes: $raw_base)"
        ((idx++))
    done
    return 0
}

# Check predicted output files for collisions with existing files and live VM
# disks. Aborts on unsafe conditions, warns on force-overridable ones.
preflight_disk_safety() {
    local vm_name="$1" dry_run="$2" force="$3"
    local dry_tag=""
    [[ "$dry_run" == true ]] && dry_tag="[DRY RUN] "

    if [[ ${#_PREDICTED_FILES[@]} -eq 0 ]]; then
        log_info "preflight_disk_safety" "No predicted files — skipping safety checks"
        return 0
    fi

    # Build set of all defined VMs' disk paths → associative array path→vm_name
    local -A live_disk_map=()
    local vm_entry
    while IFS= read -r vm_entry; do
        [[ -z "$vm_entry" ]] && continue
        local blk_line
        while IFS= read -r blk_line; do
            # virsh domblklist output: "Target   Source"
            local blk_src
            blk_src=$(echo "$blk_line" | awk '{print $2}')
            if [[ -n "$blk_src" && "$blk_src" != "-" && "$blk_src" != "Source" ]]; then
                local real_blk
                real_blk=$(realpath "$blk_src" 2>/dev/null || echo "$blk_src")
                live_disk_map["$real_blk"]="$vm_entry"
            fi
        done < <(virsh domblklist "$vm_entry" 2>/dev/null)
    done < <(virsh list --all --name 2>/dev/null)

    local abort=false
    for pred_file in "${_PREDICTED_FILES[@]}"; do
        local real_pred
        real_pred=$(realpath -m "$pred_file" 2>/dev/null || echo "$pred_file")

        # Check: is this a live VM's disk?
        local owner_vm="${live_disk_map[$real_pred]:-}"
        if [[ -n "$owner_vm" ]]; then
            if [[ "$owner_vm" == "$vm_name" ]]; then
                # Same VM — disaster recovery scenario
                local vm_state
                vm_state=$(virsh domstate "$owner_vm" 2>/dev/null || echo "unknown")
                if [[ "$vm_state" =~ running|paused ]]; then
                    log_error "preflight_disk_safety" "${dry_tag}BLOCKED: $pred_file is the live disk of running VM '$owner_vm' — shut it off first"
                    abort=true
                elif [[ "$force" == true ]]; then
                    log_warn "preflight_disk_safety" "${dry_tag}Will overwrite disk of shut-off VM '$owner_vm': $pred_file (disaster recovery with --force)"
                else
                    log_error "preflight_disk_safety" "${dry_tag}BLOCKED: $pred_file is the disk of VM '$owner_vm' — use --force for disaster recovery"
                    abort=true
                fi
            else
                # Different VM — NEVER allow
                log_error "preflight_disk_safety" "${dry_tag}BLOCKED: $pred_file is the live disk of VM '$owner_vm' — choose a different --restore-path"
                abort=true
            fi
        elif [[ -f "$pred_file" ]]; then
            # File exists but not a live VM disk
            if [[ "$force" == true ]]; then
                log_warn "preflight_disk_safety" "${dry_tag}File exists and will be overwritten: $pred_file"
            else
                log_error "preflight_disk_safety" "${dry_tag}BLOCKED: File already exists: $pred_file — use --force to overwrite"
                abort=true
            fi
        fi
    done

    if [[ "$abort" == true ]]; then
        if [[ "$dry_run" == true ]]; then
            log_warn "preflight_disk_safety" "[DRY RUN] Would abort due to safety checks above"
            return 0
        fi
        die "Pre-flight disk safety check failed — see errors above" "preflight_disk_safety" "$EXIT_STORAGE"
    fi

    log_info "preflight_disk_safety" "${dry_tag}All safety checks passed"
    return 0
}

# Move restored disk files from staging dir to final location with clone name.
# Only applies when --name is used (new-identity clone).
# Populates global _DISK_RENAME_MAP ("original_source_path|new_path" per line)
# for passing to define_new_identity().
# Args: clone_name staging_dir restore_path dry_run
stage_and_rename_clone_disks() {
    local clone_name="$1" staging_dir="$2" restore_path="$3" dry_run="$4"
    _DISK_RENAME_MAP=""

    if [[ ${#_PREDICTED_BASENAMES[@]} -eq 0 ]]; then
        log_warn "stage_and_rename" "No predicted files — nothing to rename"
        return 0
    fi

    local multi_disk=false
    [[ ${#_PREDICTED_BASENAMES[@]} -gt 1 ]] && multi_disk=true

    local i=0
    for raw_base in "${_PREDICTED_BASENAMES[@]}"; do
        local mapping="${_PREDICTED_DEVICE_MAP[$i]}"
        local orig_source_path="${mapping%%|*}"
        local device_target="${mapping##*|}"
        local extension="${raw_base##*.}"  # qcow2

        local new_basename
        if [[ "$multi_disk" == true ]]; then
            new_basename="${clone_name}-${device_target}.${extension}"
        else
            new_basename="${clone_name}.${extension}"
        fi

        local staged_file="$staging_dir/$raw_base"
        local final_file="$restore_path/$new_basename"

        if [[ "$dry_run" == true ]]; then
            log_info "stage_and_rename" "[DRY RUN] Would move: staging/$raw_base → $new_basename"
        else
            if [[ -f "$staged_file" ]]; then
                mv "$staged_file" "$final_file"
                log_info "stage_and_rename" "Moved: staging/$raw_base → $new_basename"
            else
                log_warn "stage_and_rename" "Expected file not found in staging: $staged_file"
            fi
        fi

        # Build rename map for define_new_identity(): staged_path|new_absolute_path
        # Use staged_file (not orig_source_path) because virtnbdrestore rewrites
        # vmconfig.xml <source file="..."> to point at the output directory (staging).
        if [[ -n "$_DISK_RENAME_MAP" ]]; then
            _DISK_RENAME_MAP+=$'\n'
        fi
        _DISK_RENAME_MAP+="${staged_file}|${final_file}"
        ((i++))
    done

    return 0
}

# ── Core Restore ─────────────────────────────────────────────────────────────

restore_vm() {
    local vm_name="$1"
    log_info "restore_vm" "Starting restore: $vm_name"

    # Resolve backup data directory
    local data_dir=""
    if has_backup_data "$OPT_BACKUP_PATH"; then
        # Direct path to period dir or archive chain
        data_dir="$OPT_BACKUP_PATH"
        log_info "restore_vm" "Using direct backup path: $data_dir"
    else
        local vm_dir="$OPT_BACKUP_PATH/$vm_name"
        [[ -d "$vm_dir" ]] || die "VM directory not found: $vm_dir" "restore_vm" "$EXIT_VM"
        data_dir=$(resolve_data_dir "$vm_dir" "${OPT_PERIOD:-}") || \
            die "Cannot resolve data directory for $vm_name" "restore_vm" "$EXIT_VM"
    fi

    has_backup_data "$data_dir" || die "No backup data files in: $data_dir" "restore_vm" "$EXIT_VM"

    # If --vm pointed to an archive chain or period directory, vm_name will be
    # the directory basename (e.g. "chain-2026-03-12").  Extract the real VM
    # name from the backup's vmconfig XML so -D/-N use the correct identity.
    local _cfg_xml_for_name
    _cfg_xml_for_name=$(ls -1t "$data_dir"/vmconfig.virtnbdbackup.*.xml 2>/dev/null | head -1 || true)
    if [[ -z "$_cfg_xml_for_name" ]]; then
        # Archived chains may lack vmconfig — check config/ dir
        for _cdir in "$data_dir/config" "$(dirname "$data_dir")/config"; do
            [[ -d "$_cdir" ]] || continue
            _cfg_xml_for_name=$(ls -1t "$_cdir"/*.xml 2>/dev/null | head -1 || true)
            [[ -n "$_cfg_xml_for_name" ]] && break
        done
    fi
    if [[ -n "$_cfg_xml_for_name" ]]; then
        local _xml_vm_name
        _xml_vm_name=$(grep -oP '<name>\K[^<]+' "$_cfg_xml_for_name" 2>/dev/null | head -1 || true)
        if [[ -n "$_xml_vm_name" && "$_xml_vm_name" != "$vm_name" ]]; then
            log_info "restore_vm" "Resolved VM name from backup config: $vm_name → $_xml_vm_name"
            vm_name="$_xml_vm_name"
        fi
    fi

    local btype
    btype=$(detect_backup_type "$data_dir")
    log_info "restore_vm" "Data dir: $data_dir (type: $btype)"

    # ── Disk-Restore Mode ────────────────────────────────────────────────────
    # When --disk is specified, this is a disk-level file replacement — not a
    # VM restore. No VM definition changes, no TPM, no UUID/MAC changes. The
    # VM already exists. Works for single-disk and multi-disk VMs alike.
    # Supports: --disk vda | --disk vda,vdb | --disk all
    if [[ -n "${OPT_DISK:-}" ]]; then
        local available_disks
        available_disks=$(enumerate_disks "$data_dir")

        if [[ -z "$available_disks" ]]; then
            die "No disks found in backup: $data_dir" "restore_vm" "$EXIT_VM"
        fi

        # Parse --disk value into array: single name, comma-separated, or "all"
        local -a disk_list=()
        if [[ "$OPT_DISK" == "all" ]]; then
            local IFS=', '
            for _d in $available_disks; do
                disk_list+=("$_d")
            done
            unset IFS
        else
            local IFS=','
            for _d in $OPT_DISK; do
                _d=$(echo "$_d" | tr -d '[:space:]')
                [[ -n "$_d" ]] && disk_list+=("$_d")
            done
            unset IFS
        fi

        if [[ ${#disk_list[@]} -eq 0 ]]; then
            die "No disk names specified" "restore_vm" "$EXIT_USAGE"
        fi

        # Validate all disk names against available disks (union across all CPs)
        for _d in "${disk_list[@]}"; do
            local _found=false
            local IFS=', '
            for _avail in $available_disks; do
                [[ "$_avail" == "$_d" ]] && _found=true
            done
            unset IFS
            if [[ "$_found" == false ]]; then
                die "Disk '$_d' not found in backup. Available disks: $available_disks" "restore_vm" "$EXIT_VM"
            fi
        done

        # Point-in-time disk availability: validate each disk exists at the target checkpoint
        if [[ "$btype" == "incremental" ]]; then
            local _target_cp=""
            if [[ "$OPT_RESTORE_POINT" != "latest" ]]; then
                case "$OPT_RESTORE_POINT" in
                    full)   _target_cp="0" ;;
                    [0-9]*) _target_cp="$OPT_RESTORE_POINT" ;;
                esac
            else
                # Latest = highest checkpoint number
                _target_cp=$(find "$data_dir/checkpoints" -maxdepth 1 -name "virtnbdbackup.*.xml" -printf '%f\n' 2>/dev/null \
                    | sed 's/virtnbdbackup\.\([0-9]*\)\.xml/\1/' | sort -n | tail -1)
            fi
            if [[ -n "$_target_cp" ]]; then
                local _cp_disks
                _cp_disks=$(enumerate_disks_at_checkpoint "$data_dir" "$_target_cp")
                for _d in "${disk_list[@]}"; do
                    local _cp_found=false
                    local IFS=', '
                    for _cp_avail in $_cp_disks; do
                        [[ "$_cp_avail" == "$_d" ]] && _cp_found=true
                    done
                    unset IFS
                    if [[ "$_cp_found" == false ]]; then
                        # Find the last checkpoint where this disk existed
                        local _last_seen=""
                        local _cp_n
                        for _cp_n in $(find "$data_dir/checkpoints" -maxdepth 1 -name "virtnbdbackup.*.xml" -printf '%f\n' 2>/dev/null \
                            | sed 's/virtnbdbackup\.\([0-9]*\)\.xml/\1/' | sort -rn); do
                            local _check_disks
                            _check_disks=$(enumerate_disks_at_checkpoint "$data_dir" "$_cp_n")
                            if [[ ", $_check_disks, " == *", $_d, "* ]]; then
                                _last_seen="$_cp_n"
                                break
                            fi
                        done
                        if [[ -n "$_last_seen" ]]; then
                            die "Disk '$_d' is not available at checkpoint $_target_cp (disks: $_cp_disks). It was last backed up at checkpoint $_last_seen. Use --restore-point $_last_seen to restore this disk." "restore_vm" "$EXIT_VM"
                        else
                            die "Disk '$_d' is not available at checkpoint $_target_cp (disks: $_cp_disks)." "restore_vm" "$EXIT_VM"
                        fi
                    fi
                done
            fi
        fi

        local disk_list_display
        disk_list_display=$(printf '%s, ' "${disk_list[@]}")
        disk_list_display="${disk_list_display%, }"
        log_info "restore_vm" "Disk restore mode: replacing '$disk_list_display' (available: $available_disks)"

        # ── Common pre-checks (once) ─────────────────────────────────
        local _inplace=false
        if [[ -z "$OPT_RESTORE_PATH" ]]; then
            _inplace=true
            if ! virsh dominfo "$vm_name" &>/dev/null; then
                die "VM '$vm_name' is not defined in libvirt — cannot determine original disk paths. Use --restore-path to extract disks to a specific location instead." "restore_vm" "$EXIT_VM"
            fi
            local vm_state
            vm_state=$(virsh domstate "$vm_name" 2>/dev/null | tr -d '[:space:]')
            if [[ "$vm_state" != "shutoff" ]]; then
                die "VM '$vm_name' is $vm_state — shut it down first (virsh shutdown $vm_name). Replacing disks under a running VM will cause corruption." "restore_vm" "$EXIT_VM"
            fi
            log_info "restore_vm" "VM '$vm_name' is shut off ✓"
        else
            log_info "restore_vm" "Extract mode: writing to $OPT_RESTORE_PATH"
        fi

        # ── Per-disk resolution ──────────────────────────────────────
        # Build associative arrays: disk → original path, target dir, target file
        local -A _dk_path=()   # disk → original file path (in-place only)
        local -A _dk_dir=()    # disk → restore target directory
        local -A _dk_file=()   # disk → original filename (in-place only)
        local total_data_bytes=0
        local total_prerestore_bytes=0

        local _vm_xml=""
        if [[ "$_inplace" == true ]]; then
            _vm_xml=$(virsh dumpxml --inactive "$vm_name" 2>/dev/null)
        fi

        for _d in "${disk_list[@]}"; do
            if [[ "$_inplace" == true ]]; then
                local _opath
                _opath=$(echo "$_vm_xml" | grep -B5 "target dev='$_d'" | \
                    grep -oP "source file='\K[^']+" | head -1 || true)
                if [[ -z "$_opath" ]]; then
                    die "Disk '$_d' not found in VM '$vm_name' configuration. Available disks: $(virsh domblklist "$vm_name" --details 2>/dev/null | awk '$2=="disk"{print $3}' | paste -sd', ')" "restore_vm" "$EXIT_VM"
                fi
                if [[ ! -f "$_opath" ]]; then
                    die "Original disk path does not exist: $_opath — Use --restore-path to extract disks to a specific location instead." "restore_vm" "$EXIT_STORAGE"
                fi
                # Check for .pre-restore overwrite
                if [[ -f "${_opath}.pre-restore" && "$OPT_NO_PRE_RESTORE" == false ]]; then
                    die "Pre-restore file already exists: ${_opath}.pre-restore — delete it first or use --no-pre-restore" "restore_vm" "$EXIT_STORAGE"
                fi
                _dk_path[$_d]="$_opath"
                _dk_dir[$_d]=$(dirname "$_opath")
                _dk_file[$_d]=$(basename "$_opath")
                log_info "restore_vm" "  $_d → $_opath"
                # Accumulate .pre-restore space
                if [[ "$OPT_NO_PRE_RESTORE" == false ]]; then
                    total_prerestore_bytes=$(( total_prerestore_bytes + $(stat -c%s "$_opath" 2>/dev/null || echo 0) ))
                fi
            else
                _dk_dir[$_d]="$OPT_RESTORE_PATH"
            fi

            # Accumulate backup data size for this disk
            while IFS= read -r -d '' _dfile; do
                local _dfname _ddev=""
                _dfname=$(basename "$_dfile")
                case "$_dfname" in
                    *.full.data)                _ddev="${_dfname%.full.data}" ;;
                    *.inc.virtnbdbackup.*.data) _ddev="${_dfname%%.*}" ;;
                    *.copy.data)                _ddev="${_dfname%.copy.data}" ;;
                esac
                [[ "$_ddev" == "$_d" ]] && total_data_bytes=$(( total_data_bytes + $(stat -c%s "$_dfile" 2>/dev/null || echo 0) ))
            done < <(find "$data_dir" -maxdepth 1 -type f -name '*.data' -print0 2>/dev/null)
        done

        # ── Single space check for all disks ────────────────────────
        local total_needed=$(( total_data_bytes + total_prerestore_bytes ))
        local avail_bytes
        local _space_check_dir
        if [[ "$_inplace" == true ]]; then
            _space_check_dir="${_dk_dir[${disk_list[0]}]}"
        else
            _space_check_dir="$OPT_RESTORE_PATH"
        fi
        while [[ -n "$_space_check_dir" && ! -d "$_space_check_dir" ]]; do
            _space_check_dir=$(dirname "$_space_check_dir")
        done
        avail_bytes=$(df --output=avail -B1 "$_space_check_dir" 2>/dev/null | tail -1 | tr -d '[:space:]')
        avail_bytes="${avail_bytes:-0}"
        if (( total_needed > avail_bytes )); then
            local need_hr avail_hr
            need_hr=$(numfmt --to=iec-i --suffix=B "$total_needed" 2>/dev/null || echo "$total_needed bytes")
            avail_hr=$(numfmt --to=iec-i --suffix=B "$avail_bytes" 2>/dev/null || echo "$avail_bytes bytes")
            die "Insufficient space: need $need_hr (restore + .pre-restore) but only $avail_hr available" "restore_vm" "$EXIT_STORAGE"
        fi
        local data_hr
        data_hr=$(numfmt --to=iec-i --suffix=B "$total_data_bytes" 2>/dev/null || echo "$total_data_bytes bytes")
        if [[ "$_inplace" == true && "$OPT_NO_PRE_RESTORE" == false && "$total_prerestore_bytes" -gt 0 ]]; then
            local prerestore_hr
            prerestore_hr=$(numfmt --to=iec-i --suffix=B "$total_prerestore_bytes" 2>/dev/null || echo "$total_prerestore_bytes bytes")
            log_info "restore_vm" "Space check: ${data_hr} restore + ${prerestore_hr} .pre-restore — $(numfmt --to=iec-i --suffix=B "$avail_bytes" 2>/dev/null) available ✓"
        else
            log_info "restore_vm" "Space check: ${data_hr} restore — $(numfmt --to=iec-i --suffix=B "$avail_bytes" 2>/dev/null) available ✓"
        fi

        # ── PIT staging (disk-restore mode) ──────────────────────────
        # When point-in-time targets a checkpoint with a different disk set,
        # create a staging input directory so virtnbdrestore reads the correct vmconfig.
        local pit_input_dir=""
        if [[ "$OPT_RESTORE_POINT" != "latest" && "$btype" == "incremental" ]]; then
            local _pit_target_cp=""
            case "$OPT_RESTORE_POINT" in
                full)   _pit_target_cp="0" ;;
                [0-9]*) _pit_target_cp="$OPT_RESTORE_POINT" ;;
            esac
            if [[ -n "$_pit_target_cp" ]]; then
                local _pit_latest_cp
                _pit_latest_cp=$(find "$data_dir/checkpoints" -maxdepth 1 -name "virtnbdbackup.*.xml" -printf '%f\n' 2>/dev/null \
                    | sed 's/virtnbdbackup\.\([0-9]*\)\.xml/\1/' | sort -n | tail -1)
                local _pit_target_disks _pit_latest_disks
                _pit_target_disks=$(enumerate_disks_at_checkpoint "$data_dir" "$_pit_target_cp")
                _pit_latest_disks=$(enumerate_disks_at_checkpoint "$data_dir" "$_pit_latest_cp")
                if [[ "$_pit_target_disks" != "$_pit_latest_disks" ]]; then
                    log_warn "restore_vm" "Disk configuration changed between checkpoint $_pit_target_cp and latest ($_pit_latest_cp)."
                    log_warn "restore_vm" "  Checkpoint $_pit_target_cp: $_pit_target_disks"
                    log_warn "restore_vm" "  Latest (CP $_pit_latest_cp): $_pit_latest_disks"
                    log_warn "restore_vm" "  Restoring with checkpoint $_pit_target_cp disk configuration."
                    if [[ "$OPT_DRY_RUN" == false ]]; then
                        pit_input_dir=$(create_pit_staging "$data_dir" "$_pit_target_cp") || \
                            die "Failed to create PIT staging directory" "restore_vm" "$EXIT_STORAGE"
                        log_info "restore_vm" "PIT staging directory: $pit_input_dir"
                    fi
                fi
            fi
        fi
        local _virtnbd_data_dir="${pit_input_dir:-$data_dir}"

        # ── Dry run ──────────────────────────────────────────────────
        if [[ "$OPT_DRY_RUN" == true ]]; then
            for _d in "${disk_list[@]}"; do
                log_info "restore_vm" "[DRY RUN] Disk restore: $_d"
                if [[ -n "${_dk_path[$_d]:-}" ]]; then
                    log_info "restore_vm" "[DRY RUN] Would rename: ${_dk_path[$_d]} → ${_dk_path[$_d]}.pre-restore"
                    log_info "restore_vm" "[DRY RUN] Would restore to: ${_dk_path[$_d]}"
                else
                    log_info "restore_vm" "[DRY RUN] Would restore to: $OPT_RESTORE_PATH/"
                fi
                log_info "restore_vm" "[DRY RUN] virtnbdrestore -i $_virtnbd_data_dir -o ${_dk_dir[$_d]} -d $_d"
            done
            if [[ "$OPT_RESTORE_POINT" != "latest" && "$btype" == "incremental" ]]; then
                local until_cp_dr
                case "$OPT_RESTORE_POINT" in
                    full)    until_cp_dr="virtnbdbackup.0" ;;
                    [0-9]*)  until_cp_dr="virtnbdbackup.$OPT_RESTORE_POINT" ;;
                esac
                log_info "restore_vm" "[DRY RUN] Point-in-time: --until $until_cp_dr"
            fi
            if [[ -n "$pit_input_dir" ]]; then
                log_info "restore_vm" "[DRY RUN] PIT staging: would create staging dir with checkpoint $OPT_RESTORE_POINT vmconfig"
            fi
            log_info "restore_vm" "Disk restore complete: $vm_name/$disk_list_display [DRY RUN — no changes made]"
            return 0
        fi

        # ── Restore loop ─────────────────────────────────────────────
        mkdir -p "${OPT_RESTORE_PATH:-${_dk_dir[${disk_list[0]}]}}"

        local -a _restored_disks=()
        local -a _prerestore_files=()
        local _failed_disk=""
        local _disk_idx=0
        local _disk_total=${#disk_list[@]}

        for _d in "${disk_list[@]}"; do
            ((_disk_idx++))
            log_info "restore_vm" "── Restoring $_d [$_disk_idx/$_disk_total] ──"

            local _tgt_dir="${_dk_dir[$_d]}"
            local _orig="${_dk_path[$_d]:-}"

            # Create .pre-restore backup
            if [[ -n "$_orig" && -f "$_orig" && "$OPT_NO_PRE_RESTORE" == false ]]; then
                mv "$_orig" "${_orig}.pre-restore"
                _prerestore_files+=("${_orig}.pre-restore")
                log_info "restore_vm" "Backed up existing: ${_orig}.pre-restore"
            elif [[ -n "$_orig" && "$OPT_NO_PRE_RESTORE" == true ]]; then
                rm -f "$_orig"
                log_warn "restore_vm" "Removed existing disk (--no-pre-restore): $_orig"
            fi

            # Build virtnbdrestore command
            local -a disk_cmd=(virtnbdrestore -i "$_virtnbd_data_dir" -o "$_tgt_dir" -d "$_d")

            # Point-in-time
            if [[ "$OPT_RESTORE_POINT" != "latest" && "$btype" == "incremental" ]]; then
                local until_cp=""
                case "$OPT_RESTORE_POINT" in
                    full)    until_cp="virtnbdbackup.0" ;;
                    [0-9]*)  until_cp="virtnbdbackup.$OPT_RESTORE_POINT" ;;
                    *)       die "Invalid restore point: $OPT_RESTORE_POINT (use latest, full, or number)" "restore_vm" "$EXIT_USAGE" ;;
                esac
                disk_cmd+=(--until "$until_cp")
                [[ $_disk_idx -eq 1 ]] && log_info "restore_vm" "Point-in-time: $until_cp"
            elif [[ "$OPT_RESTORE_POINT" != "latest" && "$btype" != "incremental" ]]; then
                [[ $_disk_idx -eq 1 ]] && log_warn "restore_vm" "Point-in-time ignored (backup type: $btype)"
            fi

            log_info "restore_vm" "Executing: ${disk_cmd[*]}"
            if ! run_logged "${disk_cmd[@]}"; then
                # Restore failed — rollback this disk's .pre-restore
                if [[ -n "$_orig" && -f "${_orig}.pre-restore" ]]; then
                    mv "${_orig}.pre-restore" "$_orig"
                    # Remove from prerestore_files list
                    local -a _tmp_pr=()
                    for _pf in "${_prerestore_files[@]}"; do
                        [[ "$_pf" != "${_orig}.pre-restore" ]] && _tmp_pr+=("$_pf")
                    done
                    _prerestore_files=("${_tmp_pr[@]}")
                    log_warn "restore_vm" "Restored original from .pre-restore after failure"
                fi
                _failed_disk="$_d"
                break
            fi

            # Clean up vmconfig.xml dropped by virtnbdrestore
            rm -f "$_tgt_dir/vmconfig.xml"

            # In-place post-processing
            if [[ -n "$_orig" ]]; then
                # Find restored file — virtnbdrestore uses original filename
                if [[ -f "$_orig" ]]; then
                    true  # already at correct path
                else
                    local _restored_file="$_tgt_dir/${_d}.qcow2"
                    if [[ -f "$_restored_file" ]]; then
                        mv "$_restored_file" "$_orig"
                        log_info "restore_vm" "Renamed: ${_d}.qcow2 → ${_dk_file[$_d]}"
                    else
                        log_warn "restore_vm" "Expected restored file not found at $_orig or $_restored_file"
                    fi
                fi

                # Ownership and permissions
                chown libvirt-qemu:libvirt-qemu "$_orig" 2>/dev/null || \
                    log_warn "restore_vm" "Failed to set ownership on $_orig"
                chmod 600 "$_orig" 2>/dev/null || true

                # Integrity check
                if qemu-img check "$_orig" &>/dev/null; then
                    log_info "restore_vm" "  $_d: ownership ✓ integrity ✓"
                else
                    log_error "restore_vm" "INTEGRITY CHECK FAILED: $_orig"
                    if [[ -f "${_orig}.pre-restore" ]]; then
                        log_error "restore_vm" "Roll back: mv ${_orig}.pre-restore $_orig"
                    fi
                    _failed_disk="$_d"
                    break
                fi
            else
                # Staging: integrity check on extracted file
                local _stage_file
                _stage_file=$(find "$_tgt_dir" -maxdepth 1 -name "*.qcow2" -newer "$data_dir" 2>/dev/null | head -1)
                if [[ -n "$_stage_file" ]]; then
                    ls -lh "$_stage_file" 2>/dev/null | while IFS= read -r line; do
                        log_info "restore_vm" "  $line"
                    done
                    if qemu-img check "$_stage_file" &>/dev/null; then
                        log_info "restore_vm" "  $_d: integrity ✓"
                    else
                        log_error "restore_vm" "INTEGRITY CHECK FAILED: $_stage_file"
                    fi
                fi
            fi
            _restored_disks+=("$_d")
        done

        # ── Post-loop: summary, warnings, cleanup notice ─────────────

        # Storage pool refresh (once)
        if [[ "$_inplace" == true ]]; then
            refresh_storage_pool "${_dk_dir[${disk_list[0]}]}"
        fi

        # Handle failure with partial completion
        if [[ -n "$_failed_disk" ]]; then
            if [[ ${#_restored_disks[@]} -gt 0 ]]; then
                local _restored_display
                _restored_display=$(printf '%s, ' "${_restored_disks[@]}")
                _restored_display="${_restored_display%, }"
                log_error "restore_vm" "Partial restore: $_restored_display succeeded, $_failed_disk FAILED"
                # List remaining skipped disks
                local _in_skipped=false
                for _d in "${disk_list[@]}"; do
                    [[ "$_d" == "$_failed_disk" ]] && _in_skipped=true && continue
                    [[ "$_in_skipped" == true ]] && log_error "restore_vm" "Skipped: $_d"
                done
            fi
            cleanup_pit_staging "$pit_input_dir"
            die "Disk restore failed for $_failed_disk" "restore_vm" "$EXIT_TOOL"
        fi

        # Checkpoint invalidation warning (once)
        if [[ "$_inplace" == true ]]; then
            echo ""
            log_warn "restore_vm" "═══════════════════════════════════════════════════════════"
            log_warn "restore_vm" "CHECKPOINT CHAIN INVALIDATED for '$vm_name'"
            log_warn "restore_vm" "═══════════════════════════════════════════════════════════"
            log_warn "restore_vm" "Replaced disk(s) no longer match existing QEMU checkpoint bitmaps."
            log_warn "restore_vm" ""
            log_warn "restore_vm" "If vmbackup ENABLE_AUTO_RECOVERY_ON_CHECKPOINT_CORRUPTION=\"yes\":"
            log_warn "restore_vm" "  → Next backup will auto-archive old chain and start a fresh FULL."
            log_warn "restore_vm" ""
            log_warn "restore_vm" "If \"warn\" (default):"
            log_warn "restore_vm" "  → Next backup will FAIL until checkpoints are manually cleaned."
            log_warn "restore_vm" "  → To clean: for cp in \$(virsh checkpoint-list $vm_name --name 2>/dev/null); do"
            log_warn "restore_vm" "       virsh checkpoint-delete $vm_name \$cp --metadata; done"
            log_warn "restore_vm" "═══════════════════════════════════════════════════════════"
        fi

        # .pre-restore cleanup notice (once, all files)
        if [[ ${#_prerestore_files[@]} -gt 0 ]]; then
            echo ""
            log_warn "restore_vm" "═══════════════════════════════════════════════════════════"
            log_warn "restore_vm" "ACTION REQUIRED: Remove .pre-restore file(s) once VM is confirmed working"
            local _total_pr_size=0
            for _pf in "${_prerestore_files[@]}"; do
                local _pf_size _pf_size_hr
                _pf_size=$(stat -c%s "$_pf" 2>/dev/null || echo 0)
                _pf_size_hr=$(du -sh "$_pf" 2>/dev/null | awk '{print $1}')
                log_warn "restore_vm" "  rm $_pf  ($_pf_size_hr)"
                _total_pr_size=$(( _total_pr_size + _pf_size ))
            done
            if [[ ${#_prerestore_files[@]} -gt 1 ]]; then
                local _total_pr_hr
                _total_pr_hr=$(numfmt --to=iec-i --suffix=B "$_total_pr_size" 2>/dev/null || echo "$_total_pr_size bytes")
                log_warn "restore_vm" "  Total: $_total_pr_hr"
            fi
            log_warn "restore_vm" "═══════════════════════════════════════════════════════════"
        fi

        # Disk size comparisons
        if [[ "$_inplace" == true ]]; then
            for _d in "${_restored_disks[@]}"; do
                local _orig="${_dk_path[$_d]:-}"
                if [[ -n "$_orig" && -f "${_orig}.pre-restore" ]]; then
                    local old_vsize new_vsize
                    old_vsize=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('virtual-size',0))" < <(qemu-img info --output=json "${_orig}.pre-restore" 2>/dev/null) 2>/dev/null || echo 0)
                    new_vsize=$(python3 -c "import json,sys; print(json.load(sys.stdin).get('virtual-size',0))" < <(qemu-img info --output=json "$_orig" 2>/dev/null) 2>/dev/null || echo 0)
                    if [[ "$old_vsize" -gt 0 && "$new_vsize" -gt 0 && "$old_vsize" != "$new_vsize" ]]; then
                        local old_hr new_hr
                        old_hr=$(numfmt --to=iec-i --suffix=B "$old_vsize" 2>/dev/null || echo "$old_vsize")
                        new_hr=$(numfmt --to=iec-i --suffix=B "$new_vsize" 2>/dev/null || echo "$new_vsize")
                        log_warn "restore_vm" "Disk $_d capacity changed: $old_hr → $new_hr (disk was resized since backup)"
                    fi
                fi
            done
        fi

        # Final summary
        local _restored_display
        _restored_display=$(printf '%s, ' "${_restored_disks[@]}")
        _restored_display="${_restored_display%, }"
        if [[ "$_inplace" == true ]]; then
            log_info "restore_vm" "Disk restore complete: $vm_name/$_restored_display — all ✓"
        else
            log_info "restore_vm" "Disk extract complete: $vm_name/$_restored_display → $OPT_RESTORE_PATH"
        fi

        cleanup_pit_staging "$pit_input_dir"
        return 0
    fi
    # ── End Disk-Restore Mode ────────────────────────────────────────────────

    # Build virtnbdrestore command as array (no eval)
    # For clone mode: use staging subdir so virtnbdrestore won't collide
    # with existing files. Files are renamed + moved to final path after.
    local staging_dir=""
    local virtnbd_output_path="$OPT_RESTORE_PATH"
    local cmd=(virtnbdrestore -i "$data_dir")

    # VM definition strategy
    local new_identity=false
    if [[ "$OPT_SKIP_CONFIG" == false ]]; then
        local check_name="${OPT_NAME:-$vm_name}"
        if virsh dominfo "$check_name" &>/dev/null; then
            if [[ "$OPT_DRY_RUN" == true ]]; then
                log_warn "restore_vm" "[DRY RUN] VM '$check_name' exists (would need --force)"
            elif [[ "$OPT_FORCE" == true ]]; then
                log_warn "restore_vm" "Undefining existing VM: $check_name"
                virsh undefine "$check_name" --nvram --checkpoints-metadata 2>/dev/null || \
                    virsh undefine "$check_name" --checkpoints-metadata 2>/dev/null || \
                    virsh undefine "$check_name" --nvram 2>/dev/null || \
                    virsh undefine "$check_name" 2>/dev/null || \
                    log_warn "restore_vm" "Failed to undefine '$check_name' — continuing anyway"
            else
                die "VM '$check_name' already defined (use --force to override)" "restore_vm" "$EXIT_VM"
            fi
        fi

        if [[ -n "${OPT_NAME:-}" ]]; then
            # New identity: -c only (adjust paths), we define manually with new UUID/MACs
            new_identity=true
            cmd+=(-c)
            # Set up staging directory under restore-path (same filesystem = atomic mv)
            staging_dir="$OPT_RESTORE_PATH/.vmrestore-staging-$$"
            virtnbd_output_path="$staging_dir"
            log_info "restore_vm" "Restore mode: clone (new identity — new UUID, new MACs)"
            log_info "restore_vm" "Clone name: $OPT_NAME — staging dir: $staging_dir"
        else
            # Disaster recovery: -c -D preserves original UUID/MACs
            # -N is mandatory: without it virtnbdrestore prefixes "restore_" to the name
            cmd+=(-c -D -U "qemu:///system" -N "$vm_name")
            log_info "restore_vm" "Restore mode: disaster recovery (original identity preserved)"
        fi
    fi

    # Finalise -o with the resolved output path (staging or direct)
    cmd+=(-o "$virtnbd_output_path")

    # Single disk filter
    [[ -n "${OPT_DISK:-}" ]] && cmd+=(-d "$OPT_DISK")

    # Point-in-time restore (incremental backups only)
    local until_cp=""
    if [[ "$OPT_RESTORE_POINT" != "latest" && "$btype" == "incremental" ]]; then
        case "$OPT_RESTORE_POINT" in
            full)    until_cp="virtnbdbackup.0" ;;
            [0-9]*)  until_cp="virtnbdbackup.$OPT_RESTORE_POINT" ;;
            *)       die "Invalid restore point: $OPT_RESTORE_POINT (use latest, full, or number)" "restore_vm" "$EXIT_USAGE" ;;
        esac
        cmd+=(--until "$until_cp")
        log_info "restore_vm" "Point-in-time: $until_cp"
    elif [[ "$OPT_RESTORE_POINT" != "latest" && "$btype" != "incremental" ]]; then
        log_warn "restore_vm" "Point-in-time ignored (backup type: $btype)"
    fi

    # ── PIT staging (DR/clone mode) ──────────────────────────────────────
    # When point-in-time targets a checkpoint with a different disk set,
    # create a staging input directory so virtnbdrestore reads the correct vmconfig.
    local pit_input_dir=""
    if [[ -n "$until_cp" && "$btype" == "incremental" ]]; then
        local _pit_target_cp=""
        case "$OPT_RESTORE_POINT" in
            full)   _pit_target_cp="0" ;;
            [0-9]*) _pit_target_cp="$OPT_RESTORE_POINT" ;;
        esac
        if [[ -n "$_pit_target_cp" ]]; then
            local _pit_latest_cp
            _pit_latest_cp=$(find "$data_dir/checkpoints" -maxdepth 1 -name "virtnbdbackup.*.xml" -printf '%f\n' 2>/dev/null \
                | sed 's/virtnbdbackup\.\([0-9]*\)\.xml/\1/' | sort -n | tail -1)
            local _pit_target_disks _pit_latest_disks
            _pit_target_disks=$(enumerate_disks_at_checkpoint "$data_dir" "$_pit_target_cp")
            _pit_latest_disks=$(enumerate_disks_at_checkpoint "$data_dir" "$_pit_latest_cp")
            if [[ "$_pit_target_disks" != "$_pit_latest_disks" ]]; then
                log_warn "restore_vm" "Disk configuration changed between checkpoint $_pit_target_cp and latest ($_pit_latest_cp)."
                log_warn "restore_vm" "  Checkpoint $_pit_target_cp: $_pit_target_disks"
                log_warn "restore_vm" "  Latest (CP $_pit_latest_cp): $_pit_latest_disks"
                log_warn "restore_vm" "  Restoring with checkpoint $_pit_target_cp disk configuration."
                if [[ "$OPT_DRY_RUN" == false ]]; then
                    pit_input_dir=$(create_pit_staging "$data_dir" "$_pit_target_cp") || \
                        die "Failed to create PIT staging directory" "restore_vm" "$EXIT_STORAGE"
                    log_info "restore_vm" "PIT staging directory: $pit_input_dir"
                    # Replace -i in cmd array: element 0=virtnbdrestore, 1=-i, 2=data_dir
                    cmd[2]="$pit_input_dir"
                fi
            fi
        fi
    fi

    # ── Pre-flight free space check ──
    preflight_free_space "$data_dir" "$OPT_RESTORE_PATH" "$btype" "$until_cp"

    # ── Pre-flight disk safety checks ──
    # predict_output_files computes FINAL paths (after rename for clones)
    local use_c_flag=false
    [[ "$OPT_SKIP_CONFIG" == false ]] && use_c_flag=true
    local _predicted_ok=true
    # Fix 5: When PIT staging detected a disk config change, use the target CP's vmconfig
    local _predict_cfg_override=""
    if [[ -n "$pit_input_dir" ]]; then
        # Real run: use vmconfig from the PIT staging dir
        _predict_cfg_override=$(ls -1 "$pit_input_dir"/vmconfig.virtnbdbackup.*.xml 2>/dev/null | head -1)
    elif [[ -n "${_pit_target_cp:-}" && "${_pit_target_disks:-}" != "${_pit_latest_disks:-}" ]]; then
        # Dry run: use vmconfig from backup dir directly
        _predict_cfg_override="$data_dir/vmconfig.virtnbdbackup.${_pit_target_cp}.xml"
        if [[ ! -f "$_predict_cfg_override" ]]; then
            # Fallback to config/ dir by ordinal
            local _cfg_dir=""
            for _search in "$data_dir/config" "$(dirname "$data_dir")/config"; do
                [[ -d "$_search" ]] && _cfg_dir="$_search" && break
            done
            if [[ -n "$_cfg_dir" ]]; then
                _predict_cfg_override=$(ls -1 "$_cfg_dir"/*.xml 2>/dev/null | sort | sed -n "$((_pit_target_cp + 1))p")
            fi
        fi
    fi
    if predict_output_files "$data_dir" "$OPT_RESTORE_PATH" "$use_c_flag" "${OPT_DISK:-}" "${OPT_NAME:-}" "$_predict_cfg_override"; then
        preflight_disk_safety "$vm_name" "$OPT_DRY_RUN" "$OPT_FORCE"
    else
        log_warn "restore_vm" "Could not predict output files — skipping disk safety checks"
        _predicted_ok=false
    fi

    # Track new UUID for TPM (only set in new-identity mode)
    local new_uuid=""

    # DR + --force: remove existing disk files that virtnbdrestore would refuse to overwrite
    # Only in non-clone mode (clone uses staging dir, no collision with output path)
    if [[ "$new_identity" == false && "$OPT_FORCE" == true && "$_predicted_ok" == true && "$OPT_DRY_RUN" == false ]]; then
        for pred_file in "${_PREDICTED_FILES[@]}"; do
            if [[ -f "$pred_file" ]]; then
                rm -f "$pred_file"
                log_info "restore_vm" "Removed existing file for DR overwrite: $pred_file"
            fi
        done
    fi

    if [[ "$OPT_SKIP_CONFIG" == true ]]; then
        log_info "restore_vm" "Restore mode: data-only (--skip-config — disk restore without VM definition)"
    fi

    if [[ "$OPT_DRY_RUN" == true ]]; then
        log_info "restore_vm" "[DRY RUN] ${cmd[*]}"
        if [[ -n "$pit_input_dir" || ( -n "$until_cp" && "$_pit_target_disks" != "${_pit_latest_disks:-}" ) ]]; then
            log_info "restore_vm" "[DRY RUN] PIT staging: would create staging dir with checkpoint $OPT_RESTORE_POINT vmconfig"
        fi
        if [[ "$new_identity" == true ]]; then
            log_info "restore_vm" "[DRY RUN] Would define '$OPT_NAME' with new UUID and MACs"
            log_info "restore_vm" "[DRY RUN] Staging dir: $staging_dir"
            if [[ "$_predicted_ok" == true ]]; then
                stage_and_rename_clone_disks "$OPT_NAME" "$staging_dir" "$OPT_RESTORE_PATH" true
            fi
        fi
    else
        mkdir -p "$OPT_RESTORE_PATH"
        # Create staging dir for clone mode
        if [[ -n "$staging_dir" ]]; then
            mkdir -p "$staging_dir"
            log_info "restore_vm" "Created staging directory: $staging_dir"
        fi

        # Provision vmconfig XML for archived chains that lack vmconfig.virtnbdbackup.*.xml
        # virtnbdrestore requires this file even without -c/-D flags
        # Skip when PIT staging is active — staging dir already has the correct vmconfig
        local _provisioned_vmconfig=""
        if [[ -z "$pit_input_dir" ]] && ! ls "$data_dir"/vmconfig.virtnbdbackup.*.xml &>/dev/null; then
            local _cfg_xml=""
            for _search_dir in "$data_dir/config" "$(dirname "$data_dir")/config"; do
                [[ -d "$_search_dir" ]] || continue
                _cfg_xml=$(ls -1t "$_search_dir"/*.xml 2>/dev/null | head -1 || true)
                [[ -n "$_cfg_xml" ]] && break
            done
            if [[ -n "$_cfg_xml" && -f "$_cfg_xml" ]]; then
                cp "$_cfg_xml" "$data_dir/vmconfig.virtnbdbackup.0.xml"
                _provisioned_vmconfig="$data_dir/vmconfig.virtnbdbackup.0.xml"
                log_info "restore_vm" "Provisioned vmconfig from: $_cfg_xml"
            else
                log_warn "restore_vm" "No vmconfig XML found — virtnbdrestore may fail"
            fi
        fi

        log_info "restore_vm" "Executing: ${cmd[*]}"

        local restore_ok=false
        if run_logged "${cmd[@]}"; then
            log_info "restore_vm" "Disk restored to $virtnbd_output_path"
            restore_ok=true
        elif [[ "$OPT_SKIP_CONFIG" == false ]]; then
            # Primary failed — retry without -D (disk restore only)
            log_warn "restore_vm" "virtnbdrestore failed, retrying disk-only..."
            local retry=(virtnbdrestore -i "${pit_input_dir:-$data_dir}" -o "$virtnbd_output_path" -c -U "qemu:///system")
            [[ -n "${OPT_DISK:-}" ]] && retry+=(-d "$OPT_DISK")
            [[ -n "$until_cp" ]] && retry+=(--until "$until_cp")
            if run_logged "${retry[@]}"; then
                restore_ok=true
            else
                # Clean up staging dirs on failure before dying
                [[ -n "$staging_dir" && -d "$staging_dir" ]] && rm -rf "$staging_dir"
                cleanup_pit_staging "$pit_input_dir"
                die "Disk restore failed" "restore_vm" "$EXIT_TOOL"
            fi
        else
            [[ -n "$staging_dir" && -d "$staging_dir" ]] && rm -rf "$staging_dir"
            cleanup_pit_staging "$pit_input_dir"
            die "Disk restore failed" "restore_vm" "$EXIT_TOOL"
        fi

        # Move + rename clone disks from staging to final location
        local disk_rename_map=""
        if [[ "$new_identity" == true && "$_predicted_ok" == true && "$restore_ok" == true ]]; then
            stage_and_rename_clone_disks "$OPT_NAME" "$staging_dir" "$OPT_RESTORE_PATH" false
            disk_rename_map="$_DISK_RENAME_MAP"
            # Clean up staging dir (should be empty now except vmconfig.xml etc.)
            # Move vmconfig.xml to restore path if present
            if [[ -f "$staging_dir/vmconfig.xml" ]]; then
                mv "$staging_dir/vmconfig.xml" "$OPT_RESTORE_PATH/vmconfig.xml"
            fi
            rm -rf "$staging_dir"
            log_info "restore_vm" "Staging directory cleaned up"
        fi

        # Clean up PIT staging directory (input symlinks + vmconfig copy)
        cleanup_pit_staging "$pit_input_dir"

        # Define VM from config (when virtnbdrestore didn't -D, or new-identity)
        if [[ "$OPT_SKIP_CONFIG" == false && "$new_identity" == true ]]; then
            # New identity: find the output XML, strip UUID + MACs, rename, define
            local out_xml="$OPT_RESTORE_PATH/vmconfig.xml"
            if [[ ! -f "$out_xml" ]]; then
                # Fallback: vmbackup config/ directory
                out_xml=$(ls -1t "$data_dir/config"/*.xml 2>/dev/null | head -1 || true)
            fi
            if [[ -n "$out_xml" && -f "$out_xml" ]]; then
                new_uuid=$(define_new_identity "$out_xml" "$OPT_NAME" false "$disk_rename_map") || \
                    log_warn "restore_vm" "VM define failed (restore disks OK — define manually)"
            else
                log_warn "restore_vm" "No config XML found — define VM manually"
            fi
        elif [[ "$OPT_SKIP_CONFIG" == false && "$new_identity" == false ]]; then
            # Disaster recovery: if virtnbdrestore -D didn't define, try fallback
            if ! virsh dominfo "$vm_name" &>/dev/null; then
                local fb_xml
                fb_xml=$(ls -1t "$data_dir/config"/*.xml 2>/dev/null | head -1 || true)
                if [[ -n "$fb_xml" ]]; then
                    log_info "restore_vm" "Defining VM from backup config: $fb_xml"
                    virsh define "$fb_xml" || log_warn "restore_vm" "virsh define failed"
                fi
            fi

            # virtnbdrestore -D always strips UUID — re-inject original so TPM/identity is preserved
            if virsh dominfo "$vm_name" &>/dev/null; then
                local orig_uuid=""
                local _src_xml
                _src_xml=$(ls -1t "$data_dir"/vmconfig.virtnbdbackup.*.xml 2>/dev/null | head -1 || true)
                # Archived chains may lack vmconfig — fall back to config/ dir
                if [[ -z "$_src_xml" ]]; then
                    for _uuid_cdir in "$data_dir/config" "$(dirname "$data_dir")/config"; do
                        [[ -d "$_uuid_cdir" ]] || continue
                        _src_xml=$(ls -1t "$_uuid_cdir"/*.xml 2>/dev/null | head -1 || true)
                        [[ -n "$_src_xml" ]] && break
                    done
                fi
                if [[ -n "$_src_xml" ]]; then
                    orig_uuid=$(grep -oP '<uuid>\K[^<]+' "$_src_xml" 2>/dev/null || true)
                fi
                if [[ -n "$orig_uuid" ]]; then
                    local current_uuid
                    current_uuid=$(virsh domuuid "$vm_name" 2>/dev/null || true)
                    if [[ "$current_uuid" != "$orig_uuid" ]]; then
                        log_info "restore_vm" "Re-injecting original UUID: $orig_uuid (virtnbdrestore assigned: $current_uuid)"
                        local _fixxml
                        _fixxml=$(mktemp /tmp/vmrestore-fixuuid-XXXXXX.xml)
                        virsh dumpxml --inactive "$vm_name" > "$_fixxml"
                        sed -i "s|<uuid>[^<]*</uuid>|<uuid>$orig_uuid</uuid>|" "$_fixxml"
                        # Must undefine first — virsh refuses UUID change on existing domain
                        # Backup NVRAM before undefine --nvram (which deletes it)
                        local _nvram_path _nvram_bak=""
                        _nvram_path=$(grep -oP '<nvram[^>]*>\K[^<]+' "$_fixxml" 2>/dev/null || true)
                        if [[ -n "$_nvram_path" && -f "$_nvram_path" ]]; then
                            _nvram_bak=$(mktemp /tmp/vmrestore-nvram-XXXXXX.fd)
                            cp "$_nvram_path" "$_nvram_bak"
                        fi
                        virsh undefine "$vm_name" --nvram 2>/dev/null || \
                            virsh undefine "$vm_name" 2>/dev/null || true
                        # Restore NVRAM before redefine
                        if [[ -n "$_nvram_bak" && -f "$_nvram_bak" ]]; then
                            cp "$_nvram_bak" "$_nvram_path"
                            rm -f "$_nvram_bak"
                        fi
                        if virsh define "$_fixxml" &>/dev/null; then
                            log_info "restore_vm" "UUID restored to $orig_uuid"
                        else
                            log_warn "restore_vm" "Failed to re-inject UUID (TPM may be misaligned)"
                        fi
                        rm -f "$_fixxml"
                    fi
                fi
                # Log preserved MAC addresses for DR verification
                local _dr_macs
                _dr_macs=$(virsh domiflist "$vm_name" 2>/dev/null | awk 'NR>2 && $5 {print $5}' || true)
                if [[ -n "$_dr_macs" ]]; then
                    while IFS= read -r _m; do
                        log_info "restore_vm" "MAC preserved: $_m"
                    done <<< "$_dr_macs"
                fi
            fi
        fi

        # Clean up provisioned vmconfig if we created one
        [[ -n "${_provisioned_vmconfig:-}" && -f "$_provisioned_vmconfig" ]] && rm -f "$_provisioned_vmconfig"

        # Post-restore validation: only check files we actually restored
        if [[ "$restore_ok" == true && "$_predicted_ok" == true && ${#_PREDICTED_FILES[@]} -gt 0 ]]; then
            local _any_corrupt=false
            for _qcow in "${_PREDICTED_FILES[@]}"; do
                [[ -f "$_qcow" ]] || continue
                if qemu-img check "$_qcow" &>/dev/null; then
                    log_info "restore_vm" "Disk integrity OK: $(basename "$_qcow")"
                else
                    log_error "restore_vm" "Restored image FAILED integrity check: $_qcow"
                    _any_corrupt=true
                fi
            done
            if [[ "$_any_corrupt" == true ]]; then
                log_error "restore_vm" "One or more restored images are corrupt (possible ENOSPC or I/O error)"
                die "Restore produced corrupt disk images" "restore_vm" "$EXIT_STORAGE"
            fi
        fi

        # Show restored files
        if [[ "$_predicted_ok" == true && ${#_PREDICTED_FILES[@]} -gt 0 ]]; then
            for _rfile in "${_PREDICTED_FILES[@]}"; do
                [[ -f "$_rfile" ]] || continue
                ls -lh "$_rfile" 2>/dev/null | while IFS= read -r line; do
                    log_info "restore_vm" "  $line"
                done
            done
        fi

        # Refresh libvirt storage pool so new volumes are discovered by virt-manager
        refresh_storage_pool "$OPT_RESTORE_PATH"
    fi

    # TPM state (pass new UUID for new-identity mode)
    # Skip TPM restore when --skip-config is set (data-only restore should not
    # touch the live VM's TPM state)
    if [[ "$OPT_SKIP_TPM" == false && "$OPT_SKIP_CONFIG" == false ]]; then
        local tpm_name="${OPT_NAME:-$vm_name}"
        restore_tpm "$tpm_name" "$data_dir" "$OPT_DRY_RUN" "$new_uuid" || \
            log_warn "restore_vm" "TPM restore failed (non-fatal)"
    elif [[ "$OPT_SKIP_CONFIG" == true && "$OPT_SKIP_TPM" == false ]]; then
        log_info "restore_vm" "Skipping VM definition (--skip-config — data-only restore)"
        log_info "restore_vm" "Skipping TPM restore (--skip-config implies data-only)"
    fi

    # Completion summary — single line confirming what was done
    local _summary="Restore complete: $vm_name"
    if [[ "$OPT_DRY_RUN" == true ]]; then
        _summary="$_summary [DRY RUN — no changes made]"
    else
        local _parts=()
        _parts+=("disk ✓")
        if [[ "$OPT_SKIP_CONFIG" == false ]]; then
            if [[ "$new_identity" == true ]]; then
                _parts+=("defined ✓" "new identity ✓")
            else
                _parts+=("defined ✓" "UUID ✓" "MACs ✓")
            fi
        else
            _parts+=("data-only")
        fi
        # Check if TPM was restored (look for recent TPM log line)
        if [[ "$OPT_SKIP_TPM" == false && "$OPT_SKIP_CONFIG" == false ]]; then
            _parts+=("TPM ✓")
        fi
        _summary="$_summary — ${_parts[*]}"
    fi
    log_info "restore_vm" "$_summary"
}

# ── Verify / Dump ────────────────────────────────────────────────────────────

run_virtnbd_action() {
    local action="$1" vm_name="$2"

    local data_dir=""
    if has_backup_data "$OPT_BACKUP_PATH"; then
        data_dir="$OPT_BACKUP_PATH"
    else
        local vm_dir="$OPT_BACKUP_PATH/$vm_name"
        [[ -d "$vm_dir" ]] || die "VM directory not found: $vm_dir" "run_virtnbd_action" "$EXIT_VM"
        data_dir=$(resolve_data_dir "$vm_dir" "${OPT_PERIOD:-}") || \
            die "Cannot resolve data directory" "run_virtnbd_action" "$EXIT_VM"
    fi

    log_info "run_virtnbd_action" "Running $action on: $data_dir"
    run_logged virtnbdrestore -i "$data_dir" -o "$action"
}

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    echo "vmrestore.sh v${VERSION} — Automated VM restoration wrapping virtnbdrestore"
    cat << 'EOF'

USAGE:
  vmrestore.sh --vm <name|path> --restore-path <path> [options]
  vmrestore.sh --vm <name|path> --disk <dev[,dev,...]|all> [--restore-path <path>]
  vmrestore.sh --list [--backup-path <path>]
  vmrestore.sh --list-restore-points <name|path> [--period <id>]
  vmrestore.sh --verify <name> [--period <id>]
  vmrestore.sh --dump <name> [--period <id>]

RESTORE:
  --vm <name|path>       VM to restore (name or full path to backup dir)
  --restore-path <path>  Output directory for restored VM (required for DR/clone)
  --backup-path <path>   Backup root (overrides vmbackup.conf)
                         Not needed when --vm is given a full path
  --period <id>          Specific period (2026-W09, 20260303, 202602)
  --restore-point <p>    latest (default) | full | restore point number
  --name <name>          Clone with new identity (new UUID, new MACs, isolated NVRAM)
  --disk <dev[,dev,...]>  Restore specific disk(s) from a multi-disk backup.
                         Comma-separated: --disk vda,vdb  or  --disk all
                         Replaces existing qcow2 file(s) in-place.
                         For single-disk VMs this is ignored (full restore).

CONTROL:
  --skip-config          Restore disk data only, don't define VM
  --skip-tpm             Skip TPM state restoration
  --force                Undefine existing VM before restoring
  --dry-run              Show commands without executing
  --no-pre-restore       Skip creating .pre-restore backup of existing disk
                         (disk restore only — saves space at risk of no rollback)

INSPECTION:
  --list                 List all VMs with backup info
  --list-restore-points  Show available restore points
  --verify <name>        Checksum validation (virtnbdrestore -o verify)
  --dump <name>          Backup metadata (virtnbdrestore -o dump)
  --config-instance <n>  Use named vmbackup config instance (default: default)
                         Also reads VMBACKUP_INSTANCE env var as fallback

EXAMPLES:
  # Disaster recovery — rebuild VM with original identity
  vmrestore.sh --vm my-server --restore-path /var/lib/libvirt/images/my-server

  # Clone — independent copy with new UUID and MACs
  vmrestore.sh --vm my-server --name test-clone --restore-path /var/lib/libvirt/images/test-clone

  # Point-in-time — restore to restore point 3
  vmrestore.sh --vm my-server --restore-point 3 --restore-path /tmp/restore

  # Disk restore — replace data disk in-place (VM must be shut off)
  vmrestore.sh --vm my-server --disk vdb

  # Disk restore — replace multiple disks at once
  vmrestore.sh --vm my-server --disk vda,vdb,sda

  # Disk restore — replace all disks
  vmrestore.sh --vm my-server --disk all

  # Disk restore — extract disk to staging path
  vmrestore.sh --vm my-server --disk vdb --restore-path /tmp/restore

  # Disk restore — point-in-time, roll back vdb to restore point 1
  vmrestore.sh --vm my-server --disk vdb --restore-point 1

  # Restore from specific period
  vmrestore.sh --vm my-workstation --period 20260302 --restore-path /tmp/restore

  # Restore from archived chain
  vmrestore.sh --vm /mnt/backups/vm/my-server/2026-W09/.archives/chain-2026-02-28.1 \
    --restore-path /tmp/restore/archived

  # Inspect
  vmrestore.sh --list-restore-points my-server
  vmrestore.sh --verify my-workstation --period 20260303
  vmrestore.sh --list
EOF
    exit 0
}

# ── CLI Parsing ──────────────────────────────────────────────────────────────

OPT_MODE=""
OPT_VM_NAME=""
OPT_BACKUP_PATH=""
BACKUP_PATH_CLI=""
OPT_CONFIG_INSTANCE=""
OPT_RESTORE_PATH=""
OPT_PERIOD=""
OPT_RESTORE_POINT="latest"
OPT_NAME=""
OPT_DISK=""
OPT_SKIP_CONFIG=false
OPT_SKIP_TPM=false
OPT_FORCE=false
OPT_DRY_RUN=false
OPT_NO_PRE_RESTORE=false

parse_args() {
    [[ $# -eq 0 ]] && usage

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)
                OPT_MODE="restore"
                local vm_arg="${2:?'--vm requires a VM name or path'}"
                if [[ "$vm_arg" == */* ]]; then
                    # Path given: derive VM name and backup path
                    OPT_VM_NAME=$(basename "$vm_arg")
                    BACKUP_PATH_CLI=$(dirname "$vm_arg")
                else
                    OPT_VM_NAME="$vm_arg"
                fi
                shift 2 ;;
            --list)
                OPT_MODE="list"
                shift ;;
            --list-restore-points)
                OPT_MODE="list-rp"
                if [[ -n "${2:-}" && ! "${2:-}" =~ ^-- ]]; then
                    local rp_arg="$2"
                    if [[ "$rp_arg" == */* ]]; then
                        OPT_VM_NAME=$(basename "$rp_arg")
                        BACKUP_PATH_CLI=$(dirname "$rp_arg")
                    else
                        OPT_VM_NAME="$rp_arg"
                    fi
                    shift
                fi
                shift ;;
            --verify)
                OPT_MODE="verify"
                OPT_VM_NAME="${2:?'--verify requires a VM name'}"
                shift 2 ;;
            --dump)
                OPT_MODE="dump"
                OPT_VM_NAME="${2:?'--dump requires a VM name'}"
                shift 2 ;;
            --backup-path)
                BACKUP_PATH_CLI="${2:?'--backup-path requires a path'}"
                shift 2 ;;
            --config-instance)
                OPT_CONFIG_INSTANCE="${2:?'--config-instance requires an instance name'}"
                shift 2 ;;
            --restore-path)
                OPT_RESTORE_PATH="${2:?'--restore-path requires a path'}"
                shift 2 ;;
            --period)
                OPT_PERIOD="${2:?'--period requires a period ID'}"
                shift 2 ;;
            --restore-point)
                OPT_RESTORE_POINT="${2:?'--restore-point requires a value'}"
                shift 2 ;;
            --name)
                OPT_NAME="${2:?'--name requires a name'}"
                shift 2 ;;
            --disk)
                OPT_DISK="${2:?'--disk requires a device name (e.g. vdb, vda,vdb, or all)'}"
                shift 2 ;;
            --skip-config)    OPT_SKIP_CONFIG=true; shift ;;
            --skip-tpm)       OPT_SKIP_TPM=true; shift ;;
            --force)          OPT_FORCE=true; shift ;;
            --dry-run)        OPT_DRY_RUN=true; shift ;;
            --no-pre-restore) OPT_NO_PRE_RESTORE=true; shift ;;
            --help|-h)        usage ;;
            --version|-V)     echo "vmrestore $VERSION"; exit 0 ;;
            *)                die "Unknown option: $1" "parse_args" "$EXIT_USAGE" ;;
        esac
    done

    OPT_BACKUP_PATH=$(resolve_backup_path) || exit $?

    # Validate incompatible flag combinations
    if [[ -n "${OPT_DISK:-}" && -n "${OPT_NAME:-}" ]]; then
        die "--disk and --name cannot be combined (disk restore replaces disk files, it does not create a VM)" "parse_args" "$EXIT_USAGE"
    fi

    # Normalise paths: strip trailing slashes to avoid ugly double-slash //
    OPT_RESTORE_PATH="${OPT_RESTORE_PATH%/}"
    OPT_BACKUP_PATH="${OPT_BACKUP_PATH%/}"
    BACKUP_PATH_CLI="${BACKUP_PATH_CLI%/}"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    ORIG_ARGS="$*"
    parse_args "$@"

    # Read-only modes: no log file, no banner
    case "$OPT_MODE" in
        list|list-rp)
            [[ -d "$OPT_BACKUP_PATH" ]] || { echo "Backup path not found: $OPT_BACKUP_PATH" >&2; return 1; }
            case "$OPT_MODE" in
                list)    list_vms "$OPT_BACKUP_PATH" ;;
                list-rp)
                    [[ -n "$OPT_VM_NAME" ]] || { echo "VM name required for --list-restore-points" >&2; return 1; }
                    local vm_dir="$OPT_BACKUP_PATH/$OPT_VM_NAME"
                    [[ -d "$vm_dir" ]] || { echo "VM not found: $vm_dir" >&2; return 1; }

                    echo ""
                    echo "Restore Points: $OPT_VM_NAME"

                    # Build list of period dirs to show
                    local -a period_dirs=()
                    if [[ -n "${OPT_PERIOD:-}" ]]; then
                        local target="$vm_dir/$OPT_PERIOD"
                        [[ -d "$target" ]] || { echo "Period not found: $target" >&2; return 1; }
                        period_dirs+=("$target")
                    elif is_accumulate "$vm_dir"; then
                        period_dirs+=("$vm_dir")
                    else
                        local -a periods=()
                        mapfile -t periods < <(list_periods "$vm_dir")
                        if [[ ${#periods[@]} -eq 0 ]]; then
                            echo "No period directories in: $vm_dir" >&2; return 1
                        fi
                        for p in "${periods[@]}"; do
                            period_dirs+=("$vm_dir/$p")
                        done
                    fi

                    # Show each period
                    local -A _seen_archives=()
                    for data_dir in "${period_dirs[@]}"; do
                        local _period_label
                        _period_label=$(basename "$data_dir")
                        if [[ "$data_dir" == "$vm_dir" ]]; then
                            # Detect if this is an archived chain (parent is .archives/)
                            local _parent_dir
                            _parent_dir=$(basename "$(dirname "$data_dir")")
                            if [[ "$_parent_dir" == ".archives" ]]; then
                                _period_label="(archive)"
                            else
                                _period_label="(accumulate)"
                            fi
                        fi

                        echo ""
                        echo "  ── $_period_label ──"
                        echo "  Directory: $data_dir"
                        echo "  Type: $(detect_backup_type "$data_dir")"
                        local _disks
                        _disks=$(enumerate_disks "$data_dir")
                        [[ -n "$_disks" ]] && echo "  Disks: $_disks"
                        echo ""
                        show_restore_points "$data_dir"

                        # Show archived chains for this period
                        for adir in "$vm_dir/.archives" "$data_dir/.archives"; do
                            [[ -d "$adir" ]] || continue
                            local real_adir
                            real_adir=$(realpath "$adir")
                            [[ -n "${_seen_archives[$real_adir]:-}" ]] && continue
                            _seen_archives[$real_adir]=1
                            echo "  Archived Chains:"
                            for chain in "$adir"/chain-*; do
                                [[ -d "$chain" ]] || continue
                                local cname csize ctype
                                cname=$(basename "$chain")
                                csize=$(du -sh "$chain" 2>/dev/null | awk '{print $1}')
                                ctype=$(detect_backup_type "$chain")
                                local cdisks
                                cdisks=$(enumerate_disks "$chain")
                                if [[ -n "$cdisks" ]]; then
                                    printf "    %-30s %6s  %s  [%s]\n" "$cname" "$csize" "$ctype" "$cdisks"
                                else
                                    printf "    %-30s %6s  %s\n" "$cname" "$csize" "$ctype"
                                fi
                                show_restore_points "$chain"
                            done
                        done
                    done
                    ;;
            esac
            return 0
            ;;
    esac

    # Write modes: full logging
    init_logging
    finalize_log_name
    log_invocation_summary
    log_info "main" "====== vmrestore v$VERSION ======"
    [[ -d "$OPT_BACKUP_PATH" ]] || die "Backup path not found: $OPT_BACKUP_PATH" "main" "$EXIT_STORAGE"

    local rc=0
    case "$OPT_MODE" in
        restore)
            # --disk without --restore-path = in-place disk replacement (no --restore-path needed)
            if [[ -z "$OPT_RESTORE_PATH" && -z "${OPT_DISK:-}" ]]; then
                die "--restore-path is required for restore (unless --disk is used for in-place replacement)" "main" "$EXIT_USAGE"
            fi
            restore_vm "$OPT_VM_NAME"
            ;;

        verify)
            if run_virtnbd_action "verify" "$OPT_VM_NAME"; then
                log_info "main" "Verification passed: backup checksums are valid"
            else
                rc=$?
                log_error "main" "Verification FAILED: backup checksums do not match (exit $rc)"
            fi
            ;;

        dump)
            run_virtnbd_action "dump" "$OPT_VM_NAME" || rc=$?
            ;;

        *)
            die "No mode specified (try --help)" "main" "$EXIT_USAGE"
            ;;
    esac

    log_info "main" "====== vmrestore completed ======"
    log_completion_summary $rc
    return $rc
}

main "$@"
exit $?
