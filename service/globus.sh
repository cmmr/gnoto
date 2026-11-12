#
# globus.sh - gnoto config globus: the run folder on the guest collection and
# its anonymous read permission; and lint's checks of both.
#
# Sourced by:  lib/config.sh and lib/lint.sh
# Defines:     gnoto_globus, config_globus_step, lint_globus
# Requires:    globus-cli and curl, from the image; config_confirm from
#              lib/config.sh; lint_ok, lint_warn and lint_fail from lib/lint.sh
# Env:         GLOBUS_UUID, GLOBUS_URL, GLOBUS_DIR, GLOBUS_RUN_PREFIX,
#              GLOBUS_CLI_CLIENT_ID and GLOBUS_CLI_CLIENT_SECRET
#
# Every call signs in with the client credentials in config.yaml, passed only
# to that call, as globus-cli reads them, so any member of gnoto's group can
# make it and nobody runs globus login. A run itself only copies its zip into
# globus.dir, which the collection shares, so it needs no credentials. One
# anonymous read permission on the run folder, <globus.dir>/<run_prefix>/,
# lets anyone with a run's address download its zip.
#
# Creating the guest collection stays a step done by hand, since it depends on
# the site's endpoint and its policies.

gnoto_globus() {
    env GLOBUS_CLI_CLIENT_ID="${GLOBUS_CLI_CLIENT_ID:-}" GLOBUS_CLI_CLIENT_SECRET="${GLOBUS_CLI_CLIENT_SECRET:-}" \
        globus "$@"
}

# The anonymous read permission on the run folder, as its ID, or nothing
globus_permission() {
    gnoto_globus endpoint permission list "$GLOBUS_UUID" -F json 2> /dev/null |
        jq -r --arg path "/${GLOBUS_RUN_PREFIX:-gnoto}/" '.DATA[]?
            | select(.principal_type == "anonymous" and .path == $path and (.permissions | test("r")))
            | .id' | head -n 1
}

# gnoto config globus, once its settings are written
config_globus_step() {
    local dir=${GLOBUS_DIR%/}/${GLOBUS_RUN_PREFIX:-gnoto} plan=()
    [[ ${GLOBUS_ENABLED:-false} == true ]] || return 0
    [[ -n ${GLOBUS_DIR:-} && -n ${GLOBUS_UUID:-} && -n ${GLOBUS_URL:-} ]] ||
        fail "globus needs dir, uuid and url, from the guest collection made by hand."
    [[ -n ${GLOBUS_CLI_CLIENT_ID:-} && -n ${GLOBUS_CLI_CLIENT_SECRET:-} ]] ||
        fail "globus needs cli_client_id and cli_client_secret, from a client registered for gnoto."
    [[ ${GLOBUS_RUN_PREFIX:-gnoto} =~ ^[A-Za-z0-9._-]+$ ]] || fail "globus.run_prefix should be one folder name, such as gnoto."
    gnoto_globus endpoint show "$GLOBUS_UUID" > /dev/null ||
        fail "The client can't see the collection $GLOBUS_UUID. Check the client's credentials, and that it's a manager of the collection."
    [[ -d $dir ]] || plan+=("Create the run folder $dir")
    [[ -n $(globus_permission) ]] || plan+=("Grant anonymous read permission on /${GLOBUS_RUN_PREFIX:-gnoto}/ in the collection $GLOBUS_UUID")
    if (( ${#plan[@]} > 0 )); then
        config_confirm "on Globus" "${plan[@]}" || exit 0
        mkdir -p "$dir" && chmod 2775 "$dir" && chmod o+rx "$dir" || fail "Can't create $dir."
        if [[ -z $(globus_permission) ]]; then
            gnoto_globus endpoint permission create "$GLOBUS_UUID:/${GLOBUS_RUN_PREFIX:-gnoto}/" --anonymous \
                --permissions r > /dev/null || fail "The anonymous read permission couldn't be created."
        fi
    fi
    LINT_FAILS=0
    lint_globus
    (( LINT_FAILS == 0 )) || fail "Globus isn't ready, as above."
    echo "Globus is ready."
}

# lint's Globus checks: the run folder can be written, the collection serves
# a file there to anyone, and the client's credentials see the permission
lint_globus() {
    local dir=${GLOBUS_DIR%/}/${GLOBUS_RUN_PREFIX:-gnoto} file name body out
    [[ ${GLOBUS_ENABLED:-false} == true ]] || return 0
    if [[ -z ${GLOBUS_DIR:-} || -z ${GLOBUS_URL:-} || -z ${GLOBUS_UUID:-} ]]; then
        lint_fail "globus: is on, and needs dir, uuid and url. $(gnoto_command config globus) asks for them"
        return 0
    fi
    if [[ ! -d $dir || ! -w $dir ]]; then
        lint_fail "globus: can't write $dir. $(gnoto_command config globus) creates it"
        return 0
    fi
    name=gnoto-check-$$.txt
    file=$dir/$name
    body="gnoto lint, $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf '%s\n' "$body" > "$file" && chmod a+r "$file" 2> /dev/null || :
    out=$(curl -sS -L --max-time 60 "${GLOBUS_URL%/}/${GLOBUS_RUN_PREFIX:-gnoto}/$name" 2>&1) || out=""
    rm -f "$file"
    if [[ $out == "$body" ]]; then
        lint_ok "globus: ${GLOBUS_URL%/}/ serves the run folder to anyone"
    else
        lint_fail "globus: ${GLOBUS_URL%/}/${GLOBUS_RUN_PREFIX:-gnoto}/$name didn't serve the file written there without signing in: $(head -c 120 <<< "$out")"
    fi
    if [[ -z ${GLOBUS_CLI_CLIENT_ID:-} || -z ${GLOBUS_CLI_CLIENT_SECRET:-} ]]; then
        lint_warn "globus: cli_client_id and cli_client_secret aren't set, so the permission can't be checked"
    elif [[ -n $(globus_permission) ]]; then
        lint_ok "globus: anonymous read permission on /${GLOBUS_RUN_PREFIX:-gnoto}/"
    else
        lint_warn "globus: no anonymous read permission on /${GLOBUS_RUN_PREFIX:-gnoto}/ found, or the client can't list them. $(gnoto_command config globus) grants it"
    fi
}
