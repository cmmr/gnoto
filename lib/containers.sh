#
# containers.sh - Every container call gnoto's own scripts make: pulling a step
# image and running a command in it.
#
# Sourced by:  lib/env.sh
# Defines:     lock_image, container_sif, container_exec
# Requires:    apptainer, through its stand-in; flock; fail from
#              lib/utilities.sh, and lock_get from lib/params.sh
# Env:         CODE_DIR, DATA_DIR, DB_DIR and APPTAINER_BINDS, from lib/env.sh
#
# Images are pinned by digest in each pipeline's lock.yaml and pulled once into
# <data_dir>/images, under a lock and by rename.
#
# A step runs with no environment but LC_ALL=C.UTF-8 and TZ=UTC, and an empty
# home directory at a fixed path, so neither the caller's locale, R library or
# dotfiles nor their user name can change what it computes. Apptainer mounts
# the current directory, so steps run from the run directory.

STEP_HOME=/home/gnoto

# The address lock.yaml pins for one of a pipeline's step images
lock_image() {
    lock_get "$1" ".step_images.$2"
}

# The .sif for an image address, pulling it first if it isn't there. The address
# must name a digest, as <registry>/<image>@sha256:<64 hex digits>.
container_sif() {
    local address="${1#docker://}" sif

    if [[ ! "$address" =~ ^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$ ]]; then
        fail "\"$1\" doesn't name a container image by digest."
    fi
    sif="$DATA_DIR/images/${address//\//-}.sif"
    sif="${sif/@sha256:/@sha256-}"
    [[ -f "$sif" ]] && { printf '%s' "$sif"; return 0; }

    mkdir -p "$DATA_DIR/images" || fail "Can't create $DATA_DIR/images."
    (
        flock 9 || exit 1
        [[ -f "$sif" ]] && exit 0
        rm -f "$sif.tmp"
        apptainer pull "$sif.tmp" "docker://$address" >&2 || exit 1
        mv -f "$sif.tmp" "$sif"
    ) 9> "$sif.lock" || fail "Can't pull docker://$address."
    printf '%s' "$sif"
}

# Runs a command in an image: container_exec <address> [-B <path>]... <command> ...
# Binds the data and database directories and apptainer.binds, plus any
# -B paths, each at its own path. Returns the command's exit code.
container_exec() {
    local sif home status
    local binds=(-B "$DATA_DIR" -B "$DB_DIR")

    sif=$(container_sif "$1") || exit 1
    shift
    if [[ -n "${APPTAINER_BINDS:-}" ]]; then
        binds+=(-B "$APPTAINER_BINDS")
    fi
    while [[ "${1:-}" == -B ]]; do
        binds+=(-B "$2")
        shift 2
    done

    home=$(mktemp -d "${TMPDIR:-/tmp}/gnoto-home.XXXXXX") || fail "Can't make a home directory for a step."
    status=0
    apptainer exec --cleanenv --home "$home:$STEP_HOME" --env LC_ALL=C.UTF-8 --env TZ=UTC \
        "${binds[@]}" "$sif" "$@" || status=$?
    rm -rf "$home"
    return $status
}
