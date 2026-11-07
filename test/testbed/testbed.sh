#!/bin/bash
#
# testbed.sh - Builds and drives the single-node Slurm and Apptainer test bed.
#
# Run by:    a developer, from any directory, on a machine with Docker
# Usage:     testbed.sh up        build and start the test bed
#            testbed.sh image [gnoto|gnoto-rbiom]   build an image into a .sif in
#                                 the test bed: gnoto from images/gnoto.nix, named
#                                 in IMAGE, and gnoto-rbiom from
#                                 images/gnoto-rbiom/Dockerfile, named in lock.yaml
#            testbed.sh install [dir]   copy this working tree to /opt/gnoto, or dir,
#                                 in the test bed
#            testbed.sh down      remove the container, keeping its data volume
#            testbed.sh purge     remove the container and its volumes
# Requires:  docker and bash. Works from Git Bash on Windows.
#
# Containers: gnoto-testbed, privileged, with /data on the volume
# gnoto-testbed-data, and gnoto-nix, which builds the gnoto image with its /nix
# store on the volume gnoto-nix. In the test bed, alice and bob are users in the group
# gnoto, and /data/gnoto is the data directory.

set -euo pipefail

export MSYS_NO_PATHCONV=1

REPO=$(cd "$(dirname "$0")/../.." && pwd)
TESTBED=gnoto-testbed
NIX=gnoto-nix
NIX_IMAGE=nixos/nix:2.35.4@sha256:f159a58f390677f41e8e900a74b6e2f9c7f27b364122ae6acf7a652ce6c551c0

running() {
    [[ $(docker inspect --format '{{.State.Running}}' "$1" 2> /dev/null) == true ]]
}

up() {
    (cd "$REPO/test/testbed" && docker build -q -t gnoto-testbed .)
    docker volume create gnoto-testbed-data > /dev/null
    if ! running "$TESTBED"; then
        docker rm -f "$TESTBED" > /dev/null 2>&1 || :
        docker run -d --name "$TESTBED" --hostname testbed --privileged --cgroupns=private \
            --init -v gnoto-testbed-data:/data gnoto-testbed > /dev/null
    fi
    docker exec "$TESTBED" bash -c '
        mkdir -p /data/gnoto
        chgrp gnoto /data/gnoto
        chmod 2775 /data/gnoto
        for (( i = 0; i < 60; i++ )); do
            sinfo -h -o %t 2> /dev/null | grep -q idle && exit 0
            sleep 1
        done
        echo "slurmd never came up" >&2
        tail -20 /var/log/slurm/slurmd.log /var/log/slurm/slurmctld.log >&2
        exit 1'
    docker exec "$TESTBED" sinfo
}

# Builds images/<name>.nix, gnoto by default, into <name>-<config digest>.sif in
# the test bed's images directory. gnoto's goes in IMAGE, and gnoto-rbiom's in
# the rbiom entry of each lock.yaml that has one.
# Builds images/<name>.nix in the Nix container, and prints its store path
nix_build() {
    local name=$1 store
    if ! running "$NIX"; then
        docker rm -f "$NIX" > /dev/null 2>&1 || :
        docker volume create gnoto-nix > /dev/null
        docker run -d --name "$NIX" -v gnoto-nix:/nix "$NIX_IMAGE" sleep infinity > /dev/null
    fi
    docker exec "$NIX" rm -rf "/src/$name"
    tar -C "$REPO" -cf - images | docker exec -i "$NIX" sh -c "mkdir -p /src/$name && tar -xf - -C /src/$name"
    if ! store=$(docker exec "$NIX" sh -c "nix-build --no-out-link /src/$name/images/$name.nix 2> /tmp/build-$name.log"); then
        docker exec "$NIX" tail -30 "/tmp/build-$name.log" >&2
        return 1
    fi
    printf '%s' "$store"
}

image() {
    local name=${1:-gnoto} store="" config sif lock
    case $name in
        gnoto)
            store=$(nix_build "$name") || exit 1
            config=$(docker exec "$NIX" sh -c "tar -xOf $store manifest.json" | grep -o '"Config": *"[0-9a-f]*' | grep -o '[0-9a-f]*$')
            ;;
        gnoto-rbiom)
            (cd "$REPO/images/$name" && docker build --platform linux/amd64 -t "$name:testbed" .) || exit 1
            config=$(docker image inspect --format '{{.Id}}' "$name:testbed")
            config=${config#sha256:}
            ;;
        *)
            echo "There's no image $name to build. Build gnoto or gnoto-rbiom." >&2
            exit 1
            ;;
    esac
    sif=$name-${config:0:12}.sif
    echo "Image digest: sha256:$config"

    if ! docker exec "$TESTBED" test -f "/data/gnoto/images/$sif"; then
        if [[ -n $store ]]; then
            docker exec "$NIX" cat "$store"
        else
            docker save "$name:testbed"
        fi | docker exec -i "$TESTBED" sh -c "cat > /tmp/$name.tar"
        docker exec "$TESTBED" bash -c "
            set -e
            mkdir -p /data/gnoto/images
            rm -f /data/gnoto/images/$sif.tmp
            apptainer build /data/gnoto/images/$sif.tmp docker-archive:/tmp/$name.tar
            mv /data/gnoto/images/$sif.tmp /data/gnoto/images/$sif
            chgrp -R gnoto /data/gnoto/images
            chmod 2775 /data/gnoto/images
            chmod 664 /data/gnoto/images/$sif
            rm /tmp/$name.tar"
    fi
    if [[ $name == gnoto ]]; then
        echo "$sif" > "$REPO/IMAGE"
        echo "IMAGE now names $sif"
        return
    fi
    for lock in "$REPO"/pipelines/*/lock.yaml; do
        grep -q '^  rbiom: ' "$lock" || continue
        sed -i -E "s|^(  rbiom: )\"[^\"]*\"|\1\"$sif\"|" "$lock"
        echo "${lock#"$REPO"/} now names $sif"
    done
}

# A running job loses its stand-ins if its install directory is replaced, so
# install a second copy elsewhere while jobs run
install() {
    local dest=${1:-/opt/gnoto}
    docker exec "$TESTBED" rm -rf "$dest.new"
    tar -C "$REPO" --exclude=./.git --exclude=./data --exclude=./tmp --exclude=./scratch \
        --exclude=./config.yaml -cf - . |
        docker exec -i "$TESTBED" sh -c "mkdir $dest.new && tar -xf - -C $dest.new"
    docker exec "$TESTBED" bash -c "
        set -e
        cd $dest.new
        # Data in /data/gnoto, and Slurm on
        printf '%s\n' 'core:' '  data_dir: \"/data/gnoto\"' '' 'apptainer:' '  enabled: true' \
            '  bin_dir: \"/usr/bin\"' '' 'slurm:' '  enabled: true' '  bin_dir: \"/usr/bin\"' > config.yaml
        chown -R root:gnoto .
        find . -type d -exec chmod 2775 {} +
        find . -type f -exec chmod 664 {} +
        chmod 660 config.yaml
        # Windows records no executable bits, so mark every file with a shebang
        grep -rlI --exclude-dir=.git '^#!' . | xargs -r chmod 775
        rm -rf $dest
        mv $dest.new $dest"
    echo "Installed $REPO to $dest in $TESTBED"
}

down() {
    docker rm -f "$TESTBED" > /dev/null 2>&1 || :
}

purge() {
    down
    docker rm -f "$NIX" > /dev/null 2>&1 || :
    docker volume rm gnoto-testbed-data gnoto-nix > /dev/null 2>&1 || :
}

case ${1:-} in
    up | image | install | down | purge) "$@" ;;
    *)
        sed -n '5,12p' "$0" >&2
        exit 1
        ;;
esac
