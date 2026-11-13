#
# listener.sh - Takes Wrike's webhook events, and the dashboards' requests for
# Globus access, from SQS as they arrive.
#
# Sourced by:  lib/main.sh, for _listen, which gnoto-listener.service runs
# Defines:     listen_main
# Requires:    the SQS helpers in service/aws/aws.sh; wrike_handle_task from
#              service/wrike/task_handler.sh; remove_one from lib/runs.sh;
#              expiry_sync and run_state_path from service/expire.sh;
#              service_start from service/daily.sh; access_request from
#              service/access.sh
#
# Wrike posts each event to the webhook's Lambda, which checks its signature
# and puts the payload on the queue, and the access Lambda queues a dashboard
# reader's Globus identity. This long-polls the queue, handles every event in
# each payload, since Wrike can send several at once, and deletes a message
# only once it's handled, so one that's interrupted comes back:
#
#   TaskCreated             starts the task if it's waiting, as gnoto wrike
#                           <task> does
#   TaskDeleted             removes the task's run, as gnoto remove does
#   TaskCustomFieldChanged  copies a changed Expiration date into the run's
#                           expiry file
#   globus_access           grants the identity read on the run's folder on
#                           Globus, as service/access.sh says
#
# Keep these in step with the webhook's events in service/wrike/config.sh:
# an event the webhook doesn't subscribe to never arrives, with nothing in any
# log to say so. The poll timer's scan, gnoto wrike, catches anything missed,
# such as events from a suspended webhook or past the queue's retention.
#
# A request that repeats an earlier run runs at that run's version, which a
# command reaches by handing over to it when it exits. This one never exits,
# so it leaves such a request to the scan.

LISTEN_STOP=""

# Handles one event, as compact JSON
listen_event() {
    local event=$1 type task uid field json helper
    if [[ $(jq -r '.gnoto // empty' <<< "$event") == globus_access ]]; then
        if globus_ready; then
            access_request "$event"
        else
            log "Ignored a request for Globus access, since Globus isn't set up."
        fi
        return 0
    fi
    wrike_on || { log "Ignored a message that isn't a Globus access request, since Wrike isn't set up."; return 0; }
    type=$(jq -r '.eventType // empty' <<< "$event")
    task=$(jq -r '.taskId // empty' <<< "$event")
    is_valid_wrike_id "$task" || { log "Ignored a $type event with no usable task ID."; return 0; }
    case $type in
        TaskCreated)
            ( wrike_handle_task "$task" ) || warn "Task $task wasn't started, as above. A task still waiting is tried again at the next scan."
            # A request that has to hand over to another version left its
            # hand-over, which this never exits to take, so it waits for the scan
            helper=${GNOTO_HELPER_DIR:-}
            if [[ -n $helper && -s $helper/handover ]]; then
                rm -f "$helper/handover"
                log "Task $task runs at another version, so the next scan starts it."
            fi
            # Without Slurm, a job starts on this machine once the image has
            # exited, so this stops, and systemd starts it again
            [[ -z $helper || ! -s $helper/detach ]] || LISTEN_STOP=1
            ;;
        TaskDeleted)
            uid=$(derive_uid "$task") || return 0
            if [[ -n $(run_state_path "$uid") && -z $(run_value "$uid" removed_utc) ]]; then
                log "Task $task was deleted, so its run $uid is removed."
                WRIKE_GONE_OK=1 remove_one "$uid" || warn "Run $uid couldn't be removed, so the next scan tries again."
            fi
            ;;
        TaskCustomFieldChanged)
            field=$(jq -r '.customFieldId // empty' <<< "$event")
            [[ -n $field && $field == "$(wrike_field_id expiration)" ]] || return 0
            uid=$(derive_uid "$task") || return 0
            [[ -n $(run_state_path "$uid") ]] || return 0
            json=$(wrike_call GET "tasks/$task") || return 1
            expiry_sync "$uid" "$(wrike_task_field "$json" expiration)"
            ;;
        *) log "Ignored a $type event, which gnoto doesn't act on." ;;
    esac
}

listen_main() {
    local response message handle body event errors=0 what=()
    sqs_on || fail "SQS isn't set up, so there's nothing to listen to. Run: $(gnoto_command config sqs)"
    listener_on || fail "Neither Wrike nor Globus is set up, so there's nothing to listen for. Run: $(gnoto_command config wrike), or $(gnoto_command config globus)"
    service_start listener || return 0
    trap 'LISTEN_STOP=1' TERM INT
    ! wrike_on || what+=("Wrike's events")
    ! globus_ready || what+=("requests for Globus access")
    log "Listening to $AWS_SQS_QUEUE_URL for ${what[0]}${what[1]:+ and ${what[1]}}."
    while [[ -z $LISTEN_STOP ]]; do
        service_beat listener
        if ! response=$(gnoto_aws sqs receive-message --queue-url "$AWS_SQS_QUEUE_URL" \
            --max-number-of-messages 10 --wait-time-seconds 20 --output json 2>&1); then
            errors=$((errors + 1))
            warn "SQS couldn't be read, so this waits and tries again: $(head -c 300 <<< "$response")"
            sleep $(( errors > 6 ? 60 : 10 ))
            continue
        fi
        errors=0
        while IFS= read -r message; do
            [[ -n $message ]] || continue
            handle=$(jq -r '.ReceiptHandle' <<< "$message")
            body=$(jq -r '.Body' <<< "$message")
            while IFS= read -r event; do
                [[ -z $event ]] || listen_event "$event" || :
            done < <(jq -c 'if type == "array" then .[] else . end' <<< "$body" 2> /dev/null ||
                log "Ignored a message that isn't JSON.")
            gnoto_aws sqs delete-message --queue-url "$AWS_SQS_QUEUE_URL" --receipt-handle "$handle" ||
                warn "Couldn't delete a handled message from SQS, so it comes back, and is handled again harmlessly."
        done < <(jq -c '.Messages[]?' <<< "$response" 2> /dev/null)
    done
    log "Stopped listening."
}
