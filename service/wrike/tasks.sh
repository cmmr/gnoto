#
# tasks.sh - A run's Wrike task: made for a command-line job, kept up as the
# run goes, and read for the dates people set on it.
#
# Sourced by:  lib/env.sh
# Defines:     wrike_cli_task, wrike_submitted, wrike_submit_failed,
#              wrike_report_end, wrike_folder_tasks, wrike_task_field,
#              wrike_sync_dates
# Requires:    wrike_call and the helpers in service/wrike/api.sh; run_value,
#              expiry_get and expiry_sync from service/expire.sh, for the
#              report and the dates
# Env:         WRIKE_FOLDER_ID and the IDs in generated.yaml
#
# A job from the command line gets its task in "gnoto Jobs" before it's
# submitted, created in the Running status, so gnoto wrike never takes it for a
# request waiting to start. Its uid comes from the task's ID, as a form
# request's does, so everything after treats the two alike. When Wrike is set
# up but can't be reached, the job is refused, so every job has its task.
#
# Everything after submission goes through wrike_update, so it never fails a
# stage or stops a cleanup.

# wrike_cli_task <title> <pipeline> <user>: creates a job's task and prints its
# ID. Fails, with the reason, when Wrike can't be reached.
wrike_cli_task() {
    local title=$1 pipeline=$2 user=$3 running fields json id
    running=$(wrike_status_id running)
    [[ -n $running ]] || fail "Wrike is on, but generated.yaml has no Running status. Run: $(gnoto_command config wrike)"
    fields=$(jq -cn --arg id "$(wrike_field_id pipeline)" --arg pipeline "$pipeline" \
        'if $id == "" then [] else [{id: $id, value: $pipeline}] end')
    json=$(wrike_call POST "folders/$WRIKE_FOLDER_ID/tasks" \
        --data-urlencode "title=$title" \
        --data-urlencode "description=Started from the command line by $user." \
        --data-urlencode "customStatus=$running" \
        --data-urlencode "customFields=$fields") ||
        fail "Not started: Wrike is set up, so every job gets a task there, and creating this job's failed. The message above says why."
    id=$(jq -r '.data[0].id // empty' <<< "$json")
    is_valid_wrike_id "$id" || fail "Not started: Wrike made a task, but its answer named no usable ID."
    printf '%s' "$id"
}

# What a task learns once its job is submitted, run from the run directory:
# job.yaml attached, and with S3, the address of the progress page
wrike_submitted() {
    local task=$1 uid=${PWD##*/} url
    wrike_update "" POST "tasks/$task/attachments" -H "X-File-Name: job.yaml" \
        -H "Content-Type: application/octet-stream" --data-binary "@$PWD/job.yaml"
    url=$(publish_results_url "$uid")
    [[ -z $url ]] || wrike_set_field "$task" results "$url"
}

# A job whose submission failed: its task moves to Failed, saying why
wrike_submit_failed() {
    wrike_set_status "$1" Failed
    wrike_comment "$1" "This job couldn't be submitted: $2"
}

# What a run's task says once it has ended: wrike_report_end <uid> <status>.
# Reads the run's state wherever it is, since a run whose results were
# published has no run directory by now.
wrike_report_end() {
    local uid=$1 status=$2 task url message expires text
    wrike_on || return 0
    task=$(run_value "$uid" wrike.task_id)
    [[ -n $task ]] || return 0
    url=$(run_value "$uid" published.url)
    [[ -n $url ]] || url=$(run_value "$uid" published.zip_url)
    message=$(run_value "$uid" message)
    expires=$(expiry_get "$uid" remove_utc)
    case $status in
        Completed)
            wrike_set_status "$task" Completed
            [[ -z $url ]] || wrike_set_field "$task" results "$url"
            wrike_set_field "$task" expiration "${expires:0:10}"
            if [[ -n $url ]]; then
                text="Complete: $url"
            else
                text="Complete. The results are in $DATA_DIR/runs/$uid/results, on the cluster."
            fi
            if [[ -n $expires ]]; then
                text+=" They're kept until ${expires:0:10}, the Expiration date here, which can be changed."
            else
                text+=" They're kept until someone removes them."
            fi
            ;;
        "Publish failed")
            wrike_set_status "$task" Failed
            wrike_set_field "$task" expiration "${expires:0:10}"
            text="The results were made, but publishing them failed: $message"
            text+=" They're kept on the cluster, and $(gnoto_command publish "$uid") publishes them again."
            ;;
        Cancelled)
            wrike_set_status "$task" Cancelled
            text="This run was cancelled.${message:+ $message}"
            ;;
        *)
            wrike_set_status "$task" Failed
            text="This run didn't finish: ${message:-it ended without saying why.}"
            text+=" $(gnoto_command status "$uid") on the cluster says more."
            ;;
    esac
    wrike_comment "$task" "$text"
}

# Every task in "gnoto Jobs", a compact JSON object a line, with its custom
# fields and authors, a page at a time
wrike_folder_tasks() {
    local token="" json args
    while :; do
        args=(-G --data-urlencode 'fields=["customFields","authorIds","parentIds"]' --data-urlencode "pageSize=1000")
        [[ -z $token ]] || args+=(--data-urlencode "nextPageToken=$token")
        json=$(wrike_call GET "folders/$WRIKE_FOLDER_ID/tasks" "${args[@]}") || return 1
        jq -c '.data[]?' <<< "$json"
        token=$(jq -r '.nextPageToken // empty' <<< "$json")
        [[ -n $token ]] || break
    done
}

# One custom field's value on a task, by its key, as a line of text. A list,
# as a Multiple field answers, comes back comma-separated.
wrike_task_field() {
    local id
    id=$(wrike_field_id "$2")
    [[ -n $id ]] || return 0
    jq -r --arg id "$id" '((.data[0] // .) | .customFields[]? | select(.id == $id) | .value) // ""
        | if startswith("[") then (try (fromjson | join(",")) catch .) else . end' <<< "$1" | head -n 1
}

# Copies each task's Expiration date into its run's expiry file, for runs
# whose results are kept: wrike_sync_dates [tasks, a JSON object a line]. Lists
# the folder's tasks itself when given none. Prints what changed.
wrike_sync_dates() {
    local tasks=${1-} task id uid
    [[ -n $tasks ]] || tasks=$(wrike_folder_tasks) || { warn "Couldn't list the tasks in \"gnoto Jobs\", so no dates were copied."; return 0; }
    while IFS= read -r task; do
        [[ -n $task ]] || continue
        id=$(jq -r '.id // empty' <<< "$task")
        is_valid_wrike_id "$id" || continue
        uid=$(derive_uid "$id" 2> /dev/null) || continue
        [[ -n $(run_state_path "$uid") ]] || continue
        expiry_sync "$uid" "$(wrike_task_field "$task" expiration)"
    done <<< "$tasks"
}
