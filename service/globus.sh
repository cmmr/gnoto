#
# globus.sh - gnoto config globus: the run folder on the guest collection, and
# a check that gnoto's client can share it; and lint's checks of Globus.
#
# Sourced by:  lib/lint.sh
# Defines:     config_globus_step, lint_globus, globus_rules,
#              globus_open_rules, globus_exposing_rules
# Requires:    globus-cli and curl, from the image; gnoto_globus,
#              globus_ready and globus_rule_delete from service/publish.sh;
#              config_confirm from lib/config.sh; lint_ok, lint_warn and
#              lint_fail from lib/lint.sh
# Env:         the globus section's settings, and the aws section's
#              results_base_url, run_prefix and access_url
#
# Every call signs in with the client credentials in config.yaml, passed only
# to that call, as globus-cli reads them, so any member of gnoto's group can
# make it and nobody runs globus login. The client needs the Access Manager role
# on the guest collection, since each reader who signs in through a dashboard's
# Get the data gets a permission of their own on <run_prefix>/<uid>/, which the
# run's teardown deletes (service/access.sh).
#
# Nothing may grant anonymous or all-users access to the run folder, to
# anything above it, or to any run: Globus lets anyone list the folders above
# one shared with everyone, so anyone signed in could list every run and
# download any. lint fails on such a permission. A collection holds at most
# 1000 permissions, so lint warns as the count nears it.
#
# Creating the guest collection, giving the client its role, and registering
# the dashboards' app stay steps done by hand, since they depend on the site's
# endpoint, its policies and the results' address.

GLOBUS_RULE_LIMIT=1000

# The collection's permissions, as "<id>\t<principal type>\t<path>" lines.
# Fails when the client can't list them.
globus_rules() {
    local json
    json=$(gnoto_globus endpoint permission list "$GLOBUS_UUID" -F json 2>&1) || { printf '%s' "$json" >&2; return 1; }
    jq -r '.DATA[]? | [.id, .principal_type, .path] | @tsv' <<< "$json"
}

# The permissions for anyone, anonymous or signed in, as "<id>\t<path>" lines
globus_open_rules() {
    awk -F'\t' '$2 == "anonymous" || $2 == "all_authenticated_users" { print $1 "\t" $3 }' <<< "$1"
}

# Those that open the run folder, anything above it, or anything in it
globus_exposing_rules() {
    local id path run=/${GLOBUS_RUN_PREFIX:-gnoto}/
    while IFS=$'\t' read -r id path; do
        [[ -n $id ]] || continue
        path=${path%/}/
        [[ $run != "$path"* && $path != "$run"* ]] || printf '%s\t%s\n' "$id" "$path"
    done <<< "$(globus_open_rules "$1")"
}

# The message for a client without the role it needs
globus_role_advice() {
    echo "gnoto's client needs the Access Manager role on the collection. An administrator of it grants it with: globus endpoint role create $GLOBUS_UUID --identity ${GLOBUS_CLI_CLIENT_ID:-<client ID>}@clients.auth.globus.org --role access_manager"
}

# The page the dashboards' app returns to, which it's registered with
globus_return_page() {
    printf '%s/%s/access.html' "${AWS_RESULTS_BASE_URL%/}" "${AWS_RUN_PREFIX:-gnoto}"
}

# gnoto config globus, once its settings are written
config_globus_step() {
    local dir=${GLOBUS_DIR%/}/${GLOBUS_RUN_PREFIX:-gnoto} rules exposing plan=() check name rule
    [[ ${GLOBUS_ENABLED:-false} == true ]] || return 0
    [[ -n ${GLOBUS_DIR:-} && -n ${GLOBUS_UUID:-} && -n ${GLOBUS_URL:-} ]] ||
        fail "globus needs dir, uuid and url, from the guest collection made by hand."
    [[ -n ${GLOBUS_CLI_CLIENT_ID:-} && -n ${GLOBUS_CLI_CLIENT_SECRET:-} ]] ||
        fail "globus needs cli_client_id and cli_client_secret, from a client registered for gnoto."
    [[ ${GLOBUS_RUN_PREFIX:-gnoto} =~ ^[A-Za-z0-9._-]+$ ]] || fail "globus.run_prefix should be one folder name, such as gnoto."
    gnoto_globus endpoint show "$GLOBUS_UUID" > /dev/null ||
        fail "The client can't see the collection $GLOBUS_UUID. Check its credentials, and $(globus_role_advice)"
    rules=$(globus_rules) || fail "The client can't list the collection's permissions. $(globus_role_advice)"
    exposing=$(globus_exposing_rules "$rules")
    if [[ -n $exposing ]]; then
        fail "These permissions let anyone signed in to Globus list the runs in /${GLOBUS_RUN_PREFIX:-gnoto}/ and download them. Delete each with globus endpoint permission delete $GLOBUS_UUID <id>:"$'\n'"$exposing"
    fi
    [[ -d $dir ]] || plan+=("Create the run folder $dir")
    plan+=("Check that gnoto's client can share a folder there: a test folder, with a permission for the client itself, made and deleted again")
    config_confirm "on Globus" "${plan[@]}" || exit 0
    mkdir -p "$dir" && chmod 2775 "$dir" && chmod o+rx "$dir" ||
        fail "Can't create $dir. If globus.dir exists, add it to apptainer.binds, so gnoto can see it."

    name=gnoto-check-$$
    check=$dir/$name
    mkdir "$check" || fail "Can't create $check."
    rule=$(gnoto_globus endpoint permission create "$GLOBUS_UUID:/${GLOBUS_RUN_PREFIX:-gnoto}/$name/" \
        --identity "$GLOBUS_CLI_CLIENT_ID" --permissions r -F json 2>&1 | jq -r '.access_id // empty' 2> /dev/null) || rule=""
    [[ -z $rule ]] || globus_rule_delete "$GLOBUS_UUID" "$rule" ||
        warn "Delete the test permission $rule by hand: globus endpoint permission delete $GLOBUS_UUID $rule"
    rmdir "$check"
    [[ -n $rule ]] || fail "Globus didn't make the test folder's permission. $(globus_role_advice)"
    echo "gnoto's client can share a run with the identity a reader signs in with, and nobody can list the runs."

    if [[ -z ${GLOBUS_APP_CLIENT_ID:-} ]]; then
        echo "A reader gets a run's data by signing in from its dashboard, through an app registered for gnoto: at app.globus.org/settings/developers, register a public client (\"thick client or script\") whose redirect is $(globus_return_page), then $(gnoto_command config globus "--app_client_id=<its client ID>")."
    elif [[ -z ${AWS_ACCESS_URL:-} ]]; then
        echo "The dashboards post a reader's sign-in to a Lambda that $(gnoto_command config sqs --deploy) makes, now that globus.app_client_id is set."
    fi
    LINT_FAILS=0
    lint_globus
    (( LINT_FAILS == 0 )) || fail "Globus isn't ready, as above."
    echo "Globus is ready."
}

# lint's Globus checks: everything a run on Globus needs is set, the run folder
# can be written, the client can manage the collection's permissions, none
# opens the runs to everyone, how many there are, and that Get the data's
# address answers
lint_globus() {
    local dir=${GLOBUS_DIR%/}/${GLOBUS_RUN_PREFIX:-gnoto} rules exposing count people runs name code
    [[ ${GLOBUS_ENABLED:-false} == true ]] || return 0
    if [[ -z ${GLOBUS_DIR:-} || -z ${GLOBUS_URL:-} || -z ${GLOBUS_UUID:-} ]]; then
        lint_fail "globus: is on, and needs dir, uuid and url. $(gnoto_command config globus) asks for them"
        return 0
    fi
    for name in ${GLOBUS_PIPELINES//,/ }; do
        [[ $name =~ ^[a-z][a-z0-9_]*$ && -f $CODE_DIR/pipelines/$name/pipeline.sh ]] ||
            lint_fail "globus: globus.pipelines names $name, which isn't a pipeline"
    done
    if [[ -z ${GLOBUS_APP_CLIENT_ID:-} ]]; then
        lint_fail "globus: globus.app_client_id isn't set, so nobody could get a run's data. $(gnoto_command config globus) says how to register the app"
    elif ! s3_on || ! sqs_on || [[ -z ${AWS_ACCESS_URL:-} ]]; then
        lint_fail "globus: a reader gets a run's data through its dashboard, which needs S3, the queue and aws.access_url. $(gnoto_command config sqs --deploy) makes the address once S3 is set up"
    else
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -X POST -H 'Content-Type: text/plain' \
            --data '{}' "$AWS_ACCESS_URL" 2> /dev/null) || code=""
        if [[ $code == 400 ]]; then
            lint_ok "globus: Get the data's address answers"
        else
            lint_fail "globus: Get the data's address, $AWS_ACCESS_URL, didn't answer a test request as expected (HTTP ${code:-none})"
        fi
    fi
    if [[ ! -d $dir || ! -w $dir ]]; then
        lint_fail "globus: can't write $dir. If globus.dir exists, add it to apptainer.binds, so gnoto can see it; $(gnoto_command config globus) creates the run folder"
    fi
    if [[ -z ${GLOBUS_CLI_CLIENT_ID:-} || -z ${GLOBUS_CLI_CLIENT_SECRET:-} ]]; then
        lint_fail "globus: cli_client_id and cli_client_secret aren't set, and a run on Globus needs them to be shared"
        return 0
    fi
    if ! rules=$(globus_rules 2> /dev/null); then
        lint_fail "globus: the client can't list the collection's permissions, so a run can't be shared there. $(globus_role_advice)"
        return 0
    fi
    exposing=$(globus_exposing_rules "$rules")
    if [[ -n $exposing ]]; then
        lint_fail "globus: a permission lets anyone signed in to Globus list the runs and download them: $(paste -sd ';' <<< "$exposing" | sed 's/\t/ on /g; s/;/; /g'). Delete it with: globus endpoint permission delete $GLOBUS_UUID <id>"
    fi
    count=$(grep -c . <<< "$rules" || :)
    if (( count >= GLOBUS_RULE_LIMIT * 9 / 10 )); then
        lint_warn "globus: the collection has $count permissions, of the $GLOBUS_RULE_LIMIT Globus allows. Lower globus.max_people, or shorten retention"
    elif [[ -z $exposing ]]; then
        people=$(awk -F'\t' -v run="/${GLOBUS_RUN_PREFIX:-gnoto}/" '$2 == "identity" && index($3, run) == 1' <<< "$rules" | grep -c . || :)
        runs=$(awk -F'\t' -v run="/${GLOBUS_RUN_PREFIX:-gnoto}/" '$2 == "identity" && index($3, run) == 1 { print $3 }' <<< "$rules" | sort -u | grep -c . || :)
        lint_ok "globus: $runs runs shared, with $people Globus identities, each by a permission of its own"
    fi
}
