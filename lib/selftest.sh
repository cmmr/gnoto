#
# selftest.sh - gnoto selftest: runs each pipeline's fixture jobs, and
# reports how their core tables compare with the reference copies a version
# carries.
#
# Sourced by:  lib/main.sh, for selftest and _selftest
# Defines:     selftest_main, selftest_report_main, selftest_status
# Requires:    the settings and helpers from lib/env.sh; args_parse from
#              lib/args.sh; job_yaml and job_check from lib/jobfile.sh;
#              databases_offer from lib/databases.sh; nodes_prescan and the
#              lint counters from lib/lint.sh; start_run and new_uid from
#              lib/start.sh; and for _selftest, live_status and run_lock from
#              lib/runs.sh and teardown_run from service/expire.sh
#
# Usage:  gnoto selftest [--dev] [--yes] [<pipeline> ...]
#         Runs the jobs pipelines/<name>/selftest.yaml lists, for every
#         pipeline or those named, and returns once they're submitted. --yes
#         accepts fetching the databases and fixtures they need. --dev runs
#         the install's own files and compares them with the last release, or
#         while there's none, with main's tip. Without it, they run at the
#         current version and are compared with its own reference tables.
#
# Each job in selftest.yaml names its samples as files in the database
# directory, the fixtures from docs/fixtures.md, and its options as gnoto start
# takes them. pipelines/<name>/selftest/<job>/ holds the reference copy of the
# job's core tables, the files stable-files lists, under their paths in
# results/.
#
# A selftest is <data_dir>/selftest/<id>/: state.yaml, the job files in
# jobs/, and the reference tables it compares with in expected/, copied when
# it starts. Its runs carry its id in their state, so they publish nothing and
# set no expiry. A report job, submitted after every run's followup, writes
# report.txt and report.yaml, copies each run's core tables into tables/, from
# where a maintainer copies them into pipelines/<name>/selftest/ when a change
# is meant, and then removes the runs, keeping their history. gnoto status
# lists the selftests of the last 7 days.

SELFTEST_REPORT_TIME=02:00:00

# The pipelines that have a selftest.yaml
selftest_pipelines() {
    local file
    for file in "$CODE_DIR"/pipelines/*/selftest.yaml; do
        [[ -f $file ]] || continue
        file=${file%/selftest.yaml}
        printf '%s\n' "${file##*/}"
    done
}

# What the selftest compares with, as BASELINE_DIR, the code holding the
# reference tables, and BASELINE_LABEL: this version's own, or under --dev, the
# last release's, or main's tip's while there's none
selftest_baseline() {
    local tag commit
    if [[ $CODE_DEV != true ]]; then
        BASELINE_DIR=$CODE_DIR
        BASELINE_LABEL="this version's reference tables, at ${CODE_COMMIT:0:7}"
        return 0
    fi
    tag=$(latest_release "$CODE_REPOSITORY")
    if [[ -n $tag ]]; then
        commit=$(version_resolve "$CODE_REPOSITORY" "${tag#v}") || fail "Can't find the last release, $tag, in $CODE_REPOSITORY."
        BASELINE_LABEL="the last release's reference tables, $tag"
    else
        commit=$(version_resolve "$CODE_REPOSITORY" main) || fail "Can't find main in $CODE_REPOSITORY."
        BASELINE_LABEL="main's reference tables, at ${commit:0:7}, as there's no release yet"
    fi
    cache_lock
    version_fetch "$CODE_REPOSITORY" "$commit" || fail "Can't fetch gnoto at $commit to compare with."
    BASELINE_DIR=$DATA_DIR/versions/$commit
}

# A job of selftest.yaml as JSON: selftest_job <pipeline> <index>
selftest_job() {
    J=$2 yq -o=json -I=0 '.jobs[env(J)]' "$CODE_DIR/pipelines/$1/selftest.yaml"
}

# gnoto selftest [--dev] [--yes] [<pipeline> ...]
selftest_main() {
    local usage="Usage: gnoto selftest [--dev] [--yes] [<pipeline> ...]" yes=false pipeline count i job name
    local id="" dir tries jobdir args fetch=() entry out uid after="" followup fetch_after="" bytes
    local pipelines=() runs=() lines=()
    local -A seen=() fetch_bytes=() fetch_count=()

    args_parse "$usage" "dev yes" "$@"
    [[ ${#ARG_KEYS[@]} -eq 0 ]] || fail "gnoto selftest takes --dev and --yes, not --${ARG_KEYS[0]}. $usage"
    [[ -z ${ARG_FLAGS[yes]:-} ]] || yes=true
    pipelines=(${ARG_WORDS[@]+"${ARG_WORDS[@]}"})
    (( ${#pipelines[@]} > 0 )) || mapfile -t pipelines < <(selftest_pipelines)
    (( ${#pipelines[@]} > 0 )) || fail "No pipeline has a selftest.yaml."
    for pipeline in "${pipelines[@]}"; do
        [[ $pipeline =~ ^[a-z][a-z0-9_]*$ && -f $CODE_DIR/pipelines/$pipeline/selftest.yaml ]] ||
            fail "There's no selftest for \"$pipeline\". These pipelines have one: $(selftest_pipelines | paste -sd ' ')."
    done
    code_version
    selftest_baseline

    mkdir -p "$DATA_DIR/selftest" || fail "Can't create $DATA_DIR/selftest."
    chmod g+s "$DATA_DIR/selftest" 2> /dev/null || :
    for (( tries = 0; tries < 5; tries++ )); do
        id=$(new_uid)
        is_valid_uid "$id" && mkdir "$DATA_DIR/selftest/$id" 2> /dev/null && break
        id=""
    done
    [[ -n $id ]] || fail "Can't create a directory in $DATA_DIR/selftest."
    dir=$DATA_DIR/selftest/$id
    echo "Selftest $id, against $BASELINE_LABEL"

    # 1. Each job's file, checked, and its reference tables kept
    for pipeline in "${pipelines[@]}"; do
        count=$(yq '.jobs | length' "$CODE_DIR/pipelines/$pipeline/selftest.yaml")
        for (( i = 0; i < count; i++ )); do
            job=$(selftest_job "$pipeline" "$i")
            name=$(jq -r .name <<< "$job")
            [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || fail "pipelines/$pipeline/selftest.yaml has a job named \"$name\": use lowercase letters, digits and -."
            jobdir=$dir/jobs/$pipeline-$name
            mkdir -p "$jobdir" "$dir/expected/$pipeline/$name" || fail "Can't create $jobdir."
            jq -r --arg db "$DB_DIR" '.samples[] | [.[0]] + (.[1:] | map($db + "/" + .)) | join("\t")' \
                <<< "$job" > "$jobdir/samplesheet.tsv" || fail "Can't write $jobdir/samplesheet.tsv."
            if [[ -d $BASELINE_DIR/pipelines/$pipeline/selftest/$name ]]; then
                cp -R "$BASELINE_DIR/pipelines/$pipeline/selftest/$name/." "$dir/expected/$pipeline/$name/" &&
                    chmod -R u+w,g+w "$dir/expected/$pipeline/$name" || fail "Can't copy the reference tables for $pipeline $name."
            fi
            mapfile -t args < <(jq -r '.args[]?' <<< "$job")
            args_parse "$usage" "" ${args[@]+"${args[@]}"} --title="selftest $pipeline $name" \
                --samplesheet="$jobdir/samplesheet.tsv" --retention="1 Month"
            job_yaml "$pipeline" > "$jobdir/job.yaml" || fail "Can't write the job file for $pipeline $name."

            LINT_FAILS=0
            LINT_WARNS=0
            JOB_FETCHABLE=()
            JOB_MISSING_DATABASES=0
            job_check "$jobdir/job.yaml" > "$jobdir/lint.txt"
            if (( LINT_FAILS > JOB_MISSING_DATABASES )); then
                echo "$pipeline $name:"
                grep -E '^  (FAIL|WARN) ' "$jobdir/lint.txt" | sed 's/^/  /'
                fail "Not started: $pipeline's job $name failed its checks, as gnoto lint $jobdir/job.yaml shows."
            fi
            for entry in ${JOB_FETCHABLE[@]+"${JOB_FETCHABLE[@]}"}; do
                [[ -z ${seen[$entry]:-} ]] || continue
                seen[$entry]=1
                fetch+=("$entry")
                fetch_count[$pipeline]=$(( ${fetch_count[$pipeline]:-0} + 1 ))
                fetch_bytes[$pipeline]=$(( ${fetch_bytes[$pipeline]:-0} + $(db_bytes_for "$entry") ))
            done
            lines+=("$pipeline"$'\t'"$name"$'\t'"$jobdir")
        done
    done

    # 2. What they need that's missing, fetched once for them all
    if (( ${#fetch[@]} > 0 )); then
        echo "The jobs need databases and fixtures that aren't here yet:"
        for pipeline in "${pipelines[@]}"; do
            (( ${fetch_count[$pipeline]:-0} > 0 )) || continue
            printf '  %s: %d to fetch, %s\n' "$pipeline" "${fetch_count[$pipeline]}" "$(human_size "${fetch_bytes[$pipeline]}")"
        done
        JOB_FETCHABLE=("${fetch[@]}")
        JOB_FETCH_AFTER=""
        databases_offer "$yes" > /dev/null || exit 1
    fi
    nodes_prescan

    # 3. Each job, started as a run carrying the selftest's id
    for job in "${lines[@]}"; do
        IFS=$'\t' read -r pipeline name jobdir <<< "$job"
        LINT_FAILS=0
        LINT_WARNS=0
        job_check "$jobdir/job.yaml" > "$jobdir/lint.txt"
        (( LINT_FAILS == 0 )) || fail "Not started: $pipeline's job $name failed its checks once its fetches were submitted, as $jobdir/lint.txt shows."
        fetch_after=${JOB_FETCH_AFTER:-}
        out=$( (cd "$jobdir" && SELFTEST_ID=$id start_run false "$fetch_after") 2>&1) ||
            fail "Couldn't start $pipeline's job $name: $(tail -1 <<< "$out")"
        uid=$(sed -n 's/^Started \([a-z2-7]\{8\}\), .*/\1/p' <<< "$out")
        is_valid_uid "$uid" || fail "Couldn't tell which run $pipeline's job $name started: $(tail -1 <<< "$out")"
        echo "  $pipeline $name: run $uid"
        runs+=("$(jq -cn --arg pipeline "$pipeline" --arg job "$name" --arg uid "$uid" '{pipeline: $pipeline, job: $job, uid: $uid}')")
        followup=$(jq -r '.scheduler.followup_id // ""' "$DATA_DIR/runs/$uid/$RUN_STATE_FILE")
        [[ -z $followup ]] || after+="${after:+:}$followup"
    done

    jq -n --arg id "$id" --arg owner "$(id -un)" --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg version "$([[ $CODE_DEV == true ]] && echo dev || echo "$CODE_COMMIT")" \
        --arg baseline "$BASELINE_LABEL" --argjson runs "$(printf '%s\n' "${runs[@]}" | jq -s .)" '
        {id: $id, owner: $owner, created_utc: $created, version: $version, against: $baseline,
         status: "Running", runs: $runs}' | yq -P -o=yaml . > "$dir/state.yaml" ||
        fail "Can't write $dir/state.yaml."

    # 4. The report, once every run has ended
    out=$(scheduler_submit --name "gnoto-selftest-$id" --dir "$dir" --log "$dir/report.out" --cpus 1 --mem 2G \
        --time "$SELFTEST_REPORT_TIME" --after "${after:+afterany:$after}" -- _selftest "$dir") ||
        fail "Couldn't submit the selftest's report job. Its runs go on; $(gnoto_command remove '<uid>') removes them."
    [[ $out == local ]] || I=$out yq -i '.report_job = env(I)' "$dir/state.yaml"
    chmod -R g+rwX "$dir" 2> /dev/null || :
    echo "Started ${#runs[@]} job$( (( ${#runs[@]} == 1 )) || echo s). Once they end, the report is $dir/report.txt."
    echo "Follow it with: $(gnoto_command status)"
}

# Whether a selftest's run has ended: its followup has recorded it, its
# directory has gone, or nothing is running for it
selftest_run_ended() {
    local uid=$1
    [[ -n $(jq -r '.ended_utc // ""' "$DATA_DIR/history/$uid/state.json" 2> /dev/null) ]] && return 0
    [[ -r $DATA_DIR/runs/$uid/$RUN_STATE_FILE ]] || return 0
    [[ $(cd "$DATA_DIR/runs/$uid" && live_status) == Lost ]]
}

# _selftest <selftest directory>: waits for every run to end, writes the
# report, copies each run's core tables into tables/, and removes the runs
selftest_report_main() {
    local dir=${1%/} id run pipeline name uid pending state_file status message outputs expected comparison
    local summary results lines=() entries=() identical=0 differ=0 failed=0

    id=${dir##*/}
    [[ $dir == "$DATA_DIR"/selftest/* && -r $dir/state.yaml ]] || fail "$dir isn't a selftest's directory."
    cd "$dir" || fail "Can't enter $dir."

    while :; do
        pending=0
        while IFS= read -r uid; do
            selftest_run_ended "$uid" || pending=$((pending + 1))
        done < <(yq -r '.runs[].uid' state.yaml)
        (( pending > 0 )) || break
        sleep 30
    done

    while IFS= read -r run; do
        pipeline=$(jq -r .pipeline <<< "$run")
        name=$(jq -r .job <<< "$run")
        uid=$(jq -r .uid <<< "$run")
        state_file=$DATA_DIR/runs/$uid/$RUN_STATE_FILE
        [[ -r $state_file ]] || state_file=$DATA_DIR/history/$uid/state.json
        status=$(jq -r '.status // "Lost"' "$state_file" 2> /dev/null) || status=Lost
        message=$(jq -r '(.message // "" | tostring | split("\n")[0]) // ""' "$state_file" 2> /dev/null) || message=""
        results=$DATA_DIR/runs/$uid/results
        comparison=null
        if [[ $status == Completed || $status == "Publish failed" ]] && [[ -d $results ]]; then
            outputs=$(jq -c '.outputs // []' "$state_file")
            expected=$(outputs_measure "$pipeline" "expected/$pipeline/$name") || expected="[]"
            comparison=$(outputs_compare "$pipeline" "$expected" "$outputs" "$dir/expected/$pipeline/$name" "$results") ||
                comparison=null
            # The run's tables, for pipelines/<name>/selftest/ when a change is meant
            mkdir -p "tables/$pipeline/$name"
            while IFS=$'\t' read -r path _; do
                mkdir -p "tables/$pipeline/$name/$(dirname "$path")" && cp "$results/$path" "tables/$pipeline/$name/$path" || :
            done < <(outputs_list "$pipeline" "$results")
        fi
        if [[ $comparison == null ]]; then
            failed=$((failed + 1))
            summary="$status${message:+: $message}"
        elif [[ $expected == "[]" ]]; then
            differ=$((differ + 1))
            summary="Completed. There are no reference tables for this job, so its $(jq '.tables | length' <<< "$comparison") core tables are in tables/$pipeline/$name/ to start them."
        else
            summary="Completed. $(outputs_summary "$comparison" "the reference")"
            if [[ $(jq -r .identical <<< "$comparison") == true ]]; then
                identical=$((identical + 1))
            else
                differ=$((differ + 1))
            fi
        fi
        lines+=("$pipeline $name, run $uid: $summary")
        if [[ $comparison != null && $expected != "[]" ]]; then
            lines+=("$(comparison_lines "$comparison" "the reference's" | sed '1d; s/^ */    /')")
        fi
        entries+=("$(jq -cn --arg pipeline "$pipeline" --arg job "$name" --arg uid "$uid" --arg status "$status" \
            --arg message "$message" --argjson comparison "$comparison" '
            {pipeline: $pipeline, job: $job, uid: $uid, status: $status}
            + (if $message != "" then {message: $message} else {} end)
            + (if $comparison != null then {comparison: $comparison} else {} end)')")

        # The run itself goes, keeping its history
        (
            run_lock "$uid" || exit 1
            [[ ! -d $DATA_DIR/runs/$uid ]] || teardown_run "$uid" "Removed by selftest $id, once its report was written."
        ) || warn "Couldn't remove run $uid."
    done < <(yq -o=json -I=0 '.runs[]' state.yaml)

    summary="$identical identical, $differ differing, $failed not completed"
    {
        echo "gnoto selftest $id, $(yq -r .version state.yaml), against $(yq -r .against state.yaml)"
        echo "Started $(yq -r .created_utc state.yaml) by $(yq -r .owner state.yaml), reported $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Jobs: $summary"
        echo
        printf '%s\n' "${lines[@]}" | grep -v '^$'
        echo
        echo "Each completed run's core tables are in $dir/tables/<pipeline>/<job>/. Where a difference is meant,"
        echo "they replace pipelines/<pipeline>/selftest/<job>/."
    } > report.txt
    printf '%s\n' "${entries[@]}" | jq -s . | yq -P -o=yaml . > report.yaml
    S=$summary yq -i '.status = "Reported" | .summary = strenv(S) | .reported_utc = now' state.yaml
    chmod -R g+rwX "$dir" 2> /dev/null || :
    log "Selftest $id: $summary. The report is $dir/report.txt."
}

# The selftests of the last 7 days, for gnoto status, a line each
selftest_status() {
    local file dir now created runs ended version uid rows=()
    now=$(date -u +%s)
    for file in "$DATA_DIR"/selftest/*/state.yaml; do
        [[ -r $file ]] || continue
        dir=${file%/state.yaml}
        created=$(yq -r '.created_utc // ""' "$file")
        [[ -n $created ]] && (( now - $(date -u -d "$created" +%s) <= 7 * 86400 )) || continue
        version=$(yq -r .version "$file")
        [[ ! $version =~ ^[0-9a-f]{40}$ ]] || version=${version:0:7}
        if [[ $(yq -r .status "$file") == Reported ]]; then
            rows+=("$(printf '%s\t%s\t%s\t%s\t%s' "$created" "${dir##*/}" "$version" \
                "$(yq -r .summary "$file")" "$dir/report.txt")")
        else
            runs=$(yq '.runs | length' "$file")
            ended=0
            while IFS= read -r uid; do
                [[ -z $(jq -r '.ended_utc // ""' "$DATA_DIR/history/$uid/state.json" 2> /dev/null) ]] || ended=$((ended + 1))
            done < <(yq -r '.runs[].uid' "$file")
            rows+=("$(printf '%s\t%s\t%s\t%s' "$created" "${dir##*/}" "$version" \
                "Running: $ended of $runs jobs ended")")
        fi
    done
    (( ${#rows[@]} > 0 )) || return 0
    echo
    echo "Selftests in the last 7 days"
    printf '%s\n' "${rows[@]}" | sort -r | cut -f2- | align_rows
}
