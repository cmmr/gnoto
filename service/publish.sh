#
# publish.sh - The Publish stage: puts a run's results where config.yaml says
# they go, and keeps a running job's progress page at its results address.
#
# Sourced by:  lib/env.sh
# Defines:     globus_on, globus_run_dir, globus_run_url, gnoto_globus,
#              globus_rule_grant, globus_rule_delete, zip_destination,
#              publish_destination, publish_results_url, publish_run,
#              progress_publish, published_location
# Requires:    the S3 helpers from service/aws/aws.sh; state helpers from
#              lib/run_state.sh; zip's sizes from stat; globus-cli, from the
#              image
# Env:         GLOBUS_ENABLED, GLOBUS_DIR, GLOBUS_UUID, GLOBUS_URL,
#              GLOBUS_RUN_PREFIX, GLOBUS_MIN_ZIP_MB and the client's
#              credentials, and the aws section's settings
#
# The deliverables zip is kept in exactly one place: the Globus collection when
# Globus is set, otherwise S3, otherwise the run directory. With both, a zip of
# globus.min_zip_mb (100 MB) or less goes to S3 beside the dashboard, and only
# a larger one to Globus. Present decides, since the pages link the zip where it
# goes, and records it as published.zip_destination, which Publish follows.
# With S3, the results folder, with the dashboard's pages, goes to
# <run_prefix>/<uid>/ in the bucket, and is served from
# <results_base_url>/<run_prefix>/<uid>/.
#
# On Globus, the zip goes to <globus.dir>/<run_prefix>/<uid>/, and the run gets
# a permission of its own: anonymous read on that folder alone, which the
# teardown deletes. Nothing grants access to the run folder itself, which would
# let anyone signed in to Globus list every run. The grant is made with gnoto's
# client, whose credentials are passed only to that call.
#
# Each destination is checked once it's written: the zip's size, and with S3,
# the dashboard and the number of files. Only then does the run's state record
# published.verified_utc, which lets the followup delete the run directory.
# Where it was published goes in the state's published, so a later teardown
# finds it whatever config.yaml says by then.

# Globus delivers the zip when the globus section is on with a directory
globus_on() {
    [[ ${GLOBUS_ENABLED:-false} == true && -n ${GLOBUS_DIR:-} ]]
}

# Where a run's files go in the collection: globus_run_dir <uid>
globus_run_dir() {
    is_valid_uid "$1" || return 1
    printf '%s/%s/%s' "${GLOBUS_DIR%/}" "${GLOBUS_RUN_PREFIX:-gnoto}" "$1"
}

# The address that serves a file there. ?download makes the collection answer
# with an attachment, so a click saves it: globus_run_url <uid> <file>
globus_run_url() {
    is_valid_uid "$1" || return 1
    printf '%s/%s/%s/%s?download' "${GLOBUS_URL%/}" "${GLOBUS_RUN_PREFIX:-gnoto}" "$1" "$(escape_url "$2")"
}

# globus-cli as gnoto's client, whose credentials go only to this call
gnoto_globus() {
    env GLOBUS_CLI_CLIENT_ID="${GLOBUS_CLI_CLIENT_ID:-}" GLOBUS_CLI_CLIENT_SECRET="${GLOBUS_CLI_CLIENT_SECRET:-}" \
        globus "$@"
}

# globus_rule_grant <uid>: anonymous read on the run's own folder in the
# collection, printing the rule's ID
globus_rule_grant() {
    local json id
    [[ -n ${GLOBUS_UUID:-} && -n ${GLOBUS_CLI_CLIENT_ID:-} && -n ${GLOBUS_CLI_CLIENT_SECRET:-} ]] || {
        warn "Sharing a run on Globus needs globus.uuid, cli_client_id and cli_client_secret."
        return 1
    }
    json=$(gnoto_globus endpoint permission create "$GLOBUS_UUID:/${GLOBUS_RUN_PREFIX:-gnoto}/$1/" \
        --anonymous --permissions r -F json 2>&1) || { warn "Globus refused the run's permission: $json"; return 1; }
    id=$(jq -r '.access_id // empty' <<< "$json" 2> /dev/null)
    [[ -n $id ]] || { warn "Globus made the run's permission, and its answer named no ID: $json"; return 1; }
    printf '%s' "$id"
}

# globus_rule_delete <collection> <rule>: one that's gone already is fine
globus_rule_delete() {
    local out
    out=$(gnoto_globus endpoint permission delete "$1" "$2" 2>&1) && return 0
    grep -qiE 'not ?found|AccessRuleNotFound|404' <<< "$out" && return 0
    warn "Globus didn't delete permission $2 on $1: $out"
    return 1
}

# Where a zip of so many bytes goes: globus, s3 or local. A selftest's stays
# local. With both Globus and S3, only a zip larger than globus.min_zip_mb goes
# to Globus.
zip_destination() {
    local bytes=${1:-0}
    if [[ -n $(state_get selftest) ]]; then
        echo local
    elif globus_on && s3_on; then
        if (( bytes > ${GLOBUS_MIN_ZIP_MB:-100} * 1048576 )); then echo globus; else echo s3; fi
    elif globus_on; then
        echo globus
    elif s3_on; then
        echo s3
    else
        echo local
    fi
}

# Where this run's zip goes, as Present decided, or else by its size now
publish_destination() {
    local zip
    if [[ -n $(state_get published.zip_destination) ]]; then
        state_get published.zip_destination
    else
        zip=$(publish_zip_name "${PWD##*/}")
        zip_destination "$( [[ -z $zip ]] || stat -c %s "$zip")"
    fi
}

# The address of a run's dashboard: S3's, else nothing, since with Globus alone
# the dashboard is in the zip
publish_results_url() {
    if [[ -z $(state_get selftest) ]] && s3_on; then
        printf '%sindex.html' "$(s3_run_url "$1")"
    fi
}

# Records where a run's files went, for its teardown: published_location
# <field> <value>, such as s3_bucket or globus_dir
published_location() {
    [[ $(state_get "published.$1") == "$2" ]] || state_set "published.$1" "$2" > /dev/null
}

# Keeps a running job's progress page at its results address, with S3:
# uploads the page's assets once, then index.html and progress.json whenever
# they've changed. Run from the run directory after the page is rendered.
# Never fails, and stops once Present has replaced the page.
progress_publish() {
    local uid=${PWD##*/} prefix name sum digests=.progress-digests
    s3_on && [[ -z $(state_get selftest) && -z $(state_get stages.present) ]] || return 0
    [[ -f results/index.html ]] || return 0
    prefix=$(s3_run_key "$uid")
    published_location s3_bucket "$AWS_S3_BUCKET"
    published_location s3_prefix "$prefix"
    if [[ ! -e .progress-assets && -d results/assets ]]; then
        gnoto_aws s3 cp --only-show-errors --recursive results/assets/ "s3://$AWS_S3_BUCKET/$prefix/assets/" \
            > /dev/null 2>&1 && : > .progress-assets || return 0
    fi
    for name in progress.json index.html; do
        [[ -f results/$name ]] || continue
        sum=$(md5sum < "results/$name" | cut -d' ' -f1)
        ! grep -qx "$name $sum" "$digests" 2> /dev/null || continue
        if [[ $name == index.html ]]; then
            s3_put "results/$name" "$AWS_S3_BUCKET" "$prefix/$name" "text/html; charset=utf-8" no-cache > /dev/null 2>&1
        else
            s3_put "results/$name" "$AWS_S3_BUCKET" "$prefix/$name" application/json no-cache > /dev/null 2>&1
        fi || return 0
        { grep -v "^$name " "$digests" 2> /dev/null; echo "$name $sum"; } > "$digests.tmp" &&
            mv -f "$digests.tmp" "$digests"
    done
    return 0
}

# The run's zip, which Present built in the run directory, or nothing
publish_zip_name() {
    local uid=$1 zip
    for zip in ./*_"$uid".zip "./$uid.zip"; do
        [[ -f $zip ]] && { printf '%s' "${zip#./}"; return 0; }
    done
}

# publish_run <uid>: from the run directory, once Present has finished. Fails,
# with the reason, when a destination can't be written or doesn't check out,
# and leaves the results and zip here then, so gnoto publish can try again.
publish_run() {
    local uid=$1 destination zip prefix="" dir output count local_count url="" zip_url="" size rule

    destination=$(publish_destination)
    zip=$(publish_zip_name "$uid")
    [[ -d results && -f results/index.html ]] || fail "There's no dashboard in $PWD/results to publish."

    if [[ -z $(state_get selftest) ]] && s3_on; then
        prefix=$(s3_run_key "$uid")
        published_location s3_bucket "$AWS_S3_BUCKET"
        published_location s3_prefix "$prefix"
        log "Copying the results to s3://$AWS_S3_BUCKET/$prefix/..."
        output=$(s3_upload_results results "$AWS_S3_BUCKET" "$prefix") ||
            fail "The results couldn't be copied to s3://$AWS_S3_BUCKET/$prefix/: $output"
        url=$(publish_results_url "$uid")
    fi

    case $destination in
        globus)
            [[ -n $zip ]] || fail "There's no zip in $PWD to deliver through Globus."
            dir=$(globus_run_dir "$uid") || fail "\"$uid\" isn't a uid."
            log "Copying $zip to $dir..."
            published_location globus_dir "$dir"
            mkdir -p "$dir" || fail "Can't create $dir, in globus.dir."
            # Read as the collection's anonymous user, not the job's
            chmod a+rx "$(dirname "$dir")" "$dir" 2> /dev/null || :
            rm -f "$dir/.$zip.tmp"
            cp "$zip" "$dir/.$zip.tmp" && chmod a+r "$dir/.$zip.tmp" && mv -f "$dir/.$zip.tmp" "$dir/$zip" ||
                { rm -f "$dir/.$zip.tmp"; fail "Couldn't copy $zip to $dir."; }
            [[ $(stat -c %s "$dir/$zip") == "$(stat -c %s "$zip")" ]] ||
                fail "The zip copied to $dir isn't the size of $PWD/$zip."
            # Its own permission, unless an earlier attempt made it
            if [[ -z $(state_get published.globus_rule) || $(state_get published.globus_uuid) != "$GLOBUS_UUID" ]]; then
                rule=$(globus_rule_grant "$uid") ||
                    fail "The zip is on Globus, and couldn't be shared there, as the message above says."
                published_location globus_uuid "$GLOBUS_UUID"
                state_set published.globus_rule "$rule"
            fi
            zip_url=$(globus_run_url "$uid" "$zip")
            ;;
        s3)
            [[ -n $zip ]] || fail "There's no zip in $PWD to publish to S3."
            log "Copying $zip to s3://$AWS_S3_BUCKET/$prefix/$zip..."
            output=$(s3_put "$zip" "$AWS_S3_BUCKET" "$prefix/$zip" application/zip 2>&1) ||
                fail "$zip couldn't be copied to s3://$AWS_S3_BUCKET/$prefix/: $output"
            size=$(gnoto_aws s3api head-object --bucket "$AWS_S3_BUCKET" --key "$prefix/$zip" \
                --query ContentLength --output text 2> /dev/null) || size=""
            [[ $size == "$(stat -c %s "$zip")" ]] ||
                fail "S3's copy of $zip isn't its size: ${size:-none was found}."
            zip_url=$(s3_run_url "$uid")$(escape_url "$zip")
            ;;
    esac

    if [[ -n $prefix ]]; then
        local_count=$(find results -type f | wc -l)
        count=$(s3_count "$AWS_S3_BUCKET" "$prefix") || fail "Can't list s3://$AWS_S3_BUCKET/$prefix/ to check it."
        [[ $destination != s3 ]] || count=$((count - 1))
        (( count >= local_count )) ||
            fail "S3 has $count of the results' $local_count files under s3://$AWS_S3_BUCKET/$prefix/."
        gnoto_aws s3api head-object --bucket "$AWS_S3_BUCKET" --key "$prefix/index.html" > /dev/null 2>&1 ||
            fail "S3 has no dashboard at s3://$AWS_S3_BUCKET/$prefix/index.html."
    fi

    [[ -z $url ]] || state_set published.url "$url"
    [[ -z $zip_url ]] || state_set published.zip_url "$zip_url"
    if [[ $destination != local ]]; then
        # The zip is kept in one place only
        rm -f "$zip"
        state_set published.verified_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        log "Published: ${url:-$zip_url}"
    fi
    return 0
}

# gnoto publish <uid>: runs Present and Publish again as a job, for a run whose
# Compute finished and whose results are still in its run directory, as after
# "Publish failed", or after S3 or Globus was set up. At the run's own commit.
# Safe to repeat. Needs run_lock, live_status and FINAL_STATUSES from
# lib/runs.sh, and args_parse from lib/args.sh.
publish_main() {
    local usage="Usage: gnoto publish <uid>" uid dir status url kind job_id followup_id ended status_before
    args_parse "$usage" "" "$@"
    [[ ${#ARG_KEYS[@]} -eq 0 && ${#ARG_WORDS[@]} -eq 1 ]] || fail "$usage"
    uid=${ARG_WORDS[0],,}
    is_valid_uid "$uid" || fail "\"$uid\" isn't a run's uid: those are eight letters and digits, such as k3f9a2qx."
    dir=$DATA_DIR/runs/$uid
    if [[ ! -r $dir/$RUN_STATE_FILE ]]; then
        if [[ -r $DATA_DIR/history/$uid/state.json ]]; then
            url=$(jq -r '.published.url // .published.zip_url // empty' "$DATA_DIR/history/$uid/state.json")
            [[ -z $url ]] || fail "Run $uid was published, at $url, and its run directory has gone."
            fail "Run $uid's results have gone, so there's nothing to publish."
        fi
        fail "There's no run $uid."
    fi
    cd "$dir" || fail "Can't enter $dir."
    status=$(get_run_status)
    case $status in
        Completed | "Publish failed") ;;
        *)
            [[ $FINAL_STATUSES != *" $status "* ]] || fail "Run $uid's results were never made, as it ended $status."
            fail "Run $uid is still going, as $(live_status). Publish it once it has ended."
            ;;
    esac
    [[ -n $(state_get stages.compute) && -d results ]] || fail "Run $uid has no results in $dir to publish."
    [[ ! -e remove ]] || fail "Run $uid is being removed, as gnoto remove was asked."

    # At the run's own commit, from here on
    code_version
    if [[ $(state_get dev) != true ]]; then
        version_route "$(state_get repository)" "$(state_get commit)"
    fi

    # The run is going again until its followup records its end, so remove
    # waits for that. The expiry file stays until the followup rewrites it.
    ended=$(state_get ended_utc)
    status_before=$(get_run_status)
    (
        run_lock "$uid" || fail "Can't lock run $uid."
        [[ -d $dir && ! -e remove ]] || fail "Run $uid is being removed, as gnoto remove was asked."
        state_update '
            del(.stages.present, .stages.publish, .ended_utc, .message, .stage, .published.verified_utc)
            | .status = "Submitted" | .republished_utc = $now
            | .notes = ((.notes // []) + ["Published again, as \($user) asked at \($now)."])' \
            --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg user "$(id -un)" ||
            fail "Can't record in run $uid's state that it's published again."
        rm -f cancel
    ) || exit 1

    kind=$(scheduler_kind)
    state_set scheduler.kind "$kind"
    if [[ $kind == local ]]; then
        scheduler_submit --name "gnoto-$uid" --dir "$dir" --log "$dir/publish.out" \
            -- _local "$dir" publish > /dev/null || publish_refused "Couldn't start publishing on this machine."
    else
        job_id=$(scheduler_submit --name "gnoto-$uid-publish" --dir "$dir" --log "$dir/publish.out" \
            --cpus 2 --mem 8G --time 12:00:00 -- _publish "$dir") ||
            publish_refused "Slurm refused the publishing job; the message above says why."
        state_set scheduler.job_id "$job_id"
        if ! followup_id=$(scheduler_submit --name "gnoto-$uid-followup" --dir "$dir" \
            --log "$dir/followup.out" --cpus 1 --mem 2G --time 02:00:00 \
            --after "afterany:$job_id" -- _followup "$dir"); then
            scheduler_cancel "$job_id"
            publish_refused "Slurm refused the followup, so publishing was cancelled; the message above says why."
        fi
        state_set scheduler.followup_id "$followup_id"
    fi
    echo "Publishing run $uid again. $(gnoto_command status "$uid") shows when it's done."
}

# Puts back the run's status and end, after a submission gnoto publish made
# was refused, and fails with why. Reads ended and status_before from
# publish_main, its caller.
publish_refused() {
    state_update '.status = $status | .ended_utc = $ended | .message = $why' \
        --arg status "$status_before" --arg ended "$ended" --arg why "$1" ||
        warn "Couldn't put back run ${PWD##*/}'s state."
    fail "$1"
}
