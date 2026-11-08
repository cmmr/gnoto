#!/bin/sh
#
# helper.sh - Runs host commands for the stand-ins inside the gnoto image.
#
# Started by:  the gnoto launcher, once per launch, on the host
# Usage:       helper.sh <private directory>
# Requires:    POSIX sh, env, cat, mv
# Env:         GNOTO_HELPER_LOG, optional: a file that gets one line per request
#
# The launcher makes the private directory with a requests FIFO, req/ and bin/.
# For each call, host/standin.sh makes a directory in req/ holding:
#
#   request   cwd='...', pass=<n> and set -- '<command>' '<arg>' ..., which
#             this sources. For apptainer, the set -- starts with n
#             APPTAINERENV_ or SINGULARITYENV_ words, as VAR=value, which the
#             command gets
#   stdout    FIFOs the stand-in reads, opened before the request is sent
#   stderr
#   alive     a FIFO the stand-in holds open until it exits
#
# and writes the directory's name to requests as one line. The helper answers
# with an accepted file, then a status file holding the exit code once the
# command has finished.
#
# The command's own process opens stdout and stderr for writing, which waits
# for the stand-in's readers, so no output is lost and neither side sees an
# early end-of-file. If the stand-in dies first, the watcher on alive kills that
# process, whether it's running or still waiting to open.
#
# Only commands named in host/allowed/ run, from the request's cwd, with a fixed
# environment: a job submitted from inside another never inherits its Slurm
# variables or TMPDIR. This isn't a security boundary, because the image runs as
# the same user as the helper.
#
# The helper ignores SIGTERM. Slurm signals every process in a cancelled job,
# and Nextflow then cancels its tasks through the scancel stand-in, so the helper
# has to outlive it. The launcher stops it with SIGKILL.

set -u

DIR=$1
HOST_DIR=$(cd -P -- "$(dirname -- "$0")" && pwd -P)

ALLOWED=" "
for LIST in "$HOST_DIR"/allowed/*; do
    while IFS= read -r NAME || [ -n "$NAME" ]; do
        case $NAME in
            '' | '#'*) ;;
            *[!a-z0-9_-]*)
                printf 'gnoto helper: bad command name in %s: %s\n' "$LIST" "$NAME" >&2
                exit 1
                ;;
            *) ALLOWED="$ALLOWED$NAME " ;;
        esac
    done < "$LIST"
done

# Makes the command a refusal, which reaches the stand-in like any command's output
refuse() {
    set -- sh -c 'printf "gnoto helper: %s\n" "$1" >&2; exit "$2"' sh "$2" "$1"
    run "$@"
}

# Runs the command with its output going to the stand-in, and writes its status
run() {
    "$@" < /dev/null > "$REQ/stdout" 2> "$REQ/stderr" &
    COMMAND_PID=$!

    # alive reaches end-of-file when the stand-in exits, however it was killed
    (
        cat "$REQ/alive" > /dev/null 2>&1
        kill -TERM "$COMMAND_PID" 2> /dev/null
    ) &
    WATCHER_PID=$!

    STATUS=0
    wait "$COMMAND_PID" 2> /dev/null || STATUS=$?
    kill "$WATCHER_PID" 2> /dev/null

    if [ -n "${GNOTO_HELPER_LOG-}" ]; then
        printf '%s\t%s\n' "$STATUS" "$COMMAND_LINE" >> "$GNOTO_HELPER_LOG"
    fi
    # A stand-in that was killed has already removed its directory
    { printf '%s\n' "$STATUS" > "$REQ/status.tmp" && mv -f "$REQ/status.tmp" "$REQ/status"; } 2> /dev/null
    exit 0
}

# Handles one request, in a process of its own
handle() {
    # With exec, not a redirection on the call: dash keeps a saved copy of an fd
    # a function call closes, and requests held open here would hide the
    # helper's death from new stand-ins
    exec 3<&-
    trap - TERM
    REQ=$DIR/req/$1
    COMMAND_LINE=$1

    [ -d "$REQ" ] || exit 0
    : > "$REQ/accepted"

    set --
    cwd=
    pass=0
    if ! . "$REQ/request" 2> /dev/null; then
        refuse 125 "can't read the request in $REQ"
    fi
    COMMAND_LINE="$*"

    # The first $pass words are apptainer's own variables, as VAR=value, which
    # env -i passes on. The command is the word after them.
    case $pass in
        '' | *[!0-9]*) refuse 125 "the request's pass isn't a count" ;;
    esac
    COMMAND=
    I=0
    for WORD in "$@"; do
        if [ "$I" -eq "$pass" ]; then
            COMMAND=$WORD
            break
        fi
        case $WORD in
            APPTAINERENV_*=* | SINGULARITYENV_*=*) ;;
            *) refuse 125 "the request passes $WORD, which isn't an Apptainer variable" ;;
        esac
        I=$((I + 1))
    done

    if [ -z "$COMMAND" ]; then
        refuse 125 "the request names no command"
    fi
    case $ALLOWED in
        *" $COMMAND "*) ;;
        *) refuse 126 "$COMMAND isn't one of the host commands gnoto allows" ;;
    esac
    if [ "$pass" -gt 0 ] && [ "$COMMAND" != apptainer ]; then
        refuse 125 "only apptainer takes variables through a request"
    fi
    if [ -z "$cwd" ] || ! cd -- "$cwd" 2> /dev/null; then
        refuse 125 "can't enter $cwd on the host"
    fi

    VARS="APPTAINER_TMPDIR APPTAINER_CACHEDIR SLURM_CONF LOGNAME USER HOME PATH"
    # systemctl --user needs the login session's bus, and nothing else should get it
    case $COMMAND in
        systemctl | loginctl) VARS="DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR $VARS" ;;
        ssh) VARS="SSH_AUTH_SOCK $VARS" ;;
    esac
    for VAR in $VARS; do
        eval "IS_SET=\${$VAR+x} VALUE=\${$VAR-}"
        if [ -n "$IS_SET" ]; then
            set -- "$VAR=$VALUE" "$@"
        fi
    done
    run env -i "$@"
}

trap '' TERM
exec 3<> "$DIR/requests"

while IFS= read -r LINE <&3; do
    case $LINE in
        '' | *[!A-Za-z0-9]*) continue ;;
    esac
    # Double fork: the handler is never this shell's child, so nothing piles up
    # waiting to be reaped
    (handle "$LINE" &)
done

printf 'gnoto helper: lost the requests FIFO in %s\n' "$DIR" >&2
exit 1
