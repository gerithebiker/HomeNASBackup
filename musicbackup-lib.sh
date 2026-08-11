#!/usr/bin/env bash
#
# musicbackup-lib
#
# Shared function library for the WD music backup system.
# Contains common helper functions used by the backup, startup,
# shutdown, status, and wrapper scripts.
#
# This file is intended to be sourced, not executed directly,
# hence no x bit is requred on it, 644 is sufficient.

# {{{ Colors

# We use colors only if the script is runnin in interactive mode in a shell
if [[ -t 1 ]]; then
    RED=$'\033[1;31m'
    GREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'
    CYAN=$'\033[1;36m'
    RESET=$'\033[0m'
else
    RED=""
    GREEN=""
    YELLOW=""
    CYAN=""
    RESET=""
fi

# }}}

# {{{ Functions

die() {
    printf '%sERROR:%s %s\n' "$RED" "$RESET" "$*" >&2
    exit 1
}

wait_status() {
    local elapsed=$1
    local current_minute=$((elapsed / 60))

    if (( current_minute > WAIT_STATUS_LAST )); then
        WAIT_STATUS_LAST=$current_minute

        printf '\n    %sStill waiting...%s %d minute(s) elapsed' "$YELLOW" "$RESET" "$current_minute"
    fi
}

wait_done() {
    local elapsed=$1

    if (( elapsed >= 60 )); then
        printf '\n  '
    fi

    printf '%sOK%s\n' "$GREEN" "$RESET"
}

screen_session_id() {
    {
        "$SCREEN_BIN" -ls 2>/dev/null || true
    } |
    awk -v name="$SESSION_NAME" '
        $1 ~ ("\\." name "$") {
				print $1
				exit
        }
    '
}

backup_pids() {
    ps -eo pid=,args= |
    awk '
        /[s]ynology_to_wd_music_backup\.sh/ ||
        /[r]sync .*\/volume1\/music\// {
            print $1
        }
    ' |
    sort -u
}

format_duration() {
    local seconds=$1

    printf '%02d:%02d:%02d' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

# }}} End of Functions

