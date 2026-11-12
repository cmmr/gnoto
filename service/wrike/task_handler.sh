#
# task_handler.sh - gnoto wrike: starts the Wrike requests that are waiting,
# and keeps runs in step with their tasks.
#
# Sourced by:  lib/main.sh, for wrike
# Defines:     wrike_main, wrike_handle_task, wrike_scan
# Requires:    the Wrike helpers in service/wrike/; job_yaml, options_json and
#              job_check from lib/jobfile.sh; databases_offer from
#              lib/databases.sh; nodes_prescan from lib/lint.sh; start_run from
#              lib/start.sh; remove_one from lib/runs.sh; expiry_sync and
#              run_state_path from service/expire.sh
#
# Usage:  gnoto wrike [task_id]
#
# A task is waiting when it's in "gnoto Jobs" with the status Submitted, and
# has no run directory or history yet. For each, this turns the task's answers
# into a job file, through each option's labels in options.yaml, with the
# samplesheet attached to it, and runs it through the same checks and
# submission as gnoto run, fetching missing databases without asking. A
# request that fails its checks moves to Failed, with what failed in a
# comment, which also takes it off the waiting list. A request that repeats an
# earlier run takes that run's job.yaml from history/, so it runs at that
# run's version, with its answers, on the new samplesheet.
#
# Form requests run as the account running this, usually the service account,
# so each FASTQ must sit under core.input_roots.
#
# Without a task ID, it scans "gnoto Jobs": starts every waiting task, copies
# each Expiration date into its run's expiry file, removes the runs whose task
# has been deleted, and reactivates the webhook if Wrike has suspended it.
# Each task is handled in a subshell, so one that fails leaves the rest.


# Text a requester typed, cut to a length that's safe to quote back
wrike_quote() {
    local text=${1//$'\n'/ }
    printf '%s' "${text:0:80}"
}

# Turns a request down: its task moves to Failed, with why in a comment
wrike_reject() {
    local task=$1 why=$2
    wrike_comment "$task" "This request can't run: $why Please submit a new one."
    wrike_set_status "$task" Failed
    log "Task $task was turned down: $why"
}

# The --<key>=<value> arguments gnoto new takes, from a task's answers to a
# pipeline's options, into ARG_KEYS and ARG_VALUES. Prints what's wrong with
# an answer, and returns 1.
wrike_job_args() {
    local task_json=$1 pipeline=$2 options key in field value labels raw part parts=()
    options=$(options_json "$pipeline")
    while IFS=$'\t' read -r key in; do
        [[ -n $key && $key != title && $key != samplesheet ]] || continue
        raw=$(wrike_task_field "$task_json" "$key")
        [[ -n $raw ]] || continue
        # An answer is one of the labels the form offers. Reading it back
        # through them also refuses anything else, whatever reached the field.
        labels=$(jq -c --arg key "$key" '.[] | select(.key == $key)
            | [(.values // [])[] | tostring] as $values
            | ((.labels // {}) | with_entries(.key |= tostring)) as $l
            | [$values[] | {label: ($l[.] // .), value: .}]' <<< "$options")
        value=""
        IFS=, read -ra parts <<< "$raw"
        for part in "${parts[@]}"; do
            part=$(sed 's/^ *//; s/ *$//' <<< "$part")
            [[ -n $part ]] || continue
            field=$(jq -r --arg label "$part" '.[] | select(.label == $label) | .value' <<< "$labels")
            if [[ -z $field ]]; then
                printf '"%s" isn'"'"'t an answer the form offers for %s.' "$(wrike_quote "$part")" "$key"
                return 1
            fi
            value+="${value:+,}$field"
        done
        [[ -n $value ]] || continue
        if [[ $in == top ]]; then
            ARG_KEYS+=("$key")
        else
            ARG_KEYS+=("$pipeline.$key")
        fi
        ARG_VALUES+=("$value")
    done < <(jq -r '.[] | [.key, .in] | @tsv' <<< "$options")
}

# Writes a task's job file and samplesheet into <dir>, as job.yaml and
# samplesheet.tsv. Prints what's wrong with the request, and returns 1, or
# returns 2 when Wrike can't be read.
wrike_job_file() {
    local task=$1 json=$2 dir=$3 pipeline title retention previous attachments count id name history why yaml
    title=$(jq -r '.data[0].title // ""' <<< "$json" | head -n 1)
    pipeline=$(wrike_task_field "$json" pipeline)
    retention=$(wrike_task_field "$json" retention)
    previous=$(wrike_task_field "$json" previous_run)

    attachments=$(wrike_call GET "tasks/$task/attachments") || return 2
    count=$(jq '[.data[]?] | length' <<< "$attachments")
    if (( count != 1 )); then
        echo "it needs one samplesheet attached, and it has $count attachments."
        return 1
    fi
    id=$(jq -r '.data[0].id // empty' <<< "$attachments")
    name=$(jq -r '.data[0].name // empty' <<< "$attachments")
    is_valid_wrike_id "$id" || { echo "Wrike named its attachment with an unusable ID."; return 1; }
    [[ $name =~ \.(txt|tsv|tab|out)$ ]] ||
        { echo "its samplesheet, \"$(wrike_quote "$name")\", should be tab-separated text, named .txt or .tsv."; return 1; }
    wrike_call GET "attachments/$id/download" > "$dir/samplesheet.tsv" || return 2

    if [[ $pipeline == "$WRIKE_REPEAT_ANSWER" ]]; then
        # The uid, or the results address it's in
        previous=${previous,,}
        [[ $previous =~ (^|/)([a-z2-7]{8})(/|$) ]] && previous=${BASH_REMATCH[2]}
        if ! is_valid_uid "$previous"; then
            echo "it repeats an earlier run, and \"$(wrike_quote "$previous")\" isn't a run's ID: eight letters and digits, as in its results address."
            return 1
        fi
        history=$DATA_DIR/history/$previous
        [[ -r $history/job.yaml ]] || { echo "there's no record of run $previous here to repeat."; return 1; }
        { printf '# Repeats run %s\n' "$previous"
            TITLE=$title yq '.samplesheet = "samplesheet.tsv" | .title = strenv(TITLE)
                | del(.schema, .repository, .commit, .outputs, .inputs, .databases, .dev)' "$history/job.yaml"
        } > "$dir/job.yaml" || { echo "run $previous's job.yaml can't be read."; return 1; }
        if [[ -n $retention ]]; then
            RETENTION=$retention yq -i '.retention = strenv(RETENTION)' "$dir/job.yaml" ||
                { echo "run $previous's job.yaml can't be read."; return 1; }
        fi
        return 0
    fi

    if [[ ! $pipeline =~ ^[a-z][a-z0-9_]*$ || ! -f $CODE_DIR/pipelines/$pipeline/pipeline.sh ]]; then
        echo "\"$(wrike_quote "$pipeline")\" isn't a pipeline. The pipelines are $(pipeline_names | paste -sd ' ' | sed 's/ /, /g')."
        return 1
    fi
    ARG_KEYS=(title samplesheet)
    ARG_VALUES=("$title" "$dir/samplesheet.tsv")
    wrike_job_args "$json" "$pipeline" > "$dir/why" || { cat "$dir/why"; return 1; }
    yaml=$(job_yaml "$pipeline" 2> "$dir/why") ||
        { tail -n 1 "$dir/why" | sed 's/^\[[^]]*\] ERROR: //'; return 1; }
    printf '%s\n' "$yaml" | SHEET=samplesheet.tsv yq '.samplesheet = strenv(SHEET)' > "$dir/job.yaml"
}

# Whether a task is waiting: in the folder, Submitted, and with no run yet
wrike_waiting() {
    local json=$1 uid=$2
    [[ $(jq -r '(.data[0] // .).customStatusId // ""' <<< "$json") == "$(wrike_status_id submitted)" ]] &&
        jq -e --arg folder "$WRIKE_FOLDER_ID" '(.data[0] // .) | (.parentIds // []) | index($folder)' \
            <<< "$json" > /dev/null &&
        [[ ! -e $DATA_DIR/runs/$uid && ! -e $DATA_DIR/history/$uid ]]
}

# When a request's job names another version than this one, as a repeat of an
# earlier run does, leaves a hand-over for the launcher to start that one task
# at that version, as gnoto wrike <task_id>, and returns 3. One hand-over at a
# time: a second waits for the next scan. A version from before requests from
# the form couldn't take one, so the request is turned down. Returns 0 when
# this version runs it: wrike_other_version <task> <job file>
wrike_other_version() {
    local task=$1 file=$2 ref previous repository
    ref=$(yq -r '.pipeline // ""' "$file")
    [[ $ref == *@* ]] || return 0
    ref=${ref#*@}
    code_version
    [[ $CODE_DEV != true && $ref =~ ^[0-9a-f]{40}$ && $ref != "$CODE_COMMIT" ]] || return 0
    previous=$(sed -n 's/^# Repeats run \([a-z2-7]\{8\}\)$/\1/p' "$file")
    repository=$(run_value "$previous" repository)
    if [[ -e ${GNOTO_HELPER_DIR:-}/handover ]]; then
        log "Task $task runs at gnoto $ref, and another task is handed over already, so it waits for the next scan."
        return 3
    fi
    cache_lock
    version_fetch "${repository:-$CODE_REPOSITORY}" "$ref" ||
        fail "Can't fetch gnoto at $ref, which task $task runs at, so it waits for the next scan."
    exec 8>&-
    if [[ ! -f $DATA_DIR/versions/$ref/service/wrike/task_handler.sh ]]; then
        wrike_reject "$task" "run $previous was made by a version of gnoto that can't take a request from the form. Repeat it from the command line, from its job.yaml, with the new samplesheet."
        return 3
    fi
    [[ -n ${GNOTO_HELPER_DIR:-} && -d $GNOTO_HELPER_DIR ]] ||
        fail "Can't hand task $task to gnoto at $ref: the launcher didn't pass its private directory."
    printf '%s\ntask\n%s\n' "$ref" "$task" > "$GNOTO_HELPER_DIR/handover" ||
        fail "Can't hand task $task to gnoto at $ref."
    log "Task $task repeats a run made by gnoto at $ref, so that version starts it."
    return 3
}

# wrike_handle_task <task id>: starts the task if it's waiting. A deleted
# task's run is removed.
wrike_handle_task() (
    local task=$1 json uid dir why status=0 fetch_after
    is_valid_wrike_id "$task" || fail "\"$task\" isn't a Wrike task's ID."
    uid=$(derive_uid "$task") || fail "There's no uid for task $task: RUN_ID_SALT isn't set. Run: $(gnoto_command config wrike)"
    json=$(WRIKE_GONE_OK=1 wrike_call GET "tasks/$task" -G --data-urlencode 'fields=["customFields","parentIds"]') || status=$?
    if (( status == 2 )) || [[ $(jq -r '.data[0].scope // ""' <<< "$json") == RbTask ]]; then
        if [[ -n $(run_state_path "$uid") && -z $(run_value "$uid" removed_utc) ]]; then
            log "Task $task was deleted, so its run $uid is removed."
            WRIKE_GONE_OK=1 remove_one "$uid" || :
        fi
        return 0
    fi
    (( status == 0 )) || fail "Can't read Wrike task $task, so it waits for the next scan."
    if ! wrike_waiting "$json" "$uid"; then
        log "Task $task isn't waiting to start, so it's left as it is."
        return 0
    fi

    log "Starting task $task as run $uid."
    mkdir -p "$DATA_DIR/wrike" && chmod 2775 "$DATA_DIR/wrike" 2> /dev/null || :
    dir=$(mktemp -d "$DATA_DIR/wrike/$uid.XXXXXX") || fail "Can't create a directory in $DATA_DIR/wrike."
    trap 'rm -rf "$dir"' EXIT
    status=0
    why=$(wrike_job_file "$task" "$json" "$dir") || status=$?
    (( status != 2 )) || fail "Can't read task $task's attachment from Wrike, so it waits for the next scan."
    (( status == 0 )) || { wrike_reject "$task" "$why"; return 0; }

    # A repeat runs at its earlier run's version, which starts it
    status=0
    wrike_other_version "$task" "$dir/job.yaml" || status=$?
    (( status != 3 )) || return 0

    JOB_UID=$uid
    JOB_TASK=$task
    JOB_FORM=true
    JOB_SAMPLESHEET_COPY=1
    job_check "$dir/job.yaml" > "$dir/lint.out" 2>&1 || :
    cat "$dir/lint.out"
    if (( LINT_FAILS > 0 && LINT_FAILS != ${JOB_MISSING_DATABASES:-0} )); then
        why=$(grep '^  FAIL' "$dir/lint.out" | sed 's/^  FAIL  */- /' | head -n 10)
        wrike_reject "$task" $'its checks failed:\n'"$why"$'\n'
        return 0
    fi
    nodes_prescan
    if (( LINT_FAILS > 0 )); then
        fetch_after=$(databases_offer true) || { wrike_reject "$task" "a database it needs couldn't be fetched."; return 0; }
    else
        fetch_after=${JOB_FETCH_AFTER:-}
    fi
    start_run false "$fetch_after"
)

# The webhook, reactivated if Wrike suspended it after failed deliveries
wrike_webhook_check() {
    local json status
    [[ -n ${WRIKE_WEBHOOK_ID:-} ]] || return 0
    json=$(wrike_call GET "webhooks/$WRIKE_WEBHOOK_ID") || return 0
    status=$(jq -r '.data[0].status // ""' <<< "$json")
    if [[ $status == Suspended ]]; then
        if wrike_call PUT "webhooks/$WRIKE_WEBHOOK_ID" --data-urlencode "status=Active" > /dev/null; then
            log "The Wrike webhook was suspended, and is active again. The scan catches what it missed."
        else
            warn "The Wrike webhook is suspended, and couldn't be reactivated."
        fi
    fi
}

# Runs with results or still going whose task isn't in the folder any more,
# and has been deleted, are removed
wrike_scan_gone() {
    local listed=$1 file uid task status json
    for file in "$DATA_DIR"/runs/*/run_state.json "$DATA_DIR"/history/*/state.json; do
        [[ -r $file ]] || continue
        uid=${file%/*}
        uid=${uid##*/}
        is_valid_uid "$uid" || continue
        task=$(jq -r '.wrike.task_id // empty' "$file" 2> /dev/null)
        [[ -n $task && -z $(jq -r '.removed_utc // empty' "$file") ]] || continue
        [[ $file == */history/* && ! -e $DATA_DIR/runs/$uid && ! -e $DATA_DIR/expiry/$uid &&
            -z $(jq -r '.published.s3_prefix // .published.globus_dir // empty' "$file") ]] && continue
        grep -qxF "$task" <<< "$listed" && continue
        status=0
        json=$(WRIKE_GONE_OK=1 wrike_call GET "tasks/$task") || status=$?
        if (( status == 2 )) || [[ $(jq -r '.data[0].scope // ""' <<< "$json") == RbTask ]]; then
            log "Task $task was deleted, so its run $uid is removed."
            WRIKE_GONE_OK=1 remove_one "$uid" || :
        fi
    done
}

# The reconciliation scan
wrike_scan() {
    local tasks listed task id uid started=0
    wrike_webhook_check
    tasks=$(wrike_folder_tasks) || fail "Can't list the tasks in \"gnoto Jobs\", so nothing was scanned."
    listed=$(jq -r '.id // empty' <<< "$tasks")
    while IFS= read -r task; do
        [[ -n $task ]] || continue
        id=$(jq -r '.id // empty' <<< "$task")
        is_valid_wrike_id "$id" || continue
        uid=$(derive_uid "$id") || continue
        if wrike_waiting "$task" "$uid"; then
            wrike_handle_task "$id" || warn "Task $id wasn't started, as above. A task still waiting is tried again at the next scan."
            started=$((started + 1))
        fi
    done <<< "$tasks"
    wrike_sync_dates "$tasks"
    wrike_scan_gone "$listed"
    log "Scanned \"gnoto Jobs\": $(grep -c . <<< "$listed" || :) tasks, $started waiting."
}

# gnoto wrike [task_id]
wrike_main() {
    local usage="Usage: gnoto wrike [task_id]"
    args_parse "$usage" "" "$@"
    [[ ${#ARG_KEYS[@]} -eq 0 && ${#ARG_WORDS[@]} -le 1 ]] || fail "$usage"
    [[ ${WRIKE_ENABLED:-false} == true ]] || fail "Wrike is off. $(gnoto_command config wrike --on) turns it on."
    wrike_on || fail "Wrike isn't set up yet. Run: $(gnoto_command config wrike)"
    if [[ ${#ARG_WORDS[@]} -eq 1 ]]; then
        wrike_handle_task "${ARG_WORDS[0]}"
    else
        wrike_scan
    fi
}
