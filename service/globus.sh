#
# globus.sh - gnoto config globus: the run folder on the guest collection, and
# a check that a run shared there reaches anyone with its address; and lint's
# checks of both.
#
# Sourced by:  lib/lint.sh
# Defines:     config_globus_step, lint_globus, globus_open_rules
# Requires:    globus-cli and curl, from the image; gnoto_globus,
#              and globus_rule_delete from service/publish.sh;
#              config_confirm from lib/config.sh; lint_ok, lint_warn and
#              lint_fail from lib/lint.sh
# Env:         GLOBUS_UUID, GLOBUS_URL, GLOBUS_DIR, GLOBUS_RUN_PREFIX,
#              GLOBUS_CLI_CLIENT_ID and GLOBUS_CLI_CLIENT_SECRET
#
# Every call signs in with the client credentials in config.yaml, passed only
# to that call, as globus-cli reads them, so any member of gnoto's group can
# make it and nobody runs globus login. The client needs the Access Manager role
# on the guest collection, since each run published there gets a permission of
# its own, anonymous read on <run_prefix>/<uid>/, which its teardown deletes.
#
# Nothing may grant anyone access to the run folder itself, or to anything
# above it: a signed-in Globus user could then list every run and download any
# of them, as cmmr/nextflow's one permission on its run folder allowed. lint
# fails on such a rule. Globus lets one user be covered by at most 100 of a
# collection's rules, and an anonymous rule covers everyone, so lint warns as
# the count nears it.
#
# Creating the guest collection, and giving the client its role, stay steps
# done by hand, since they depend on the site's endpoint and its policies.

GLOBUS_RULE_LIMIT=100

# The collection's rules for anyone, anonymous or signed in, as "<id>\t<path>"
# lines. Fails when the client can't list them.
globus_open_rules() {
    local json
    json=$(gnoto_globus endpoint permission list "$GLOBUS_UUID" -F json 2>&1) || { printf '%s' "$json" >&2; return 1; }
    jq -r '.DATA[]? | select(.principal_type == "anonymous" or .principal_type == "all_authenticated_users")
        | [.id, .path] | @tsv' <<< "$json"
}

# Those rules that open the run folder itself, or anything above it
globus_broad_rules() {
    local id path run=/${GLOBUS_RUN_PREFIX:-gnoto}/
    while IFS=$'\t' read -r id path; do
        [[ -n $id ]] || continue
        path=${path%/}/
        [[ $run != "$path"* ]] || printf '%s\t%s\n' "$id" "$path"
    done <<< "$1"
}

# The message for a client without the role it needs
globus_role_advice() {
    echo "gnoto's client needs the Access Manager role on the collection. An administrator of it grants it with: globus endpoint role create $GLOBUS_UUID --identity ${GLOBUS_CLI_CLIENT_ID:-<client ID>}@clients.auth.globus.org --role access_manager"
}

# gnoto config globus, once its settings are written
config_globus_step() {
    local dir=${GLOBUS_DIR%/}/${GLOBUS_RUN_PREFIX:-gnoto} rules broad plan=() check name body rule out
    [[ ${GLOBUS_ENABLED:-false} == true ]] || return 0
    [[ -n ${GLOBUS_DIR:-} && -n ${GLOBUS_UUID:-} && -n ${GLOBUS_URL:-} ]] ||
        fail "globus needs dir, uuid and url, from the guest collection made by hand."
    [[ -n ${GLOBUS_CLI_CLIENT_ID:-} && -n ${GLOBUS_CLI_CLIENT_SECRET:-} ]] ||
        fail "globus needs cli_client_id and cli_client_secret, from a client registered for gnoto."
    [[ ${GLOBUS_RUN_PREFIX:-gnoto} =~ ^[A-Za-z0-9._-]+$ ]] || fail "globus.run_prefix should be one folder name, such as gnoto."
    gnoto_globus endpoint show "$GLOBUS_UUID" > /dev/null ||
        fail "The client can't see the collection $GLOBUS_UUID. Check its credentials, and $(globus_role_advice)"
    rules=$(globus_open_rules) || fail "The client can't list the collection's permissions. $(globus_role_advice)"
    broad=$(globus_broad_rules "$rules")
    if [[ -n $broad ]]; then
        fail "These permissions let anyone list every run in /${GLOBUS_RUN_PREFIX:-gnoto}/ and download any of them. Delete each with globus endpoint permission delete $GLOBUS_UUID <id>:"$'\n'"$broad"
    fi
    [[ -d $dir ]] || plan+=("Create the run folder $dir")
    plan+=("Check that a run shared there reaches anyone with its address: a test folder, with a permission of its own, made and deleted again")
    config_confirm "on Globus" "${plan[@]}" || exit 0
    mkdir -p "$dir" && chmod 2775 "$dir" && chmod o+rx "$dir" ||
        fail "Can't create $dir. If globus.dir exists, add it to apptainer.binds, so gnoto can see it."

    name=gnoto-check-$$
    check=$dir/$name
    mkdir "$check" && chmod a+rx "$check" || fail "Can't create $check."
    body="gnoto config globus, $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "$body" > "$check/check.txt" && chmod a+r "$check/check.txt" || fail "Can't write in $check."
    rule=$(gnoto_globus endpoint permission create "$GLOBUS_UUID:/${GLOBUS_RUN_PREFIX:-gnoto}/$name/" \
        --anonymous --permissions r -F json 2>&1 | jq -r '.access_id // empty' 2> /dev/null) || rule=""
    if [[ -z $rule ]]; then
        rm -rf "$check"
        fail "Globus didn't make the test folder's permission. $(globus_role_advice)"
    fi
    out=$(curl -sS -L --max-time 60 "${GLOBUS_URL%/}/${GLOBUS_RUN_PREFIX:-gnoto}/$name/check.txt" 2>&1) || out=""
    globus_rule_delete "$GLOBUS_UUID" "$rule" || warn "Delete the test permission $rule by hand: globus endpoint permission delete $GLOBUS_UUID $rule"
    rm -rf "$check"
    [[ $out == "$body" ]] ||
        fail "The collection didn't serve the test file to anyone, at ${GLOBUS_URL%/}/${GLOBUS_RUN_PREFIX:-gnoto}/$name/check.txt: $(head -c 200 <<< "$out")"
    echo "A run shared on Globus reaches anyone with its address, and nobody can list the runs."
    LINT_FAILS=0
    lint_globus
    (( LINT_FAILS == 0 )) || fail "Globus isn't ready, as above."
    echo "Globus is ready."
}

# lint's Globus checks: the run folder can be written, the client can manage the
# collection's permissions, none opens the run folder, and how many there are
lint_globus() {
    local dir=${GLOBUS_DIR%/}/${GLOBUS_RUN_PREFIX:-gnoto} rules broad count
    [[ ${GLOBUS_ENABLED:-false} == true ]] || return 0
    if [[ -z ${GLOBUS_DIR:-} || -z ${GLOBUS_URL:-} || -z ${GLOBUS_UUID:-} ]]; then
        lint_fail "globus: is on, and needs dir, uuid and url. $(gnoto_command config globus) asks for them"
        return 0
    fi
    if [[ ! -d $dir || ! -w $dir ]]; then
        lint_fail "globus: can't write $dir. If globus.dir exists, add it to apptainer.binds, so gnoto can see it; $(gnoto_command config globus) creates the run folder"
    fi
    if [[ -z ${GLOBUS_CLI_CLIENT_ID:-} || -z ${GLOBUS_CLI_CLIENT_SECRET:-} ]]; then
        lint_fail "globus: cli_client_id and cli_client_secret aren't set, and a run on Globus needs them to be shared"
        return 0
    fi
    if ! rules=$(globus_open_rules 2> /dev/null); then
        lint_fail "globus: the client can't list the collection's permissions, so a run can't be shared there. $(globus_role_advice)"
        return 0
    fi
    broad=$(globus_broad_rules "$rules")
    if [[ -n $broad ]]; then
        lint_fail "globus: a permission lets anyone list every run and download any of them: $(paste -sd ';' <<< "$broad" | sed 's/\t/ on /g; s/;/; /g'). Delete it with: globus endpoint permission delete $GLOBUS_UUID <id>"
    fi
    count=$(grep -c . <<< "$rules" || :)
    if (( count >= GLOBUS_RULE_LIMIT * 9 / 10 )); then
        lint_warn "globus: $count runs are shared, and Globus lets a user be covered by at most $GLOBUS_RULE_LIMIT permissions. Raise globus.min_zip_mb, or shorten retention"
    elif [[ -z $broad ]]; then
        lint_ok "globus: $count runs shared, each by a permission of its own"
    fi
}
