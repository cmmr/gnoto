#
# job.sh - The head job: runs one job's three stages, Compute, Present and
# Publish, in its run directory.
#
# Sourced by:  lib/main.sh, for the _job and _local commands that
#              lib/start.sh submits
# Defines:     job_main
# Requires:    nextflow, sha256sum and stat, from the image; the settings and
#              helpers from lib/env.sh, and record_write from lib/jobfile.sh
# Runs:        pipelines/<name>/pipeline.sh's steps, Nextflow,
#              steps/<name>_composition.sh, present/<name>.sh, and
#              present/progress.sh in the background
#
# Compute makes the results: it takes each input's size and checksum, runs the
# pipeline's pre-process steps, writes the params file, runs Nextflow and the
# post-process steps, then the composition step that builds the core tables.
# These always run: no setting turns them off. Present writes the dashboard
# into results/ and the deliverables zip beside it, and needs no network.
# Publish copies them to S3 and Globus, which phase 7 builds. Each stage
# records itself in the state's stages when it finishes, so the followup knows
# whether the results were made.
#
# The params file is built in layers, each overwriting only the keys it names:
# pipeline.sh's defaults, which include what it makes of the job's answers,
# then detected_params.yaml from a step that measured the data, then the
# parameters the job file sets. The keys gnoto owns, PARAMS_LOCKED, are put
# back last.
#
# Nextflow and each step run in the background while this waits, so a SIGTERM,
# from Slurm or from the progress watcher when it sees a cancel file, reaches
# them at once. Nextflow then cancels its tasks through the scancel stand-in.
#
# Never touches Wrike or the run's results address: the followup reports how
# the run ended, from .status, .message and .notes in the state.

CHILD_PID=""
PROGRESS_PID=""
JOB_SIGNAL=""

# Passes a signal on to whatever runs now, and remembers it
job_on_signal() {
    JOB_SIGNAL=$1
    if [[ -n $CHILD_PID ]]; then
        pkill -TERM -P "$CHILD_PID" 2> /dev/null || :
        kill -TERM "$CHILD_PID" 2> /dev/null || :
    fi
}

# Runs a command in the background, teeing its output to a log, and waits for
# it however long a signal takes to reach it: job_run <log> <command> ...
job_run() {
    local log=$1 status=0
    shift
    "$@" > >(tee -a "$log") 2>&1 &
    CHILD_PID=$!
    wait "$CHILD_PID" || status=$?
    while kill -0 "$CHILD_PID" 2> /dev/null; do
        status=0
        wait "$CHILD_PID" || status=$?
    done
    CHILD_PID=""
    return $status
}

stop_progress() {
    [[ -n $PROGRESS_PID ]] || return 0
    kill "$PROGRESS_PID" 2> /dev/null || :
    wait "$PROGRESS_PID" 2> /dev/null || :
    PROGRESS_PID=""
}

# Stops the job when a signal has arrived, as cancelled when there's a cancel
# file, or as stopped otherwise, which is Slurm's time limit or scancel
job_check_signal() {
    [[ -n $JOB_SIGNAL ]] || return 0
    stop_progress
    if [[ -e cancel ]]; then
        set_run_status Cancelled
        fail "The job was cancelled."
    fi
    fail "The job was stopped before it finished, by its time limit (slurm.job_time) or by Slurm."
}

# The name a step is listed under on the progress page: its script's name less
# the pipeline's prefix, so steps/taxprofiler_humann.sh is humann
step_name() {
    local name=${1%% *}
    name=${name##*/}
    name=${name%.sh}
    printf '%s' "${name#"$2"_}"
}

# Every step this run takes, in order, as .steps for the progress page: each
# pre-process step, the Nextflow run, each post-process step, the core tables
# and the dashboard, all waiting
record_steps() {
    local pipeline=$1 command name nextflow="nextflow" i

    for (( i = 0; i + 1 < ${#NEXTFLOW_ARGS[@]}; i++ )); do
        if [[ ${NEXTFLOW_ARGS[i]} == run ]]; then
            nextflow=${NEXTFLOW_ARGS[i + 1]##*/}
            break
        fi
    done
    NEXTFLOW_STEP=${#PRE_PROCESS_CMDS[@]}
    POST_STEP_FIRST=$((NEXTFLOW_STEP + 1))
    COMPOSITION_STEP=$((POST_STEP_FIRST + ${#POST_PROCESS_CMDS[@]}))
    PRESENT_STEP=$((COMPOSITION_STEP + 1))
    {
        for command in ${PRE_PROCESS_CMDS[@]+"${PRE_PROCESS_CMDS[@]}"}; do
            name=$(step_name "$command" "$pipeline")
            printf '%s\t%s.out\n' "$name" "$name"
        done
        printf '%s\tnextflow.out\n' "$nextflow"
        for command in ${POST_PROCESS_CMDS[@]+"${POST_PROCESS_CMDS[@]}"}; do
            name=$(step_name "$command" "$pipeline")
            printf '%s\t%s.out\n' "$name" "$name"
        done
        printf 'composition\tcomposition.out\n'
        printf 'dashboard\tpresent.out\n'
    } | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
        | {name: .[0], log: .[1], state: "waiting"})' | {
        read -r steps
        state_set_json steps "$steps"
    } || warn "Couldn't record this run's steps, so the progress page lists Nextflow's processes alone."
}

# One step, with its row on the progress page kept up with it, and its output
# in <name>.out: run_step <index> <name> <command> [arguments]. A step that
# fails fails the run, with the step's own message.
run_step() {
    local index=$1 name=$2 status=0
    shift 2
    set_step_state "$index" active
    job_run "$name.out" "$@" || status=$?
    job_check_signal
    if (( status != 0 )); then
        set_step_state "$index" failed
        [[ -n $(state_get message) ]] || fail "The $name step failed. Its output is in $name.out."
        exit "$status"
    fi
    set_step_state "$index" done
}

# Each input's size and SHA-256, taken from the files as given, here on the
# compute node, so start stays fast on the login node. Recorded in the state as
# inputs, in the samplesheet's order.
stage_inputs() {
    local threads=${SLURM_CPUS_PER_TASK:-${SLURM_CPUS_ON_NODE:-2}} sums inputs

    set_run_stage "Checking your sequencing files."
    cut -f2- original_samplesheet.tsv | tr '\t' '\n' | grep -v '^$' | sort -u > .inputs.list ||
        fail "Can't read the run's samplesheet."
    xargs -d '\n' -P "$threads" -n 4 sha256sum < .inputs.list > .inputs.sha256 ||
        fail "Couldn't read every FASTQ to take its checksum. The samplesheet's files must stay in place until the run ends."
    sums=$(while read -r sum path; do
        printf '%s\t%s\t%s\n' "$path" "$(stat -L -c %s "$path")" "$sum"
    done < .inputs.sha256 | jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
        | {(.[0]): {bytes: (.[1] | tonumber), sha256: .[2]}}) | add // {}')
    inputs=$(jq -R -s --argjson sums "$sums" '
        split("\n") | map(select(length > 0) | split("\t")
        | {sample: .[0], fastq1: (.[1] | split("/") | last), bytes_1: $sums[.[1]].bytes,
           sha256_1: $sums[.[1]].sha256}
          + (if (.[2] // "") != "" then {fastq2: (.[2] | split("/") | last),
             bytes_2: $sums[.[2]].bytes, sha256_2: $sums[.[2]].sha256} else {} end))' \
        original_samplesheet.tsv) || fail "Couldn't record the inputs' checksums."
    state_set_json inputs "$inputs" || fail "Couldn't record the inputs' checksums."
    rm -f .inputs.list .inputs.sha256
}

# Measured values the record keeps: ampliseq's batch for each input, and an
# option such as taxprofiler's instrument_platform, when the job left it to be
# measured
record_measured() {
    local runs options key
    runs=$(state_get_json samples.runs)
    if [[ $runs != null ]]; then
        state_update '.inputs |= map(. as $input | (if $runs[$input.sample] then
            {sample, run: $runs[$input.sample]} + del(.sample) else . end))' --argjson runs "$runs" ||
            fail "Couldn't record each input's batch."
    fi
    options=$(options_json "$1")
    for key in $(jq -r '.[] | select(.measured // false) | .key' <<< "$options"); do
        if [[ $key == instrument_platform && -z $(form_answer "$key") && -n $(state_get samples.platform) ]]; then
            state_set "answers.$key" "$(state_get samples.platform)"
        fi
    done
}

# The params file, from the layers described at the top
params_build() {
    local key value
    local -A locked=()

    for key in ${PARAMS_LOCKED[@]+"${PARAMS_LOCKED[@]}"}; do
        locked[$key]=${PIPELINE_PARAMS[$key]:-}
    done
    if [[ -r detected_params.yaml ]]; then
        log "Applying the parameters in detected_params.yaml."
        params_load detected_params.yaml
    fi
    params_apply_job "$(state_get_json job_params)"
    for key in "${!locked[@]}"; do
        value=${locked[$key]}
        if [[ ${PIPELINE_PARAMS[$key]:-} != "$value" ]]; then
            warn "\"$key\" is gnoto's to set, so it's put back."
            if [[ -n $value ]]; then
                params_set_json "$key" "$value"
            else
                params_unset "$key"
            fi
        fi
    done
    params_write "$PARAMS_FILE"
    state_set_json params "$(params_json)" || fail "Couldn't record the run's parameters."
}

# A size or time from config.yaml, when Nextflow can read it as written, such
# as 900.GB or 168.h
nextflow_unit() {
    [[ $1 =~ ^[0-9]+\.(B|KB|MB|GB|TB|s|m|h|d)$ ]] && printf '%s' "$1"
}

# site.config: where this site runs tasks and the most each may ask for, from
# config.yaml. None of it changes what a task computes.
write_site_config() {
    local limits=() cpus memory time binds="-B $DB_DIR" bind
    if [[ $(scheduler_kind) == slurm ]]; then
        [[ -z ${SLURM_MAX_CPUS:-} ]] || limits+=("cpus: $SLURM_MAX_CPUS")
        memory=$(nextflow_unit "${SLURM_MAX_MEMORY:-}") && limits+=("memory: $memory")
        time=$(nextflow_unit "${SLURM_MAX_TIME:-}") && limits+=("time: $time")
    else
        cpus=$(nproc 2> /dev/null) && limits+=("cpus: $cpus")
        memory=$(awk '/^MemTotal:/ { printf "%d.GB", $2 / 1048576 }' /proc/meminfo 2> /dev/null) &&
            [[ -n $memory ]] && limits+=("memory: $memory")
    fi
    IFS=, read -ra bind <<< "${APPTAINER_BINDS:-}"
    for bind in ${bind[@]+"${bind[@]}"}; do
        bind=${bind// /}
        [[ -z $bind ]] || binds+=" -B $bind"
    done
    {
        echo "// Written by gnoto from config.yaml: where tasks run, and the most each may ask for"
        echo "process {"
        if [[ $(scheduler_kind) == slurm ]]; then
            echo "    executor = 'slurm'"
            [[ -z ${SLURM_PARTITION:-} ]] || echo "    queue = '$SLURM_PARTITION'"
            [[ -z ${SLURM_ACCOUNT:-} ]] || echo "    clusterOptions = '--account=$SLURM_ACCOUNT'"
        else
            echo "    executor = 'local'"
        fi
        (( ${#limits[@]} == 0 )) || echo "    resourceLimits = [$(IFS=,; echo "${limits[*]}" | sed 's/,/, /g')]"
        echo "}"
        echo "apptainer {"
        echo "    enabled = true"
        echo "    autoMounts = true"
        echo "    cacheDir = '$DATA_DIR/images'"
        echo "    runOptions = '$binds'"
        echo "}"
    } > site.config
}

compute() {
    local pipeline=$1 i status=0 cause

    stage_inputs

    NEXTFLOW_ARGS=()
    PRE_PROCESS_CMDS=()
    POST_PROCESS_CMDS=()
    PARAMS_LOCKED=()
    PIPELINE_DATABASES=()
    ONE_READ_LAYOUT=false
    PARAMS_FILE=""
    params_reset
    export GNOTO_JOB_PARAMS
    GNOTO_JOB_PARAMS=$(state_get_json job_params)
    INSTRUMENT_PLATFORM=$(form_answer instrument_platform)
    if [[ -n $INSTRUMENT_PLATFORM ]]; then
        export INSTRUMENT_PLATFORM
    else
        unset INSTRUMENT_PLATFORM
    fi
    source "$CODE_DIR/pipelines/$pipeline/pipeline.sh"
    [[ ${#NEXTFLOW_ARGS[@]} -gt 0 && -n $PARAMS_FILE ]] ||
        fail "pipelines/$pipeline/pipeline.sh sets no NEXTFLOW_ARGS or PARAMS_FILE."
    record_steps "$pipeline"

    if [[ ${#PRE_PROCESS_CMDS[@]} -gt 0 ]]; then
        set_run_status "Pre-Processing"
        set_run_stage "Preparing your sequencing files."
        for (( i = 0; i < ${#PRE_PROCESS_CMDS[@]}; i++ )); do
            # shellcheck disable=SC2086
            run_step "$i" "$(step_name "${PRE_PROCESS_CMDS[i]}" "$pipeline")" ${PRE_PROCESS_CMDS[i]}
        done
    fi
    record_measured "$pipeline"

    params_build
    record_write || fail "Couldn't write record.yaml."
    write_site_config
    {
        printf '#!/bin/bash\n'
        printf '# %s, run %s, written %s\n' "$(state_get version)" "${PWD##*/}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'exec nextflow'
        printf ' %q' "${NEXTFLOW_ARGS[@]}" -ansi-log false -c site.config
        [[ -z ${NEXTFLOW_CONFIG:-} ]] || printf ' -c %q' "$NEXTFLOW_CONFIG"
        printf '\n'
    } > nextflow_command.sh
    chmod +x nextflow_command.sh

    set_run_status "Running"
    set_run_stage "Running the analysis."
    set_step_state "$NEXTFLOW_STEP" active
    job_run nextflow.out ./nextflow_command.sh || status=$?
    job_check_signal
    if (( status != 0 )); then
        set_step_state "$NEXTFLOW_STEP" failed
        cause=$(nextflow_cause nextflow.out nextflow.log)
        fail "The Nextflow pipeline failed${cause:+: $cause}. Its output is in nextflow.out."
    fi
    set_step_state "$NEXTFLOW_STEP" done
    [[ -d results ]] || fail "Nextflow finished, but wrote no results directory."

    if [[ ${#POST_PROCESS_CMDS[@]} -gt 0 ]]; then
        set_run_status "Post-Processing"
        set_run_stage "Finishing the analysis."
        for (( i = 0; i < ${#POST_PROCESS_CMDS[@]}; i++ )); do
            # shellcheck disable=SC2086
            run_step $((POST_STEP_FIRST + i)) "$(step_name "${POST_PROCESS_CMDS[i]}" "$pipeline")" ${POST_PROCESS_CMDS[i]}
        done
    fi

    set_run_stage "Building the feature tables."
    if [[ -f $CODE_DIR/steps/${pipeline}_composition.sh ]]; then
        run_step "$COMPOSITION_STEP" composition "$CODE_DIR/steps/${pipeline}_composition.sh" results
    else
        warn "There's no steps/${pipeline}_composition.sh, so no core tables were built."
        set_step_state "$COMPOSITION_STEP" done
    fi

    # The published copies: the record, and the job file with its samplesheet
    # reduced to the file's name, so neither names a site path
    record_write || fail "Couldn't write record.yaml."
    cp record.yaml results/record.yaml || fail "Couldn't copy record.yaml into results/."
    SAMPLESHEET_NAME=$(basename "$(state_get samplesheet)") \
        yq '.samplesheet = strenv(SAMPLESHEET_NAME)' job.yaml > results/job.yaml ||
        fail "Couldn't copy job.yaml into results/."
    state_set stages.compute "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

present() {
    local pipeline=$1 status=0
    set_run_status "Presenting"
    set_run_stage "Building your results pages."
    if [[ ! -f $CODE_DIR/present/$pipeline.sh ]]; then
        fail "There's no present/$pipeline.sh, so no dashboard was built."
    fi
    run_step "$PRESENT_STEP" present "$CODE_DIR/present/$pipeline.sh" results
    state_set stages.present "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# Phase 7 copies the zip and pages to Globus or S3 here. Until then, the
# results stay in the run directory, as they do when neither is set.
publish() {
    if [[ ${AWS_ENABLED:-false} == true || ${GLOBUS_ENABLED:-false} == true ]]; then
        state_append notes "Publishing to S3 and Globus isn't built yet, so the results stay in $PWD." || :
    fi
    log "The results are in $PWD/results."
    state_set stages.publish "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

# job_main <run directory>
job_main() {
    local run_dir=${1%/} pipeline self

    [[ $run_dir == "$DATA_DIR"/runs/* ]] && is_valid_uid "${run_dir##*/}" ||
        fail "$run_dir isn't a run directory."
    cd "$run_dir" || fail "Can't enter $run_dir."
    state_present || fail "$run_dir has no run_state.json."
    pipeline=$(state_get pipeline)

    state_set started_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    state_set host "$(uname -n)"
    [[ -z ${SLURM_JOB_ID:-} ]] || state_set scheduler.job_id "$SLURM_JOB_ID"
    if [[ -e cancel ]]; then
        set_run_status Cancelled
        fail "The job was cancelled before it started."
    fi

    trap 'job_on_signal TERM' TERM
    trap 'job_on_signal INT' INT
    trap 'job_on_signal HUP' HUP
    trap stop_progress EXIT

    set_run_status "Initializing"
    set_run_stage "Getting your run ready."
    databases_wait "$(state_get_json databases | jq -r '.[]?')"
    if [[ -f $CODE_DIR/present/progress.sh ]]; then
        # Taken first: in a command started with &, $BASHPID would be the
        # watcher's own
        self=$BASHPID
        bash "$CODE_DIR/present/progress.sh" --watch "$self" > progress.out 2>&1 &
        PROGRESS_PID=$!
    fi

    compute "$pipeline"
    job_check_signal

    # The watcher stops before the dashboard replaces its page
    stop_progress
    present "$pipeline"
    publish
    set_run_status Completed
    state_set stage "Finished."
}
