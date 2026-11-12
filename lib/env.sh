#
# env.sh - Loads gnoto's settings and helpers into a script.
#
# Sourced by:  every gnoto script that runs in the image, as
#              source "<code>/lib/env.sh"
# Requires:    yq and jq, from the image
# Env:         GNOTO_INSTALL_DIR, from the launcher, names where config.yaml is.
#              Without it, the install directory is the code's own.
#
# Reads config.yaml in the install directory, if there is one, then
# generated.yaml in the data directory. Each setting becomes a shell variable:
# core.data_dir is DATA_DIR, and slurm.max_cpus is SLURM_MAX_CPUS. A nested key
# joins with underscores, so wrike.statuses.running is WRIKE_STATUSES_RUNNING.
# config.yaml wins over generated.yaml. lib/config/<section>.sh declares each
# section's settings and defaults, and config.yaml's other keys are ignored.
# Without config.yaml, everything is at its default: the data directory is
# <install>/data, and jobs run locally.
#
# A section other than core is on only when its enabled is true, as
# SLURM_ENABLED and the like say. Apptainer's is true by default. Code that uses
# a section checks that first.
#
# The settings are exported, except secrets, which no child process or container
# should see. generated.yaml's are set but not exported.
#
# Besides lib/'s helpers, it loads the integrations' that a job and its
# followup use: Wrike's calls and tasks from service/wrike/, the AWS calls from
# service/aws/aws.sh, and Publish from service/publish.sh.
#
# Safe to source more than once. A child process sources it again, because
# functions don't pass to it.

CODE_DIR=$(cd -P -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)
INSTALL_DIR=${GNOTO_INSTALL_DIR:-$CODE_DIR}
export CODE_DIR INSTALL_DIR

umask 002

# Prints "<variable>\t<value>" for each scalar in a YAML file, or fails with
# yq's message, which gives the line. core's keys keep their own names.
gnoto_settings() {
    local json
    json=$(yq -o=json . "$1") || return 1
    jq -r '
        (. // {}) | to_entries[]
        | select(.value | type == "object")
        | .key as $section
        | .value | paths(scalars) as $path
        | getpath($path) as $value
        | (if $section == "core" then [] else [$section] end) + ($path | map(tostring))
        | join("_") | ascii_upcase
        | select(test("^[A-Z][A-Z0-9_]*$"))
        | "\(.)\t\($value | tostring)"
    ' <<< "$json"
}

# Sets the variables from one file: all of them, or with "known", only those
# lib/config/ declares
gnoto_load_settings() {
    local file=$1 only_known=${2:-} lines name value
    lines=$(gnoto_settings "$file") || {
        printf 'gnoto: %s has an error, above\n' "$file" >&2
        return 1
    }
    while IFS=$'\t' read -r name value; do
        [[ -n $name ]] || continue
        if [[ -n $only_known && " ${GNOTO_KNOWN[*]} " != *" $name "* ]]; then
            continue
        fi
        printf -v "$name" '%s' "$value"
    done <<< "$lines"
}

# Declares a section of config.yaml, and the line gnoto config prints for it
config_section() {
    CONFIG_SECTIONS+=("$1")
    CONFIG_ABOUT[$1]=$2
}

# Declares a setting: its section, key, type, default, and the question gnoto
# config asks for it. The types are bool, int, text, secret, path (on the host),
# paths (comma-separated) and dir (a directory gnoto writes to).
config_setting() {
    local section=$1 key=$2 name=${2^^}
    [[ $section == core ]] || name=${section^^}_$name
    GNOTO_KNOWN+=("$name")
    [[ $3 != secret ]] || GNOTO_SECRETS+=("$name")
    printf -v "$name" '%s' "$4"
    CONFIG_KEYS[$section]+="$key "
    CONFIG_TYPE[$section.$key]=$3
    CONFIG_QUESTION[$section.$key]=$5
}

declare -gA CONFIG_ABOUT=() CONFIG_KEYS=() CONFIG_TYPE=() CONFIG_QUESTION=()
CONFIG_SECTIONS=()
GNOTO_KNOWN=()
GNOTO_SECRETS=(RUN_ID_SALT)
for GNOTO_SECTION in core apptainer slurm wrike aws globus; do
    source "$CODE_DIR/lib/config/$GNOTO_SECTION.sh"
done
unset GNOTO_SECTION

GNOTO_CONFIG=$INSTALL_DIR/config.yaml
if [[ -e $GNOTO_CONFIG ]]; then
    [[ -r $GNOTO_CONFIG ]] || { printf "gnoto: can't read %s\n" "$GNOTO_CONFIG" >&2; return 1; }
    gnoto_load_settings "$GNOTO_CONFIG" known || return 1
fi

DATA_DIR=${DATA_DIR:-$INSTALL_DIR/data}
DB_DIR=${DB_DIR:-$DATA_DIR/db}

if [[ -r $DATA_DIR/generated.yaml ]]; then
    # config.yaml wins, so load generated.yaml first, then config.yaml again
    gnoto_load_settings "$DATA_DIR/generated.yaml" || return 1
    if [[ -e $GNOTO_CONFIG ]]; then
        gnoto_load_settings "$GNOTO_CONFIG" known || return 1
    fi
    DATA_DIR=${DATA_DIR:-$INSTALL_DIR/data}
    DB_DIR=${DB_DIR:-$DATA_DIR/db}
fi
unset GNOTO_CONFIG

AWS_RUN_PREFIX=${AWS_RUN_PREFIX:-gnoto}
GLOBUS_RUN_PREFIX=${GLOBUS_RUN_PREFIX:-gnoto}

for GNOTO_NAME in "${GNOTO_KNOWN[@]}" DATA_DIR DB_DIR AWS_RUN_PREFIX GLOBUS_RUN_PREFIX; do
    if [[ " ${GNOTO_SECRETS[*]} " != *" $GNOTO_NAME "* ]]; then
        export "${GNOTO_NAME?}"
    fi
done
unset GNOTO_NAME

export NXF_HOME=$DATA_DIR/nextflow
export NXF_ASSETS=$NXF_HOME/assets
export NXF_APPTAINER_CACHEDIR=$DATA_DIR/images

source "$CODE_DIR/lib/utilities.sh"
source "$CODE_DIR/lib/run_state.sh"
source "$CODE_DIR/lib/params.sh"
source "$CODE_DIR/lib/containers.sh"
source "$CODE_DIR/lib/scheduler.sh"
source "$CODE_DIR/lib/versions.sh"
source "$CODE_DIR/lib/outputs.sh"
source "$CODE_DIR/service/wrike/api.sh"
source "$CODE_DIR/service/wrike/tasks.sh"
source "$CODE_DIR/service/aws/aws.sh"
source "$CODE_DIR/service/publish.sh"
