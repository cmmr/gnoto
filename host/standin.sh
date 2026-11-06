#!/bin/bash
#
# standin.sh - Runs one host command through host/helper.sh.
#
# Linked by the gnoto launcher under each name in host/allowed/, in a private
# directory that comes first on PATH inside the image, so sbatch, apptainer and
# the rest resolve here. Runs inside the image. The protocol is described in
# host/helper.sh.
#
# Env:    GNOTO_HELPER_DIR, the launcher's private directory
#
# Exits with the host command's exit code, or 125 if the helper can't run it.
# Standard input isn't passed on: the host command reads /dev/null.

set -u

NAME=${0##*/}
DIR=${GNOTO_HELPER_DIR:-}
REQ=
OUT_PID=
ERR_PID=

# So a stand-in never runs another stand-in in place of a tool it uses here
PATH=${PATH//"$DIR/bin:"/}

fail() {
    printf 'gnoto: %s: %s\n' "$NAME" "$1" >&2
    exit 125
}

cleanup() {
    kill $OUT_PID $ERR_PID 2> /dev/null
    [[ -n $REQ ]] && rm -rf "$REQ"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[[ -n $DIR && -p $DIR/requests ]] || fail "no gnoto helper is running"

REQ=$(mktemp -d "$DIR/req/XXXXXXXX") || fail "can't make a request in $DIR"

# Single-quoted words, which POSIX sh reads back exactly
SQ="'"
ESC="'\\''"
WORDS="set --"
for ARG in "$NAME" "$@"; do
    WORDS+=" '${ARG//"$SQ"/"$ESC"}'"
done
printf "cwd='%s'\n%s\n" "${PWD//"$SQ"/"$ESC"}" "$WORDS" > "$REQ/request" ||
    fail "can't write the request in $REQ"

mkfifo "$REQ/stdout" "$REQ/stderr" "$REQ/alive" || fail "can't make FIFOs in $REQ"

cat "$REQ/stdout" &
OUT_PID=$!
cat "$REQ/stderr" >&2 &
ERR_PID=$!

# Held until this process exits. The helper stops the host command when it closes.
exec 9<> "$REQ/alive"

# Opening the FIFO blocks only if the helper has gone
timeout 5 bash -c 'printf "%s\n" "$1" > "$2"' _ "${REQ##*/}" "$DIR/requests" 9>&- ||
    fail "the gnoto helper isn't running"

for (( i = 0; i < 3000; i++ )); do
    [[ -e $REQ/accepted ]] && break
    read -r -t 0.01 -u 9 _
done
[[ -e $REQ/accepted ]] || fail "the gnoto helper didn't take the request"

wait $OUT_PID $ERR_PID
OUT_PID=
ERR_PID=

# The output closes when the command exits, just before the helper writes this
for (( i = 0; i < 1000; i++ )); do
    [[ -s $REQ/status ]] && break
    read -r -t 0.01 -u 9 _
done
[[ -s $REQ/status ]] || fail "the gnoto helper stopped before $NAME finished"
read -r STATUS < "$REQ/status"
exit "$STATUS"
