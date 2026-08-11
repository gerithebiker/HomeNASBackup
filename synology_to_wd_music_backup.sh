#!/usr/bin/env bash
#
# synology_to_wd_music_backup.sh
#
# Mirrors the Synology music library to the WD backup NAS over NFS.
# Performs an rsync synchronization followed by a second dry-run
# verification and writes a detailed log and final report.
#
# Usage:
#   synology_to_wd_music_backup.sh
#   synology_to_wd_music_backup.sh --dry-run
#
# Options:
#   --dry-run    Preview changes without copying or deleting files.
#
# Exit codes:
#   0    Backup and verification completed successfully.
#   1    Setup, mount, rsync, or verification error.
#   2    Post-copy verification found pending differences.
#

set -Eeuo pipefail
IFS=$'\n\t'
START_EPOCH="$(date +%s)"

# -------------------------------------
# Now we source in the global variables
# -------------------------------------
CONFIG_FILE='/etc/musicbackup.conf'

if [[ ! -r "$CONFIG_FILE" ]]; then
    RED=$'\033[1;31m'
    RESET=$'\033[0m'
    printf "${RED}ERROR:${RESET} Cannot read %s\n" "$CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# now we check if the library is in from the config, and read it
if [[ ! -r "$LIB_FILE" ]]; then
    printf 'ERROR: Cannot read library: %s\n' "$LIB_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$LIB_FILE"

# ==============================================
# Now we set the variables for the script to run

MODE="LIVE"
if [[ "${1:-}" == "--dry-run" ]]; then
    MODE="DRY-RUN"
elif [[ $# -gt 0 ]]; then
    printf 'Usage: %s [--dry-run]\n' "$0" >&2
    exit 1
fi

TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG_FILE="${LOG_DIR}/wd_music_backup_${TIMESTAMP}.log"
VERIFY_FILE=""
DEST="${MOUNT_POINT%/}/${DEST_SUBDIR#/}"
DEST="${DEST%/}/"

MOUNTED_BY_SCRIPT=0
START_EPOCH="$(date +%s)"
RSYNC_EXIT=99
VERIFY_EXIT=-1
VERIFY_CHANGES=-1
VERIFY_STATUS="SKIPPED"

mkdir -p "$LOG_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

die() {
    log "ERROR: $*"
    exit 1
}

is_mounted() {
    awk -v mp="$MOUNT_POINT" '$2 == mp {found=1} END {exit !found}' /proc/mounts
}

mounted_source() {
    awk -v mp="$MOUNT_POINT" '$2 == mp {print $1; exit}' /proc/mounts
}

cleanup() {
    local exit_code=$?

    if [[ "$MOUNTED_BY_SCRIPT" -eq 1 ]] && is_mounted; then
        log "Unmounting $MOUNT_POINT ..."
        if umount "$MOUNT_POINT"; then
            log "Unmount completed."
        else
            log "WARNING: unmount failed; the NFS mount was left in place."
        fi
    fi

    rmdir "$LOCK_DIR" 2>/dev/null || true

    local end_epoch duration
    end_epoch="$(date +%s)"
    duration=$((end_epoch - START_EPOCH))

    {
        echo
        echo "================ FINAL REPORT ================"
        echo "Mode:                  $MODE"
        echo "Finished:              $(date '+%Y-%m-%d %H:%M:%S')"
        printf 'Duration:              %02d:%02d:%02d\n' \
            $((duration / 3600)) \
            $(((duration % 3600) / 60)) \
            $((duration % 60))
        echo "Source:                $SOURCE"
        echo "NFS export:            ${WD_HOST}:${WD_EXPORT}"
        echo "Destination:           $DEST"
        echo "rsync exit code:       $RSYNC_EXIT"
        echo "Verification status:   $VERIFY_STATUS"
        echo "verification exit:     $VERIFY_EXIT"
        echo "pending verify items:  $VERIFY_CHANGES"
        echo "Script exit code:      $exit_code"
        echo "Log:                   $LOG_FILE"
        if [[ -n "$VERIFY_FILE" ]]; then
            echo "Verification details:  $VERIFY_FILE"
        else
            echo "Verification details:  not created in dry-run mode"
        fi
        echo "=============================================="
    } | tee -a "$LOG_FILE"

    exit "$exit_code"
}
trap cleanup EXIT
trap 'die "Interrupted."' INT TERM HUP

command -v rsync >/dev/null 2>&1 || die "rsync is not installed."
command -v mount >/dev/null 2>&1 || die "mount is not available."
command -v umount >/dev/null 2>&1 || die "umount is not available."

[[ -d "$SOURCE" ]] || die "Source directory does not exist: $SOURCE"
[[ "$SOURCE" != "/" ]] || die "Refusing to use / as source."
[[ "$DEST" != "/" ]] || die "Refusing to use / as destination."
[[ "$MOUNT_POINT" != "/" ]] || die "Refusing to use / as mount point."

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "Another backup appears to be running: $LOCK_DIR"
fi

log "WD music backup started."
log "Mode:        $MODE"
log "Source:      $SOURCE"
log "NFS target:  ${WD_HOST}:${WD_EXPORT}"
log "Mount point: $MOUNT_POINT"
log "Destination: $DEST"

mkdir -p "$MOUNT_POINT"

if is_mounted; then
    log "Mount point is already mounted."
else
    log "Mounting NFS export ..."
    mount -t nfs -o "$NFS_OPTIONS" \
        "${WD_HOST}:${WD_EXPORT}" \
        "$MOUNT_POINT"
    MOUNTED_BY_SCRIPT=1
    log "NFS mount completed."
fi

MOUNT_SOURCE="$(mounted_source || true)"
log "Mounted source: ${MOUNT_SOURCE:-UNKNOWN}"

[[ -n "$MOUNT_SOURCE" ]] || die "Could not confirm the NFS mount."
[[ "$MOUNT_SOURCE" == "${WD_HOST}:${WD_EXPORT}" ]] || \
    die "Unexpected filesystem is mounted at $MOUNT_POINT: $MOUNT_SOURCE"

MARKER_PATH="${MOUNT_POINT%/}/${TARGET_MARKER}"
[[ -f "$MARKER_PATH" ]] || die \
    "Safety marker is missing: $MARKER_PATH
Mount and verify the correct WD export, then create it once with:
touch '$MARKER_PATH'"

mkdir -p "$DEST"

RSYNC_EXCLUDE_ARGS=(--exclude="/${TARGET_MARKER}")
for pattern in "${EXCLUDES[@]}"; do
    RSYNC_EXCLUDE_ARGS+=(--exclude="$pattern")
done

COMMON_RSYNC_ARGS=(
    -a
	-vv
    --no-owner
    --no-group
    --no-perms
	--chmod=Du+rwx,Fu+rw
    --human-readable
    --stats
    --itemize-changes
    --delete-delay
	--omit-dir-times
    --partial
    --partial-dir=".rsync-partial"
    "${RSYNC_EXCLUDE_ARGS[@]}"
)

if [[ "$MODE" == "DRY-RUN" ]]; then
    log "Starting PREVIEW ONLY. No files will be copied or deleted."

    set +e
    rsync \
        "${COMMON_RSYNC_ARGS[@]}" \
        --dry-run \
        "$SOURCE" "$DEST" 2>&1 | tee -a "$LOG_FILE"
    RSYNC_EXIT=${PIPESTATUS[0]}
    set -e

    [[ "$RSYNC_EXIT" -eq 0 ]] || \
        die "Dry-run rsync failed with exit code $RSYNC_EXIT."

    VERIFY_STATUS="SKIPPED (dry-run mode)"
    VERIFY_EXIT=-1
    VERIFY_CHANGES=-1
    log "Dry-run completed successfully."
    exit 0
fi

log "Starting LIVE rsync synchronization."
log "WARNING: files absent from SOURCE will be deleted from DESTINATION."

set +e
rsync \
    "${COMMON_RSYNC_ARGS[@]}" \
    "$SOURCE" "$DEST" 2>&1 | tee -a "$LOG_FILE"
RSYNC_EXIT=${PIPESTATUS[0]}
set -e

if [[ "$RSYNC_EXIT" -ne 0 ]]; then
    die "rsync failed with exit code $RSYNC_EXIT."
fi

log "Main synchronization completed successfully."
sync

VERIFY_FILE="${LOG_DIR}/wd_music_verify_${TIMESTAMP}.txt"
log "Starting metadata verification with a second rsync dry-run."

set +e
rsync \
    -a \
	-v \
    --no-owner \
    --no-group \
    --no-perms \
    --delete-delay \
    --dry-run \
	--omit-dir-times \
    --itemize-changes \
    --out-format='%i|%n%L' \
    "${RSYNC_EXCLUDE_ARGS[@]}" \
    "$SOURCE" "$DEST" >"$VERIFY_FILE" 2>&1
VERIFY_EXIT=$?

# Next line added for debugging
printf 'DEBUG: survived verify rsync, rc=%d, shell flags=%s\n' "$VERIFY_EXIT" "$-" >&2

set -e

if [[ "$VERIFY_EXIT" -ne 0 ]]; then
    VERIFY_STATUS="ERROR"
    die "Verification rsync failed with exit code $VERIFY_EXIT."
fi

VERIFY_CHANGES="$(grep -c '|' "$VERIFY_FILE" || true)"

if [[ "$VERIFY_CHANGES" -eq 0 ]]; then
    VERIFY_STATUS="PASSED"
    log "VERIFICATION PASSED: no pending changes were found."
else
    VERIFY_STATUS="FAILED"
    log "VERIFICATION FAILED: $VERIFY_CHANGES pending item(s) remain."
    log "See: $VERIFY_FILE"
    exit 2
fi

# {{{ Housekeeping

HOUSEKEEPING_DAYS=$LOG_RETENTION_DAYS

log "Housekeeping: removing backup logs older than ${HOUSEKEEPING_DAYS} days."

OLD_LOG_COUNT=0

while IFS= read -r FILE; do
    [[ -z "$FILE" ]] && continue

    ((OLD_LOG_COUNT++))

    log "Removing old log: $(basename "$FILE")"

    rm -f -- "$FILE"

done < <(
    find "$LOG_DIR" \
        -type f \
        -name 'wd_music_backup_*.log' \
        -mtime +"$HOUSEKEEPING_DAYS"
)

if (( OLD_LOG_COUNT == 0 )); then
    log "Housekeeping complete. No old log files found."
else
    log "Housekeeping complete. Removed ${OLD_LOG_COUNT} old log file(s)."
fi

# }}} End Housekeeping
END_EPOCH="$(date +%s)"
DURATION=$((END_EPOCH - START_EPOCH))

printf "${GREEN}================= Time Report ==================${RESET}\n"
printf "${GREEN}Backup runtime: %s ${CYAN}$(format_duration "$DURATION")${RESET}\n"
printf "${GREEN}================================================${RESET}\n"

log "Backup completed and verified successfully."
exit 0

