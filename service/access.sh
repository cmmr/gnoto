#
# access.sh - Get the data: grants the Globus identity a dashboard's reader
# signed in with read on the run's folder in the collection, for the listener.
#
# Sourced by:  lib/main.sh, for _listen
# Defines:     access_request
# Requires:    gnoto_globus and globus_path_rules from service/publish.sh;
#              s3_put from service/aws/aws.sh; run_state_path and run_value
#              from service/expire.sh; log and warn from lib/utilities.sh
# Env:         GLOBUS_MAX_PEOPLE, AWS_S3_BUCKET and AWS_RUN_PREFIX
#
# The access Lambda (service/aws/lambda/access.py) queues
# {"gnoto": "globus_access", run, request, identity, username} once Globus has
# signed the reader in and the run's globus.json is in the bucket. Anyone with
# the dashboard's address may have the data, so this checks the run, not the
# reader: the address's token against the run's state, that its zip is on
# Globus and hasn't been removed, and how many people it's shared with. Then
# it grants the identity read on the run's folder, unless it has it already,
# and answers at <run's prefix>/access/<request>.json, which the dashboard
# waits for:
#
#   granted   the identity can download the zip
#   full      the run is shared with globus.max_people identities already
#   gone      the run's zip isn't on Globus any more
#   failed    Globus refused, as the listener's log says
#
# The permissions are the record of who has access, and the teardown deletes
# every one on the folder, so nothing goes in the run's state, which another
# account may own.

ACCESS_IDENTITY_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# access_answer <run> <request> <status>
access_answer() {
    local key=${AWS_RUN_PREFIX:-gnoto}/$1/access/$2.json
    printf '{"status":"%s"}\n' "$3" | s3_put - "$AWS_S3_BUCKET" "$key" application/json no-cache > /dev/null 2>&1 ||
        warn "Couldn't answer a Globus access request at s3://$AWS_S3_BUCKET/$key."
}

# Handles one request, as compact JSON. Returns 0 whatever the outcome, since
# the dashboard has its answer and the reader can ask again.
access_request() {
    local json=$1 run request identity username uid collection path rules count out
    run=$(jq -r '.run // empty' <<< "$json")
    request=$(jq -r '.request // empty' <<< "$json")
    identity=$(jq -r '.identity // empty' <<< "$json")
    username=$(jq -r '.username // empty' <<< "$json" | tr -cd '[:graph:]' | head -c 200)
    if [[ ! $run =~ ^[a-z2-7]{8}-[a-z2-7]{16}$ || ! $request =~ ^[0-9a-f]{32}$ ||
        ! $identity =~ $ACCESS_IDENTITY_PATTERN ]]; then
        log "Ignored a Globus access request that isn't well formed."
        return 0
    fi
    uid=${run%%-*}
    username=${username:-$identity}

    if [[ -z $(run_state_path "$uid") ]]; then
        log "Ignored a Globus access request for $run, which isn't a run here."
        return 0
    fi
    # The Lambda found globus.json at this address, which gnoto wrote, so a
    # token that doesn't match means the run's state isn't what published it
    if [[ $(run_value "$uid" address_token) != "${run#*-}" ]]; then
        log "Ignored a Globus access request for run $uid at an address that isn't its own."
        return 0
    fi
    collection=$(run_value "$uid" published.globus_uuid)
    path=$(run_value "$uid" published.globus_path)
    if [[ -n $(run_value "$uid" removed_utc) || -z $collection || -z $path ||
        $(run_value "$uid" published.zip_destination) != globus ]]; then
        log "Run $uid's zip isn't on Globus, so $username wasn't given access."
        access_answer "$run" "$request" gone
        return 0
    fi

    if ! rules=$(globus_path_rules "$collection" "$path" 2>&1); then
        warn "Couldn't list run $uid's Globus permissions, so $username wasn't given access: $rules"
        access_answer "$run" "$request" failed
        return 0
    fi
    if grep -q $'\tidentity\t'"$identity"'$' <<< "$rules"; then
        log "Run $uid: $username has Globus access already."
        access_answer "$run" "$request" granted
        return 0
    fi
    count=$(grep -c . <<< "$rules" || :)
    if (( count >= ${GLOBUS_MAX_PEOPLE:-20} )); then
        log "Run $uid is shared with $count Globus identities, globus.max_people, so $username wasn't given access."
        access_answer "$run" "$request" full
        return 0
    fi
    if out=$(gnoto_globus endpoint permission create "$collection:$path" --identity "$identity" \
        --permissions r -F json 2>&1) || grep -q Exists <<< "$out"; then
        log "Run $uid: gave $username ($identity) read on Globus."
        access_answer "$run" "$request" granted
    else
        warn "Globus refused run $uid's permission for $username: $(head -c 300 <<< "$out")"
        access_answer "$run" "$request" failed
    fi
    return 0
}
