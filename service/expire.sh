#
# expire.sh - Deleting a run's results: the teardown that gnoto remove, a run's
# followup and the daily expiry check share, the daily check itself, and gnoto
# extend.
#
# Sourced by:  lib/main.sh, for remove, extend, _followup, _local, _daily and
#              wrike
# Defines:     teardown_run, run_dir_delete, expiry_get, expiry_set,
#              expiry_sync, expire_check, extend_main, run_state_path
# Requires:    flock and yq; the settings and helpers from lib/env.sh, with
#              the Wrike, S3 and Globus helpers there; run_lock from
#              lib/runs.sh; clean_run and utc_plus from lib/followup.sh, for
#              the daily check; render_template from present/dashboard.sh,
#              for the expired page
#
# The run directory goes, with results/ and the deliverables zip in it, and so
# do the run's copies on S3 and the Globus collection, where the run's state
# says they went, the run's own permission on Globus, and its expiry file. With
# S3, the expired page takes the dashboard's address. With Wrike, the task
# moves to Expired. history/<uid>/ stays, so the record can re-run the job
# while its inputs exist.
#
# <data_dir>/expiry/<uid> is YAML: remove_utc, when the results go; cleanup_utc,
# when a failed or --debug run's leftovers go; and noticed, the removal date the
# daily check last warned of. Every change to it is made with the run's lock
# held. A removal date counts by the day, as Wrike's Expiration date does: the
# daily check removes a run's results on that date.

# The state a run left: its run directory's, or once that has gone, history's
run_state_path() {
    if [[ -r $DATA_DIR/runs/$1/$RUN_STATE_FILE ]]; then
        printf '%s' "$DATA_DIR/runs/$1/$RUN_STATE_FILE"
    elif [[ -r $DATA_DIR/history/$1/state.json ]]; then
        printf '%s' "$DATA_DIR/history/$1/state.json"
    fi
}

# One value from a run's state, wherever it is: run_value <uid> <dotted key>
run_value() {
    local file
    file=$(run_state_path "$1")
    [[ -n $file ]] || return 0
    jq -r --arg key "$2" 'getpath($key | split(".")) // "" | tostring' "$file" 2> /dev/null
}

# expiry_get <uid> <key>
expiry_get() {
    [[ -r $DATA_DIR/expiry/$1 ]] || return 0
    KEY=$2 yq -r '.[strenv(KEY)] // ""' "$DATA_DIR/expiry/$1" 2> /dev/null
}

# expiry_set <uid> <key> <value>, with the run's lock held. An empty value
# removes the key, and the file goes once it holds neither time.
expiry_set() {
    local uid=$1 file=$DATA_DIR/expiry/$1 tmp
    mkdir -p "$DATA_DIR/expiry" || return 1
    tmp=$(mktemp "$file.XXXXXX") && chmod 664 "$tmp" || return 1
    {
        echo "# The times gnoto's daily timer acts on for run $uid."
        { if [[ -s $file ]]; then yq -o=json . "$file"; else echo "{}"; fi; } | jq --arg key "$2" --arg value "$3" '
            (. // {}) | if $value == "" then del(.[$key]) else .[$key] = $value end' | yq -P -oy '.'
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    if [[ -z $(yq -r '.remove_utc // .cleanup_utc // ""' "$tmp") ]]; then
        rm -f "$tmp" "$file"
    else
        mv -f "$tmp" "$file"
    fi
}

# Deletes a run directory, with the run's lock held: takes history's lock too,
# so a command that waited on the run directory's lock takes history's next,
# and moves the directory aside first, so a half-deleted run never looks like
# a run. Warns about what it couldn't delete, and returns 1.
run_dir_delete() (
    local uid=$1 dir=$DATA_DIR/runs/$1 history=$DATA_DIR/history/$1 gone errors
    [[ -d $dir ]] || return 0
    mkdir -p "$history" && { exec 7>> "$history/.lock"; } 2> /dev/null && flock -w 30 7 ||
        { warn "Can't lock $history, so run $uid's directory wasn't deleted."; return 1; }
    gone=$(mktemp -u "$DATA_DIR/runs/.tmp.remove.$uid.XXXXXX")
    mv -T "$dir" "$gone" 2> /dev/null ||
        { warn "Can't move $dir aside to delete it, so run $uid's directory wasn't deleted."; return 1; }
    errors=$(rm -rf "$gone" 2>&1)
    if [[ -e $gone ]]; then
        warn "Couldn't delete everything in run $uid's directory. What's left is in $gone: $(head -3 <<< "$errors" | paste -sd ' ')"
        return 1
    fi
)

# Takes a run's results off S3, leaving the expired page in place of its
# dashboard: s3_expire <uid> <bucket> <prefix> <state file>. The page links
# assets/ like every other page, so assets/ stays, or is put back.
s3_expire() (
    local uid=$1 bucket=$2 prefix=${3%/} state=$4 keys page title completed samples
    [[ ${prefix##*/} =~ ^$uid(-[a-z2-7]{16})?$ ]] ||
        { warn "Run $uid's S3 location, s3://$bucket/$prefix/, isn't named for it, so it wasn't touched."; return 1; }
    keys=$(s3_keys "$bucket" "$prefix") || { warn "Couldn't list s3://$bucket/$prefix/."; return 1; }
    [[ -n $keys ]] || return 0
    source "$CODE_DIR/present/dashboard.sh" || return 1
    page=$(mktemp -d "${TMPDIR:-/tmp}/gnoto-expired.XXXXXX") || return 1
    trap 'rm -rf "$page"' EXIT
    if ! grep -qx "$prefix/assets/gnoto.css" <<< "$keys"; then
        dashboard_assets "$page" && gnoto_aws s3 cp --only-show-errors --recursive "$page/assets/" \
            "s3://$bucket/$prefix/assets/" > /dev/null || warn "Couldn't put the expired page's assets beside it."
    fi
    title=$(jq -r '.title // "Sequencing results"' "$state" 2> /dev/null)
    completed=$(jq -r '.stages.compute // ""' "$state" 2> /dev/null)
    samples=$(jq -r '.samples.count // ""' "$state" 2> /dev/null)
    [[ -z $completed ]] || completed="Completed $(date -u -d "$completed" '+%B %-d, %Y') &middot; "
    if [[ $samples =~ ^[0-9]+$ ]] && (( samples > 0 )); then
        samples="&middot; $samples sample$( (( samples == 1 )) || echo s)"
    else
        samples=""
    fi
    render_template "$PRESENT_DIR/templates/expired.html" \
        TASK_NAME "$(escape_html "${title:-Sequencing results}")" \
        RUN_ID "$uid" \
        COMPLETED "$completed" \
        SAMPLE_COUNT "$samples" \
        EXPIRED "$(date -u '+%B %-d, %Y')" > "$page/index.html" ||
        { warn "Couldn't write the expired page for run $uid."; return 1; }
    s3_delete_prefix "$bucket" "$prefix" assets || return 1
    s3_put "$page/index.html" "$bucket" "$prefix/index.html" "text/html; charset=utf-8" no-cache > /dev/null ||
        warn "Run $uid's results were deleted from S3, but the page saying so wasn't put in their place."
    return 0
)

# teardown_run <uid> <note>: deletes run <uid>'s results, with the run's lock
# held, from run_lock or the followup, and records in history's state when
# they went, as removed_utc, and <note>, if any. A copy on S3 or Globus that
# can't be deleted keeps the run's expiry file, with a removal time of now, so
# the daily check tries again. Warns about anything it couldn't delete, and
# returns 1.
teardown_run() (
    local uid=$1 note=$2 dir=$DATA_DIR/runs/$1 history=$DATA_DIR/history/$1 state task="" bucket="" prefix="" globus=""
    local collection="" path="" left=0 remote=0

    state=$(run_state_path "$uid")
    if [[ -n $state ]]; then
        IFS=$'\x1f' read -r task bucket prefix globus collection path < <(jq -r '[.wrike.task_id // "",
            .published.s3_bucket // "", .published.s3_prefix // "", .published.globus_dir // "",
            .published.globus_uuid // "", .published.globus_path // ""] | join("\u001f")' "$state" 2> /dev/null) || :
    fi

    if [[ -n $bucket && -n $prefix ]]; then
        s3_expire "$uid" "$bucket" "$prefix" "$state" || { left=1; remote=1; }
    fi
    # Everyone's permission on the run's folder goes first, so nothing is
    # served while the folder goes
    if [[ -n $collection && -n $path ]]; then
        globus_path_rules_delete "$collection" "$path" || { left=1; remote=1; }
    fi
    if [[ -n $globus ]]; then
        if [[ $globus != */"$uid" ]]; then
            warn "Run $uid's Globus folder, $globus, isn't named for it, so it wasn't touched."
            left=1
            remote=1
        elif [[ -e $globus ]]; then
            rm -rf "$globus" 2> /dev/null
            [[ ! -e $globus ]] || { warn "Couldn't delete everything in $globus."; left=1; remote=1; }
        fi
    fi

    run_dir_delete "$uid" || left=1
    if (( remote )); then
        expiry_set "$uid" remove_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" ||
            warn "Couldn't keep $DATA_DIR/expiry/$uid for the daily timer to try again."
    else
        rm -f "$DATA_DIR/expiry/$uid" 2> /dev/null || { warn "Couldn't delete $DATA_DIR/expiry/$uid."; left=1; }
    fi
    if [[ -f $history/state.json ]] && (( ! remote )); then
        (cd "$history" && RUN_STATE_FILE=state.json state_update '
            .removed_utc //= $now | if $note == "" then . else .notes = ((.notes // []) + [$note]) end' \
            --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg note "$note") ||
            warn "Couldn't record in $history/state.json that the results were removed."
    fi

    if [[ -n $task ]] && wrike_on && (( ! remote )); then
        wrike_set_status "$task" Expired
        wrike_comment "$task" "${note:-The results were removed.} Its record is kept, so the same analysis can run again on these files or new ones: in a new request, choose to repeat run $uid."
    fi
    return $left
)

# Whole days from today to a date, negative once it has passed
days_until() {
    echo $(( ($(date -u -d "${1:0:10}" +%s) - $(date -u -d "$(date -u +%F)" +%s)) / 86400 ))
}

# The first day a run's results may be removed: its end plus
# core.expiration_notice_days. Prints nothing for a run that hasn't ended.
expiry_floor() {
    local ended
    ended=$(run_value "$1" ended_utc)
    [[ -n $ended ]] || return 0
    date -u -d "${ended:0:10} + ${EXPIRATION_NOTICE_DAYS:-14} days" +%F
}

# Whether a run kept results that expire: it ended Completed or "Publish
# failed", and they haven't been removed
run_kept_results() {
    local status
    status=$(run_value "$1" status)
    [[ ($status == Completed || $status == "Publish failed") && -z $(run_value "$1" removed_utc) &&
        -n $(run_value "$1" ended_utc) ]]
}

# expiry_sync <uid> <date or nothing>: makes a run's removal date the one
# Wrike's Expiration field holds, under the run's lock. Nothing means
# Unlimited. While gnoto's own write of the date waits to be replayed, the
# expiry file is the newer, so it's left as it is. A date before the floor
# becomes the floor, in Wrike too. Prints what changed, if anything.
expiry_sync() (
    local uid=$1 date=$2 task floor current
    run_kept_results "$uid" || exit 0
    run_lock "$uid" || { warn "Can't lock run $uid, so its expiration date wasn't copied from Wrike."; exit 0; }
    run_kept_results "$uid" || exit 0
    task=$(run_value "$uid" wrike.task_id)
    [[ ! -e $DATA_DIR/logs/wrike-replay/$task.field.$(wrike_field_id expiration).json ]] || exit 0
    current=$(expiry_get "$uid" remove_utc)
    if [[ -z $date ]]; then
        [[ -n $current ]] || exit 0
        expiry_set "$uid" remove_utc "" && expiry_set "$uid" noticed "" &&
            echo "Run $uid is kept for good, as its Wrike task's Expiration date was cleared."
        exit 0
    fi
    [[ $date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] || exit 0
    date=${date:0:10}
    floor=$(expiry_floor "$uid")
    if [[ -n $floor && $date < $floor ]]; then
        date=$floor
        wrike_set_field "$task" expiration "$floor"
    fi
    [[ ${current:0:10} != "$date" ]] || exit 0
    expiry_set "$uid" remove_utc "${date}T00:00:00Z" && expiry_set "$uid" noticed "" &&
        echo "Run $uid's results are now removed on $date, as its Wrike task says."
)

# The leftovers a failed or --debug run kept go at cleanup_utc. A run whose
# results were published loses its run directory then too.
expire_cleanup() (
    local uid=$1 dir=$DATA_DIR/runs/$1 status
    [[ -d $dir ]] || exit 0
    cd "$dir" || exit 1
    status=$(get_run_status)
    clean_run "$status" force
    if [[ ($status == Completed || $status == "Publish failed") && -n $(state_get published.verified_utc) ]]; then
        run_dir_delete "$uid" || exit 1
    fi
    chmod -R g+rwX "$dir" 2> /dev/null || :
)

# Warns a run's Wrike task that its results go soon, once for each removal
# date, mentioning whoever raised the task and its followers
expire_notice() {
    local uid=$1 remove=$2 days=$3 task json mentions bot when text
    task=$(run_value "$uid" wrike.task_id)
    [[ -n $task ]] && wrike_on || return 0
    json=$(wrike_call GET "tasks/$task" 2> /dev/null) || return 1
    bot=${WRIKE_BOT_ID:-}
    mentions=$(jq -r --arg bot "$bot" '.data[0].authorIds[]? | select(. != $bot)' <<< "$json" |
        while read -r id; do [[ -z $id ]] || printf '%s ' "$(wrike_mention "$id")"; done)
    mentions+='<a class="stream-user-id avatar quasi-contact" rel="@followers">@followers</a>'
    when="in $days days"
    (( days != 1 )) || when="tomorrow"
    text="$mentions This run's results are removed on $(date -u -d "${remove:0:10}" '+%B %-d, %Y'), $when."
    text+=" To keep them longer, change this task's Expiration date to a later one, before then."
    wrike_comment_html "$task" "$text"
}

# The daily expiry check: copies each Wrike task's Expiration date into its
# run's file, then for each run in expiry/, removes its results once their
# date has come, deletes the leftovers whose cleanup time has come, and warns
# the run's Wrike task once its removal is core.expiration_notice_days away.
# A run it can't act on is left for tomorrow.
expire_check() {
    local file uid remove cleanup noticed days today removed=0 cleaned=0 noticed_count=0 line
    today=$(date -u +%F)
    if wrike_on; then
        while IFS= read -r line; do
            [[ -z $line ]] || log "$line"
        done < <(wrike_sync_dates)
    fi
    for file in "$DATA_DIR"/expiry/*; do
        uid=${file##*/}
        is_valid_uid "$uid" && [[ -f $file ]] || continue
        remove=$(expiry_get "$uid" remove_utc)
        cleanup=$(expiry_get "$uid" cleanup_utc)
        noticed=$(expiry_get "$uid" noticed)
        if [[ -n $remove && ! ${remove:0:10} > $today ]]; then
            if (
                run_lock "$uid" || { warn "Can't lock run $uid, so its results wait for tomorrow."; exit 1; }
                [[ $(expiry_get "$uid" remove_utc) == "$remove" ]] || exit 1
                teardown_run "$uid" "Results removed on their expiration date, ${remove:0:10}."
            ); then
                log "Run $uid: its results were removed, as their date, ${remove:0:10}, had come."
                removed=$((removed + 1))
            else
                warn "Run $uid: its results couldn't all be removed, so the rest wait for tomorrow."
            fi
            continue
        fi
        if [[ -n $cleanup && ! ${cleanup:0:10} > $today ]]; then
            if (
                run_lock "$uid" || exit 1
                expire_cleanup "$uid" && expiry_set "$uid" cleanup_utc ""
            ); then
                log "Run $uid: its leftovers were deleted, as kept for ${KEEP_RUN_DAYS:-14} days."
                cleaned=$((cleaned + 1))
            else
                warn "Run $uid: its leftovers couldn't be deleted, so they wait for tomorrow."
            fi
        fi
        [[ -n $remove ]] || continue
        days=$(days_until "$remove")
        if (( days <= ${EXPIRATION_NOTICE_DAYS:-14} )) && [[ $noticed != "${remove:0:10}" ]] &&
            run_kept_results "$uid"; then
            if expire_notice "$uid" "$remove" "$days"; then
                ( run_lock "$uid" && expiry_set "$uid" noticed "${remove:0:10}" ) ||
                    warn "Run $uid: couldn't record that its task was warned."
                noticed_count=$((noticed_count + 1))
            fi
        fi
    done
    log "Expiry: $removed runs' results removed, $cleaned runs' leftovers deleted, $noticed_count Wrike tasks warned."
}

# gnoto extend <uid> <YYYY-MM-DD|never>
extend_main() {
    local usage="Usage: gnoto extend <uid> <YYYY-MM-DD|never>" uid when floor task status
    args_parse "$usage" "" "$@"
    [[ ${#ARG_KEYS[@]} -eq 0 && ${#ARG_WORDS[@]} -eq 2 ]] || fail "$usage"
    uid=${ARG_WORDS[0],,}
    when=${ARG_WORDS[1],,}
    is_valid_uid "$uid" || fail "\"$uid\" isn't a run's uid: those are eight letters and digits, such as k3f9a2qx."
    [[ $when == never ]] || { [[ $when =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && date -u -d "$when" > /dev/null 2>&1; } ||
        fail "\"${ARG_WORDS[1]}\" isn't a date written YYYY-MM-DD, or never. $usage"
    [[ -n $(run_state_path "$uid") ]] || fail "There's no run $uid."
    [[ -z $(run_value "$uid" removed_utc) ]] || fail "Run $uid's results have already gone."
    [[ -n $(run_value "$uid" ended_utc) ]] ||
        fail "Run $uid is still going. Its results are kept as its retention says once it ends, and can be extended then."
    floor=$(expiry_floor "$uid")
    if [[ $when != never && $when < $floor ]]; then
        fail "Run $uid's results are kept until at least $floor, ${EXPIRATION_NOTICE_DAYS:-14} days after it ended, so they can't be removed sooner."
    fi
    status=$(run_value "$uid" status)
    (
        run_lock "$uid" || fail "Can't lock run $uid."
        [[ -z $(run_value "$uid" removed_utc) ]] || fail "Run $uid's results have already gone."
        if [[ $when == never ]]; then
            expiry_set "$uid" remove_utc "" && expiry_set "$uid" noticed "" || fail "Can't write $DATA_DIR/expiry/$uid."
            [[ $status == Completed || $status == "Publish failed" ]] || expiry_set "$uid" cleanup_utc "" ||
                fail "Can't write $DATA_DIR/expiry/$uid."
        else
            expiry_set "$uid" remove_utc "${when}T00:00:00Z" && expiry_set "$uid" noticed "" ||
                fail "Can't write $DATA_DIR/expiry/$uid."
            # A failed run's leftovers are what it kept, for gnoto resume
            [[ $status == Completed || $status == "Publish failed" ]] ||
                expiry_set "$uid" cleanup_utc "${when}T00:00:00Z" || fail "Can't write $DATA_DIR/expiry/$uid."
        fi
    ) || exit 1
    task=$(run_value "$uid" wrike.task_id)
    if [[ -n $task ]] && wrike_on; then
        wrike_set_field "$task" expiration "$([[ $when == never ]] || echo "$when")"
    fi
    if [[ $when == never ]]; then
        echo "Run $uid's results are kept for good. $(gnoto_command remove "$uid") removes them."
    else
        echo "Run $uid's results are kept until $when, and removed that day."
    fi
}
