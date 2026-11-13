#
# publish.sh - The Publish stage: puts a run's results where config.yaml says
# they go, and keeps a running job's progress page at its results address.
#
# Sourced by:  lib/env.sh
# Defines:     globus_ready, globus_takes, globus_run_dir, globus_run_path,
#              globus_run_url, globus_browse_url, gnoto_globus,
#              globus_path_rules, globus_path_rules_delete, globus_rule_delete,
#              run_address, zip_destination, publish_destination,
#              publish_results_url, publish_access_page, publish_run,
#              progress_publish, published_location
# Requires:    the S3 helpers from service/aws/aws.sh; state helpers from
#              lib/run_state.sh; zip's sizes from stat; globus-cli, from the
#              image
# Env:         GLOBUS_ENABLED, GLOBUS_DIR, GLOBUS_UUID, GLOBUS_URL,
#              GLOBUS_RUN_PREFIX, GLOBUS_PIPELINES, GLOBUS_APP_CLIENT_ID and
#              the client's credentials, and the aws section's settings
#
# The deliverables zip is kept in exactly one place: on the Globus collection
# for a pipeline named in globus.pipelines (taxprofiler and biobakery unless
# set) when Globus is ready, otherwise on S3 beside the dashboard, otherwise in
# the run directory. Present decides, since the pages link the zip where it
# goes, and records it as published.zip_destination, which Publish follows.
#
# With S3, the results folder, with the dashboard's pages, goes to
# <run_prefix>/<uid>-<token>/ in the bucket, and is served from
# <results_base_url>/<uid>-<token>/. The token, made with the
# run's state, is what keeps the address from being guessed: the uid shows
# wherever the run does, such as in squeue and the zip's name.
#
# On Globus, the zip goes to <globus.dir>/<run_prefix>/<uid>/, and Publish
# grants nobody anything, since an anonymous permission would let anyone signed
# in to Globus list every run and download any. Whoever has the dashboard's
# address gets the data through its Get the data button instead: it signs them
# in to Globus, and the listener grants that identity read on the run's folder
# (service/access.sh). So Globus is ready only with S3 and the queue's access
# address too. Publish writes globus.json beside the dashboard, which tells
# the access Lambda the address is a run on Globus, and access.html, the page
# Globus's sign-in returns to, at <run_prefix>/access.html. The teardown
# deletes every permission on the run's folder.
#
# Each destination is checked once it's written: the zip's size, and with S3,
# the dashboard and the number of files. Only then does the run's state record
# published.verified_utc, which lets the followup delete the run directory.
# Where it was published goes in the state's published, so a later teardown
# finds it whatever config.yaml says by then.

GLOBUS_AUTH_URL=${GLOBUS_AUTH_URL:-https://auth.globus.org}

# Globus delivers zips when its section is on with its directory, collection
# and the dashboard's app, and S3 and the access address are set up, since a
# reader gets a run's data only through its dashboard
globus_ready() {
    [[ ${GLOBUS_ENABLED:-false} == true && -n ${GLOBUS_DIR:-} && -n ${GLOBUS_UUID:-} &&
        -n ${GLOBUS_URL:-} && -n ${GLOBUS_APP_CLIENT_ID:-} && -n ${AWS_SQS_ACCESS_URL:-} ]] && s3_on && sqs_on
}

# Whether a pipeline's zip goes to Globus when it's ready: globus_takes <pipeline>
globus_takes() {
    local list=${GLOBUS_PIPELINES-taxprofiler,biobakery}
    list=${list// /}
    [[ -n $1 && ",$list," == *",$1,"* ]]
}

# Where a run's files go in the collection: globus_run_dir <uid>
globus_run_dir() {
    is_valid_uid "$1" || return 1
    printf '%s/%s/%s' "${GLOBUS_DIR%/}" "${GLOBUS_RUN_PREFIX:-gnoto}" "$1"
}

# That folder as the collection names it, for its permissions:
# globus_run_path <uid>
globus_run_path() {
    is_valid_uid "$1" || return 1
    printf '/%s/%s/' "${GLOBUS_RUN_PREFIX:-gnoto}" "$1"
}

# The address that serves a file there. ?download makes the collection answer
# with an attachment, so a click saves it: globus_run_url <uid> <file>
globus_run_url() {
    is_valid_uid "$1" || return 1
    printf '%s/%s/%s/%s?download' "${GLOBUS_URL%/}" "${GLOBUS_RUN_PREFIX:-gnoto}" "$1" "$(escape_url "$2")"
}

# The folder in Globus's web app, to transfer it from: globus_browse_url <uid>
globus_browse_url() {
    local path
    path=$(globus_run_path "$1") || return 1
    printf 'https://app.globus.org/file-manager?origin_id=%s&origin_path=%s' \
        "$GLOBUS_UUID" "$(jq -rn --arg p "$path" '$p | @uri')"
}

# globus-cli as gnoto's client, whose credentials go only to this call, in the
# environment of a subshell that becomes it, never on a command line
gnoto_globus() {
    (
        export GLOBUS_CLI_CLIENT_ID=${GLOBUS_CLI_CLIENT_ID:-} GLOBUS_CLI_CLIENT_SECRET=${GLOBUS_CLI_CLIENT_SECRET:-}
        exec globus "$@"
    )
}

# The permissions on one folder, as "<id>\t<principal type>\t<principal>"
# lines: globus_path_rules <collection> <path>. Fails, with Globus's answer,
# when they can't be listed.
globus_path_rules() {
    local json
    json=$(gnoto_globus endpoint permission list "$1" -F json 2>&1) || { printf '%s' "$json" >&2; return 1; }
    jq -r --arg path "${2%/}/" '.DATA[]? | select(((.path // "") | rtrimstr("/")) + "/" == $path)
        | [.id, .principal_type, (.principal // "")] | @tsv' <<< "$json"
}

# Deletes every permission on a folder: globus_path_rules_delete <collection>
# <path>. Warns about any it couldn't, and returns 1.
globus_path_rules_delete() {
    local rules id failed=0
    rules=$(globus_path_rules "$1" "$2" 2>&1) ||
        { warn "Couldn't list the Globus permissions on $2, so they weren't deleted: $rules"; return 1; }
    while IFS=$'\t' read -r id _; do
        [[ -n $id ]] || continue
        globus_rule_delete "$1" "$id" || failed=1
    done <<< "$rules"
    return $failed
}

# globus_rule_delete <collection> <rule>: one that's gone already is fine
globus_rule_delete() {
    local out
    out=$(gnoto_globus endpoint permission delete "$1" "$2" 2>&1) && return 0
    grep -qiE 'not ?found|AccessRuleNotFound|404' <<< "$out" && return 0
    warn "Globus didn't delete permission $2 on $1: $out"
    return 1
}

# A run's published folder, <uid>-<token>, from the run directory's state:
# run_address <uid>
run_address() {
    local token
    token=$(state_get address_token)
    [[ $token =~ ^[a-z2-7]{16}$ ]] || return 1
    printf '%s-%s' "$1" "$token"
}

# Where a pipeline's zip goes: globus, s3 or local. A selftest's stays local.
zip_destination() {
    if [[ -n $(state_get selftest) ]]; then
        echo local
    elif globus_ready && globus_takes "${1:-}"; then
        echo globus
    elif s3_on; then
        echo s3
    else
        echo local
    fi
}

# Where this run's zip goes, as Present decided, or else by its pipeline now
publish_destination() {
    if [[ -n $(state_get published.zip_destination) ]]; then
        state_get published.zip_destination
    else
        zip_destination "$(state_get pipeline)"
    fi
}

# The address of a run's dashboard: S3's, else nothing, since without S3 the
# dashboard stays in the run directory and the zip
publish_results_url() {
    local address
    if [[ -z $(state_get selftest) ]] && s3_on && address=$(run_address "$1"); then
        printf '%sindex.html' "$(s3_run_url "$address")"
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
    local uid=${PWD##*/} address prefix name sum digests=.progress-digests
    s3_on && [[ -z $(state_get selftest) && -z $(state_get stages.present) ]] || return 0
    [[ -f results/index.html ]] || return 0
    address=$(run_address "$uid") || return 0
    prefix=$(s3_run_key "$address")
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

# Puts the page Globus's sign-in returns to at <run_prefix>/access.html in the
# bucket, from present/templates/access.html with the access address filled in.
# One page serves every run, since Globus returns only to an address it was
# given when the dashboard's app was registered.
publish_access_page() {
    local page url
    page=$(< "$CODE_DIR/present/templates/access.html") || return 1
    url=$(jq -n --arg url "$AWS_SQS_ACCESS_URL" '$url')
    page=${page//__ACCESS_URL__/"$url"}
    printf '%s\n' "$page" | s3_put - "$AWS_S3_BUCKET" "${AWS_S3_RUN_PREFIX:-gnoto}/access.html" \
        "text/html; charset=utf-8" no-cache > /dev/null 2>&1
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
    local uid=$1 destination zip prefix="" address dir output count local_count url="" zip_url="" size

    destination=$(publish_destination)
    zip=$(publish_zip_name "$uid")
    [[ -d results && -f results/index.html ]] || fail "There's no dashboard in $PWD/results to publish."

    if [[ -z $(state_get selftest) ]] && s3_on; then
        address=$(run_address "$uid") || fail "Run $uid's state has no address token, so it has no address to publish at."
        prefix=$(s3_run_key "$address")
        published_location s3_bucket "$AWS_S3_BUCKET"
        published_location s3_prefix "$prefix"
    fi

    # A zip on Globus goes first, so the dashboard that offers it never comes
    # before it
    if [[ $destination == globus ]]; then
        [[ -n $zip ]] || fail "There's no zip in $PWD to deliver through Globus."
        [[ -n $prefix ]] || fail "A zip on Globus is reached through its dashboard on S3, and S3 isn't set up."
        dir=$(globus_run_dir "$uid") || fail "\"$uid\" isn't a uid."
        log "Copying $zip to $dir..."
        published_location globus_dir "$dir"
        published_location globus_uuid "$GLOBUS_UUID"
        published_location globus_path "$(globus_run_path "$uid")"
        mkdir -p "$dir" || fail "Can't create $dir, in globus.dir."
        # Read through the collection as its owner's account, not the job's
        chmod a+rx "$(dirname "$dir")" "$dir" 2> /dev/null || :
        rm -f "$dir/.$zip.tmp"
        cp "$zip" "$dir/.$zip.tmp" && chmod a+r "$dir/.$zip.tmp" && mv -f "$dir/.$zip.tmp" "$dir/$zip" ||
            { rm -f "$dir/.$zip.tmp"; fail "Couldn't copy $zip to $dir."; }
        [[ $(stat -c %s "$dir/$zip") == "$(stat -c %s "$zip")" ]] ||
            fail "The zip copied to $dir isn't the size of $PWD/$zip."
    fi

    if [[ -n $prefix ]]; then
        log "Copying the results to s3://$AWS_S3_BUCKET/$prefix/..."
        output=$(s3_upload_results results "$AWS_S3_BUCKET" "$prefix") ||
            fail "The results couldn't be copied to s3://$AWS_S3_BUCKET/$prefix/: $output"
        url=$(publish_results_url "$uid")
    fi

    case $destination in
        globus)
            publish_access_page ||
                fail "The page Globus's sign-in returns to couldn't be put at s3://$AWS_S3_BUCKET/${AWS_S3_RUN_PREFIX:-gnoto}/access.html."
            # Last, since it's what lets a reader ask for the zip
            output=$(printf '{"uid":"%s"}\n' "$uid" |
                s3_put - "$AWS_S3_BUCKET" "$prefix/globus.json" application/json no-cache 2>&1) ||
                fail "The zip is on Globus, and the dashboard couldn't be told so at s3://$AWS_S3_BUCKET/$prefix/globus.json: $output"
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
            zip_url=$(s3_run_url "$address")$(escape_url "$zip")
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
