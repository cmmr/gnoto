#
# params.sh - The parameter map a pipeline's params file is built from.
#
# Sourced by:  lib/env.sh
# Defines:     params_reset, params_set, params_set_json, params_get, params_has,
#              params_unset, params_load, params_json, params_write, db_path,
#              params_reference, lock_get, form_answer, form_answer_includes,
#              PIPELINE_PARAMS, PIPELINE_PARAM_ORDER
# Requires:    jq and yq; fail from lib/utilities.sh, and state_get from
#              lib/run_state.sh for form_answer
# Env:         DB_DIR, which db: names resolve against
#
# A pipeline's pipeline.sh sets its defaults with params_set. Later layers, such
# as the job's own section or a step's measured values, overwrite the keys they
# name. PIPELINE_PARAM_ORDER keeps the order keys were first set in.
#
# Each value is held as JSON, so a loaded list or map keeps its shape.
# params_set types a shell string: true, false, null and numbers go in bare, as
# Nextflow expects, and anything else is a string.
#
# A value naming a database is written as db:<path under db_dir>. params_json,
# which the record is built from, keeps the name. params_write, which Nextflow
# reads, resolves it.

declare -A PIPELINE_PARAMS=()
declare -a PIPELINE_PARAM_ORDER=()

params_reset() {
    PIPELINE_PARAMS=()
    PIPELINE_PARAM_ORDER=()
}

# A key is written unquoted into YAML, so it's checked
params_valid_key() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

params_set_json() {
    local key="$1" json="$2"

    params_valid_key "$key" || fail "\"$key\" isn't a usable pipeline parameter name."
    jq . > /dev/null 2>&1 <<< "$json" || fail "The value of \"$key\" isn't JSON: $json"
    if [[ -z "${PIPELINE_PARAMS[$key]+set}" ]]; then
        PIPELINE_PARAM_ORDER+=("$key")
    fi
    PIPELINE_PARAMS["$key"]=$(jq -c . <<< "$json")
}

params_set() {
    local key="$1" value="$2"

    if [[ "$value" =~ ^(true|false|null)$ || "$value" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then
        params_set_json "$key" "$value"
    else
        params_set_json "$key" "$(jq -cn --arg v "$value" '$v')"
    fi
}

# A string as it is, and anything else as JSON
params_get() {
    local json="${PIPELINE_PARAMS[$1]:-}"
    [[ -n "$json" ]] || return 0
    jq -r 'if type == "string" then . else tojson end' <<< "$json"
}

params_has() {
    [[ -n "${PIPELINE_PARAMS[$1]+set}" ]]
}

params_unset() {
    unset "PIPELINE_PARAMS[$1]"
}

# Applies one layer from a YAML or JSON file whose top level maps keys to values
params_load() {
    local file="$1" json key value

    [[ -r "$file" ]] || fail "Can't read the parameters in $file."
    json=$(yq -o=json . "$file") || fail "Can't parse the parameters in $file."
    [[ $(jq -r 'type' <<< "$json") =~ ^(object|null)$ ]] ||
        fail "$file doesn't map parameter names to values."
    while IFS=$'\t' read -r key value; do
        [[ -n "$key" ]] || continue
        params_set_json "$key" "$value"
    done < <(jq -r '(. // {}) | to_entries[] | "\(.key)\t\(.value | tojson)"' <<< "$json")
}

# The map as a JSON object, db: names as they are
params_json() {
    local key
    for key in "${PIPELINE_PARAM_ORDER[@]}"; do
        params_has "$key" || continue
        jq -cn --arg k "$key" --argjson v "${PIPELINE_PARAMS[$key]}" '{($k): $v}'
    done | jq -s 'add // {}'
}

# The path a db: name resolves to. Fails on a name that would leave db_dir.
db_path() {
    local name="${1#db:}"

    if [[ -z "$name" || "$name" == /* || "/$name/" == */../* ]]; then
        fail "\"$1\" isn't a usable database name."
    fi
    printf '%s/%s' "$DB_DIR" "$name"
}

# Writes the map as the YAML params file Nextflow reads, with db: names resolved
params_write() {
    local file="$1" json name path

    json=$(params_json) || fail "Can't assemble the parameters."
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        # db_path fails only its own subshell, so stop here too
        path=$(db_path "$name") || exit 1
        json=$(jq --arg name "$name" --arg path "$path" \
            'walk(if . == $name then $path else . end)' <<< "$json")
    done < <(jq -r '[.. | strings | select(startswith("db:"))] | unique[]' <<< "$json")
    yq -P -o=yaml . <<< "$json" > "$file" || fail "Can't write the parameters to $file."
}

# A reference choice, such as dada_ref_taxonomy silva=138.2, replaced with the
# local files conf/databases.yaml maps it to, so the pipeline downloads nothing
params_reference() {
    local param="$1" choice="$2" json key value

    json=$(PARAM="$param" CHOICE="$choice" yq -o=json -e '
        [.databases[] | select(.choice.parameter == strenv(PARAM) and .choice.value == strenv(CHOICE))]
        | .[0].choice.params' "$CODE_DIR/conf/databases.yaml" 2> /dev/null) ||
        fail "No database in conf/databases.yaml provides $param $choice."
    params_unset "$param"
    while IFS=$'\t' read -r key value; do
        params_set_json "$key" "$value"
    done < <(jq -r 'to_entries[] | "\(.key)\t\(.value | tojson)"' <<< "$json")
}

# A value from a pipeline's lock.yaml, by yq path, such as .upstream.commit
lock_get() {
    local lock="$CODE_DIR/pipelines/$1/lock.yaml" value
    value=$(yq -e "$2" "$lock" 2> /dev/null) || fail "$lock has no $2."
    printf '%s' "$value"
}

# One checked request form answer, from the run's state, where both routes
# record them under answers. Empty when it wasn't answered.
form_answer() {
    state_get "answers.$1"
}

# True when a multiple-choice answer, recorded comma-separated, includes $2
form_answer_includes() {
    local answer
    answer=$(form_answer "$1")
    [[ ",$answer," == *",$2,"* ]]
}
