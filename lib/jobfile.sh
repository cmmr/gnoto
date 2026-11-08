#
# jobfile.sh - Job files and records: the options a pipeline offers, gnoto new,
# the checks gnoto lint, run and start make on a job file, and record.yaml.
#
# Sourced by:  lib/main.sh, for new, lint <job.yaml>, run and start, and by
#              lib/job.sh, for the record
# Defines:     options_json, job_yaml, job_new, job_check, pipeline_eval,
#              record_write, and the JOB_* variables job_check sets
# Requires:    yq, jq, git, df, stat, find, sha256sum and realpath; the settings
#              and helpers from lib/env.sh, args_parse from lib/args.sh,
#              code_version, version_commit, version_route and version_reachable
#              from lib/versions.sh, and lint_ok, lint_warn and lint_fail from
#              lib/lint.sh
#
# A job file names a pipeline and version, gnoto's own options at the top level,
# and the pipeline's parameters in a section named for it. pipelines/<name>/
# options.yaml lists the options gnoto offers: their answers go to the run's
# state as answers, where pipeline.sh reads them through form_answer. Any other
# key in the pipeline's section is a parameter passed as written, checked
# against the pipeline's schema at its pinned commit.
#
# Each runs at the version it names. A command that's handed a job file, or
# a pipeline@<version>, at another version fetches that version and hands the
# command to it, through version_route, before it checks anything. Under --dev,
# the install's own files run instead, and the record is marked dev.
#
# A record.yaml is a job file too, for an exact re-run: it runs at its own
# commit, with its parameters as recorded, its measured values, and its inputs
# found by size, then checksum, under the directory --inputs names.

TITLE_PATTERN='^[A-Za-z0-9][A-Za-z0-9 ._,:+=()-]{0,99}$'
SAMPLE_PATTERN='^[A-Za-z0-9][A-Za-z0-9._+-]{0,99}$'
ANSWER_PATTERN='^[A-Za-z0-9 ,.:+=/_()-]*$'

# The keys a record holds that a job file doesn't
RECORD_KEYS=" schema repository commit dev nextflow_config_sha256 outputs inputs "

pipeline_names() {
    local dir
    for dir in "$CODE_DIR"/pipelines/*/; do
        [[ -f $dir/pipeline.sh ]] && basename "$dir"
    done
}

# A pipeline's options.yaml as a JSON array of options
options_json() {
    yq -o=json '.options // []' "$CODE_DIR/pipelines/$1/options.yaml" ||
        fail "Can't read pipelines/$1/options.yaml."
}

# A string as a double-quoted YAML scalar
yaml_quote() {
    jq -cn --arg value "$1" '$value'
}

# One option of a job file, with its help and allowed values as comments above
# it: write_option <indent> <option as JSON> <value as YAML>
write_option() {
    local indent=$1 option=$2 value=$3 key help values
    key=$(jq -r .key <<< "$option")
    help=$(jq -r '.help // empty' <<< "$option")
    values=$(jq -r '.values // empty | map(tostring) | join(", ")' <<< "$option")
    [[ -z $help ]] || printf '%s# %s\n' "$indent" "$help"
    [[ -z $values ]] || printf '%s# %s\n' "$indent" "$values"
    printf '%s%s: %s\n' "$indent" "$key" "$value"
}

# A value given as --<key> for an option, as JSON of the type of the option's
# values. Fails with a message when the option has values and this isn't one,
# or, with multiple, when a comma-separated part isn't.
option_value() {
    local out
    out=$(jq -cn --argjson option "$1" --arg key "$2" --arg raw "$3" '
        ($option.values // null) as $values
        | ($values // [] | map(tostring) | join(", ")) as $allowed
        | if $raw == "" or $values == null then $raw
          elif $option.multiple // false then
              [$raw | split(",")[] | sub("^ +"; "") | sub(" +$"; "") | select(. != "")
                  | select(. as $part | $values | map(tostring) | index($part) | not)] as $bad
              | if $bad == [] then $raw
                else "--\($key) takes some of: \($allowed), not \($bad | join(", "))" | halt_error(1) end
          else [$values[] | select(tostring == $raw)]
              | if length > 0 then .[0]
                else "--\($key) takes one of: \($allowed), not \($raw)" | halt_error(1) end
          end' 2>&1) || fail "$out"
    printf '%s' "$out"
}

# A value given as --<pipeline>.<parameter>, as JSON of the type its schema entry
# names: true or false for a boolean, a number for an integer or number, and
# otherwise text
param_value() {
    jq -cn --argjson spec "$1" --arg raw "$2" '
        ([$spec.type // "string"] | flatten) as $types
        | if ($types | index("boolean")) and ($raw == "true" or $raw == "false") then $raw == "true"
          elif ($types | index("integer")) and ($raw | test("^-?[0-9]+$")) then $raw | tonumber
          elif ($types | index("number")) and ($raw | test("^-?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][-+]?[0-9]+)?$"))
              then $raw | tonumber
          else $raw end'
}

# The job file gnoto new prints and gnoto start runs, for <pipeline>[@<version>]
# and the --<key>=<value> pairs in ARG_KEYS and ARG_VALUES, at the version
# named, or the current one, and pinned to its commit. Keys follow the file:
# --title and gnoto's other options at the top, and --<pipeline>.<key> for the
# pipeline's section, which takes its options and any parameter its schema has.
# A relative samplesheet is made absolute against the current directory, as any
# path given on a command line is.
job_yaml() {
    local spec=$1 name ref="" commit pinned options option i key raw param schema="" spec_json value why
    local -A top=() section=()
    local param_keys=() param_values=()

    name=${spec%%@*}
    [[ $spec != *@* ]] || ref=${spec#*@}
    code_version
    if [[ $CODE_DEV == true ]]; then
        [[ -z $ref ]] || warn "With --dev, this install's own files run, so the job file names plain $name."
        pinned=$name
    else
        commit=$(version_commit "$ref") || fail "Can't find gnoto's version $ref."
        version_route "$CODE_REPOSITORY" "$commit"
        pinned=$name@$CODE_COMMIT
    fi
    if [[ ! $name =~ ^[a-z][a-z0-9_]*$ || ! -f $CODE_DIR/pipelines/$name/pipeline.sh ]]; then
        fail "There's no pipeline \"$name\". The pipelines are: $(pipeline_names | paste -sd ' ')."
    fi
    options=$(options_json "$name")

    for (( i = 0; i < ${#ARG_KEYS[@]}; i++ )); do
        key=${ARG_KEYS[i]}
        raw=${ARG_VALUES[i]}
        if [[ $key == "$name".* ]]; then
            param=${key#*.}
            option=$(jq -c --arg key "$param" '.[] | select(.in == "section" and .key == $key)' <<< "$options")
            if [[ -n $option ]]; then
                section[$param]=$(option_value "$option" "$key" "$raw") || exit 1
                continue
            fi
            [[ $param =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "--$key: $param isn't a parameter name."
            if [[ -z $schema ]]; then
                schema=$(pipeline_schema "$name") || fail "Can't check --$key against $name's parameters."
            fi
            spec_json=$(jq -c --arg key "$param" '.[$key] // null' <<< "$schema")
            [[ $spec_json != null ]] || fail "--$key: $name has no parameter $param at its pinned commit."
            value=$(param_value "$spec_json" "$raw")
            why=$(schema_mismatch "$spec_json" "$value")
            [[ -z $why ]] || fail "--$key $why."
            param_keys+=("$param")
            param_values+=("$value")
            continue
        fi
        option=$(jq -c --arg key "$key" '.[] | select(.in == "top" and .key == $key)' <<< "$options")
        if [[ -n $option ]]; then
            top[$key]=$(option_value "$option" "$key" "$raw") || exit 1
            if [[ $key == samplesheet && -n $raw && $raw != /* ]]; then
                top[$key]=$(yaml_quote "$(realpath -ms -- "$raw")")
            fi
            continue
        fi
        if jq -e --arg key "$key" 'any(.[]; .in == "section" and .key == $key)' <<< "$options" > /dev/null; then
            fail "--$key goes in $name's section, as --$name.$key."
        elif [[ $key == *.* && -f $CODE_DIR/pipelines/${key%%.*}/pipeline.sh ]]; then
            fail "--$key: this job runs $name, so its parameters go as --$name.<parameter>."
        fi
        why=$(jq -r --arg name "$name" '
            map(if .in == "top" then "--\(.key)" else "--\($name).\(.key)" end) | join(", ")' <<< "$options")
        fail "--$key isn't an option for $name. Its options are $why, and any $name parameter goes as --$name.<parameter>."
    done

    printf '# Check with: gnoto lint <this file>. Run with: gnoto run <this file>\n'
    printf 'pipeline: %s\n' "$pinned"
    while IFS= read -r option; do
        key=$(jq -r .key <<< "$option")
        printf '\n'
        write_option "" "$option" "${top[$key]:-$(jq -c '.default // "" | tostring' <<< "$option")}"
    done < <(jq -c '.[] | select(.in == "top")' <<< "$options")
    printf '\n'
    yq -o=json '.section_help // []' "$CODE_DIR/pipelines/$name/options.yaml" | jq -r '.[] | "# \(.)"'
    printf '%s:\n' "$name"
    while IFS= read -r option; do
        key=$(jq -r .key <<< "$option")
        write_option "  " "$option" "${section[$key]:-$(jq -c '.default // "" | tostring' <<< "$option")}"
    done < <(jq -c '.[] | select(.in == "section")' <<< "$options")
    for (( i = 0; i < ${#param_keys[@]}; i++ )); do
        printf '  %s: %s\n' "${param_keys[i]}" "${param_values[i]}"
    done
}

# gnoto new <pipeline>[@<version>] [--<key>=<value> ...]: prints a job file
job_new() {
    local usage="Usage: gnoto new <pipeline>[@<version>] [--<key>=<value> ...] > job.yaml" yaml

    args_parse "$usage" "" "$@"
    [[ ${#ARG_WORDS[@]} -eq 1 ]] || fail "$usage"
    yaml=$(job_yaml "${ARG_WORDS[0]}") || exit 1
    printf '%s\n' "$yaml"
}

# A pipeline's parameter schema as one JSON object of name: {type, format, enum,
# pattern, group}. nf-core pipelines' come from nextflow_schema.json at the
# pinned commit, fetched with git, which checks it against the commit, and kept
# in <data_dir>/schemas/. gnoto's own workflows carry their own.
pipeline_schema() {
    local pipeline=$1 repository commit cache bare tmp

    repository=$(yq -e '.upstream.repository' "$CODE_DIR/pipelines/$pipeline/lock.yaml" 2> /dev/null) ||
        repository=""
    if [[ -z $repository ]]; then
        schema_flatten < "$CODE_DIR/workflows/$pipeline/nextflow_schema.json"
        return
    fi
    commit=$(lock_get "$pipeline" .upstream.commit)
    cache=$DATA_DIR/schemas/$repository/$commit.json
    if [[ ! -s $cache ]]; then
        bare=$DATA_DIR/schemas/$repository.git
        mkdir -p "${cache%/*}" || return 1
        (
            flock -w 300 9 || exit 1
            [[ -s $cache ]] && exit 0
            [[ -d $bare ]] || git init -q --bare "$bare" || exit 1
            git -C "$bare" fetch -q --depth 1 "https://github.com/$repository" "$commit" || exit 2
            tmp=$(mktemp "$cache.XXXXXX") && chmod 664 "$tmp" || exit 1
            git -C "$bare" show "$commit:nextflow_schema.json" > "$tmp" && mv -f "$tmp" "$cache" || {
                rm -f "$tmp"
                exit 1
            }
        ) 9> "$cache.lock"
        case $? in
            0) ;;
            2)
                echo "can't reach https://github.com/$repository to fetch its schema" >&2
                return 1
                ;;
            *)
                echo "can't fetch nextflow_schema.json for $repository at $commit into $DATA_DIR/schemas" >&2
                return 1
                ;;
        esac
    fi
    schema_flatten < "$cache"
}

# Reads a nextflow_schema.json, and prints each parameter with its group
schema_flatten() {
    jq '
        [((.["$defs"] // .definitions // {}) | to_entries[]
            | .key as $group | (.value.properties // {}) | to_entries[]
            | {key, value: (.value + {group: $group})}),
         ((.properties // {}) | to_entries[] | {key, value: (.value + {group: ""})})]
        | from_entries'
}

# Why a value doesn't fit a parameter's schema entry, or nothing when it does
schema_mismatch() {
    local spec=$1 value=$2
    jq -rn --argjson spec "$spec" --argjson value "$value" '
        ($value | type) as $type
        | ($spec.type // "") as $want
        | if $want == "boolean" and $type != "boolean" then "takes true or false"
          elif $want == "integer" and ($type != "number" or ($value | floor) != $value) then "takes a whole number"
          elif $want == "number" and $type != "number" then "takes a number"
          elif $want == "string" and $type != "string" then "takes text, in quotes"
          elif ($spec.enum // null) != null and ($spec.enum | index($value)) == null
              then "takes one of: \($spec.enum | map(tostring) | join(", "))"
          elif ($spec.pattern // null) != null and $type == "string" and ($value | test($spec.pattern) | not)
              then "must match \($spec.pattern)"
          elif (($spec.format // "") | test("path")) and ($type != "string" or ($value | startswith("db:") | not))
              then "names a file, so it must be a db: name, such as db:<path under the database directory>"
          else empty end'
}

# Evaluates pipeline.sh with a job's answers and parameters, in a scratch run
# directory, and prints {locked, params, databases, one_layout} as JSON. With
# "exact", the parameters are a record's, set as they are. On a failure, prints
# pipeline.sh's own message to stderr and returns 1.
pipeline_eval() {
    local pipeline=$1 answers=$2 job_params=$3 exact=${4:-} dir status=0

    dir=$(mktemp -d "${TMPDIR:-/tmp}/gnoto-eval.XXXXXX") || return 1
    (
        cd "$dir" || exit 1
        state_init eval > /dev/null || exit 1
        state_set_json answers "$answers" > /dev/null || exit 1
        NEXTFLOW_ARGS=()
        PRE_PROCESS_CMDS=()
        POST_PROCESS_CMDS=()
        PARAMS_LOCKED=()
        PIPELINE_DATABASES=()
        ONE_READ_LAYOUT=false
        PARAMS_FILE=""
        export GNOTO_JOB_PARAMS=$job_params
        source "$CODE_DIR/pipelines/$pipeline/pipeline.sh"
        if [[ $exact == exact ]]; then
            params_apply_exact "$job_params"
        else
            params_apply_job "$job_params"
        fi
        jq -n --argjson params "$(params_json)" \
            --argjson locked "$(printf '%s\n' "${PARAMS_LOCKED[@]}" | jq -R . | jq -s 'map(select(length > 0))')" \
            --argjson databases "$(printf '%s\n' ${PIPELINE_DATABASES[@]+"${PIPELINE_DATABASES[@]}"} | jq -R . | jq -s 'map(select(length > 0))')" \
            --argjson one_layout "$ONE_READ_LAYOUT" \
            '{locked: $locked, params: $params, databases: $databases, one_layout: $one_layout}'
    ) 2> "$dir/stderr" || status=$?
    if (( status != 0 )); then
        sed -n 's/^\[[^]]*\] ERROR: //p' "$dir/stderr" >&2
        grep -q 'ERROR: ' "$dir/stderr" || tail -3 "$dir/stderr" >&2
    fi
    rm -rf "$dir"
    return $status
}

# The checks lint, run and start make on a job file. Prints a line for each,
# counts failures in LINT_FAILS, and sets, for run and start:
#   JOB_FILE          the job file's absolute path
#   JOB_PIPELINE      the pipeline's name, and JOB_VERSION what the file asked for
#   JOB_TOP           gnoto's own top-level answers, as JSON
#   JOB_ANSWERS       every option's answer, as JSON
#   JOB_PARAMS        the parameters the file sets, as JSON
#   JOB_EVAL          what pipeline_eval found
#   JOB_SAMPLESHEET   the samplesheet's absolute path
#   JOB_SAMPLES_TEXT  the samplesheet, with every FASTQ as an absolute path
#   JOB_INPUT_BYTES   the FASTQs' total size
job_check() {
    local file=$1 json spec ref why options keys key option value values multiple part commit repository
    local section_json schema spec_json mismatch locked errfile param_fails exact_flag=""

    JOB_FILE="" JOB_PIPELINE="" JOB_VERSION="" JOB_TOP="{}" JOB_ANSWERS="{}" JOB_PARAMS="{}"
    JOB_EVAL="" JOB_SAMPLESHEET="" JOB_SAMPLES_TEXT="" JOB_INPUT_BYTES=0 JOB_EXACT=false
    JOB_EXPECTED_INPUTS="[]" JOB_RECORDED_RUNS="{}"

    if [[ ! -r $file ]]; then
        lint_fail "can't read $file"
        return
    fi
    JOB_FILE=$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")
    if ! json=$(yq -o=json . "$file" 2>&1); then
        lint_fail "$file isn't valid YAML: $json"
        return
    fi
    if [[ $(jq -r type <<< "$json") != object ]]; then
        lint_fail "$file should map keys to values, starting with pipeline:"
        return
    fi

    # The pipeline and its version. A record names its commit, and re-runs there.
    spec=$(jq -r '.pipeline // "" | tostring' <<< "$json")
    JOB_VERSION=$spec
    JOB_PIPELINE=${spec%%@*}
    ref=""
    [[ $spec != *@* ]] || ref=${spec#*@}
    if [[ -z $spec ]]; then
        lint_fail "pipeline: is missing. gnoto new <pipeline> writes a job file with it filled in"
        return
    fi
    JOB_EXACT=false
    if jq -e 'has("commit") and has("inputs") and has("schema")' <<< "$json" > /dev/null; then
        JOB_EXACT=true
        commit=$(jq -r '.commit // "" | tostring' <<< "$json")
        repository=$(jq -r '.repository // "" | tostring' <<< "$json")
        if [[ $(jq -r '.dev // false' <<< "$json") == true || ! $commit =~ ^[0-9a-f]{40}$ ]]; then
            lint_fail "pipeline: $file is the record of a --dev run, which ran an install's own files, so it can't be re-run"
            return
        fi
    fi
    code_version
    if [[ $CODE_DEV == true ]]; then
        if [[ $JOB_EXACT == true ]]; then
            lint_fail "pipeline: a record re-runs at its own commit, so --dev can't run it"
            return
        fi
        lint_warn "pipeline: --dev runs this install's own files, so the record is marked dev"
    else
        if [[ $JOB_EXACT == false ]]; then
            repository=$CODE_REPOSITORY
            errfile=$(mktemp "${TMPDIR:-/tmp}/gnoto-version.XXXXXX")
            if ! commit=$(version_commit "$ref" 2> "$errfile"); then
                lint_fail "pipeline: $spec: $(tail -1 "$errfile")"
                rm -f "$errfile"
                return
            fi
            rm -f "$errfile"
        fi
        version_route "$repository" "$commit"
        if [[ $JOB_EXACT == true ]]; then
            lint_ok "pipeline: $spec, re-run from its record at its commit"
        else
            lint_ok "pipeline: $spec, commit $CODE_COMMIT"
        fi
        if [[ -n $ref && ! $ref =~ ^[0-9a-f]{40}$ && ! $ref =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            lint_warn "pipeline: $ref moves, so the run records the commit it names now, $CODE_COMMIT"
        elif [[ $ref =~ ^[0-9a-f]{40}$ && $(version_reachable "$CODE_REPOSITORY" "$CODE_COMMIT") == no ]]; then
            lint_warn "pipeline: neither main nor a release reaches commit $CODE_COMMIT, so $CODE_REPOSITORY may not keep it"
        fi
    fi
    if [[ ! $JOB_PIPELINE =~ ^[a-z][a-z0-9_]*$ || ! -f $CODE_DIR/pipelines/$JOB_PIPELINE/pipeline.sh ]]; then
        lint_fail "pipeline: there's no pipeline \"$JOB_PIPELINE\". The pipelines are: $(pipeline_names | paste -sd ' ')"
        return
    fi

    options=$(options_json "$JOB_PIPELINE")

    # Keys the file has but nothing reads
    keys=$(jq -r --arg section "$JOB_PIPELINE" --argjson options "$options" --arg exact "$JOB_EXACT" \
        --arg record "$RECORD_KEYS" '
        keys[] | select(. != "pipeline" and . != $section)
        | . as $key | select($exact == "false" or ($record | contains(" \($key) ") | not))
        | select(. as $key | $options | map(select(.in == "top") | .key) | index($key) | not)' <<< "$json")
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        if [[ -f $CODE_DIR/pipelines/$key/pipeline.sh ]]; then
            lint_fail "$key: this job runs $JOB_PIPELINE, so its parameters go under $JOB_PIPELINE:"
        else
            lint_fail "$key: isn't an option gnoto has for $JOB_PIPELINE"
        fi
    done <<< "$keys"
    section_json=$(jq --arg section "$JOB_PIPELINE" '.[$section] // {}' <<< "$json")
    if [[ $(jq -r type <<< "$section_json") != object ]]; then
        lint_fail "$JOB_PIPELINE: should hold parameter names and their values"
        section_json="{}"
    fi

    # Each option's answer, against options.yaml. A record has no samplesheet,
    # and keeps a section option only as the parameters it became, unless it
    # was measured.
    while IFS= read -r option; do
        [[ -n $option ]] || continue
        key=$(jq -r .key <<< "$option")
        if [[ $JOB_EXACT == true ]]; then
            [[ $key != samplesheet ]] || continue
            [[ $(jq -r .in <<< "$option") == top || $(jq -r '.measured // false' <<< "$option") == true ]] ||
                continue
        fi
        if [[ $(jq -r .in <<< "$option") == top ]]; then
            value=$(jq --arg key "$key" '.[$key]' <<< "$json")
        else
            value=$(jq --arg key "$key" '.[$key]' <<< "$section_json")
        fi
        if [[ $(jq -r type <<< "$value") == object ]]; then
            lint_fail "$key: takes a single value"
            continue
        fi
        value=$(jq -r 'if . == null then "" elif type == "array" then map(tostring) | join(",")
            else tostring end' <<< "$value")
        if [[ $value == *$'\n'* ]]; then
            lint_fail "$key: takes a single value"
            continue
        fi
        if [[ -z $value ]]; then
            if [[ $(jq -r '.required // false' <<< "$option") == true ]]; then
                lint_fail "$key: is required"
            fi
            continue
        fi
        values=$(jq -c '.values // null | if . == null then null else map(tostring) end' <<< "$option")
        multiple=$(jq -r '.multiple // false' <<< "$option")
        if [[ $key == title ]]; then
            [[ $value =~ $TITLE_PATTERN ]] ||
                { lint_fail "title: use up to 100 letters, digits, spaces and . _ , : + = ( ) -, starting with a letter or digit"; continue; }
        elif [[ $key != samplesheet && ! $value =~ $ANSWER_PATTERN ]]; then
            lint_fail "$key: \"$value\" has a character answers can't use"
            continue
        fi
        if [[ $values != null ]]; then
            if [[ $multiple == true ]]; then
                value=$(tr ',' '\n' <<< "$value" | sed 's/^ *//; s/ *$//' | grep -v '^$' | paste -sd ',')
                why=""
                while IFS= read -r part; do
                    jq -e --arg part "$part" 'index($part) != null' <<< "$values" > /dev/null ||
                        why+="${why:+, }\"$part\""
                done < <(tr ',' '\n' <<< "$value")
            else
                why=""
                jq -e --arg value "$value" 'index($value) != null' <<< "$values" > /dev/null || why="\"$value\""
            fi
            if [[ -n $why ]]; then
                lint_fail "$key: $why isn't one of: $(jq -r 'join(", ")' <<< "$values")"
                continue
            fi
        fi
        JOB_ANSWERS=$(jq -c --arg key "$key" --arg value "$value" '.[$key] = $value' <<< "$JOB_ANSWERS")
        if [[ $(jq -r .in <<< "$option") == top && $key != samplesheet ]]; then
            JOB_TOP=$(jq -c --arg key "$key" --arg value "$value" '.[$key] = $value' <<< "$JOB_TOP")
        fi
    done < <(jq -c '.[]' <<< "$options")
    lint_ok "answers: $(jq -r 'to_entries | map("\(.key) \(.value)") | join("; ")' <<< "$JOB_ANSWERS")"

    # pipeline.sh with these answers alone, for the keys gnoto sets itself
    errfile=$(mktemp "${TMPDIR:-/tmp}/gnoto-eval.XXXXXX")
    if ! JOB_EVAL=$(pipeline_eval "$JOB_PIPELINE" "$JOB_ANSWERS" "{}" 2> "$errfile"); then
        lint_fail "$JOB_PIPELINE: $(cat "$errfile")"
        rm -f "$errfile"
        JOB_EVAL=""
        job_check_reads "$json"
        return
    fi
    locked=$(jq -c .locked <<< "$JOB_EVAL")

    # The section's other keys are parameters, passed as written. A record's
    # are every parameter its run passed, which pass as recorded.
    JOB_PARAMS=$(jq -c --argjson options "$options" --arg exact "$JOB_EXACT" '
        with_entries(select(.key as $key | $options | map(select(.in == "section"
            and ($exact == "false" or (.measured // false))) | .key) | index($key) | not))
        | with_entries(select(.value != null))' <<< "$section_json")
    param_fails=$LINT_FAILS
    if [[ $JOB_EXACT == false && $JOB_PARAMS != "{}" ]]; then
        if ! schema=$(pipeline_schema "$JOB_PIPELINE" 2>&1); then
            lint_fail "$JOB_PIPELINE: can't check its parameters: $schema"
            schema=""
        fi
        while IFS=$'\t' read -r key value; do
            [[ -n $key ]] || continue
            if [[ ! $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                lint_fail "$JOB_PIPELINE.$key: isn't a parameter name"
                continue
            fi
            if jq -e --arg key "$key" 'index($key) != null' <<< "$locked" > /dev/null; then
                lint_fail "$JOB_PIPELINE.$key: gnoto sets this itself, so a job file can't"
                continue
            fi
            [[ -n $schema ]] || continue
            spec_json=$(jq -c --arg key "$key" '.[$key] // null' <<< "$schema")
            if [[ $spec_json == null ]]; then
                lint_fail "$JOB_PIPELINE.$key: isn't a parameter $JOB_PIPELINE takes at its pinned commit"
                continue
            fi
            case $(jq -r .group <<< "$spec_json") in
                generic_options | institutional_config_options)
                    lint_fail "$JOB_PIPELINE.$key: nf-core's generic and institutional parameters can change what's loaded at run time, so gnoto sets them"
                    continue
                    ;;
            esac
            if mismatch=$(schema_mismatch "$spec_json" "$value") && [[ -n $mismatch ]]; then
                lint_fail "$JOB_PIPELINE.$key: $mismatch"
                continue
            fi
            if jq -e 'type == "string" and startswith("db:")' <<< "$value" > /dev/null &&
                ! (db_path "$(jq -r . <<< "$value")") > /dev/null 2>&1; then
                lint_fail "$JOB_PIPELINE.$key: $(jq -r . <<< "$value") isn't a usable database name"
                continue
            fi
            if jq -e '.. | strings | test("\n")' <<< "$value" > /dev/null 2>&1; then
                lint_fail "$JOB_PIPELINE.$key: can't hold a line break"
            fi
        done < <(jq -r 'to_entries[] | "\(.key)\t\(.value | tojson)"' <<< "$JOB_PARAMS")
    fi

    # pipeline.sh again, with the parameters as well, when they passed
    if (( LINT_FAILS == param_fails )); then
        [[ $JOB_EXACT == false ]] || exact_flag=exact
        if JOB_EVAL=$(pipeline_eval "$JOB_PIPELINE" "$JOB_ANSWERS" "$JOB_PARAMS" $exact_flag 2> "$errfile"); then
            if [[ $JOB_EXACT == true ]]; then
                lint_ok "$JOB_PIPELINE: $(jq length <<< "$JOB_PARAMS") parameters, as recorded"
            else
                lint_ok "$JOB_PIPELINE: $(jq -r '.params | length' <<< "$JOB_EVAL") parameters, $(jq length <<< "$JOB_PARAMS") of them set here"
            fi
        else
            lint_fail "$JOB_PIPELINE: $(cat "$errfile")"
            JOB_EVAL=""
        fi
    fi
    rm -f "$errfile"

    job_check_reads "$json"

    # Every database the parameters name, and any the pipeline's steps read
    JOB_DATABASES=""
    if [[ -n $JOB_EVAL ]]; then
        JOB_DATABASES=$(jq -r '[(.params | .. | strings | select(startswith("db:"))), .databases[]] | unique[]' \
            <<< "$JOB_EVAL")
        databases_check "$JOB_DATABASES"
    fi

    job_check_disk
}

# The reads a job runs on: a job file's samplesheet, or a record's inputs
job_check_reads() {
    if [[ $JOB_EXACT == true ]]; then
        job_check_inputs "$1"
    else
        job_check_samplesheet "$1"
    fi
}

# The file under the directory --inputs names that a record's input is: the
# one of its size, or where several share it, the one with its checksum. Reads
# by_size and sums from job_check_inputs, its caller: input_file <bytes> <sha256>
input_file() {
    local candidates path
    candidates=${by_size[$1]:-}
    [[ -n $candidates ]] || return 0
    if [[ $(grep -c . <<< "$candidates") -eq 1 ]]; then
        printf '%s' "${candidates%$'\n'}"
        return 0
    fi
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        [[ -n ${sums[$path]:-} ]] || sums[$path]=$(sha256sum < "$path" | cut -d' ' -f1)
        if [[ ${sums[$path]} == "$2" ]]; then
            printf '%s' "$path"
            return 0
        fi
    done <<< "$candidates"
}

# A record's inputs, found under JOB_INPUTS_DIR, the directory --inputs names,
# by size, so the login node reads little, and by checksum only where sizes are
# shared. The job checks every checksum while staging. Sets what
# job_check_samplesheet does, and JOB_EXPECTED_INPUTS, the record's inputs, and
# JOB_RECORDED_RUNS, each sample's recorded batch.
job_check_inputs() {
    local json=$1 dir=${JOB_INPUTS_DIR:-} size path sample name bytes sum i errors=0 files=0 total=0 line
    local -A by_size=() sums=() seen=()
    local fields=()

    if [[ -z $dir ]]; then
        lint_fail "inputs: a record re-runs with --inputs=<dir>, naming the directory its FASTQ files are in"
        return
    fi
    if [[ ! -d $dir || ! -r $dir ]]; then
        lint_fail "inputs: can't read $dir. If it exists, add it to apptainer.binds"
        return
    fi
    dir=$(cd "$dir" && pwd -P)
    JOB_EXPECTED_INPUTS=$(jq -c '.inputs // []' <<< "$json")
    JOB_RECORDED_RUNS=$(jq -c '[.inputs[]? | select(.run) | {(.sample): .run}] | add // {}' <<< "$json")
    while IFS=$'\t' read -r size path; do
        by_size[$size]+="$path"$'\n'
    done < <(find -L "$dir" -type f -size +0 -printf '%s\t%p\n' 2> /dev/null)

    JOB_SAMPLES_TEXT=""
    while IFS= read -r line; do
        IFS=$'\t' read -ra fields <<< "$line"
        sample=${fields[0]}
        line=$sample
        for i in 1 4; do
            name=${fields[i]:-}
            bytes=${fields[i + 1]:-}
            sum=${fields[i + 2]:-}
            [[ -n $name ]] || continue
            path=$(input_file "$bytes" "$sum")
            if [[ -z $path ]]; then
                errors=$((errors + 1))
                (( errors > 10 )) ||
                    lint_fail "inputs: nothing under $dir is $name, sample $sample's $bytes-byte file with SHA-256 ${sum:0:12}..."
                continue
            fi
            line+=$'\t'$path
            files=$((files + 1))
            total=$((total + bytes))
        done
        seen[$sample]=1
        JOB_SAMPLES_TEXT+="$line"$'\n'
    done < <(jq -r '.inputs[]? | [.sample, .fastq1, .bytes_1, .sha256_1, (.fastq2 // ""), (.bytes_2 // ""),
        (.sha256_2 // "")] | map(tostring) | join("\t")' <<< "$json")
    (( errors <= 10 )) || lint_fail "inputs: $((errors - 10)) more files missing besides"
    JOB_INPUT_BYTES=$total
    if (( ${#seen[@]} == 0 )); then
        lint_fail "inputs: the record names none"
    elif (( errors == 0 )); then
        lint_ok "inputs: ${#seen[@]} sample$( (( ${#seen[@]} == 1 )) || echo s), $files FASTQ file$( (( files == 1 )) || echo s), $(human_size "$total"), found under $dir by size. The job checks each one's checksum"
    fi
}

# Reports one samplesheet problem, up to ten, so a sheet with a bad path doesn't
# print a line per sample. Reads errors and number from job_check_samplesheet,
# its caller.
sheet_problem() {
    errors=$((errors + 1))
    (( errors <= 10 )) && lint_fail "samplesheet line $number: $*"
    (( errors == 11 )) && lint_fail "samplesheet: more problems besides"
    return 0
}

# The samplesheet: every line parses, every sample name fits the pattern, and
# every FASTQ exists, can be read and isn't empty. Relative paths are relative
# to the samplesheet's own directory.
job_check_samplesheet() {
    local json=$1 sheet dir line number=0 sample fq1 fq2 extra fq layout="" samples=0 files=0 bytes=0 size
    local -A seen=() sample_layout=()
    local errors=0 one_layout

    sheet=$(jq -r '.samplesheet // "" | tostring' <<< "$json")
    [[ -n $sheet ]] || return 0
    [[ $sheet == /* ]] || sheet=$(dirname "$JOB_FILE")/$sheet
    if [[ ! -f $sheet || ! -r $sheet ]]; then
        lint_fail "samplesheet: can't read $sheet. If it exists, add its directory to apptainer.binds"
        return
    fi
    JOB_SAMPLESHEET=$(cd "$(dirname "$sheet")" && pwd -P)/$(basename "$sheet")
    dir=$(dirname "$JOB_SAMPLESHEET")
    one_layout=$(jq -r '.one_layout // false' <<< "${JOB_EVAL:-null}" 2> /dev/null) || one_layout=false

    JOB_SAMPLES_TEXT=""
    while IFS= read -r line || [[ -n $line ]]; do
        number=$((number + 1))
        line=${line//$'\r'/}
        line=${line//$'\xc2\xa0'/ }
        read -r sample fq1 fq2 extra <<< "$line"
        [[ -n $sample && $sample != \#* ]] || continue
        [[ $number -eq 1 && ${sample,,} == sample ]] && continue
        if [[ -z $fq1 || -n $extra ]]; then
            sheet_problem "should be a sample name and one or two FASTQ files"
            continue
        fi
        [[ $sample =~ $SAMPLE_PATTERN ]] ||
            sheet_problem "the sample name \"$sample\" should be up to 100 letters, digits and . _ + -, starting with a letter or digit"
        layout=single
        [[ -z $fq2 ]] || layout=paired
        if [[ $one_layout == true && -n ${sample_layout[*]+set} && " ${sample_layout[*]} " != *" $layout "* ]]; then
            sheet_problem "is $layout-end, but the lines before it aren't, and $JOB_PIPELINE runs every sample one way"
        elif [[ -n ${sample_layout[$sample]:-} && ${sample_layout[$sample]} != "$layout" ]]; then
            sheet_problem "$sample is $layout-end here but not on an earlier line"
        fi
        sample_layout[$sample]=$layout
        [[ -n ${seen[$sample]:-} ]] || samples=$((samples + 1))
        seen[$sample]=1
        [[ $fq1 != "$fq2" ]] || sheet_problem "names $fq1 twice"
        for fq in "$fq1" ${fq2:+"$fq2"}; do
            [[ $fq == /* ]] || fq=$dir/$fq
            if [[ ! -f $fq ]]; then
                sheet_problem "$fq doesn't exist, or isn't under a path gnoto can see. If it exists, add its directory to apptainer.binds"
            elif [[ ! -r $fq ]]; then
                sheet_problem "can't read $fq"
            elif [[ ! -s $fq ]]; then
                sheet_problem "$fq is empty"
            else
                size=$(stat -L -c %s "$fq")
                bytes=$((bytes + size))
                files=$((files + 1))
            fi
        done
        [[ $fq1 == /* ]] || fq1=$dir/$fq1
        [[ -z $fq2 || $fq2 == /* ]] || fq2=$dir/$fq2
        JOB_SAMPLES_TEXT+="$sample"$'\t'"$fq1${fq2:+$'\t'$fq2}"$'\n'
    done < "$JOB_SAMPLESHEET"
    JOB_INPUT_BYTES=$bytes
    if (( samples == 0 && errors == 0 )); then
        lint_fail "samplesheet: $JOB_SAMPLESHEET names no samples"
    elif (( errors == 0 )); then
        lint_ok "samplesheet: $samples sample$( (( samples == 1 )) || echo s), $files FASTQ file$( (( files == 1 )) || echo s), $(human_size "$bytes"), all readable"
    fi
}

# Room in the data directory for the run, as a rough multiple of its inputs
job_check_disk() {
    local free need
    (( JOB_INPUT_BYTES > 0 )) || return 0
    free=$(df -P -B1 "$DATA_DIR" 2> /dev/null | awk 'NR == 2 { print $4 }') || free=""
    [[ -n $free ]] || { lint_warn "disk: can't tell how much room $DATA_DIR has"; return 0; }
    need=$((JOB_INPUT_BYTES * 4))
    if (( free < need )); then
        lint_warn "disk: $DATA_DIR has $(human_size "$free") free, and a run can need about $(human_size "$need") for these inputs"
    else
        lint_ok "disk: $(human_size "$free") free in $DATA_DIR"
    fi
}

# Writes record.yaml from the run's state: the job file resolved, with the
# parameters passed, measured values, and each input's size and checksum last
record_write() {
    local options json tmp

    options=$(options_json "$(state_get pipeline)")
    json=$(jq --argjson options "$options" '
        . as $state
        | ($options | map(select(.in == "top" and .key != "samplesheet" and .key != "title"
            and .key != "retention") | .key)) as $top
        | ($options | map(select(.in == "section" and (.measured // false)) | .key)) as $measured
        | {schema: 1, pipeline: .version, repository: .repository, commit: .commit}
        + (if .dev then {dev: true} else {} end)
        + (if .nextflow_config_sha256 then {nextflow_config_sha256} else {} end)
        + {title: .title, retention: .retention}
        + ([$top[] | select($state.answers[.] != null) | {(.): $state.answers[.]}] | add // {})
        + {(.pipeline): ((.params // {})
            + ([$measured[] | select($state.answers[.] != null) | {(.): $state.answers[.]}] | add // {}))}
        + {outputs: (.outputs // [])}
        + {inputs: (.inputs // [])}' "$RUN_STATE_FILE") || return 1
    tmp=$(mktemp record.yaml.XXXXXX) && chmod 664 "$tmp" || return 1
    if yq -P -o=yaml . <<< "$json" > "$tmp" && mv -f "$tmp" record.yaml; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}
