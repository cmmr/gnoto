#
# api.sh - Wrike's API, for every gnoto script that talks to Wrike.
#
# Sourced by:  lib/env.sh
# Defines:     wrike_on, wrike_call, wrike_update, wrike_replay,
#              wrike_status_id, wrike_set_status, wrike_comment,
#              wrike_set_field, wrike_field_id, wrike_task_uid,
#              is_valid_wrike_id, wrike_mention
# Requires:    curl and jq; warn from lib/utilities.sh
# Env:         WRIKE_ENABLED, WRIKE_API_TOKEN and WRIKE_API_URL, from
#              config.yaml; WRIKE_FOLDER_ID, WRIKE_STATUSES_<NAME> and
#              WRIKE_FIELDS_<KEY>, from generated.yaml, which gnoto config
#              wrike writes; DATA_DIR
#
# The token goes to curl in a config read from stdin, never on its command
# line, where ps would show it to anyone on a shared login node.
#
# wrike_call retries a call that Wrike answers with 429 or a 5xx, or that
# doesn't reach Wrike, waiting twice as long each time, as Wrike advises. Once
# a job is submitted, every change gnoto makes in Wrike goes through
# wrike_update, a side effect that never fails its caller: a change that still
# fails is kept in <data_dir>/logs/wrike-replay/ for the daily timer to try
# again. A change with a key, such as a task's status, replaces any earlier
# one of the same key waiting there, so a replay never sets an older status
# over a newer one, and one that succeeds clears it.

# The Pipeline field's answer that repeats an earlier run on new samples
WRIKE_REPEAT_ANSWER="Repeat an earlier run"

WRIKE_TRIES=${WRIKE_TRIES:-5}
WRIKE_WAIT=${WRIKE_WAIT:-2}
WRIKE_REPLAY_DAYS=14

# Wrike's IDs: letters, digits and -_:.= only, which keeps one safe in a path,
# a URL and a file name
is_valid_wrike_id() {
    [[ ${#1} -ge 1 && ${#1} -le 256 && $1 =~ ^[A-Za-z0-9_:.=-]+$ && $1 != . && $1 != .. ]]
}

# True when Wrike is on and set up: its token, and the folder config wrike made
wrike_on() {
    [[ ${WRIKE_ENABLED:-false} == true && -n ${WRIKE_API_TOKEN:-} && -n ${WRIKE_FOLDER_ID:-} ]]
}

# wrike_call <verb> <endpoint> [curl arguments]: prints Wrike's answer. Returns
# 2 when Wrike says there's no such thing (404), and 1 for any other failure,
# with a warning naming the call and Wrike's reason.
wrike_call() {
    local verb=$1 endpoint=$2 body code status try wait=$WRIKE_WAIT reason
    shift 2

    [[ -n ${WRIKE_API_TOKEN:-} ]] || { warn "wrike.api_token isn't set, so gnoto can't reach Wrike."; return 1; }
    body=$(mktemp "${TMPDIR:-/tmp}/gnoto-wrike.XXXXXX") || return 1
    for (( try = 1; ; try++ )); do
        status=0
        code=$(printf 'header = "Authorization: bearer %s"\n' "${WRIKE_API_TOKEN//\"/\\\"}" |
            curl -sS --config - -X "$verb" --connect-timeout 20 --max-time 300 -o "$body" \
                -w '%{http_code}' "$@" "${WRIKE_API_URL%/}/${endpoint#/}" 2> "$body.err") || status=$?
        if (( status == 0 )) && [[ $code == 2?? ]]; then
            cat "$body"
            rm -f "$body" "$body.err"
            return 0
        fi
        if (( status == 0 )) && [[ $code != 429 && $code != 5?? ]]; then
            break
        fi
        (( try < WRIKE_TRIES )) || break
        sleep "$wait"
        wait=$(( wait * 2 > 60 ? 60 : wait * 2 ))
    done
    if (( status != 0 )); then
        reason="couldn't reach $WRIKE_API_URL: $(head -c 300 "$body.err" | tr '\n' ' ')"
    else
        reason="Wrike answered $code$(jq -r '.errorDescription // .error // empty | ": \(.)"' "$body" 2> /dev/null | head -c 300)"
    fi
    rm -f "$body" "$body.err"
    # A caller expecting a task may be gone sets WRIKE_GONE_OK, and gets 2 quietly
    [[ $code == 404 && -n ${WRIKE_GONE_OK:-} ]] || warn "Wrike call $verb ${endpoint%%\?*} failed: $reason"
    [[ $code != 404 ]] || return 2
    return 1
}

# wrike_update <key> <verb> <endpoint> [curl arguments]: a change in Wrike that
# mustn't fail its caller. A change Wrike can't take now waits in
# logs/wrike-replay/ for the daily timer, under <key>, or a name of its own when
# <key> is empty. One about a task that's gone (404) is dropped.
wrike_update() {
    local key=$1 dir=$DATA_DIR/logs/wrike-replay file status=0
    shift
    wrike_call "$@" > /dev/null || status=$?
    if (( status == 0 )); then
        [[ -z $key ]] || rm -f "$dir/$key.json" 2> /dev/null || :
        return 0
    fi
    (( status != 2 )) || return 0
    mkdir -p "$dir" 2> /dev/null && chmod 2775 "$dir" 2> /dev/null || :
    file=$dir/${key:-$(date -u +%Y%m%dT%H%M%S)-$$-$RANDOM}.json
    if jq -n '$ARGS.positional' --args -- "$@" > "$file.tmp" 2> /dev/null && chmod 664 "$file.tmp" &&
        mv -f "$file.tmp" "$file"; then
        warn "The daily timer tries that Wrike change again."
    else
        rm -f "$file.tmp"
        warn "Couldn't keep that Wrike change in $dir for the daily timer to try again."
    fi
    return 0
}

# Tries every change waiting in logs/wrike-replay/ again, oldest first. One
# that succeeds, or whose task is gone, is dropped, and so is one older than
# WRIKE_REPLAY_DAYS. Prints how many were tried and how many succeeded.
wrike_replay() {
    local dir=$DATA_DIR/logs/wrike-replay file args=() status tried=0 done=0
    [[ -d $dir ]] || { echo "0 0"; return 0; }
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        if [[ -n $(find "$file" -mtime +$WRIKE_REPLAY_DAYS 2> /dev/null) ]]; then
            warn "Gave up on a Wrike change from $(date -u -r "$file" +%F): $(jq -c . "$file" 2> /dev/null)"
            rm -f "$file"
            continue
        fi
        # NUL-separated, since a comment's text can hold line breaks
        mapfile -d '' -t args < <(jq -j '.[] | . + "\u0000"' "$file" 2> /dev/null)
        (( ${#args[@]} >= 2 )) || { rm -f "$file"; continue; }
        tried=$((tried + 1))
        status=0
        wrike_call "${args[@]}" > /dev/null || status=$?
        if (( status == 0 || status == 2 )); then
            rm -f "$file"
            done=$((done + 1))
        fi
    done < <(ls -1tr "$dir"/*.json 2> /dev/null)
    echo "$tried $done"
}

# A custom status's ID by its name, such as Running, from generated.yaml
wrike_status_id() {
    local name=WRIKE_STATUSES_${1^^}
    printf '%s' "${!name:-}"
}

# A custom field's ID by its key, such as expiration or picrust
wrike_field_id() {
    local name=WRIKE_FIELDS_${1^^}
    printf '%s' "${!name:-}"
}

# wrike_set_status <task> <status name>
wrike_set_status() {
    local id
    id=$(wrike_status_id "$2")
    if [[ -z $id ]]; then
        warn "generated.yaml has no Wrike status $2, so task $1's status wasn't changed. $(gnoto_command config wrike) adds it."
        return 0
    fi
    wrike_update "$1.status" PUT "tasks/$1" --data-urlencode "customStatus=$id"
}

# wrike_comment <task> <text>, as plain text
wrike_comment() {
    wrike_update "" POST "tasks/$1/comments" --data-urlencode "plainText=true" --data-urlencode "text=$2"
}

# wrike_comment_html <task> <html>, for a comment that mentions someone
wrike_comment_html() {
    wrike_update "" POST "tasks/$1/comments" --data-urlencode "text=$2"
}

# wrike_set_field <task> <field key> <value>. An empty value clears the field.
wrike_set_field() {
    local id
    id=$(wrike_field_id "$2")
    [[ -n $id ]] || return 0
    wrike_update "$1.field.$id" PUT "tasks/$1" \
        --data-urlencode "customFields=$(jq -cn --arg id "$id" --arg value "$3" '[{id: $id, value: $value}]')"
}

# A mention of a Wrike user, by ID, which Wrike draws with the user's name
wrike_mention() {
    printf '<a class="stream-user-id avatar" rel="%s">@%s</a>' "$1" "$1"
}

# The uid of a run made for a Wrike task, from its ID
wrike_task_uid() {
    is_valid_wrike_id "$1" || { warn "\"$1\" isn't a Wrike task ID."; return 1; }
    derive_uid "$1"
}
