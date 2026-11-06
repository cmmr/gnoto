#!/bin/bash
#
# stub-test.sh - Tests host/helper.sh and host/standin.sh against stub commands.
#
# Usage:     test/helper/stub-test.sh <shell for the helper, such as dash or bash>
# Requires:  bash, the named shell, coreutils, gzip and procps, as in debian:13-slim
#
# Plays both sides on one machine: the helper runs the stubs in test/helper/stub.sh
# as the host commands, and the stand-ins run with the private bin first on PATH,
# as they would inside the image. Prints one line per check, and exits 1 if any
# check fails.

set -u

CODE_DIR=$(cd "$(dirname "$0")/../.." && pwd)
HELPER_SH=${1:-sh}
WORK=$(mktemp -d)
PRIVATE=$WORK/private
STUBS=$WORK/stubs
FAILED=0

mkdir -p "$PRIVATE/bin" "$PRIVATE/req" "$STUBS"
mkfifo "$PRIVATE/requests"
for NAME in sbatch squeue scancel sinfo sacct apptainer systemctl loginctl reboot; do
    ln -s "$CODE_DIR/host/standin.sh" "$PRIVATE/bin/$NAME"
    ln -s "$CODE_DIR/test/helper/stub.sh" "$STUBS/$NAME"
done

start_helper() {
    env -i PATH="$STUBS:/usr/bin:/bin" HOME=/root USER=tester LOGNAME=tester \
        SLURM_CONF=/etc/slurm/slurm.conf SLURM_JOB_ID=999 TMPDIR=/should/not/pass \
        XDG_RUNTIME_DIR=/run/user/0 DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/0/bus \
        LANG=xx_YY.UTF-8 GNOTO_HELPER_LOG="$WORK/helper.log" \
        "$HELPER_SH" "$CODE_DIR/host/helper.sh" "$PRIVATE" < /dev/null &
    HELPER_PID=$!
}

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Runs a command as it would run inside the image
image() {
    PATH="$PRIVATE/bin:/usr/bin:/bin" GNOTO_HELPER_DIR="$PRIVATE" "$@"
}

start_helper
trap 'kill -KILL $HELPER_PID 2> /dev/null; rm -rf "$WORK"' EXIT

echo "Helper shell: $HELPER_SH ($(readlink -f "$(command -v "$HELPER_SH")"))"

for CODE in 0 1 7 125 255; do
    image sbatch exit "$CODE"
    check "exit code $CODE" "$CODE" "$?"
done

ARGS=("a b" "" "it's" '"dq"' 'back\slash' '$HOME' '`id`' '*' $'two\nlines' '--flag=x y' "  lead" "tail  " "ünï" "'" "''" "a'b'c")
EXPECTED=$(printf '[%s]\n' "${ARGS[@]}")
check "awkward arguments" "$EXPECTED" "$(image sbatch args "${ARGS[@]}")"

LONG=()
for (( i = 0; i < 5000; i++ )); do LONG+=("job_$i"); done
check "5000 arguments" "$(printf '[%s]\n' "${LONG[@]}" | sha256sum)" "$(image scancel args "${LONG[@]}" | sha256sum)"

OUT=$(image sbatch stderr 2> "$WORK/err")
check "stdout kept apart" "out" "$OUT"
check "stderr kept apart" "err" "$(cat "$WORK/err")"

check "large binary output" "$("$STUBS/sbatch" big 5000000 | sha256sum)" "$(image sbatch big 5000000 | sha256sum)"

mkdir -p "$WORK/dir with 'quotes' and spaces"
check "working directory" "$WORK/dir with 'quotes' and spaces" \
    "$(cd "$WORK/dir with 'quotes' and spaces" && image sbatch pwd)"

check "stdin is /dev/null" "" "$(echo should-not-arrive | timeout 10 bash -c 'PATH="$1/bin:/usr/bin:/bin" GNOTO_HELPER_DIR="$1" sbatch stdin' _ "$PRIVATE")"

ENV_NAMES=$(image sbatch env | cut -d= -f1 | tr '\n' ' ')
check "fixed environment" "HOME LOGNAME PATH SLURM_CONF USER " "$ENV_NAMES"
check "systemctl also gets the session bus" "DBUS_SESSION_BUS_ADDRESS HOME LOGNAME PATH SLURM_CONF USER XDG_RUNTIME_DIR " \
    "$(image systemctl env | cut -d= -f1 | tr '\n' ' ')"

SIGIGN=$(image sbatch signals | awk '/SigIgn/ { print $2 }')
check "host command doesn't ignore SIGTERM" "0" "$(( 0x$SIGIGN & 0x4000 ))"

image reboot args x > /dev/null 2> "$WORK/err"
CODE=$?
check "command off the allowed list refused" "126" "$CODE"
check "refusal says why" "gnoto helper: reboot isn't one of the host commands gnoto allows" "$(cat "$WORK/err")"

# Concurrent calls, each with its own arguments
PIDS=()
for (( i = 0; i < 100; i++ )); do
    ( [[ $(image squeue args "call $i" "x$i") == "$(printf '[%s]\n' "call $i" "x$i")" ]] && touch "$WORK/concurrent.$i" ) &
    PIDS+=($!)
done
wait "${PIDS[@]}"
check "100 concurrent calls" "100" "$(ls "$WORK" | grep -c '^concurrent\.')"

START=$(date +%s%N)
for (( i = 0; i < 100; i++ )); do image squeue exit 0; done
echo "      100 sequential calls took $(( ($(date +%s%N) - START) / 1000000 )) ms"

# Killing a stand-in stops the host process, for TERM and for KILL
for SIGNAL in TERM KILL; do
    rm -f "$WORK/pid"
    PATH="$PRIVATE/bin:/usr/bin:/bin" GNOTO_HELPER_DIR="$PRIVATE" sbatch sleep "$WORK/pid" 300 &
    STANDIN=$!
    for (( i = 0; i < 100; i++ )); do [[ -s $WORK/pid ]] && break; sleep 0.05; done
    HOST_PID=$(cat "$WORK/pid")
    check "signalling the stand-in itself" "/bin/bash $PRIVATE/bin/sbatch sleep" \
        "$(tr '\0' ' ' < /proc/$STANDIN/cmdline | cut -d' ' -f1-3)"
    kill -"$SIGNAL" "$STANDIN"
    for (( i = 0; i < 50; i++ )); do kill -0 "$HOST_PID" 2> /dev/null || break; sleep 0.1; done
    check "SIG$SIGNAL to a stand-in stops the host command" "gone" \
        "$(kill -0 "$HOST_PID" 2> /dev/null && echo running || echo gone)"
    wait "$STANDIN" 2> /dev/null
done

# The helper ignores SIGTERM
kill -TERM "$HELPER_PID"
sleep 0.2
check "helper survives SIGTERM" "0" "$(image sbatch exit 0; echo $?)"

# A call in flight when the helper dies still finishes, and later calls fail fast
rm -f "$WORK/pid"
image sbatch sleep "$WORK/pid" 2 > /dev/null &
INFLIGHT=$!
for (( i = 0; i < 100; i++ )); do [[ -s $WORK/pid ]] && break; sleep 0.05; done
kill -KILL "$HELPER_PID"
wait "$INFLIGHT"
check "call in flight finishes after the helper dies" "0" "$?"
START=$(date +%s)
image sbatch exit 0 2> "$WORK/err"
CODE=$?
check "call after the helper dies fails" "125" "$CODE"
check "and says why" "gnoto: sbatch: the gnoto helper isn't running" "$(cat "$WORK/err")"
echo "      and took $(( $(date +%s) - START )) s"

# Only the SIGKILLed stand-in's is left, for the launcher to remove
check "request directories left" "1" "$(ls "$PRIVATE/req" | wc -l)"
echo "      helper log: $(wc -l < "$WORK/helper.log") requests"

exit $FAILED
