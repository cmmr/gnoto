#
# start.sh - gnoto run, gnoto start and gnoto resume: lints a job, creates its
# run directory, and submits the job and its followup.
#
# Sourced by:  lib/main.sh, for run, start and resume
# Defines:     run_main, start_main, resume_main, start_run, submit_run
# Requires:    the settings and helpers from lib/env.sh; args_parse from
#              lib/args.sh; job_check, job_yaml and record_write from
#              lib/jobfile.sh; cache_lock, code_version and version_route from
#              lib/versions.sh; lint_ok, lint_warn, lint_fail and nodes_prescan
#              from lib/lint.sh; databases_check and databases_offer from
#              lib/databases.sh; live_status and short_version from
#              lib/runs.sh, for resume
#
# Usage:  gnoto run [--debug] [--dev] [--yes] job.yaml
#         gnoto run [--debug] [--yes] --inputs=<dir> record.yaml
#         gnoto start <pipeline>[@<version>] [--debug] [--dev] [--yes] [--<key>=<value> ...]
#         gnoto resume [uid]
#         run starts a job file, or re-runs a record exactly, from the FASTQ
#         files under --inputs. start makes the job file gnoto new would
#         print, in a temporary file, and starts that. --debug keeps the whole
#         run directory for core.keep_run_days. --dev runs the install's own
#         files, which the launcher acts on. --yes accepts fetching missing
#         databases, which the job then waits for. resume starts a failed or
#         cancelled run again where it stopped, or without a uid, lists the
#         runs it can.
#
# Each runs at the version the job names, as lib/versions.sh hands it on, and
# holds the cache lock shared until the run's state names its commit, so gnoto
# prune can't remove the version as the run starts.
#
# Once the job file passes, and before anything is submitted, the check before
# each job asks Slurm's nodes over ssh whether they can run it, so that the
# job, and any database fetch it waits for, avoid the nodes that can't.
#
# A run is <data_dir>/runs/<uid>/. Its directory is made with mkdir and no -p,
# so two starts racing for one uid can't both submit: that's the guard against
# duplicate submission, and it must stay. The job file, the samplesheet with
# every path made absolute, the run's state and the first record.yaml go in
# before anything is submitted.
#
# With Slurm, the head job runs as the caller, with --no-requeue, because Slurm
# would otherwise restart it from the top after a node failure, over a run
# directory already in use, and --signal=B:TERM@300, which gives Nextflow five
# minutes to cancel its tasks before slurm.job_time. The followup runs however
# the head job ends. Without Slurm, both run on this machine, one after the
# other, in one detached process.
#
# gnoto resume runs at the run's own commit, in its own directory, with the
# job file and parameters it recorded, under the current config.yaml. The
# attempt that ended goes into the state's attempts, and the run's status,
# expiry and cleanup start over. The head job then skips the steps that
# finished, and runs Nextflow with -resume, so every task that finished comes
# from the run's cache.

HEAD_JOB_CPUS=2
HEAD_JOB_MEM=8G
FOLLOWUP_TIME=02:00:00

# A random uid: 40 bits as eight lowercase base32 characters
new_uid() {
    head -c 5 /dev/urandom | base32 | tr 'A-Z' 'a-z'
}

run_main() {
    local usage="Usage: gnoto run [--debug] [--dev] [--yes] job.yaml, or gnoto run [--debug] [--yes] --inputs=<dir> record.yaml" i

    args_parse "$usage" "debug dev yes" "$@"
    JOB_INPUTS_DIR=""
    for (( i = 0; i < ${#ARG_KEYS[@]}; i++ )); do
        [[ ${ARG_KEYS[i]} == inputs ]] ||
            fail "gnoto run takes --debug, --dev, --yes and --inputs, not --${ARG_KEYS[i]}. $usage"
        JOB_INPUTS_DIR=${ARG_VALUES[i]}
    done
    [[ ${#ARG_WORDS[@]} -eq 1 ]] || fail "$usage"
    run_job "${ARG_WORDS[0]}"
}

start_main() {
    local usage="Usage: gnoto start <pipeline>[@<version>] [--debug] [--dev] [--yes] [--<key>=<value> ...]" yaml

    args_parse "$usage" "debug dev yes" "$@"
    [[ ${#ARG_WORDS[@]} -eq 1 ]] || fail "$usage"
    yaml=$(job_yaml "${ARG_WORDS[0]}") || exit 1
    START_JOB_FILE=$(mktemp "${TMPDIR:-/tmp}/gnoto-job.XXXXXX") ||
        fail "Can't write the job file in ${TMPDIR:-/tmp}."
    trap 'rm -f "$START_JOB_FILE"' EXIT
    printf '%s\n' "$yaml" > "$START_JOB_FILE" || fail "Can't write the job file $START_JOB_FILE."
    run_job "$START_JOB_FILE"
}

# Checks a job file and starts it, with --debug and --yes from ARG_FLAGS
run_job() {
    local file=$1 fetch_after="" debug=false yes=false

    [[ -z ${ARG_FLAGS[debug]:-} ]] || debug=true
    [[ -z ${ARG_FLAGS[yes]:-} ]] || yes=true
    job_check "$file"
    if [[ $JOB_EXACT == false && -n ${JOB_INPUTS_DIR:-} ]]; then
        fail "--inputs is for re-running a record.yaml, and $file is a job file, which names its samplesheet."
    fi
    if (( LINT_FAILS == ${JOB_MISSING_DATABASES:-0} )); then
        nodes_prescan
    fi
    if (( LINT_FAILS > 0 && LINT_FAILS == ${JOB_MISSING_DATABASES:-0} )); then
        fetch_after=$(databases_offer "$yes") || exit 1
    elif (( LINT_FAILS > 0 )); then
        fail "Not started: $LINT_FAILS check$( (( LINT_FAILS == 1 )) || echo s) failed, above."
    else
        fetch_after=${JOB_FETCH_AFTER:-}
    fi
    start_run "$debug" "$fetch_after"
}

# Makes the run directory from what job_check set, and submits it. Takes
# whether to keep the whole run directory, and a Slurm dependency on database
# fetches, if any.
start_run() {
    local debug=$1 fetch_after=$2 uid run_dir tries nextflow_config="" nextflow_sha="" job_file=$JOB_FILE

    # gnoto start's job file is temporary, so the state names none
    [[ -z ${START_JOB_FILE:-} ]] || job_file=""
    slurm_time "${SLURM_JOB_TIME:-}" > /dev/null ||
        fail "Not started: slurm.job_time is \"$SLURM_JOB_TIME\". Write it as Slurm does, such as 2-00:00:00, or as 48.h."
    [[ $CODE_DEV == true ]] || cache_lock

    mkdir -p "$DATA_DIR/runs" || fail "Can't create $DATA_DIR/runs."
    chmod g+s "$DATA_DIR/runs" 2> /dev/null || :
    for (( tries = 0; tries < 5; tries++ )); do
        uid=$(new_uid)
        is_valid_uid "$uid" || continue
        run_dir=$DATA_DIR/runs/$uid
        [[ ! -e $DATA_DIR/history/$uid ]] || continue
        mkdir "$run_dir" 2> /dev/null && break
        run_dir=""
    done
    [[ -n $run_dir ]] || fail "Can't create a run directory in $DATA_DIR/runs."
    chmod g+s "$run_dir" 2> /dev/null || :
    cd "$run_dir" || fail "Can't enter $run_dir."

    cp "$JOB_FILE" job.yaml || fail "Can't copy $JOB_FILE into $run_dir."
    printf '%s' "$JOB_SAMPLES_TEXT" > original_samplesheet.tsv ||
        fail "Can't write the samplesheet into $run_dir."

    # core.nextflow_config: the record holds only its checksum, because its text
    # can name site paths. The state keeps the text, for status and debugging.
    if [[ -n ${NEXTFLOW_CONFIG:-} ]]; then
        [[ -r $NEXTFLOW_CONFIG ]] || fail "Can't read core.nextflow_config, $NEXTFLOW_CONFIG."
        nextflow_config=$(cat "$NEXTFLOW_CONFIG")
        nextflow_sha=$(sha256sum < "$NEXTFLOW_CONFIG" | cut -d' ' -f1)
    fi

    state_init "$uid" > /dev/null || fail "Can't write the run's state in $run_dir."
    state_update '. + $fields' --argjson fields "$(jq -n \
        --arg pipeline "$JOB_PIPELINE" \
        --arg version "$JOB_VERSION" \
        --arg commit "$CODE_COMMIT" \
        --arg repository "$CODE_REPOSITORY" \
        --argjson dev "$CODE_DEV" \
        --argjson top "$JOB_TOP" \
        --argjson answers "$JOB_ANSWERS" \
        --argjson job_params "$JOB_PARAMS" \
        --argjson params "$(jq '.params' <<< "$JOB_EVAL")" \
        --argjson debug "$debug" \
        --arg owner "$(id -un)" \
        --arg samplesheet "$JOB_SAMPLESHEET" \
        --argjson databases "$(printf '%s\n' "${JOB_DATABASES:-}" | jq -R . | jq -s 'map(select(length > 0))')" \
        --arg job_file "$job_file" \
        --arg nextflow_config "$nextflow_config" \
        --arg nextflow_sha "$nextflow_sha" \
        --argjson exact "$JOB_EXACT" \
        --argjson expected "$JOB_EXPECTED_INPUTS" \
        --argjson runs "$JOB_RECORDED_RUNS" \
        --argjson recorded_databases "$JOB_RECORDED_DATABASES" '
        {pipeline: $pipeline, version: $version, commit: $commit, repository: $repository,
         dev: $dev, title: $top.title, retention: ($top.retention // "3 Months"),
         answers: $answers, job_params: $job_params, params: $params,
         debug: $debug, owner: $owner, job_file: $job_file, samplesheet: $samplesheet,
         databases: $databases}
        + (if $exact then {exact: true, expected_inputs: $expected, recorded_runs: $runs,
            recorded_databases: $recorded_databases} else {} end)
        + (if $nextflow_config != "" then {nextflow_config: $nextflow_config,
            nextflow_config_sha256: $nextflow_sha} else {} end)')" ||
        fail "Can't write the run's state in $run_dir."
    record_write || fail "Can't write record.yaml in $run_dir."
    exec 8>&-

    submit_run "$run_dir" "$fetch_after"
    echo "Started $uid, $JOB_PIPELINE, in $run_dir"
    [[ -z $fetch_after ]] || echo "It waits for the database fetches to finish."
    [[ $debug == false ]] || echo "With --debug, the whole run directory stays for ${KEEP_RUN_DAYS:-14} days."
    echo "Follow it with: $(gnoto_command status "$uid")"
}

# Submits a run's head job and followup, from its run directory, and records
# them: submit_run <run directory> <Slurm dependency on fetches, if any>
submit_run() {
    local run_dir=$1 fetch_after=$2 uid=${1##*/} job_time job_id followup_id kind

    job_time=$(slurm_time "${SLURM_JOB_TIME:-}") ||
        start_failed "slurm.job_time is \"$SLURM_JOB_TIME\". Write it as Slurm does, such as 2-00:00:00, or as 48.h."
    kind=$(scheduler_kind)
    state_set scheduler.kind "$kind"
    if [[ $kind == local ]]; then
        scheduler_submit --name "gnoto-$uid" --dir "$run_dir" --log "$run_dir/job.out" \
            -- _local "$run_dir" > /dev/null || start_failed "Couldn't start the job on this machine."
    else
        job_id=$(scheduler_submit --name "gnoto-$uid" --dir "$run_dir" --log "$run_dir/job.out" \
            --cpus "$HEAD_JOB_CPUS" --mem "$HEAD_JOB_MEM" --time "$job_time" \
            --signal B:TERM@300 --after "$fetch_after" -- _job "$run_dir") ||
            start_failed "Slurm refused the job; the message above says why."
        state_set scheduler.job_id "$job_id"
        [[ -z $fetch_after ]] || state_set scheduler.after "$fetch_after"
        if ! followup_id=$(scheduler_submit --name "gnoto-$uid-followup" --dir "$run_dir" \
            --log "$run_dir/followup.out" --cpus 1 --mem 2G --time "$FOLLOWUP_TIME" \
            --after "afterany:$job_id" -- _followup "$run_dir"); then
            scheduler_cancel "$job_id"
            start_failed "Slurm refused the job's followup, so the job was cancelled; the message above says why."
        fi
        state_set scheduler.followup_id "$followup_id"
    fi
    set_run_status Submitted
    chmod -R g+rwX "$run_dir" 2> /dev/null || :
}

# A submission that failed leaves a failed run, so status shows why
start_failed() {
    set_run_status Failed
    fail "$1"
}

# Why a run can't be resumed, or nothing when it can. Run in its directory.
resume_refusal() {
    local status nextflow
    [[ ! -e remove ]] || { echo "gnoto remove was asked to remove it"; return; }
    status=$(get_run_status)
    case $status in
        Completed) echo "it completed"; return ;;
        "Publish failed") echo "its results were made, and only building or publishing their pages failed"; return ;;
        Failed | Cancelled) ;;
        *) [[ $(live_status) == Lost ]] || { echo "it's still going, as $status"; return; } ;;
    esac
    [[ $(state_get dev) != true ]] || { echo "it ran an install's own files, with --dev"; return; }
    [[ $(state_get commit) =~ ^[0-9a-f]{40}$ ]] || { echo "its state names no commit"; return; }
    nextflow=$(state_get_json steps | jq -r '(. // []) | map(select(.log == "nextflow.out")) | .[0].state // "waiting"')
    if [[ $nextflow != waiting && ! -d work ]]; then
        echo "its cache, the work directory, is gone"
    fi
}

# Lists the runs gnoto resume can resume
resume_list() {
    local dir uid why found=0
    for dir in "$DATA_DIR"/runs/*/; do
        dir=${dir%/}
        uid=${dir##*/}
        is_valid_uid "$uid" && [[ -r $dir/$RUN_STATE_FILE ]] || continue
        why=$(cd "$dir" && resume_refusal)
        [[ -z $why ]] || continue
        (( found > 0 )) || echo "Runs $(gnoto_command resume '<uid>') can resume:"
        found=$((found + 1))
        (cd "$dir" && printf '  %s  %-18s %-10s %-9s %s\n' "$uid" "$(short_version "$(state_get version)")" \
            "$(get_run_status)" "$(date -u -d "$(state_get ended_utc)" '+%b %-d' 2> /dev/null)" \
            "$(state_get message | head -1)")
    done
    (( found > 0 )) || echo "No run can be resumed: none has failed or been cancelled with its cache kept."
}

# Fails when one of a run's inputs is gone or has changed size since the run
# began. The job checks each one's checksum. Run in its directory.
resume_inputs() {
    local uid=$1 sample paths fq bytes
    while IFS=$'\t' read -r sample paths; do
        [[ -n $sample ]] || continue
        for fq in ${paths//$'\t'/ }; do
            [[ -r $fq ]] || fail "Run $uid can't be resumed: its input $fq is gone, or can't be read."
            bytes=$(jq -r --arg sample "$sample" --arg name "${fq##*/}" '
                [.inputs[]? | select(.sample == $sample)
                    | if .fastq1 == $name then .bytes_1 elif .fastq2 == $name then .bytes_2 else empty end]
                | .[0] // empty' "$RUN_STATE_FILE")
            [[ -z $bytes || $(stat -L -c %s "$fq") == "$bytes" ]] ||
                fail "Run $uid can't be resumed: its input $fq has changed size since the run began."
        done
    done < original_samplesheet.tsv
}

# gnoto resume [uid]
resume_main() {
    local usage="Usage: gnoto resume [uid]" uid dir why fetch_after

    args_parse "$usage" "" "$@"
    [[ ${#ARG_KEYS[@]} -eq 0 && ${#ARG_WORDS[@]} -le 1 ]] || fail "$usage"
    if [[ ${#ARG_WORDS[@]} -eq 0 ]]; then
        resume_list
        return
    fi
    uid=${ARG_WORDS[0],,}
    is_valid_uid "$uid" || fail "\"$uid\" isn't a run's uid: those are eight letters and digits, such as k3f9a2qx."
    dir=$DATA_DIR/runs/$uid
    if [[ ! -r $dir/$RUN_STATE_FILE ]]; then
        [[ -r $DATA_DIR/history/$uid/state.json ]] && fail "Run $uid can't be resumed: its run directory has gone."
        fail "There's no run $uid."
    fi
    cd "$dir" || fail "Can't enter $dir."
    why=$(resume_refusal)
    [[ -z $why ]] || fail "Run $uid can't be resumed: $why."

    # At the run's own commit, from here on
    code_version
    version_route "$(state_get repository)" "$(state_get commit)"
    cache_lock
    resume_inputs "$uid"

    JOB_DATABASES=$(state_get_json databases | jq -r '.[]?')
    databases_check "$JOB_DATABASES" > /dev/null
    (( LINT_FAILS == 0 )) ||
        fail "Run $uid can't be resumed: a database it needs is missing. $(gnoto_command lint "$dir/job.yaml") offers to fetch it."
    fetch_after=${JOB_FETCH_AFTER:-}
    nodes_prescan

    (
        run_lock "$uid" || fail "Can't lock run $uid."
        [[ -d $dir && ! -e remove ]] || fail "Run $uid can't be resumed: gnoto remove was asked to remove it."
        state_update '
            .attempts = ((.attempts // []) + [{status, message, created_utc, resumed_utc, started_utc,
                ended_utc, host, scheduler, notes} | with_entries(select(.value != null))])
            | del(.message, .stage, .stages, .started_utc, .ended_utc, .host, .scheduler)
            | .notes = [] | .resumed_utc = $now | .status = "Submitted"' \
            --arg now "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" || fail "Can't record run $uid's last attempt."
        rm -f cancel "$DATA_DIR/expiry/$uid"
    ) || exit 1
    exec 8>&-

    submit_run "$dir" "$fetch_after"
    echo "Resumed $uid, $(state_get version), in $dir. The tasks that finished come from its cache."
    echo "Follow it with: $(gnoto_command status "$uid")"
}
