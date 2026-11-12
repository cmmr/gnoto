#
# lint.sh - gnoto lint: checks a job file, or with none, this install's
# settings and what they point at.
#
# Sourced by:  lib/main.sh, for lint, run, start, wrike and the units'
#              commands; lib/config.sh, for the integrations' steps and gnoto
#              config slurm --probe
# Defines:     lint_main, lint_config, lint_ok, lint_warn, lint_fail,
#              lint_list, LINT_FAILS, LINT_WARNS
# Requires:    the settings and helpers from lib/env.sh, args_parse from
#              lib/args.sh, job_check from lib/jobfile.sh, and databases_offer
#              from lib/databases.sh; sinfo through its stand-in, with Slurm;
#              lib/nodes.sh, and the integrations' checks in
#              service/wrike/config.sh, service/aws/config.sh,
#              service/globus.sh and service/systemd/systemd.sh, which it
#              sources
#
# Each check prints OK, WARN or FAIL, and any FAIL gives a non-zero exit code.

LINT_FAILS=0
LINT_WARNS=0

source "$CODE_DIR/lib/nodes.sh"
source "$CODE_DIR/service/wrike/config.sh"
source "$CODE_DIR/service/aws/config.sh"
source "$CODE_DIR/service/globus.sh"
source "$CODE_DIR/service/systemd/systemd.sh"

# One check's result. A message over several lines is indented under the first.
lint_line() {
    local label=$1
    shift
    printf '  %-5s %s\n' "$label" "$*" | sed '2,$s/^/        /'
}

lint_ok() {
    lint_line OK "$@"
}

lint_warn() {
    lint_line WARN "$@"
    LINT_WARNS=$((LINT_WARNS + 1))
}

lint_fail() {
    lint_line FAIL "$@"
    LINT_FAILS=$((LINT_FAILS + 1))
}

# A Nextflow duration such as 48.h, 30.m or 2.d, or Slurm's time, such as
# 7-00:00:00 or UNLIMITED, in whole hours. Prints nothing when it can't tell.
lint_hours() {
    local value=$1
    case $value in
        UNLIMITED | INFINITE | unlimited | infinite) echo 1000000 ;;
        *.d) awk -v n="${value%.d}" 'BEGIN { printf "%d", n * 24 }' ;;
        *.h) awk -v n="${value%.h}" 'BEGIN { printf "%d", n }' ;;
        *.m) awk -v n="${value%.m}" 'BEGIN { printf "%d", n / 60 }' ;;
        [0-9]*) slurm_hours "$value" ;;
    esac
}

# Every task request in pipelines/<pipeline>/resources.config and a workflow's
# own nextflow.config set as a plain value rather than one that grows with each
# attempt, as "<pipeline or workflow>\t<process>\t<key>\t<value>\t<fixed>",
# where fixed is 1 for a line marked "// fixed": a CPU count the results
# depend on
fixed_requests() {
    awk '
        FNR == 1 {
            name = FILENAME
            sub(/\/(resources|nextflow)\.config$/, "", name)
            sub(/.*\//, "", name)
        }
        /withName:/ { process = $0; sub(/.*withName: *./, "", process); sub(/. *\{.*/, "", process) }
        /^ *(cpus|time|memory) *= *[0-9]/ {
            key = $1
            value = $0
            sub(/^[^=]*= */, "", value)
            fixed = (value ~ /\/\/ *fixed/) ? 1 : 0
            sub(/ *\/\/.*/, "", value)
            print name "\t" process "\t" key "\t" value "\t" fixed
        }
    ' "$CODE_DIR"/pipelines/*/resources.config "$CODE_DIR"/workflows/*/nextflow.config | sort -u
}

# Every setting in a YAML file, as section.key lines
yaml_keys() {
    yq -o=json . "$1" 2> /dev/null | jq -r '(. // {}) | to_entries[]
        | if (.value | type) == "object" then .key as $s | .value | keys[] | "\($s).\(.)" else .key end'
}

lint_config_file() {
    local config=$INSTALL_DIR/config.yaml file mode group key section setting yq_value boot_value
    local generated=$DATA_DIR/generated.yaml

    if [[ ! -e $config ]]; then
        lint_ok "config.yaml: none, so every setting is at its default. $(gnoto_command config) lists the sections"
        return
    fi
    lint_ok "config.yaml: valid YAML"

    for file in "$config" "$generated"; do
        [[ -e $file ]] || continue
        mode=$(stat -c %a "$file")
        group=""
        [[ -z $(mapped_gid "$file") ]] || group=", group $(stat -c %G "$file"), whose members can use its tokens and keys"
        if [[ $mode != 660 ]]; then
            lint_fail "$file: is mode $mode. Make it 660, so only its group can read the secrets in it: chmod 660 $file"
        else
            lint_ok "${file##*/}: mode 660$group"
        fi
    done
    if git -c safe.directory='*' -C "$INSTALL_DIR" ls-files --error-unmatch config.yaml > /dev/null 2>&1; then
        lint_fail "config.yaml: is tracked by git, which would publish its secrets. Run: git rm --cached config.yaml"
    fi

    # Keys this version doesn't know, which are likely typos
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        section=${key%%.*}
        if [[ $key != *.* ]]; then
            lint_warn "config.yaml: $key: should be a section, such as core:"
        elif [[ -z ${CONFIG_ABOUT[$section]+set} ]]; then
            lint_warn "config.yaml: there's no section $section. $(gnoto_command config) lists them"
        elif [[ " ${CONFIG_KEYS[$section]} " != *" ${key#*.} "* ]]; then
            lint_warn "config.yaml: $key isn't a setting gnoto knows, so it's ignored. Is it a typo?"
        fi
    done < <(yaml_keys "$config")

    # The launcher reads eight settings with its own awk, before it can start
    # the image that holds yq. Both must read them the same way.
    for setting in core.data_dir core.db_dir apptainer.enabled apptainer.bin_dir apptainer.binds \
        slurm.enabled slurm.bin_dir slurm.conf; do
        yq_value=$(SECTION=${setting%%.*} KEY=${setting#*.} \
            yq '.[strenv(SECTION)][strenv(KEY)] // "" | tostring' "$config" 2> /dev/null) || yq_value=""
        boot_value=$(sed -n "s/^${setting//./\\.}=//p" <<< "${GNOTO_BOOTSTRAP:-}")
        if [[ $yq_value != "$boot_value" ]]; then
            lint_fail "config.yaml: the launcher reads $setting as \"$boot_value\", and yq as \"$yq_value\". Write it as   ${setting#*.}: \"value\"   or true or false"
        fi
    done
}

# A file's group ID, or nothing when the image's user namespace doesn't map the
# group, as an unprivileged Apptainer does for every group but the user's own:
# such a group shows as nobody, and can't be compared
mapped_gid() {
    local gid
    gid=$(stat -c %g "$1" 2> /dev/null) || return 0
    [[ $gid == 65534 ]] || printf '%s' "$gid"
}

lint_directories() {
    local dir name probe ours theirs
    ours=$(mapped_gid "$INSTALL_DIR/config.yaml")
    [[ -e $INSTALL_DIR/config.yaml ]] || ours=$(mapped_gid "$INSTALL_DIR")
    for name in DATA_DIR DB_DIR ${GLOBUS_ENABLED:+GLOBUS_DIR}; do
        [[ $name != GLOBUS_DIR || ${GLOBUS_ENABLED:-} == true ]] || continue
        dir=${!name}
        [[ -n $dir ]] || continue
        if probe=$(mktemp "$dir/.lint.XXXXXX" 2> /dev/null); then
            rm -f "$probe"
            theirs=$(mapped_gid "$dir")
            if [[ -n $ours && -n $theirs && $ours != "$theirs" ]]; then
                lint_warn "$dir: its group is $(stat -c %G "$dir"), not gnoto's. Run: chgrp -R $(stat -c %G "$INSTALL_DIR/config.yaml" 2> /dev/null || stat -c %G "$INSTALL_DIR") $dir"
            else
                lint_ok "$dir: writable"
            fi
        else
            lint_fail "$dir: can't write in it"
        fi
    done
    if (exec 9>> "$DATA_DIR/.lint.lock" && flock -w 5 9) 2> /dev/null; then
        lint_ok "flock: works in $DATA_DIR here"
    else
        lint_fail "flock: doesn't work in $DATA_DIR. Some filesystems, such as Lustre, need their flock mount option"
    fi
}

lint_engine() {
    local version
    if version=$(apptainer --version 2> /dev/null); then
        lint_ok "apptainer: $version"
    else
        lint_fail "apptainer: doesn't answer"
    fi
    [[ ! -e $NXF_HOME/config ]] ||
        lint_fail "$NXF_HOME/config: Nextflow loads it into every run, where it could change results. Delete it, and put any site setting in core.nextflow_config"
}

lint_nextflow_config() {
    local dir flat risky
    [[ -n ${NEXTFLOW_CONFIG:-} ]] || return 0
    if [[ ! -r $NEXTFLOW_CONFIG ]]; then
        lint_fail "core.nextflow_config: can't read $NEXTFLOW_CONFIG"
        return
    fi
    dir=$(mktemp -d "${TMPDIR:-/tmp}/gnoto-lint.XXXXXX")
    if ! flat=$(cd "$dir" && nextflow -q -c "$NEXTFLOW_CONFIG" config -flat 2>&1); then
        lint_fail "core.nextflow_config: Nextflow can't read it: $(tail -1 <<< "$flat")"
        rm -rf "$dir"
        return
    fi
    rm -rf "$dir"
    risky=$(grep -oE "^[^ ]+" <<< "$flat" | grep -E \
        '^params\.|(^|\.)container$|(^|\.)ext\.|^env\.|(^|\.)cpus$|(^|\.)beforeScript$|(^|\.)containerOptions$|^(apptainer|singularity|docker)\.runOptions$' |
        sort -u | paste -sd ' ')
    if [[ -n $risky ]]; then
        lint_warn "core.nextflow_config: sets $risky, which could change results"
    else
        lint_ok "core.nextflow_config: sets nothing that changes results"
    fi
}

# Slurm's own checks, when it's on, and a note when it's here but off
lint_scheduler() {
    local partitions partition time_limit hours limit line file process key value fixed
    if [[ $(scheduler_kind) != slurm ]]; then
        if [[ -n ${GNOTO_FOUND_SLURM_BIN_DIR:-} ]]; then
            lint_warn "slurm: is on this machine but off in gnoto, so jobs run here. To use it: $(gnoto_command config slurm --on)"
        else
            lint_ok "jobs: run on this machine"
        fi
        return
    fi
    if ! partitions=$(sinfo -h -o '%P %l' 2>&1); then
        lint_fail "slurm: sinfo doesn't answer: $(head -1 <<< "$partitions")
Slurm's module may not be loaded in the shell gnoto started from. Load it, or set slurm.bin_dir and slurm.conf ($(gnoto_command config slurm))"
        return
    fi
    lint_ok "slurm: sinfo answers"
    partition=${SLURM_PARTITION:-$(awk '$1 ~ /\*$/ { sub(/\*$/, "", $1); print $1; exit }' <<< "$partitions")}
    LINT_SLURM_OK=true
    LINT_PARTITION=$partition
    time_limit=$(awk -v p="$partition" '{ name = $1; sub(/\*$/, "", name) } name == p { print $2; exit }' <<< "$partitions")
    if [[ -z $time_limit ]]; then
        lint_fail "slurm.partition: there's no partition \"$partition\". sinfo lists $(awk '{ print $1 }' <<< "$partitions" | paste -sd ' ')"
        return
    fi
    if [[ -n ${SLURM_JOB_TIME:-} ]]; then
        hours=$(slurm_time "$SLURM_JOB_TIME") && hours=$(lint_hours "$hours") || hours=""
        limit=$(lint_hours "$time_limit")
        if [[ -z $hours ]]; then
            lint_fail "slurm.job_time: \"$SLURM_JOB_TIME\" isn't a time sbatch takes. Write it as Slurm does, such as 2-00:00:00, or as 48.h"
        elif [[ -n $limit ]] && (( hours > limit )); then
            lint_fail "slurm.job_time: $SLURM_JOB_TIME is longer than partition $partition allows, $time_limit"
        else
            lint_ok "slurm.job_time: $SLURM_JOB_TIME, within partition $partition's $time_limit"
        fi
    fi
    for key in max_cpus max_memory max_time; do
        line=SLURM_${key^^}
        [[ -n ${!line:-} ]] ||
            lint_warn "slurm.$key: isn't set, so a task that asks for more than a node has never runs. $(gnoto_command config slurm) suggests one"
    done
    [[ -z ${SLURM_MAX_MEMORY:-} || $SLURM_MAX_MEMORY =~ ^[0-9]+\.(B|KB|MB|GB|TB)$ ]] ||
        lint_fail "slurm.max_memory: write it as Nextflow does, such as 900.GB"
    [[ -z ${SLURM_MAX_TIME:-} || $SLURM_MAX_TIME =~ ^[0-9]+\.(s|m|h|d)$ ]] ||
        lint_fail "slurm.max_time: write it as Nextflow does, such as 168.h"
    [[ -z ${SLURM_MIN_TMP:-} || $SLURM_MIN_TMP =~ ^[0-9]+\.(B|KB|MB|GB|TB)$ ]] ||
        lint_fail "slurm.min_tmp: write it as Nextflow does, such as 50.GB, or none to skip the check"

    # A task whose plain request the limits cut short
    limit=$(lint_hours "${SLURM_MAX_TIME:-}")
    while IFS=$'\t' read -r file process key value fixed; do
        case $key in
            time)
                hours=$(lint_hours "$value")
                if [[ -n $limit && -n $hours ]] && (( hours > limit )); then
                    lint_warn "slurm.max_time: $SLURM_MAX_TIME cuts $file's $process short, which asks for $value"
                fi
                ;;
            cpus)
                if [[ $fixed == 1 && -n ${SLURM_MAX_CPUS:-} ]] && (( value > SLURM_MAX_CPUS )); then
                    lint_fail "slurm.max_cpus: $SLURM_MAX_CPUS is below the $value CPUs $file's $process needs for its results to match other sites'"
                fi
                ;;
        esac
    done < <(fixed_requests)
}

# Words joined by commas
lint_list() {
    local IFS=,
    printf '%s' "$*" | sed 's/,/, /g'
}

# What the integrations' own checks will cover, for now only whether each is on
# The integrations' own checks, each in service/, for the sections that are
# on. Those that aren't say so.
lint_integrations() {
    local section name
    for section in wrike aws globus; do
        name=${section^^}_ENABLED
        [[ ${!name:-false} == true ]] || lint_ok "$section: off"
    done
    lint_wrike
    lint_s3
    lint_sqs
    lint_globus
    lint_systemd
}

# Which version this is, and which is current
lint_version() {
    local current
    code_version
    current=$(current_commit)
    if [[ $CODE_DEV == true ]]; then
        lint_ok "version: this install's own files, under --dev"
    elif [[ $CODE_COMMIT == "$current" ]]; then
        lint_ok "version: $CODE_COMMIT, the current one, from $CODE_REPOSITORY"
    else
        lint_ok "version: $CODE_COMMIT, and the current one is ${current:-not set}"
    fi
}

lint_config() {
    lint_version
    lint_config_file
    lint_engine
    lint_directories
    lint_scheduler
    nodes_lint
    lint_nextflow_config
    lint_integrations
}

# gnoto lint [--dev] [--deep] [--yes] [job.yaml], or gnoto lint [--deep]
# [--yes] --inputs=<dir> record.yaml. --deep checks each database by its tree
# digest, rather than by its size. --yes accepts fetching missing databases.
# --dev, which the launcher acts on, checks with the install's own files.
lint_main() {
    local usage="Usage: gnoto lint [--dev] [--deep] [--yes] [job.yaml], or gnoto lint [--deep] [--yes] --inputs=<dir> record.yaml"
    local yes=false file="" i

    args_parse "$usage" "dev deep yes" "$@"
    JOB_INPUTS_DIR=""
    for (( i = 0; i < ${#ARG_KEYS[@]}; i++ )); do
        [[ ${ARG_KEYS[i]} == inputs ]] ||
            fail "gnoto lint takes --dev, --deep, --yes and --inputs, not --${ARG_KEYS[i]}. $usage"
        JOB_INPUTS_DIR=${ARG_VALUES[i]}
    done
    [[ ${#ARG_WORDS[@]} -le 1 ]] || fail "$usage"
    [[ -z ${ARG_FLAGS[yes]:-} ]] || yes=true
    LINT_DEEP=false
    [[ -z ${ARG_FLAGS[deep]:-} ]] || LINT_DEEP=true
    file=${ARG_WORDS[0]:-}
    [[ -n $file || $LINT_DEEP == false ]] || fail "--deep checks a job's databases, so it needs a job file. $usage"
    if [[ -z $file ]]; then
        lint_config
    else
        job_check "$file"
        # Missing databases are the one failure lint can fix, by fetching them
        if (( LINT_FAILS > 0 && LINT_FAILS == ${JOB_MISSING_DATABASES:-0} )) &&
            [[ $yes == true || -t 0 ]]; then
            databases_offer "$yes" > /dev/null || return 1
            echo "Once the fetches finish, $(gnoto_command run "$file") starts this job. Started now, it waits for them."
            return 1
        fi
    fi
    if (( LINT_FAILS > 0 )); then
        echo "$LINT_FAILS failed, $LINT_WARNS warned."
        return 1
    fi
    if (( LINT_WARNS > 0 )); then
        echo "Passed, with $LINT_WARNS warned."
    else
        echo "Passed."
    fi
}
