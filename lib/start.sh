#
# start.sh - gnoto start: lints a job file, creates its run directory, and
# submits the job and its followup.
#
# Sourced by:  lib/main.sh, for start
# Defines:     start_main, start_run
# Requires:    the settings and helpers from lib/env.sh; job_check and
#              record_write from lib/jobfile.sh; lint_ok, lint_warn and
#              lint_fail from lib/lint.sh; databases_offer from lib/databases.sh
#
# Usage:  gnoto start [--debug] [--yes] job.yaml
#         --debug keeps the whole run directory for core.keep_run_days. --yes
#         accepts fetching missing databases, which the job then waits for.
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

HEAD_JOB_CPUS=2
HEAD_JOB_MEM=8G
FOLLOWUP_TIME=02:00:00

# A random uid: 40 bits as eight lowercase base32 characters
new_uid() {
    head -c 5 /dev/urandom | base32 | tr 'A-Z' 'a-z'
}

start_main() {
    local debug=false yes=false file="" fetch_after=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --debug) debug=true; shift ;;
            --yes) yes=true; shift ;;
            -*) fail "Usage: gnoto start [--debug] [--yes] job.yaml" ;;
            *)
                [[ -z $file ]] || fail "Usage: gnoto start [--debug] [--yes] job.yaml"
                file=$1
                shift
                ;;
        esac
    done
    [[ -n $file ]] || fail "Usage: gnoto start [--debug] [--yes] job.yaml"

    job_check "$file"
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
    local debug=$1 fetch_after=$2 uid run_dir tries nextflow_config="" nextflow_sha="" job_id followup_id
    local job_time

    job_time=$(slurm_time "${SLURM_JOB_TIME:-}") ||
        fail "Not started: slurm.job_time is \"$SLURM_JOB_TIME\". Write it as Slurm does, such as 2-00:00:00, or as 48.h."

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
        --arg job_file "$JOB_FILE" \
        --arg nextflow_config "$nextflow_config" \
        --arg nextflow_sha "$nextflow_sha" \
        --arg kind "$(scheduler_kind)" '
        {pipeline: $pipeline, version: $version, commit: $commit, repository: $repository,
         dev: $dev, title: $top.title, retention: ($top.retention // "3 Months"),
         answers: $answers, job_params: $job_params, params: $params,
         debug: $debug, owner: $owner, job_file: $job_file, samplesheet: $samplesheet,
         databases: $databases,
         scheduler: {kind: $kind}}
        + (if $nextflow_config != "" then {nextflow_config: $nextflow_config,
            nextflow_config_sha256: $nextflow_sha} else {} end)')" ||
        fail "Can't write the run's state in $run_dir."
    record_write || fail "Can't write record.yaml in $run_dir."

    if [[ $(scheduler_kind) == local ]]; then
        scheduler_submit --name "gnoto-$uid" --dir "$run_dir" --log "$run_dir/job.out" \
            -- _local "$run_dir" > /dev/null || start_failed "Couldn't start the job on this machine."
    else
        job_id=$(scheduler_submit --name "gnoto-$uid" --dir "$run_dir" --log "$run_dir/job.out" \
            --cpus "$HEAD_JOB_CPUS" --mem "$HEAD_JOB_MEM" --time "$job_time" \
            --signal B:TERM@300 --after "$fetch_after" -- _job "$run_dir") ||
            start_failed "Slurm refused the job; sbatch's message is above."
        state_set scheduler.job_id "$job_id"
        if ! followup_id=$(scheduler_submit --name "gnoto-$uid-followup" --dir "$run_dir" \
            --log "$run_dir/followup.out" --cpus 1 --mem 2G --time "$FOLLOWUP_TIME" \
            --after "afterany:$job_id" -- _followup "$run_dir"); then
            scheduler_cancel "$job_id"
            start_failed "Slurm refused the job's followup, so the job was cancelled; sbatch's message is above."
        fi
        state_set scheduler.followup_id "$followup_id"
    fi
    set_run_status Submitted
    chmod -R g+rwX "$run_dir" 2> /dev/null || :

    echo "Started $uid, $JOB_PIPELINE, in $run_dir"
    [[ -z $fetch_after ]] || echo "It waits for the database fetches to finish."
    [[ $debug == false ]] || echo "With --debug, the whole run directory stays for ${KEEP_RUN_DAYS:-14} days."
    echo "Follow it with: gnoto status $uid"
}

# A submission that failed leaves a failed run, so status shows why
start_failed() {
    set_run_status Failed
    fail "$1"
}
