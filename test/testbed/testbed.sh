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
#            testbed.sh repo      make the test bed's git repository, if it has
#                                 none, from this repo's main
#            testbed.sh commit [message]   commit this working tree to that
#                                 repository's main, and print the commit
#            testbed.sh install [dir]   commit this working tree, clone it to
#                                 /opt/gnoto, or dir, and make it current there
#            testbed.sh services [up|down]   start or remove the integrations'
#                                 stand-ins: a Wrike stub, s3mock and ElasticMQ
#            testbed.sh down      remove the container, keeping its data volume
#            testbed.sh purge     remove the container and its volumes
# Requires:  docker, git and bash. Works from Git Bash on Windows.
#
# Containers: gnoto-testbed, privileged, with /data on the volume
# gnoto-testbed-data, and gnoto-nix, which builds the gnoto image with its /nix
# store on the volume gnoto-nix. In the test bed, alice and bob are users in the group
# gnoto, and /data/gnoto is the data directory. /tmp/gnoto.git is the
# repository installs are cloned from and gnoto fetches versions from, as
# file:///tmp/gnoto.git: gnoto runs only commits, so the working tree reaches
# the test bed as a test commit there, which goes nowhere else.

set -euo pipefail

export MSYS_NO_PATHCONV=1

REPO=$(cd "$(dirname "$0")/../.." && pwd)
TESTBED=gnoto-testbed
NIX=gnoto-nix
NIX_IMAGE=nixos/nix:2.35.4@sha256:f159a58f390677f41e8e900a74b6e2f9c7f27b364122ae6acf7a652ce6c551c0
TEST_REPO=/tmp/gnoto.git
SERVICES_NET=gnoto-services
STUB_IMAGE=python:3.14-slim@sha256:9aaa474097d094040649f2162a627c0049b408f52138d980916788d80f04802f
S3_IMAGE=adobe/s3mock:5.2.3@sha256:ab01a6946750f451ca215a47e91030695b260e4003b8a5a6201d25029b8fca92
QUEUE_IMAGE=softwaremill/elasticmq-native:1.7.1@sha256:e4580ab9ad1bd5cd37b4ba04911bc5ccc8cd2d9ab4de56ece65acee71c24e05c

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

# The test bed's own repository, /tmp/gnoto.git, which installs clone and
# versions are fetched from as file:///tmp/gnoto.git. It's in /tmp because
# Apptainer binds /tmp by default, so even an install without config.yaml can
# fetch from it, and it goes with the container. It starts as this repo's main
# and takes test commits that are never pushed anywhere else.
repo() {
    if ! docker exec "$TESTBED" test -d "$TEST_REPO"; then
        # Git for Windows can't take a Unix-style path with MSYS_NO_PATHCONV set
        (cd "$REPO" && git bundle create - main 2> /dev/null) |
            docker exec -i "$TESTBED" sh -c 'cat > /tmp/gnoto.bundle'
        docker exec "$TESTBED" bash -c "
            set -e
            git clone -q --bare /tmp/gnoto.bundle $TEST_REPO 2> /dev/null
            rm /tmp/gnoto.bundle
            git -C $TEST_REPO symbolic-ref HEAD refs/heads/main
            git -C $TEST_REPO config uploadpack.allowAnySHA1InWant true
            git -C $TEST_REPO config core.sharedRepository group
            git config --system safe.directory '*'"
    fi
    # alice and bob push test commits too, as checks/versions.sh does
    docker exec "$TESTBED" bash -c "chgrp -R gnoto $TEST_REPO && chmod -R g+rwX,a+rX $TEST_REPO &&
        find $TEST_REPO -type d -exec chmod g+s {} +"
    docker exec "$TESTBED" git -C "$TEST_REPO" log --oneline -3 main
}

# Commits this working tree, every file git would track, to the test bed's
# repository's main, unless main has it already, and prints main's commit.
# Windows records no executable bits, so every file with a shebang is marked.
commit() {
    local message=${1:-Test bed snapshot of the working tree} file
    repo > /dev/null
    (
        cd "$REPO"
        git ls-files -z -co --exclude-standard | while IFS= read -r -d '' file; do
            [[ -f $file ]] && printf '%s\0' "$file"
        done | tar --null -T - -cf -
    ) | docker exec -i "$TESTBED" bash -c "
        set -e
        rm -rf /tmp/gnoto-snapshot
        git clone -q $TEST_REPO /tmp/gnoto-snapshot
        cd /tmp/gnoto-snapshot
        find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
        tar -xf -
        find . -path ./.git -prune -o -type f -exec chmod 644 {} +
        grep -rlI --exclude-dir=.git '^#!' . | xargs -r chmod 755
        git add -A
        if ! git diff --cached --quiet; then
            git -c user.name='gnoto test bed' -c user.email=testbed@localhost commit -q -m '$message'
            git push -q origin HEAD:main
        fi
        git rev-parse HEAD
        chgrp -R gnoto $TEST_REPO && chmod -R g+rwX,a+rX $TEST_REPO"
}

# A clone of the test bed's repository at main, after committing this working
# tree there. The destination's config.yaml is kept, or a new one puts data in
# /data/gnoto with Slurm on. Its data directory's current version becomes the
# new commit, which the next command fetches.
install() {
    local dest=${1:-/opt/gnoto} head
    head=$(commit)
    docker exec "$TESTBED" bash -c "
        set -e
        rm -rf $dest.new
        git clone -q file://$TEST_REPO $dest.new
        cd $dest.new
        if [[ -f $dest/config.yaml ]]; then
            cp -p $dest/config.yaml config.yaml
        else
            printf '%s\n' 'core:' '  data_dir: \"/data/gnoto\"' '' 'apptainer:' '  enabled: true' \
                '  bin_dir: \"/usr/bin\"' '' 'slurm:' '  enabled: true' '  bin_dir: \"/usr/bin\"' > config.yaml
            chmod 660 config.yaml
        fi
        chown -R root:gnoto .
        find . -path ./.git -prune -o -type d -exec chmod 2775 {} +
        chmod -R g+w .git
        data=\$(sed -n '/^core:/,/^[^ ]/s/^  data_dir: \"\(.*\)\"/\1/p' config.yaml)
        data=\${data:-$dest/data}
        mkdir -p \$data
        printf '%s\n%s\n' $head file://$TEST_REPO > \$data/current
        chgrp gnoto \$data/current && chmod 664 \$data/current
        rm -rf $dest
        mv $dest.new $dest"
    echo "Installed $REPO to $dest in $TESTBED, at the test bed's commit $head, now current there"
}


# The stand-ins for the integrations, on a network the test bed joins:
# wrike-stub, test/wrike/stub.py, for Wrike's API; s3mock, for S3, which serves
# its buckets to anyone at http://s3mock:9090/<bucket>/; and elasticmq, for SQS
services() {
    case ${1:-up} in
        up)
            docker network inspect "$SERVICES_NET" > /dev/null 2>&1 || docker network create "$SERVICES_NET" > /dev/null
            docker network connect "$SERVICES_NET" "$TESTBED" 2> /dev/null || :
            if ! running gnoto-wrike-stub; then
                docker rm -f gnoto-wrike-stub > /dev/null 2>&1 || :
                docker create --name gnoto-wrike-stub --network "$SERVICES_NET" --network-alias wrike-stub \
                    "$STUB_IMAGE" python3 /stub.py > /dev/null
                tar -c -C "$REPO/test/wrike" stub.py | docker cp - gnoto-wrike-stub:/
                docker start gnoto-wrike-stub > /dev/null
            fi
            if ! running gnoto-s3mock; then
                docker rm -f gnoto-s3mock > /dev/null 2>&1 || :
                docker run -d --name gnoto-s3mock --network "$SERVICES_NET" --network-alias s3mock \
                    -e COM_ADOBE_TESTING_S3MOCK_STORE_INITIAL_BUCKETS=gnoto-results "$S3_IMAGE" > /dev/null
            fi
            if ! running gnoto-elasticmq; then
                docker rm -f gnoto-elasticmq > /dev/null 2>&1 || :
                docker run -d --name gnoto-elasticmq --network "$SERVICES_NET" --network-alias elasticmq \
                    "$QUEUE_IMAGE" > /dev/null
            fi
            echo "Wrike at http://wrike-stub:8080/api/v4 (token stub-token), S3 at http://s3mock:9090, SQS at http://elasticmq:9324"
            ;;
        down)
            docker rm -f gnoto-wrike-stub gnoto-s3mock gnoto-elasticmq > /dev/null 2>&1 || :
            docker network disconnect "$SERVICES_NET" "$TESTBED" > /dev/null 2>&1 || :
            docker network rm "$SERVICES_NET" > /dev/null 2>&1 || :
            ;;
        *) echo "Usage: testbed.sh services [up|down]" >&2; exit 1 ;;
    esac
}

down() {
    services down
    docker rm -f "$TESTBED" > /dev/null 2>    docker rm -f "$TESTBED" > /dev/null 2>&1 || :1 || :
}

purge() {
    down
    docker rm -f "$NIX" > /dev/null 2>&1 || :
    docker volume rm gnoto-testbed-data gnoto-nix > /dev/null 2>&1 || :
}

case ${1:-} in
    up | image | repo | commit | install | services | down | purge) "$@" ;;
    *)
        sed -n '5,20p' "$0" >&2
        exit 1
        ;;
esac
