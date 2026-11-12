#!/bin/bash
#
# progress.sh - Keeps a running job's progress page current, and stops the job
# when it's cancelled.
#
# Run by:    lib/job.sh, in the background from the start of Compute to the
#            start of Present, as progress.sh --watch <pid>; and the followup,
#            once, to leave a failed or cancelled run's page
# Usage:     progress.sh [--watch <pid>] [--interval <seconds>]
# Requires:  GNU awk and jq; squeue and sacct, through their stand-ins, when the
#            run is on Slurm
# Reads:     status, title, stage, message, steps, scheduler.kind, started_utc,
#            stages.present and clocks in ./run_state.json; each step's console
#            output and, beside it, Nextflow's log for a step that ran Nextflow
#            (nextflow.out and nextflow.log, humann.out and humann.log); and
#            ./cancel
# Writes:    results/index.html, results/progress.json and results/assets/, and
#            with S3, their copies at the run's results address, through
#            progress_publish in service/publish.sh;
#            clocks.elapsed_seconds and clocks.cpu_seconds in ./run_state.json
#
# Runs from the run directory. With --watch, it renders the page every interval
# (10 seconds) until it's sent SIGTERM or <pid> ends, and the first time it
# finds a file named cancel in the run directory, it sends <pid>, the job's own
# process, SIGTERM, which stops the job as cancelled. It checks for that file
# every 2 seconds. Without --watch, it renders once.
#
# The page shows the run's steps in order, with each Nextflow run's processes
# under the step that drives it, a dial of every task together, the run's jobs
# and clocks, and for a run that failed, its message and what Nextflow said.
# The processes come from Nextflow's log: its "Submitted process", "Cached
# process" and "Re-submitted process" lines, which the console carries too, and
# its "Task completed" lines, which only the log does. A trace file would need
# each workflow's own setting to find, and doesn't say what was submitted.
#
# progress.json holds only what the page shows, and the page is rendered with
# it, so it reads off disk too. Nothing in either names a path on this site.
# Parsing logs isn't a stable interface, so every failure here is soft: a page
# that can't be built is skipped, and this never fails the run.
#
# It never writes over the dashboard: once the state records stages.present, it
# leaves the page alone.

set -uo pipefail

source "${BASH_SOURCE[0]%/*}/../lib/env.sh" || exit 0
source "$CODE_DIR/present/dashboard.sh"
source "$CODE_DIR/present/common.sh"

RESULTS_DIR=results
PROGRESS_TEMPLATE=$CODE_DIR/present/templates/progress.html
STATE_FILE=progress.json
INTERVAL=10
TICK=2
LOG_TAIL_LINES=200
DIAL_CIRCUMFERENCE=339.292
STARTING_MESSAGE="Starting up. The pipeline is being prepared; progress will appear here shortly."
WATCH_PID=""
STOPPED=""

usage() {
    echo "Usage: progress.sh [--watch <pid>] [--interval <seconds>]" >&2
    exit 1
}

while (( $# > 0 )); do
    case $1 in
        --watch)
            [[ ${2:-} =~ ^[0-9]+$ ]] || usage
            WATCH_PID=$2
            shift 2
            ;;
        --interval)
            [[ ${2:-} =~ ^[0-9]+$ && $2 -gt 0 ]] || usage
            INTERVAL=$2
            shift 2
            ;;
        *) usage ;;
    esac
done

# The Nextflow log beside a step's console output, which carries the task
# completions the console doesn't, or the console itself without one
nextflow_log_for() {
    local log=${1%.out}.log
    if [[ $1 == *.out && -r $log ]]; then
        printf '%s' "$log"
    else
        printf '%s' "$1"
    fi
}

# One Nextflow run's processes, from its log, as rows, in the order each was
# first submitted. The first line is "TOTALS <ended> <tasks> <in flight>", for
# the dial. A retry is the same task again, and a task whose error was ignored
# has ended. Indented under its step given a second argument. Prints nothing
# when the log names no process.
render_rows() {
    # A step's console file doesn't exist until the step starts
    [[ -r $1 ]] || return 1
    LC_ALL=C awk -v indent="${2:-}" -v stopped="$STOPPED" '
        function esc(s) {
            gsub(/&/, "\\&amp;", s)
            gsub(/</, "\\&lt;", s)
            gsub(/>/, "\\&gt;", s)
            gsub(/"/, "\\&quot;", s)
            return s
        }

        # A task name is its process, a space and its tag
        function proc_of(name,   p) {
            p = index(name, " ")
            return p ? substr(name, 1, p - 1) : name
        }

        function seen(proc) {
            if (!(proc in total)) {
                order[++np] = proc
                total[proc] = 0
            }
        }

        # NFCORE_AMPLISEQ:AMPLISEQ:FASTQC is FASTQC
        function pretty(proc) {
            sub(/^.*:/, "", proc)
            return proc
        }

        match($0, /\[[0-9a-f][0-9a-f]\/[0-9a-f]+\] (Submitted|Re-submitted|Cached) process > /) {
            head = substr($0, RSTART, RLENGTH)
            proc = proc_of(substr($0, RSTART + RLENGTH))
            seen(proc)
            if (head ~ /Re-submitted/) next
            total[proc]++
            if (head ~ /Cached/) good[proc]++
            next
        }

        index($0, "Task completed > ") {
            s = substr($0, index($0, "Task completed > "))
            p = index(s, "name: ")
            if (!p) next
            s = substr(s, p + 6)
            p = index(s, "; status: ")
            if (!p) next
            proc = proc_of(substr(s, 1, p - 1))
            code = ""
            p = index(s, "; exit: ")
            if (p) {
                code = substr(s, p + 8)
                sub(/;.*/, "", code)
            }
            seen(proc)
            if (code == "0") good[proc]++
            else bad[proc]++
            next
        }

        index($0, "NOTE: Process ") && index($0, " terminated with an error exit status") {
            s = substr($0, index($0, "NOTE: Process ") + 15)
            proc = proc_of(s)
            if (index($0, "-- Execution is retried")) retried[proc]++
            else if (index($0, "-- Error is ignored")) ignored[proc]++
        }

        END {
            if (np == 0) exit 0
            for (i = 1; i <= np; i++) {
                proc = order[i]
                t = total[proc]
                ended = good[proc] + bad[proc] - retried[proc]
                if (ended < 0) ended = 0
                if (ended > t) ended = t
                fatal = bad[proc] - retried[proc] - ignored[proc]
                if (fatal < 0) fatal = 0
                pct[i] = t > 0 ? int(100 * ended / t) : 0
                state[i] = fatal > 0 ? "failed" : (ended >= t ? "done" : "active")
                count[i] = (ended - fatal) " of " t (fatal > 0 ? ", " fatal " failed" : "")
                tasks_done += ended
                tasks_total += t
                flying += t - ended
            }
            printf "TOTALS %d %d %d\n", tasks_done, tasks_total, flying

            for (i = 1; i <= np; i++) {
                # Navy once done, striped green in flight, grey in flight on a run
                # that has stopped, and red when one failed
                fill = stopped ? "bg-outline" : "bg-bio-growth stripe"
                if (state[i] == "done") fill = "bg-primary-container"
                if (state[i] == "failed") fill = "bg-error-red"
                label = esc(pretty(order[i]))
                printf "<div class=\"flex items-center gap-3 py-1\">"
                printf "<span class=\"font-code-md text-code-md text-on-surface truncate%s", (indent != "" ? " pl-4" : "")
                printf " basis-[42%%] shrink-0\" title=\"%s\">%s</span>", label, label
                printf "<span class=\"flex-1 h-1.5 bg-surface-variant rounded-full overflow-hidden\">"
                printf "<span class=\"block h-full %s rounded-full\" style=\"width:%s%%\"></span>", \
                    fill, (state[i] == "active" && pct[i] < 3 ? 3 : pct[i])
                printf "</span>"
                printf "<span class=\"font-code-sm text-code-sm text-on-surface-variant w-9"
                printf " text-right shrink-0\">%s%%</span>", pct[i]
                printf "<span class=\"font-body-sm text-body-sm text-on-surface-variant w-24"
                printf " text-right shrink-0 hidden sm:block\">%s</span>", esc(count[i])
                printf "</div>\n"
            }
        }
    ' "$1"
}

# A step's row, in the same columns as a process's and set heavier. A step has
# no tasks to count, so its bar is empty until it starts, striped while it
# runs, and full once it's over: navy when it finished, red when it failed.
# A step still running on a run that has stopped is grey.
step_row() {
    local name=$1 state=$2 fill="" percent="" note
    case $state in
        active)
            if [[ -n $STOPPED ]]; then
                fill="bg-outline" note=stopped
            else
                fill="bg-bio-growth stripe" note=running
            fi
            ;;
        done) fill="bg-primary-container" note=done percent=100% ;;
        failed) fill="bg-error-red" note=failed ;;
        *) note=waiting ;;
    esac
    printf '<div class="flex items-center gap-3 py-1">'
    printf '<span class="font-code-md text-code-md text-on-surface font-semibold truncate'
    printf ' basis-[42%%] shrink-0" title="%s">%s</span>' "$(escape_html "$name")" "$(escape_html "$name")"
    printf '<span class="flex-1 h-1.5 bg-surface-variant rounded-full overflow-hidden">'
    [[ -z $fill ]] || printf '<span class="block h-full w-full %s rounded-full"></span>' "$fill"
    printf '</span>'
    printf '<span class="font-code-sm text-code-sm text-on-surface-variant w-9 text-right shrink-0">%s</span>' "$percent"
    printf '<span class="font-body-sm text-body-sm text-on-surface-variant w-24 text-right shrink-0 hidden sm:block">%s</span>' "$note"
    printf '</div>\n'
}

# The recorded steps in order, each followed by the processes of the Nextflow
# run it drives, totals first, as render_rows writes them. A step with no
# processes counts as one task, so the dial moves before and after Nextflow.
render_steps() {
    local name log state rows totals done_count total_count flying
    local tasks_done=0 tasks_total=0 tasks_flying=0 body=""

    while IFS=$'\t' read -r name log state; do
        rows=""
        if [[ -n $log && -r $log ]]; then
            rows=$(render_rows "$(nextflow_log_for "$log")" indent) || rows=""
        fi
        if [[ $rows == TOTALS\ * ]]; then
            totals=${rows%%$'\n'*}
            rows=${rows#*$'\n'}$'\n'
            read -r _ done_count total_count flying <<< "$totals"
            tasks_done=$((tasks_done + done_count))
            tasks_total=$((tasks_total + total_count))
            tasks_flying=$((tasks_flying + flying))
        else
            rows=""
            tasks_total=$((tasks_total + 1))
            [[ $state == done ]] && tasks_done=$((tasks_done + 1))
        fi
        body+="$(step_row "$name" "$state")"$'\n'"$rows"
    done < <(state_get_json steps | jq -r '.[]? | [.name, .log, .state] | @tsv' 2> /dev/null)

    [[ -n $body ]] || return 0
    printf 'TOTALS %d %d %d\n%s' "$tasks_done" "$tasks_total" "$tasks_flying" "$body"
}

# This run's Slurm jobs, as "<running> <pending>": those whose work directory
# is the run directory or below it, which is the job and every task Nextflow
# submits, less the followup, which waits on the job throughout. Nothing when
# squeue can't answer.
slurm_job_counts() {
    command -v squeue > /dev/null 2>&1 || return 0
    squeue --user="$(id -un)" --states=RUNNING,PENDING --noheader --format='%T|%r|%j|%Z' 2> /dev/null |
        LC_ALL=C awk -F'|' -v here="$PWD" '
            { for (i = 1; i <= NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i) }
            $3 ~ /-followup$/ { next }
            $1 == "PENDING" && $2 ~ /^Dependency/ { next }
            $4 != here && index($4, here "/") != 1 { next }
            $1 == "RUNNING" { running++; next }
            $1 == "PENDING" { pending++ }
            END { printf "%d %d\n", running, pending }
        '
}

# The two counts under the dial
count_block() {
    local number=$1 label=$2
    printf '<div class="flex flex-col items-center">'
    printf '<span class="font-headline-lg text-headline-lg font-bold text-primary leading-none">%s</span>' "$number"
    printf '<span class="font-label-caps text-label-caps text-on-surface-variant mt-1">%s</span>' "$label"
    printf '</div>'
}

cluster_widget() {
    local title=$1
    shift
    printf '<div class="flex items-center justify-center gap-7 pt-5 border-t border-outline-variant w-full"'
    printf ' title="%s">' "$(escape_html "$title")"
    while (( $# >= 2 )); do
        count_block "$1" "$2"
        shift 2
    done
    printf '</div>'
}

# Seconds as hours and minutes, the hours running past 24
clock() {
    printf '%dh %02dm' "$(($1 / 3600))" "$(($1 / 60 % 60))"
}

timers_widget() {
    local elapsed=$1 cpu=$2
    [[ $elapsed =~ ^[0-9]+$ ]] && (( elapsed > 0 )) || return 0
    printf '<div class="flex flex-col gap-1 pt-5 border-t border-outline-variant w-full">'
    printf '<div class="flex items-baseline justify-between gap-2">'
    printf '<span class="font-body-sm text-body-sm text-on-surface-variant">Elapsed</span>'
    printf '<span class="font-body-sm text-body-sm text-on-surface">%s</span></div>' "$(clock "$elapsed")"
    if [[ $cpu =~ ^[0-9]+$ ]]; then
        printf '<div class="flex items-baseline justify-between gap-2"'
        printf ' title="CPU time held across every job of this run, finished ones included">'
        printf '<span class="font-body-sm text-body-sm text-on-surface-variant">CPU time</span>'
        printf '<span class="font-body-sm text-body-sm text-on-surface">%s</span></div>' "$(clock "$cpu")"
    fi
    printf '</div>'
}

# The style of the dial's arc: how much of the ring to draw, and for nothing, a
# flat cap, since a round one on an arc of zero is drawn as a dot
dial_arc() {
    if (( $1 <= 0 )); then
        printf 'stroke-dasharray: 0 %s; stroke-linecap: butt' "$DIAL_CIRCUMFERENCE"
        return 0
    fi
    LC_ALL=C awk -v p="$1" -v c="$DIAL_CIRCUMFERENCE" 'BEGIN { printf "stroke-dasharray: %.1f %s", c * p / 100, c }'
}

# What a failed step printed: Nextflow's account of a failed task, from the
# last "ERROR ~ Error executing process" to the end, or any last "ERROR ~"
# block, or else the end of the output. Asked for by name because Nextflow
# closes a failed run with a second, empty error that would otherwise be all
# there is.
error_block() {
    [[ -s $1 ]] || return 1
    LC_ALL=C awk -v tail="$LOG_TAIL_LINES" '
        { line[NR] = $0 }
        /^ERROR ~ Error executing process/ { task = NR }
        /^ERROR ~/ { any = NR }
        END {
            if (NR == 0) exit 1
            first = task ? task : (any ? any : NR - tail + 1)
            if (NR - first + 1 > tail) first = NR - tail + 1
            if (first < 1) first = 1
            for (i = first; i <= NR; i++) print line[i]
        }
    ' "$1"
}

# A log under a heading, in a box that scrolls rather than grows
log_panel() {
    printf '<details class="border border-outline-variant rounded-lg" open>'
    printf '<summary class="font-label-caps text-label-caps text-on-surface-variant px-3 py-2 cursor-pointer">%s</summary>' \
        "$(escape_html "$1")"
    printf '<pre class="font-code-sm text-code-sm text-on-surface bg-surface-container px-3 py-2 max-h-96 overflow-auto">%s</pre>' \
        "$(escape_html "$2")"
    printf '</details>'
}

# What went wrong, for a run that didn't finish: the message the stage that
# failed left, and what the failed step printed, with this site's paths taken
# out. The full logs stay in the run directory, for gnoto status.
failure_report() {
    local message output="" name log state failed_name="" failed_log=""

    message=$(state_get message | present_redact)
    while IFS=$'\t' read -r name log state; do
        if [[ $state == failed ]]; then
            failed_name=$name
            failed_log=$log
            break
        fi
    done < <(state_get_json steps | jq -r '.[]? | [.name, .log, .state] | @tsv' 2> /dev/null)
    if [[ -n $failed_log ]]; then
        output=$(error_block "$failed_log" | present_redact) || output=""
    fi
    [[ -n $message$output ]] || return 0

    printf '<div class="bg-surface-container-lowest border border-error-red/40 rounded-xl shadow-sm p-padding-card flex flex-col gap-3">'
    printf '<h2 class="font-headline-lg text-headline-lg font-bold text-error-red">What went wrong</h2>'
    [[ -z $message ]] || printf '<p class="font-body-md text-body-md text-on-surface">%s</p>' "$(escape_html "$message")"
    [[ -z $output ]] || log_panel "What the $failed_name step printed" "$output"
    printf '<p class="font-body-sm text-body-sm text-on-surface-variant">'
    printf 'Run %s. Whoever ran it can see its full logs with gnoto status %s.</p>' \
        "$(escape_html "$RUN_ID")" "$(escape_html "$RUN_ID")"
    printf '</div>'
}

status_pill() {
    local tone="text-secondary-fixed bg-secondary-fixed/10 border-secondary-fixed/20" dot="bg-secondary-fixed" pulse=1
    case ${1,,} in
        failed)
            tone="text-error-red bg-error-red/10 border-error-red/20" dot="bg-error-red" pulse=0 ;;
        cancelled)
            tone="text-warning-amber bg-warning-amber/10 border-warning-amber/20" dot="bg-warning-amber" pulse=0 ;;
        completed)
            tone="text-bio-growth bg-bio-growth/10 border-bio-growth/20" dot="bg-bio-growth" pulse=0 ;;
    esac
    printf '<span class="flex items-center gap-2 px-3 py-1.5 rounded-full border %s font-label-caps text-label-caps font-bold">' "$tone"
    printf '<span class="relative flex h-2 w-2">'
    (( pulse == 0 )) || printf '<span class="animate-ping absolute inline-flex h-full w-full rounded-full %s opacity-75"></span>' "$dot"
    printf '<span class="relative inline-flex rounded-full h-2 w-2 %s"></span></span>' "$dot"
    printf '%s</span>' "$(escape_html "$1")"
}

# True for a run that has stopped for good, whose page stops asking
run_ended() {
    [[ ${1,,} == failed || ${1,,} == cancelled || ${1,,} == completed ]]
}

# Writes a file into the results by rename, so a reader never sees half of one
write_result() {
    local tmp
    tmp=$(mktemp "$RESULTS_DIR/.$1.XXXXXX") || return 1
    if cat > "$tmp" && chmod 664 "$tmp" && mv -f "$tmp" "$RESULTS_DIR/$1"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

render_once() {
    local status title stage rows totals tasks_done=0 tasks_total=0 flying=0 percent=0 tasks
    local cluster="" timers="" failure="" elapsed="" cpu="" started counts running pending kind
    local page_state=live page_note footnote json

    if [[ -n $(state_get stages.present) ]]; then
        return 0
    fi
    [[ -r $PROGRESS_TEMPLATE ]] || { warn "There's no progress template at $PROGRESS_TEMPLATE."; return 1; }
    mkdir -p "$RESULTS_DIR" || return 1
    [[ -r $RESULTS_DIR/assets/gnoto.css ]] || dashboard_assets "$RESULTS_DIR" || warn "Couldn't copy the page's assets."

    status=$(get_run_status)
    status=${status:-Running}
    title=$(present_title)
    stage=$(state_get stage)
    if [[ -z $stage ]]; then
        case ${status,,} in
            submitted | queued) stage="Waiting for a slot to run in." ;;
            failed) stage="This run didn't finish." ;;
            cancelled) stage="This run was cancelled." ;;
            *) stage="Your analysis is running." ;;
        esac
    fi

    STOPPED=""
    run_ended "$status" && STOPPED=1
    if state_has steps; then
        rows=$(render_steps) || rows=""
    else
        rows=$(render_rows "$(nextflow_log_for nextflow.out)") || rows=""
    fi
    if [[ $rows == TOTALS\ * ]]; then
        totals=${rows%%$'\n'*}
        rows=${rows#*$'\n'}
        read -r _ tasks_done tasks_total flying <<< "$totals"
    fi
    [[ -n $rows ]] || rows="<p class=\"font-body-sm text-body-sm text-on-surface-variant\">$STARTING_MESSAGE</p>"
    tasks="Waiting for the first task"
    if (( tasks_total > 0 )); then
        percent=$((100 * tasks_done / tasks_total))
        tasks="$tasks_done of $tasks_total tasks"
    fi

    # The clocks, kept in the state while the run goes, so the page an ended
    # run is left showing still says how long it took
    kind=$(state_get scheduler.kind)
    if run_ended "$status"; then
        page_state=ended
        elapsed=$(state_get clocks.elapsed_seconds)
        cpu=$(state_get clocks.cpu_seconds)
    else
        started=$(state_get started_utc)
        if [[ -n $started ]] && started=$(date -u -d "$started" +%s 2> /dev/null); then
            elapsed=$(($(date -u +%s) - started))
            state_set_number clocks.elapsed_seconds "$elapsed" > /dev/null 2>&1 || :
        fi
        cpu=$(state_get clocks.cpu_seconds)
        # sacct through the helper is slow, and a minute is fine enough here.
        # Its window opens a few minutes before the job did.
        if [[ $kind == slurm && -n $elapsed && $(($(date +%s) - LAST_CPU)) -ge 60 ]]; then
            LAST_CPU=$(date +%s)
            if cpu=$(run_cpu_seconds "now-$((elapsed + 300))seconds") && [[ -n $cpu ]]; then
                state_set_number clocks.cpu_seconds "$cpu" > /dev/null 2>&1 || :
            else
                cpu=$(state_get clocks.cpu_seconds)
            fi
        fi
    fi
    timers=$(timers_widget "$elapsed" "$cpu")

    if [[ $kind == slurm ]]; then
        counts=""
        run_ended "$status" || counts=$(slurm_job_counts)
        read -r running pending <<< "${counts:-0 0}"
        cluster=$(cluster_widget "$running of this run's jobs are running, $pending waiting for a slot" \
            "$running" Running "$pending" Queued)
    else
        run_ended "$status" && flying=0
        cluster=$(cluster_widget "$flying of this run's tasks are running" "$flying" Running)
    fi

    case ${status,,} in
        failed)
            failure=$(failure_report) || failure=""
            page_note=""
            footnote="This run didn't finish, and this page has stopped updating. What went wrong is above."
            ;;
        cancelled)
            failure=$(failure_report) || failure=""
            page_note=""
            footnote="This run was cancelled, and this page has stopped updating."
            ;;
        *)
            page_note="This page follows the run, and becomes the results when it finishes."
            footnote="This page updates itself every $INTERVAL seconds, and is replaced by the results when the run finishes."
            ;;
    esac

    json=$(jq -n \
        --arg state "$page_state" \
        --arg status_pill "$(status_pill "$status")" \
        --arg stage "$(present_redact <<< "$stage")" \
        --arg page_note "$page_note" \
        --argjson percent "$percent" \
        --arg arc "$(dial_arc "$percent")" \
        --arg tasks "$tasks" \
        --arg cluster "$cluster" \
        --arg timers "$timers" \
        --arg rows "$rows" \
        --arg failure "$failure" \
        --arg footnote "$footnote" \
        --arg updated "$(date -u '+%b %-d, %Y at %H:%M UTC')" \
        '{$state, $status_pill, $stage, $page_note, $percent, $arc, $tasks,
          $cluster, $timers, $rows, $failure, $footnote, $updated}') || return 1

    printf '%s\n' "$json" | write_result "$STATE_FILE" || return 1
    render_template "$PROGRESS_TEMPLATE" \
        TASK_NAME "$(escape_html "$title")" \
        RUN_ID "$(escape_html "$RUN_ID")" \
        STATE_FILE "$STATE_FILE" \
        INTERVAL "$((INTERVAL * 1000))" \
        ARC "$(dial_arc 0)" \
        STARTING "$STARTING_MESSAGE" \
        STATE "${json//</\\u003c}" | write_result index.html
}

RUN_ID=$(present_run_id) || RUN_ID=${PWD##*/}
state_present || { warn "There's no run_state.json in $PWD, so there's no progress to show."; exit 0; }
LAST_CPU=0

if [[ -z $WATCH_PID ]]; then
    render_once && progress_publish || warn "Couldn't write the progress page."
    exit 0
fi

# A trapped signal cuts a wait short where it would sit out a sleep, so the
# sleep is waited on in the background, and a page being written when the
# signal comes lands first
SLEEP_PID=""
trap '[[ -z $SLEEP_PID ]] || kill "$SLEEP_PID" 2> /dev/null; exit 0' TERM INT HUP

SIGNALLED=""
LAST_RENDER=0
while kill -0 "$WATCH_PID" 2> /dev/null; do
    if [[ -z $SIGNALLED && -e cancel ]]; then
        log "Found the cancel file, so stopping process $WATCH_PID."
        set_run_stage "Cancelling the run."
        kill -TERM "$WATCH_PID" 2> /dev/null || warn "Couldn't signal process $WATCH_PID."
        SIGNALLED=1
        LAST_RENDER=0
    fi
    if (( $(date +%s) - LAST_RENDER >= INTERVAL )); then
        render_once && progress_publish || warn "Couldn't write the progress page, so it'll be tried again."
        LAST_RENDER=$(date +%s)
    fi
    sleep "$TICK" &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    SLEEP_PID=""
done
exit 0
