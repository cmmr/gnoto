#
# nodes.sh - Checks that Slurm's compute nodes can run gnoto's jobs, and keeps
# the list of nodes those jobs avoid: gnoto lint's check, the check before each
# job, and gnoto config slurm --probe.
#
# Sourced by:  lib/lint.sh
# Defines:     nodes_lint, nodes_prescan, nodes_probe, and the helpers below
# Requires:    lint_ok, lint_warn, lint_fail and lint_list from lib/lint.sh;
#              excluded_nodes, excluded_nodes_update, slurm_exclude_list,
#              no_node_left and scheduler_kind from lib/scheduler.sh; human_size
#              from lib/utilities.sh; sinfo, sbatch, squeue, scancel and ssh
#              through their stand-ins
# Env:         DATA_DIR, DB_DIR, SLURM_PARTITION, SLURM_ACCOUNT and
#              SLURM_MIN_TMP, from lib/env.sh
#
# A node fails the check when it can't see or write the data directory, see
# the database directory or use flock in the data directory, any of which
# fails every job Slurm puts there, or when its /tmp has less free than
# slurm.min_tmp, since tools inside a task write there. Over ssh, a node fails
# too when ssh can't reach it but reaches others. A node that fails goes on
# <data_dir>/excluded-nodes, which every job gnoto submits avoids, and one that
# passes comes off it.
#
# The three checks, from quickest to fullest:
#   before each job: over ssh, and nothing at all where ssh doesn't reach the
#     nodes
#   gnoto lint: over ssh, or where ssh doesn't reach them, a Slurm job on each
#     node with CPUs free now, so it never waits for one
#   gnoto config slurm --probe: a Slurm job on every node, waiting up to an
#     hour for busy ones
# Each covers the nodes Slurm is starting jobs on. A drained or down node would
# never run a check job.

NODES_BAD=()
NODES_OK=()
NODES_LINT_WAIT=60
NODES_PROBE_WAIT=3600

# The partition gnoto's jobs go to: slurm.partition, or Slurm's default
nodes_partition() {
    if [[ -n ${SLURM_PARTITION:-} ]]; then
        printf '%s' "$SLURM_PARTITION"
    else
        sinfo -h -o %P 2> /dev/null | sed -n 's/[*]$//p' | head -1 || :
    fi
}

# Fills NODE_NAMES and NODE_HOSTS with the partition's nodes that Slurm is
# starting jobs on, and NODES_SKIPPED with the others, as "<node> (<state>)"
nodes_load() {
    local node host state
    NODE_NAMES=()
    NODE_HOSTS=()
    NODES_SKIPPED=()
    while read -r node host state; do
        [[ -n $node ]] || continue
        case $state in
            idle | mixed | allocated | completing | planned | reserved) ;;
            *) NODES_SKIPPED+=("$node ($state)"); continue ;;
        esac
        NODE_NAMES+=("$node")
        NODE_HOSTS+=("${host:-$node}")
    done < <(sinfo -h -N -p "$1" -o '%N %n %T' 2> /dev/null | awk '!seen[$1]++')
}

# slurm.min_tmp in KB, or nothing when it's unset
nodes_min_tmp_kb() {
    [[ ${SLURM_MIN_TMP:-} =~ ^([0-9]+)\.(B|KB|MB|GB|TB)$ ]] || return 0
    awk -v n="${BASH_REMATCH[1]}" -v u="${BASH_REMATCH[2]}" 'BEGIN {
        f["B"] = 1 / 1024; f["KB"] = 1; f["MB"] = 1024; f["GB"] = 1048576; f["TB"] = 1073741824
        printf "%.0f", n * f[u]
    }'
}

# What a node runs for the check: sh with no single quote, ! or line break, so
# that over ssh it can go in single quotes to a csh login shell. Prints
# gnoto-lint-ok, or what failed: missing, unwritable or noflock and the
# directory, or lowtmp and the KB free in /tmp.
node_check_script() {
    local d=$DATA_DIR b=$DB_DIR min
    min=$(nodes_min_tmp_kb)
    printf 'test -d %s || { echo missing %s; exit 1; }; ' "$d" "$d"
    printf 'test -w %s || { echo unwritable %s; exit 1; }; ' "$d" "$d"
    printf 'test -d %s || { echo missing %s; exit 1; }; ' "$b" "$b"
    printf 'flock -w 10 %s/.lint.lock true || { echo noflock %s; exit 1; }; ' "$d" "$d"
    [[ -z $min ]] ||
        printf 'set -- $(df -Pk /tmp 2> /dev/null | tail -n 1); test "${4:-0}" -ge %s || { echo lowtmp ${4:-0}; exit 1; }; ' "$min"
    printf 'echo gnoto-lint-ok'
}

# What a node can't do, from the last line its check printed, with any line
# after the first saying more. Prints nothing for a node that passed, and
# returns 1 for a line that isn't a check's result.
node_finding() {
    case $1 in
        gnoto-lint-ok) ;;
        "missing /"*) printf "can't see %s" "${1#missing }" ;;
        "unwritable /"*) printf "can't write %s" "${1#unwritable }" ;;
        "noflock /"*)
            printf "can't use flock in %s\ngnoto's locks don't hold there. Lustre, for one, needs its flock mount option" \
                "${1#noflock }"
            ;;
        "lowtmp "*)
            [[ ${1#lowtmp } =~ ^[0-9]+$ ]] || return 1
            printf 'has %s free in /tmp, less than slurm.min_tmp, %s' \
                "$(human_size "$(( ${1#lowtmp } * 1024 ))")" "${SLURM_MIN_TMP:-}"
            ;;
        *) return 1 ;;
    esac
}

# Asks one node over ssh, never prompting, in 30 seconds at most. Prints the
# last line the check printed, or "ssh:" and why ssh couldn't ask it.
node_ssh_check() {
    local out status=0 last
    out=$(timeout 30 ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$1" "sh -c '$NODES_SCRIPT'" 2>&1) ||
        status=$?
    # ssh ends its own messages with a carriage return, which would garble the
    # line lint prints them in
    out=${out//$'\r'/}
    last=$(grep -v '^[[:space:]]*$' <<< "$out" | tail -1) || last=""
    if node_finding "$last" > /dev/null; then
        printf '%s\n' "$last"
    else
        case $status in
            124) echo "ssh: no answer in 30 seconds" ;;
            127) echo "ssh: there's no ssh command on this machine" ;;
            *) printf 'ssh: %s\n' "${last:-it failed with exit code $status}" ;;
        esac
    fi
}

# Asks nodes $1 to $2 - 1 of NODE_NAMES over ssh, 16 at a time, into
# NODE_RESULT
nodes_ssh_range() {
    local from=$1 to=$2 dir i pids=()
    dir=$(mktemp -d) || return 1
    for (( i = from; i < to; i++ )); do
        (( i - from < 16 )) || wait "${pids[i - from - 16]}" || :
        node_ssh_check "${NODE_HOSTS[i]}" > "$dir/$i" &
        pids+=("$!")
    done
    wait || :
    for (( i = from; i < to; i++ )); do
        NODE_RESULT[${NODE_NAMES[i]}]=$(cat "$dir/$i" 2> /dev/null || :)
    done
    rm -rf "$dir"
}

# Asks every node over ssh, into NODE_RESULT. Returns 1, having asked only the
# first 16, when ssh reaches none of them, with NODES_SSH_WHY saying why.
nodes_ssh_scan() {
    local n=${#NODE_NAMES[@]} first i
    declare -gA NODE_RESULT=()
    NODES_SSH_WHY="no node to ask"
    (( n > 0 )) || return 1
    first=$(( n < 16 ? n : 16 ))
    if ! nodes_ssh_range 0 "$first"; then
        NODES_SSH_WHY="no scratch directory for its answers"
        return 1
    fi
    for (( i = 0; i < first; i++ )); do
        if [[ ${NODE_RESULT[${NODE_NAMES[i]}]:-} != "ssh: "* ]]; then
            nodes_ssh_range "$first" "$n" || :
            return 0
        fi
    done
    NODES_SSH_WHY=${NODE_RESULT[${NODE_NAMES[0]}]:-}
    NODES_SSH_WHY=${NODES_SSH_WHY#ssh: }
    return 1
}

# A node that failed a check: puts it on the list, and says so. The finding is
# what the node can't do, and any line after the first says more:
# node_bad <node> <finding>
node_bad() {
    local node=$1 found=${2%%$'\n'*} more=""
    [[ $2 != *$'\n'* ]] || more=". ${2#*$'\n'}"
    NODES_BAD+=("$node")
    if printf '+%s\t%s\n' "$node" "${NODES_BY:-a check} found it $found" | excluded_nodes_update 2> /dev/null; then
        lint_warn "compute node $node: $found$more. gnoto's jobs avoid it until a check finds it working"
    else
        lint_fail "compute node $node: $found$more. gnoto couldn't add it to $DATA_DIR/excluded-nodes, so jobs Slurm puts there will fail"
    fi
}

# Reports an ssh scan, puts each node that failed on the list, and leaves the
# nodes that passed in NODES_OK. ssh reached at least one node, so one it
# couldn't reach fails too: a node the others' ssh doesn't reach is broken in
# some way. With NODES_BRIEF set, it counts the nodes that passed rather than
# naming them.
nodes_ssh_report() {
    local node result finding why
    NODES_OK=()
    for node in "${NODE_NAMES[@]}"; do
        result=${NODE_RESULT[$node]:-}
        if [[ $result == gnoto-lint-ok ]]; then
            NODES_OK+=("$node")
        elif finding=$(node_finding "$result"); then
            node_bad "$node" "$finding"
        else
            why=${result#ssh: }
            why=${why%.}
            node_bad "$node" "couldn't be reached over ssh, which reaches the other nodes (${why:-no answer})"
        fi
    done
    if (( ${#NODES_OK[@]} == 0 )); then
        :
    elif [[ -n ${NODES_BRIEF:-} ]]; then
        if (( ${#NODES_OK[@]} == 1 )); then
            lint_ok "compute nodes: the one that ssh reached can run gnoto's jobs"
        else
            lint_ok "compute nodes: the ${#NODES_OK[@]} that ssh reached can run gnoto's jobs"
        fi
    else
        lint_ok "compute nodes: $(lint_list "${NODES_OK[@]}") can run gnoto's jobs: they see $DATA_DIR and $DB_DIR, flock works there$(nodes_tmp_clause)"
    fi
}

# ", and /tmp has <slurm.min_tmp> free", when that's checked
nodes_tmp_clause() {
    [[ -z $(nodes_min_tmp_kb) ]] || printf ', and /tmp has %s free' "$SLURM_MIN_TMP"
}

# The partition's nodes with a CPU and 200 MB free now, by sinfo's counts, one
# per line
nodes_free() {
    sinfo -h -N -p "$1" -O 'NodeList:200,CPUsState:40,Memory:20,AllocMem:20,StateLong:40' 2> /dev/null |
        awk '{ split($2, cpus, "/") }
            ($5 == "idle" || $5 == "mixed") && cpus[2] > 0 && $3 - $4 >= 200 && !seen[$1]++ { print $1 }'
}

# "a minute", "an hour" or "<n> minutes", for a number of seconds
nodes_duration() {
    case $(( $1 / 60 )) in
        1) echo "a minute" ;;
        60) echo "an hour" ;;
        *) echo "$(( $1 / 60 )) minutes" ;;
    esac
}

# On an interrupt while check jobs are out: cancels them and removes their
# directory
nodes_job_abort() {
    scancel --name="$NODES_CHECK_NAME" --user="$(id -un)" 2> /dev/null || :
    rm -rf "$NODES_CHECK_DIR"
    exit 130
}

# Checks nodes with a small Slurm job pinned to each, waiting up to $1 seconds
# for them all, and with "progress", saying each minute which it's waiting
# for. Puts each node that failed on the list, and leaves the nodes that
# passed in NODES_OK: nodes_job_check <seconds> [progress] -- <node>...
#
# A node missing a mount fails each job there before its script runs, leaving
# no log, so a job that failed with no log is a node that failed. A log is
# looked for only once its job has ended, and again a moment later, since a
# directory's listing can lag on this machine.
nodes_job_check() {
    local limit=$1 progress="" dir name node id state states last finding waited=0
    local args=() pids=() pending=() late=() unchecked=() nolog=()
    local -A ids=() ended=()
    shift
    [[ ${1:-} != progress ]] || { progress=1; shift; }
    [[ ${1:-} != -- ]] || shift
    NODES_OK=()
    if ! dir=$(mktemp -d "$DATA_DIR/.node-check.XXXXXX"); then
        lint_warn "compute nodes: can't make a directory in $DATA_DIR to check them from"
        return 0
    fi
    name=gnoto-check-${dir##*.}
    NODES_CHECK_DIR=$dir
    NODES_CHECK_NAME=$name
    trap nodes_job_abort INT TERM

    for node in "$@"; do
        if (( ${#pids[@]} >= 16 )); then
            wait "${pids[0]}" || :
            pids=("${pids[@]:1}")
        fi
        args=(--parsable --job-name="$name" --time=00:02:00 --mem=100M --cpus-per-task=1
            --partition="$NODES_PARTITION" --nodelist="$node" --output="$dir/$node.out")
        [[ -z ${SLURM_ACCOUNT:-} ]] || args+=(--account="$SLURM_ACCOUNT")
        sbatch "${args[@]}" --wrap "$NODES_SCRIPT" < /dev/null > "$dir/$node.id" 2>&1 &
        pids+=("$!")
    done
    wait || :
    for node in "$@"; do
        id=$(head -1 "$dir/$node.id" 2> /dev/null || :)
        id=${id%%;*}
        if [[ $id =~ ^[0-9]+$ ]]; then
            ids[$node]=$id
        else
            lint_fail "compute node $node: sbatch refused its check job: $(tail -1 "$dir/$node.id" 2> /dev/null || :)"
        fi
    done

    while (( ${#ids[@]} > ${#ended[@]} )); do
        if states=$(squeue -h -t all --name="$name" -o '%i %T' 2> /dev/null); then
            for node in "${!ids[@]}"; do
                [[ -z ${ended[$node]:-} ]] || continue
                state=$(awk -v id="${ids[$node]}" '$1 == id { print $2; exit }' <<< "$states")
                case $state in
                    PENDING | CONFIGURING | RUNNING | COMPLETING | SUSPENDED | RESIZING | REQUEUE*) ;;
                    *) ended[$node]=${state:-GONE} ;;
                esac
            done
        fi
        (( ${#ids[@]} > ${#ended[@]} && waited < limit )) || break
        if [[ -n $progress ]] && (( waited > 0 && waited % 60 == 0 )); then
            pending=()
            for node in "$@"; do
                [[ -z ${ids[$node]:-} || -n ${ended[$node]:-} ]] || pending+=("$node")
            done
            printf '        Still waiting for %s to free up, %d of up to %d minutes so far\n' \
                "$(lint_list "${pending[@]}")" $(( waited / 60 )) $(( limit / 60 )) >&2
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done

    for node in "$@"; do
        [[ -n ${ids[$node]:-} && -z ${ended[$node]:-} ]] || continue
        scancel "${ids[$node]}" 2> /dev/null || :
        late+=("$node")
    done
    for node in "$@"; do
        [[ -n ${ended[$node]:-} && ! -e $dir/$node.out ]] || continue
        nolog+=("$node")
    done
    (( ${#nolog[@]} == 0 )) || sleep 3
    for node in "$@"; do
        [[ -n ${ended[$node]:-} ]] || continue
        state=${ended[$node]}
        last=$(grep -v '^[[:space:]]*$' "$dir/$node.out" 2> /dev/null | tail -1 || :)
        if [[ $last == gnoto-lint-ok ]]; then
            NODES_OK+=("$node")
        elif [[ $state != FAILED && $state != COMPLETED && $state != GONE ]]; then
            unchecked+=("$node ($state)")
        elif [[ ! -e $dir/$node.out ]]; then
            node_bad "$node" "couldn't write a job's log in $DATA_DIR"$'\n'"$node probably can't reach it"
        elif finding=$(node_finding "$last"); then
            node_bad "$node" "$finding"
        else
            node_bad "$node" "couldn't run its check job"$'\n'"$(tail -3 "$dir/$node.out" 2> /dev/null || :)"
        fi
    done
    trap - INT TERM
    rm -rf "$dir"

    (( ${#NODES_OK[@]} == 0 )) ||
        lint_ok "compute nodes: $(lint_list "${NODES_OK[@]}") can run gnoto's jobs: they see $DATA_DIR and $DB_DIR, flock works there$(nodes_tmp_clause), by a Slurm job on each"
    (( ${#unchecked[@]} == 0 )) ||
        lint_warn "compute nodes: not checked, as their check jobs ended without running: $(lint_list "${unchecked[@]}")"
    (( ${#late[@]} == 0 )) ||
        lint_warn "compute nodes: not checked, as their check jobs hadn't run after $(nodes_duration "$limit"), so they were cancelled: $(lint_list "${late[@]}")"
}

# After a check: takes the nodes that passed, and any Slurm no longer has, off
# the list, and reports the ones still on it. With NODES_BRIEF set, those go
# on one line: nodes_done [node that passed]...
nodes_done() {
    local node since why known listed now changes="" still=()
    listed=$(excluded_nodes | cut -f1)
    known=$(sinfo -h -N -o %N 2> /dev/null | sort -u) || known=""
    for node in "$@"; do
        changes+="-$node"$'\n'
    done
    while IFS= read -r node; do
        [[ -n $node && -n $known ]] || continue
        grep -qxF -- "$node" <<< "$known" || changes+="-$node"$'\n'
    done <<< "$listed"
    if ! printf '%s' "$changes" | excluded_nodes_update 2> /dev/null; then
        lint_warn "compute nodes: couldn't update $DATA_DIR/excluded-nodes, the list of nodes gnoto's jobs avoid"
        return 0
    fi
    now=$(excluded_nodes | cut -f1)
    while IFS= read -r node; do
        [[ -n $node ]] || continue
        if [[ " $* " == *" $node "* ]]; then
            lint_ok "compute node $node: works now, so gnoto's jobs use it again"
        elif ! grep -qxF -- "$node" <<< "$now"; then
            lint_ok "compute node $node: Slurm no longer has it, so gnoto's jobs no longer avoid it"
        fi
    done <<< "$listed"
    while IFS=$'\t' read -r node since why; do
        [[ -n $node && " ${NODES_BAD[*]} " != *" $node "* ]] || continue
        if [[ -n ${NODES_BRIEF:-} ]]; then
            still+=("$node")
        else
            lint_warn "compute node $node: not checked this time, so gnoto's jobs still avoid it. On $since, $why"
        fi
    done < <(excluded_nodes)
    (( ${#still[@]} == 0 )) ||
        lint_ok "compute nodes: gnoto's jobs still avoid $(lint_list "${still[@]}"), which weren't checked this time"
    slurm_exclude_list > /dev/null || lint_fail "compute nodes: $(no_node_left)"
}

# Loads the partition's nodes and the check's script, and reports the nodes
# that won't be checked. Returns 1 when none will be.
nodes_begin() {
    NODES_OK=()
    nodes_load "$NODES_PARTITION"
    if [[ -z ${NODES_BRIEF:-} ]] && (( ${#NODES_SKIPPED[@]} > 0 )); then
        lint_ok "compute nodes: not checked, as Slurm isn't starting jobs there: $(lint_list "${NODES_SKIPPED[@]}")"
    fi
    if [[ ! $DATA_DIR$DB_DIR =~ ^[A-Za-z0-9_./-]+$ ]]; then
        [[ -n ${NODES_BRIEF:-} ]] ||
            lint_warn "compute nodes: not checked, as $DATA_DIR or $DB_DIR holds a character the check can't pass"
        return 1
    fi
    if (( ${#NODE_NAMES[@]} == 0 )); then
        [[ -n ${NODES_BRIEF:-} ]] ||
            lint_warn "compute nodes: sinfo lists none taking jobs in partition $NODES_PARTITION, so none was checked"
        nodes_done
        return 1
    fi
    NODES_SCRIPT=$(node_check_script)
}

# gnoto lint's check: over ssh, or where ssh reaches no node, a Slurm job on
# each node with CPUs free now
nodes_lint() {
    local free=() busy=() node
    [[ $(scheduler_kind) == slurm && ${LINT_SLURM_OK:-} == true ]] || return 0
    NODES_PARTITION=$LINT_PARTITION
    NODES_BY="gnoto lint"
    nodes_begin || return 0
    if nodes_ssh_scan; then
        nodes_ssh_report
    else
        lint_ok "compute nodes: ssh doesn't reach them from here ($NODES_SSH_WHY), so Slurm jobs check the nodes with CPUs free instead"
        mapfile -t free < <(nodes_free "$NODES_PARTITION")
        for node in "${NODE_NAMES[@]}"; do
            [[ " ${free[*]} " == *" $node "* ]] || busy+=("$node")
        done
        (( ${#free[@]} == 0 )) || nodes_job_check "$NODES_LINT_WAIT" -- "${free[@]}"
        (( ${#busy[@]} == 0 )) ||
            lint_warn "compute nodes: not checked, as they have no CPU free now: $(lint_list "${busy[@]}"). $(gnoto_command config slurm --probe) checks every node, waiting for busy ones"
    fi
    nodes_done ${NODES_OK[@]+"${NODES_OK[@]}"}
}

# The check before each job: over ssh, and nothing at all where ssh reaches no
# node. A node that fails goes on the list before the job is submitted.
nodes_prescan() {
    [[ $(scheduler_kind) == slurm ]] || return 0
    NODES_PARTITION=$(nodes_partition)
    [[ -n $NODES_PARTITION ]] || return 0
    NODES_BY="the check before a job"
    NODES_BRIEF=1
    if nodes_begin && nodes_ssh_scan; then
        nodes_ssh_report
        nodes_done ${NODES_OK[@]+"${NODES_OK[@]}"}
    fi
    NODES_BRIEF=""
}

# gnoto config slurm --probe: a Slurm job on every node the partition is
# starting jobs on, waiting up to an hour for busy ones
nodes_probe() {
    [[ $(scheduler_kind) == slurm ]] ||
        fail "Slurm is off in gnoto, so there are no nodes to probe. To turn it on: $(gnoto_command config slurm --on)"
    NODES_PARTITION=$(nodes_partition)
    [[ -n $NODES_PARTITION ]] ||
        fail "sinfo didn't answer, or names no default partition, so no node was probed."
    NODES_BY="gnoto config slurm --probe"
    if nodes_begin; then
        if (( ${#NODE_NAMES[@]} == 1 )); then
            echo "Probing the one node taking jobs in partition $NODES_PARTITION, with a Slurm job. If it's busy, it's waited for, for up to $(nodes_duration "$NODES_PROBE_WAIT")." >&2
        else
            echo "Probing the ${#NODE_NAMES[@]} nodes taking jobs in partition $NODES_PARTITION, with a Slurm job on each. Busy nodes are waited for, for up to $(nodes_duration "$NODES_PROBE_WAIT")." >&2
        fi
        nodes_job_check "$NODES_PROBE_WAIT" progress -- "${NODE_NAMES[@]}"
        nodes_done ${NODES_OK[@]+"${NODES_OK[@]}"}
    fi
    if (( LINT_FAILS > 0 )); then
        echo "$LINT_FAILS failed, $LINT_WARNS warned."
        return 1
    elif (( LINT_WARNS > 0 )); then
        echo "Passed, with $LINT_WARNS warned."
    else
        echo "Passed."
    fi
}
