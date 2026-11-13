#
# run_state.sh - The one file a run keeps its state in, and the helpers that read
# and write it.
#
# Sourced by:  lib/env.sh
# Defines:     RUN_STATE_FILE, state_init, state_present, state_update, state_get,
#              state_get_json, state_get_tsv, state_has, state_set, state_set_json,
#              state_set_number, state_set_tsv, state_append, state_unset,
#              set_run_status, get_run_status, set_run_stage, set_step_state
# Requires:    jq and flock; warn from lib/utilities.sh
#
# Every scalar a run records about itself lives in run_state.json in the run
# directory, which every script that touches state runs from. Bulk artifacts,
# such as samplesheets and logs, stay files of their own. It's never published,
# because it holds hosts and the Wrike task ID.
#
# Values are addressed by a dotted path, such as "samples.count".
#
# Writes take a lock and land by rename, so a reader always sees a whole
# document, and two writers don't lose an update. A write that can't get the
# lock fails rather than going ahead unlocked.

RUN_STATE_FILE="run_state.json"
RUN_STATE_LOCK=".run_state.lock"
RUN_STATE_SCHEMA=1
RUN_STATE_TRIES=5
RUN_STATE_LOCK_WAIT=30

state_present() {
    [[ -f "$RUN_STATE_FILE" ]]
}

# A run's state starts with its address token: 80 random bits as 16 lowercase
# base32 characters, which name its published folder with the uid, so its
# address can't be found from the uid alone (service/publish.sh)
state_init() {
    local run_id="${1:-${PWD##*/}}" token

    token=$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z') || return 1
    jq -n \
        --argjson schema "$RUN_STATE_SCHEMA" \
        --arg run_id "$run_id" \
        --arg token "$token" \
        --arg created_utc "$(date -u "+%Y-%m-%dT%H:%M:%SZ")" \
        '{schema: $schema, run_id: $run_id, address_token: $token, status: "Submitted",
          created_utc: $created_utc, notes: []}' \
        > "$RUN_STATE_FILE"
}

# One read-modify-write under the lock
state_update_once() {
    local filter="$1" tmp
    shift

    # Beside the state file, so the rename stays on one filesystem. mktemp makes
    # it 600, and every member of gnoto's group reads the state.
    tmp=$(mktemp ".run_state.XXXXXX") && chmod 664 "$tmp" || return 1
    {
        flock -w "$RUN_STATE_LOCK_WAIT" 9 || { rm -f "$tmp"; return 1; }
        if ! jq "$@" "$filter" "$RUN_STATE_FILE" > "$tmp" ||
            ! mv -f "$tmp" "$RUN_STATE_FILE" 2> /dev/null; then
            rm -f "$tmp"
            return 1
        fi
    } 9>> "$RUN_STATE_LOCK"
}

# Applies a jq filter to the document, retrying, because what a run records is
# what everything downstream reports from. Warns and returns rather than
# failing, because fail itself writes through here.
state_update() {
    local attempt

    if ! state_present; then
        warn "No $RUN_STATE_FILE in $PWD, so the state wasn't recorded."
        return 1
    fi
    for (( attempt = 1; attempt <= RUN_STATE_TRIES; attempt++ )); do
        state_update_once "$@" && return 0
        sleep 1
    done
    warn "Couldn't update $RUN_STATE_FILE in $PWD after $RUN_STATE_TRIES tries."
    return 1
}

# One value as text. A missing key and null both read as empty. Numbers and
# booleans read as written, and objects and arrays as JSON.
state_get() {
    state_present || return 0
    jq -r --arg key "$1" '
        getpath($key | split(".")) as $value
        | if $value == null then ""
          elif ($value | type) == "string" then $value
          else ($value | tojson) end' "$RUN_STATE_FILE"
}

# One value as compact JSON, or null
state_get_json() {
    state_present || { printf 'null'; return 0; }
    jq -c --arg key "$1" 'getpath($key | split(".")) // null' "$RUN_STATE_FILE"
}

# An object as "key<tab>value" lines
state_get_tsv() {
    state_present || return 0
    jq -r --arg key "$1" '
        getpath($key | split(".")) // {}
        | to_entries[]
        | "\(.key)\t\(.value | if type == "string" then . else tojson end)"' \
        "$RUN_STATE_FILE"
}

state_has() {
    state_present || return 1
    jq -e --arg key "$1" 'getpath($key | split(".")) != null' \
        "$RUN_STATE_FILE" > /dev/null 2>&1
}

state_set() {
    state_update 'setpath($key | split("."); $value)' --arg key "$1" --arg value "$2"
}

# The same, for a value that's already JSON
state_set_json() {
    local key="$1" value="$2"

    if ! jq . > /dev/null 2>&1 <<< "$value"; then
        warn "The value offered for \"$key\" isn't JSON, so it wasn't recorded."
        return 1
    fi
    state_update 'setpath($key | split("."); $value)' --arg key "$key" --argjson value "$value"
}

# A number, stored as one. Anything else is skipped with a warning.
state_set_number() {
    if [[ ! "$2" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        warn "\"$2\" isn't a number, so \"$1\" wasn't recorded."
        return 1
    fi
    state_set_json "$1" "$2"
}

# An object from "key<tab>value" lines on stdin, with string values
state_set_tsv() {
    local object
    object=$(jq -R -s 'split("\n")
        | map(select(length > 0) | split("\t") | {(.[0]): (.[1] // "")})
        | add // {}') || return 1
    state_set_json "$1" "$object"
}

# Adds a line to an array, such as notes
state_append() {
    state_update '($key | split(".")) as $path
        | setpath($path; ((getpath($path) // []) + [$value]))' \
        --arg key "$1" --arg value "$2"
}

state_unset() {
    state_update 'delpaths([$key | split(".")])' --arg key "$1"
}

set_run_status() {
    state_set status "$1"
}

get_run_status() {
    state_get status
}

# What the run is doing now, in a sentence for the progress page. Best effort:
# a run mustn't fail over a status line.
set_run_stage() {
    state_set stage "$1" 2> /dev/null || true
}

# One step's state, by its place in .steps: waiting, active, done or failed.
# Best effort, like the stage.
set_step_state() {
    state_update '.steps[$index].state = $state' \
        --argjson index "$1" --arg state "$2" 2> /dev/null || true
}
