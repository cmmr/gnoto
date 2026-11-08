#!/bin/bash
#
# publish.sh - Publishes the images gnoto builds, and the ones it keeps a copy
# of, to ghcr.io/cmmr.
#
# Run by:    .github/workflows/images.yml, on a push to main that changes a
#            recipe, or by hand with a local registry for a test
# Usage:     images/publish.sh gnoto <docker-archive tarball>
#            images/publish.sh gnoto-rbiom
#            images/publish.sh mirrors
# Requires:  bash, git and docker. skopeo runs from its image, pinned below.
# Env:       REGISTRY, where images go, ghcr.io/cmmr by default; REGISTRY_USER
#            and REGISTRY_TOKEN, to log in there, unset for a local registry;
#            TLS_VERIFY, false for a local registry; CHECK_REGISTRY, a registry
#            gnoto's image is pushed to first to learn its digest,
#            localhost:5000 by default; DOCKER_NETWORK, the network skopeo's
#            container joins, host by default; SKOPEO_MOUNT, a docker -v that
#            shows skopeo gnoto's tarball, its own directory by default;
#            GITHUB_STEP_SUMMARY, where CI collects the digests
#
# Each image is tagged with the first 12 characters of its recipe's git hash,
# images/gnoto.nix or images/gnoto-rbiom/, so a recipe that's already published
# is left alone. A mirror keeps its source's tag and digest. The digests then go
# into IMAGE and lock.yaml by hand, in a commit of their own.
#
# gnoto's image rebuilds byte for byte, and skopeo's gzip is deterministic, so
# the same recipe and skopeo give the same digest. Its digest is learned from
# CHECK_REGISTRY first: an existing tag with another digest fails, as a build
# that no longer reproduces. gnoto-rbiom doesn't rebuild byte for byte, so an
# existing tag is kept as it is.

set -euo pipefail

export MSYS_NO_PATHCONV=1

SKOPEO=quay.io/skopeo/stable:v1.22.3@sha256:2681eccb8b02c495b013c2669cbf7f41d5c0b0b0e644e7c69bd3ea9bcb20641f
REGISTRY=${REGISTRY:-ghcr.io/cmmr}
TLS_VERIFY=${TLS_VERIFY:-true}
CHECK_REGISTRY=${CHECK_REGISTRY:-localhost:5000}
DOCKER_NETWORK=${DOCKER_NETWORK:-host}
REPO=$(cd "$(dirname "$0")/.." && pwd)

fail() {
    echo "publish.sh: $*" >&2
    exit 1
}

# A path as docker sees it, which from Git Bash is a Windows one
host_path() {
    if command -v cygpath > /dev/null; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

WORK=$(mktemp -d "${RUNNER_TEMP:-/tmp}/publish.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Runs skopeo, with WORK at /work
skopeo() {
    local mounts=(-v "$(host_path "$WORK"):/work")
    [[ -z ${SKOPEO_MOUNT:-} ]] || mounts+=(-v "$SKOPEO_MOUNT")
    docker run --rm -i --network "$DOCKER_NETWORK" "${mounts[@]}" "$SKOPEO" "$@"
}

AUTH=()
if [[ -n ${REGISTRY_TOKEN:-} ]]; then
    skopeo login --authfile /work/auth.json -u "${REGISTRY_USER:?}" --password-stdin "${REGISTRY%%/*}" <<< "$REGISTRY_TOKEN" > /dev/null ||
        fail "can't log in to ${REGISTRY%%/*}"
    AUTH=(--authfile /work/auth.json)
fi

# The digest of an image in REGISTRY, or nothing when it isn't there
registry_digest() {
    skopeo inspect "${AUTH[@]}" --tls-verify="$TLS_VERIFY" --format '{{.Digest}}' "docker://$1" 2> /dev/null || :
}

# Copies a docker-archive tarball to an address, and prints the digest it got
push_archive() {
    local tarball=$1 address=$2 tls=$3
    rm -f "$WORK/digest"
    skopeo copy -q "${AUTH[@]}" --dest-tls-verify="$tls" --digestfile /work/digest \
        "docker-archive:$tarball" "docker://$address" >&2 || fail "can't push $address"
    cat "$WORK/digest"
}

# Records an image's address, and says whether the commit's files name it
report() {
    local address=$1 named_in=$2
    echo "$address"
    if grep -rqF -- "${address#docker://}" $named_in 2> /dev/null; then
        echo "  named in ${named_in//$REPO\//}"
    else
        echo "::warning::$address isn't named in ${named_in//$REPO\//} yet"
    fi
    [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || printf -- '- `%s`\n' "$address" >> "$GITHUB_STEP_SUMMARY"
}

recipe_tag() {
    git -C "$(host_path "$REPO")" rev-parse "HEAD:$1" | cut -c1-12
}

publish_gnoto() {
    local tarball=$1 tag digest existing
    if [[ -z ${SKOPEO_MOUNT:-} ]]; then
        tarball=$(readlink -f "$tarball") && [[ -f $tarball ]] || fail "there's no tarball $1"
        SKOPEO_MOUNT="${tarball%/*}:${tarball%/*}:ro"
    fi
    tag=$(recipe_tag images/gnoto.nix)

    digest=$(push_archive "$tarball" "$CHECK_REGISTRY/gnoto:$tag" false)
    existing=$(registry_digest "$REGISTRY/gnoto:$tag")
    if [[ -z $existing ]]; then
        existing=$(push_archive "$tarball" "$REGISTRY/gnoto:$tag" "$TLS_VERIFY")
    fi
    [[ $existing == "$digest" ]] ||
        fail "images/gnoto.nix built $digest, but $REGISTRY/gnoto:$tag is $existing, so the build no longer reproduces"
    report "docker://$REGISTRY/gnoto@$digest" "$REPO/IMAGE"
}

publish_rbiom() {
    local tag digest
    tag=$(recipe_tag images/gnoto-rbiom)
    digest=$(registry_digest "$REGISTRY/gnoto-rbiom:$tag")
    if [[ -z $digest ]]; then
        docker build --platform linux/amd64 -t "gnoto-rbiom:$tag" "$(host_path "$REPO/images/gnoto-rbiom")" >&2 ||
            fail "can't build images/gnoto-rbiom"
        docker save -o "$(host_path "$WORK/gnoto-rbiom.tar")" "gnoto-rbiom:$tag" || fail "can't save gnoto-rbiom:$tag"
        digest=$(push_archive /work/gnoto-rbiom.tar "$REGISTRY/gnoto-rbiom:$tag" "$TLS_VERIFY")
    fi
    report "$REGISTRY/gnoto-rbiom@$digest" "$REPO/pipelines/*/lock.yaml"
}

# Each line of mirrors.txt is a source address, by tag and digest
publish_mirrors() {
    local source name tag digest dest
    while read -r source; do
        [[ -n $source && $source != \#* ]] || continue
        [[ $source =~ ^([^@]+/([^/@:]+)):([^@:/]+)@(sha256:[0-9a-f]{64})$ ]] ||
            fail "images/mirrors.txt: $source doesn't name a tag and a digest"
        name=${BASH_REMATCH[2]}
        tag=${BASH_REMATCH[3]}
        digest=${BASH_REMATCH[4]}
        dest=$REGISTRY/$name:$tag
        if [[ $(registry_digest "$dest") != "$digest" ]]; then
            rm -f "$WORK/digest"
            skopeo copy -q --all --preserve-digests "${AUTH[@]}" --dest-tls-verify="$TLS_VERIFY" \
                --digestfile /work/digest "docker://${BASH_REMATCH[1]}@$digest" "docker://$dest" >&2 ||
                fail "can't copy $source to $dest"
            [[ $(cat "$WORK/digest") == "$digest" ]] || fail "$dest got $(cat "$WORK/digest"), not $digest"
        fi
        report "$REGISTRY/$name@$digest" "$REPO/modules $REPO/pipelines/*/lock.yaml"
    done < "$REPO/images/mirrors.txt"
}

case ${1:-} in
    gnoto) publish_gnoto "${2:?Usage: publish.sh gnoto <tarball>}" ;;
    gnoto-rbiom) publish_rbiom ;;
    mirrors) publish_mirrors ;;
    *) fail "Usage: publish.sh gnoto <tarball> | gnoto-rbiom | mirrors" ;;
esac
