#!/bin/bash
#
# lock.sh - Writes and checks what the lock files pin: a digest for every image
# a Nextflow process runs in, and each database's size and tree digest.
#
# Run by:    a developer, through gnoto exec --dev from an install's working
#            tree, after moving an upstream commit, an image or a database, and
#            at each release; and by .github/workflows/checks.yml, as check
# Usage:     lock.sh containers <pipeline>   writes pipelines/<pipeline>/containers.config
#            lock.sh databases <pipeline>    writes lock.yaml's databases, and
#                                            the fixtures its selftest.yaml runs
#                                            on, from the manifests in core.db_dir
#            lock.sh digest <address>        prints an image's address by digest
#            lock.sh check                   fails on any image named by tag
# Requires:  bash, git, curl, jq, yq, gawk and sha256sum, as the gnoto image has
# Env:       DB_DIR, for databases: core.db_dir, which gnoto exec sets
#
# containers.config gives each process of the pinned upstream pipeline its
# image by digest, with a withName selector for its name and every alias it's
# included under, so none of the pipeline's own code changes. Each module's
# Docker-style address is the one read, and an address with no registry takes
# the one the pipeline sets for Apptainer. Reading every module, rather than
# asking nextflow inspect, also covers processes only a hand-added parameter
# turns on.
#
# nf-core also names an https:// file for Singularity and Apptainer, which is
# passed over, with one exception. Seqera's pixi-built images put their tools
# on PATH only in their entrypoint, /shell-hook.sh, which apptainer exec never
# runs, so their tools can't be found. A process whose image is one of those
# takes the module's own https:// file instead, which Seqera's registry serves
# at a path naming its SHA-256: the file is checked against it here.
#
# A digest is the sha256 of the manifest the registry serves for the tag. For a
# multi-platform image, that's its index, which must list linux/amd64.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/lock.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ACCEPT="application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json"
DIGEST_RE='^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+@sha256:[0-9a-f]{64}$'
# A file a registry serves by its SHA-256, as Seqera's Singularity images are
BLOB_RE='^https://[a-z0-9.-]+/.*/blobs/sha256/[0-9a-f]{2}/([0-9a-f]{64})/data$'
CHECK_FAILS=0

fail() {
    echo "lock.sh: $*" >&2
    exit 1
}

# In check, a problem is reported and counted, and the check goes on
problem() {
    echo "FAIL  $*"
    CHECK_FAILS=$((CHECK_FAILS + 1))
}

# GETs <path> under a repository in a registry's API into a file, asking for an
# anonymous token when the registry wants one, and prints the HTTP status. A
# blob's redirect is followed, and curl drops the token at another host.
registry_get() {
    local host=$1 repo=$2 path=$3 out=$4 url code challenge realm service scope token
    url=https://$host/v2/$repo/$path
    code=$(curl -sS -L -o "$out" -D "$WORK/headers" -w '%{http_code}' -H "Accept: $ACCEPT" "$url") || return 1
    if [[ $code == 401 ]]; then
        challenge=$(tr -d '\r' < "$WORK/headers" | grep -i '^www-authenticate: *bearer' | head -n 1)
        realm=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<< "$challenge")
        service=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<< "$challenge")
        scope=$(sed -n 's/.*scope="\([^"]*\)".*/\1/p' <<< "$challenge")
        [[ -n $realm ]] || { printf '401'; return 0; }
        token=$(curl -sS -G "$realm" ${service:+--data-urlencode "service=$service"} \
            --data-urlencode "scope=${scope:-repository:$repo:pull}" | jq -r '.token // .access_token // empty') ||
            return 1
        code=$(curl -sS -L -o "$out" -D "$WORK/headers" -w '%{http_code}' -H "Accept: $ACCEPT" \
            -H "Authorization: Bearer $token" "$url") || return 1
    fi
    printf '%s' "$code"
}

# Splits an address into "<registry host> <repository> <tag or digest>"
address_parts() {
    local address=$1 host rest
    host=${address%%/*}
    rest=${address#*/}
    [[ $host != docker.io ]] || host=registry-1.docker.io
    if [[ $rest == *@* ]]; then
        printf '%s %s %s' "$host" "${rest%@*}" "${rest#*@}"
    else
        printf '%s %s %s' "$host" "${rest%:*}" "${rest##*:}"
    fi
}

# Fetches the manifest an address names into $WORK/manifest. Fails naming the
# address when the registry can't be reached or hasn't got it.
fetch_manifest() {
    local address=$1 host repo ref code
    read -r host repo ref <<< "$(address_parts "$address")"
    code=$(registry_get "$host" "$repo" "manifests/$ref" "$WORK/manifest") ||
        { echo "can't reach $host for $address"; return 1; }
    [[ $code == 200 ]] || { echo "$host answered $code for $address"; return 1; }
}

# The digest of the manifest just fetched, after checking a multi-platform
# index lists linux/amd64
manifest_digest() {
    local address=$1 type
    type=$(jq -r '.mediaType // ""' "$WORK/manifest")
    if [[ $type == *index* || $type == *manifest.list* ]] &&
        ! jq -e '.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")' \
            "$WORK/manifest" > /dev/null; then
        echo "$address has no linux/amd64 image"
        return 1
    fi
    printf 'sha256:%s' "$(sha256sum "$WORK/manifest" | cut -d' ' -f1)"
}

# An address by tag, as <registry>/<repository>@<digest>
digest_address() {
    local address=$1 digest
    fetch_manifest "$address" >&2 || return 1
    digest=$(manifest_digest "$address") || { echo "$digest" >&2; return 1; }
    printf '%s@%s' "${address%:*}" "$digest"
}

# Whether an address by digest is in its registry, as that digest
digest_exists() {
    local address=$1 message got
    message=$(fetch_manifest "$address") || { echo "$message"; return 1; }
    got=$(manifest_digest "$address") || { echo "$got"; return 1; }
    [[ $got == "${address#*@}" ]] || { echo "$address is served as $got"; return 1; }
}

# The entrypoint of the linux/amd64 image an address by digest names, as one
# line
image_entrypoint() {
    local address=$1 host repo ref digest
    read -r host repo ref <<< "$(address_parts "$address")"
    fetch_manifest "$address" > /dev/null || return 1
    digest=$(jq -r 'if .manifests then (.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64") | .digest) else empty end' \
        "$WORK/manifest" | head -n 1)
    if [[ -n $digest ]]; then
        [[ $(registry_get "$host" "$repo" "manifests/$digest" "$WORK/manifest") == 200 ]] || return 1
    fi
    digest=$(jq -r '.config.digest' "$WORK/manifest")
    [[ $(registry_get "$host" "$repo" "blobs/$digest" "$WORK/config") == 200 ]] || return 1
    jq -r '(.config.Entrypoint // []) | join(" ")' "$WORK/config"
}

# Whether an image keeps its tools off PATH until its entrypoint runs
needs_entrypoint() {
    local entrypoint
    entrypoint=$(image_entrypoint "$1") || fail "can't read the configuration of $1"
    [[ $entrypoint == *shell-hook* ]]
}

# Checks that a file a registry serves by its SHA-256 has that SHA-256
blob_matches() {
    local url=$1 sum
    [[ $url =~ $BLOB_RE ]] || return 1
    sum=$(curl -sSL --fail "$url" | sha256sum) || return 1
    [[ ${sum%% *} == "${BASH_REMATCH[1]}" ]]
}

# Every process in the .nf files under a directory, as
# "<name><tab><Docker-style address><tab><https:// file or -><tab><file>". A
# process whose container directive names no single Docker-style address gets
# "?" for it.
scan_processes() {
    local dir=$1
    find "$dir" -name '*.nf' -type f -print0 | sort -z | xargs -0r gawk -v q="'" '
        function flush(   rest, s, found, n, https) {
            if (name == "") return
            rest = buf
            n = 0
            https = "-"
            while (match(rest, "[" q "\"][^" q "\"$]+[" q "\"]")) {
                s = substr(rest, RSTART + 1, RLENGTH - 2)
                rest = substr(rest, RSTART + RLENGTH)
                if (s ~ /^https:\/\//) https = s
                else if (s ~ /:/ && s !~ /^http:/) { found = s; n++ }
            }
            printf "%s\t%s\t%s\t%s\n", name, (n == 1 ? found : "?"), https, file
            name = ""
        }
        FNR == 1 { flush(); file = FILENAME }
        /^[[:space:]]*process[[:space:]]+[A-Za-z0-9_]+[[:space:]]*\{/ {
            flush()
            name = $0
            sub(/^[[:space:]]*process[[:space:]]+/, "", name)
            sub(/[[:space:]]*\{.*$/, "", name)
            buf = ""
            incontainer = 0
            next
        }
        name != "" && /^[[:space:]]*container[[:space:]]/ { incontainer = 1; buf = $0; next }
        incontainer {
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*[A-Za-z_]+:/ ||
                ($0 ~ /^[[:space:]]*[A-Za-z_]+[[:space:]]/ && $0 !~ /^[[:space:]]*container[[:space:]]/)) {
                incontainer = 0
            } else {
                buf = buf " " $0
            }
        }
        END { flush() }'
}

# Every alias a process is included under in the .nf files under a directory,
# as "<name><tab><alias>"
scan_aliases() {
    local dir=$1
    find "$dir" -name '*.nf' -type f -print0 | sort -z | xargs -0r gawk '
        /^[[:space:]]*include[[:space:]]*\{/ { ininclude = 1; text = "" }
        ininclude {
            text = text " " $0
            if ($0 ~ /\}/) {
                sub(/^[^{]*\{/, "", text)
                sub(/\}.*$/, "", text)
                gsub(/;/, " ", text)
                n = split(text, words, /[[:space:]]+/)
                for (i = 1; i + 2 <= n; i++)
                    if (words[i + 1] == "as" && words[i] ~ /^[A-Za-z0-9_]+$/ && words[i + 2] ~ /^[A-Za-z0-9_]+$/)
                        printf "%s\t%s\n", words[i], words[i + 2]
                ininclude = 0
            }
        }' | sort -u
}

# The registry the pipeline gives addresses without one, for Apptainer
pipeline_registry() {
    local registry
    registry=$(sed -n "s/^[[:space:]]*apptainer\.registry[[:space:]]*=[[:space:]]*['\"]\([^'\"]*\)['\"].*/\1/p" \
        "$1/nextflow.config" | tail -n 1)
    [[ -n $registry ]] || fail "$1/nextflow.config sets no apptainer.registry"
    printf '%s' "$registry"
}

# A pipeline's upstream at the commit its lock pins, in $WORK/<pipeline>
fetch_upstream() {
    local pipeline=$1 lock=$REPO/pipelines/$1/lock.yaml repository commit dir=$WORK/$1
    [[ -d $dir ]] && return 0
    repository=$(yq -e '.upstream.repository' "$lock") || fail "$lock names no upstream repository"
    commit=$(yq -e '.upstream.commit' "$lock") || fail "$lock names no upstream commit"
    [[ $repository == */* && $repository != *://* ]] && repository=https://github.com/$repository
    git init -q "$dir" &&
        git -C "$dir" fetch -q --depth 1 "$repository" "$commit" &&
        git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD ||
        fail "can't fetch $repository at $commit"
}

# Every selector the pipeline's processes need, as "<selector><tab><address by
# tag><tab><https:// file or ->", from its upstream in $WORK/<pipeline>. Fails
# on a process with no address it can read, and on a selector two images claim.
pipeline_selectors() {
    local dir=$WORK/$1 registry
    registry=$(pipeline_registry "$dir")
    scan_processes "$dir" > "$WORK/processes"
    if gawk -F'\t' '$2 == "?"' "$WORK/processes" | grep -q .; then
        gawk -F'\t' '$2 == "?" { print "  " $1 " in " $4 }' "$WORK/processes" >&2
        fail "these processes name no single Docker-style image"
    fi
    scan_aliases "$dir" > "$WORK/aliases"
    gawk -F'\t' -v registry="$registry" '
        FILENAME == ARGV[1] { aliases[$1] = aliases[$1] " " $2; next }
        {
            address = $2
            first = address
            sub(/\/.*/, "", first)
            if (first !~ /[.:]/ && first != "localhost") address = registry "/" address
            n = split($1 aliases[$1], names, " ")
            for (i = 1; i <= n; i++) print names[i] "\t" address "\t" $3
        }' "$WORK/aliases" "$WORK/processes" | sort -u > "$WORK/selectors"
    if cut -f1 "$WORK/selectors" | uniq -d | grep -q .; then
        fail "$(cut -f1 "$WORK/selectors" | uniq -d | head -n 5 | tr '\n' ' ')run in more than one image"
    fi
    cat "$WORK/selectors"
}

write_containers() {
    local pipeline=$1 dir=$REPO/pipelines/$1 out repository commit address https pinned count=0 files=0
    local -A digests=() blobs=()
    [[ -f $dir/lock.yaml ]] || fail "there's no $dir/lock.yaml"
    fetch_upstream "$pipeline"
    pipeline_selectors "$pipeline" > "$WORK/pinning"
    repository=$(yq '.upstream.repository' "$dir/lock.yaml")
    commit=$(yq '.upstream.commit' "$dir/lock.yaml")

    while IFS=$'\t' read -r _ address https; do
        [[ -z ${digests[$address]:-} ]] || continue
        pinned=$(digest_address "$address") || fail "can't pin $address"
        digests[$address]=$pinned
        count=$((count + 1))
        needs_entrypoint "$pinned" || continue
        [[ $https =~ $BLOB_RE ]] || fail "$address needs its entrypoint, and its module names no file by SHA-256 for Apptainer"
        if [[ -z ${blobs[$https]:-} ]]; then
            echo "Checking $https, for $address..." >&2
            blob_matches "$https" || fail "$https doesn't have the SHA-256 its path names"
            blobs[$https]=1
        fi
        digests[$address]=$https
        files=$((files + 1))
    done < "$WORK/pinning"

    out=$(mktemp "$dir/containers.config.XXXXXX")
    {
        echo "// containers.config - The image each process of $repository runs in, by"
        echo "// digest, at the commit lock.yaml pins, ${commit:0:7}. Written by pipelines/lock.sh"
        echo "// from every module there; each digest's tag follows it. An image that needs"
        echo "// its entrypoint gives way to the module's file for Apptainer, by its SHA-256."
        echo
        echo "process {"
        while IFS=$'\t' read -r selector address _; do
            printf "    withName: '%s' { container = '%s' } // %s" "$selector" "${digests[$address]}" "$address"
            [[ ${digests[$address]} != https://* ]] || printf ', whose image needs its entrypoint'
            printf '\n'
        done < "$WORK/pinning"
        echo "}"
    } > "$out"
    chmod 644 "$out"
    mv -f "$out" "$dir/containers.config"
    yq -i '.nextflow_containers = "containers.config" | .nextflow_containers style="double"' "$dir/lock.yaml"
    echo "Wrote $dir/containers.config: $(wc -l < "$WORK/pinning") processes and aliases in $count images, $files of them by their file for Apptainer."
}

# lock.yaml's databases: each pipelines/databases.yaml entry used by this
# pipeline, and each fixture its selftest.yaml names, from its manifest. An
# entry with no manifest in core.db_dir keeps what the lock had, with a warning.
write_databases() {
    local pipeline=$1 lock=$REPO/pipelines/$1/lock.yaml path manifest entry json='{}' missing=0
    [[ -f $lock ]] || fail "there's no $lock"
    [[ -n ${DB_DIR:-} ]] || fail "DB_DIR isn't set. Run this through gnoto exec --dev."
    while IFS=$'\t' read -r path manifest; do
        if [[ -f $DB_DIR/$manifest ]]; then
            entry=$(yq -o=json '{"files": .files, "bytes": .bytes, "tree_sha256": .tree_sha256}' "$DB_DIR/$manifest") ||
                fail "can't read $DB_DIR/$manifest"
            jq -e '.files > 0 and .bytes > 0 and (.tree_sha256 | test("^[0-9a-f]{64}$"))' <<< "$entry" > /dev/null ||
                fail "$DB_DIR/$manifest has no files, bytes and tree_sha256"
        else
            entry=$(P="db:$path" yq -o=json '.databases[strenv(P)] // null' "$lock")
            echo "No manifest for db:$path in $DB_DIR, so its lock entry stays as it was." >&2
            missing=$((missing + 1))
        fi
        [[ $entry == null ]] || json=$(jq --arg key "db:$path" --argjson entry "$entry" '.[$key] = $entry' <<< "$json")
    done < <(
        yq -o=json '.databases' "$REPO/pipelines/databases.yaml" | jq -r --arg pipeline "$pipeline" '
            .[] | select(any(.used_by[]?; startswith($pipeline + ":"))) | [.path, .manifest] | @tsv'
        # The fixtures its selftest runs on, which its runs check like any database
        if [[ -f $REPO/pipelines/$pipeline/selftest.yaml ]]; then
            yq -r '.jobs[].samples[][1:][]' "$REPO/pipelines/$pipeline/selftest.yaml" |
                sed -n 's#^\(fixtures/[^/]*/v1\)/.*#\1#p' | LC_ALL=C sort -u | awk '{ print $0 "\t" $0 ".manifest.yaml" }'
        fi)
    # Through a YAML file, so the section is written in block style
    yq -P -p=json -o=yaml <<< "$json" > "$WORK/databases.yaml" &&
        F=$WORK/databases.yaml yq -i '.databases = load(strenv(F))' "$lock" || fail "can't write $lock"
    echo "Wrote the databases in $lock: $(jq length <<< "$json"), $missing without a manifest here."
}

# Each line of a containers.config, as "<selector><tab><image><tab><the
# address by tag its comment names>"
config_entries() {
    sed -n "s|^ *withName: '\([^']*\)' { container = '\([^']*\)' } // \([^ ,]*\).*\$|\1\t\2\t\3|p" "$1"
}

# Checks one image address: by digest, and in its registry
check_address() {
    local address=$1 where=$2 message
    if [[ ! $address =~ $DIGEST_RE ]]; then
        problem "$where: $address isn't named by digest"
        return
    fi
    [[ -n ${CHECKED[$address]:-} ]] && return
    CHECKED[$address]=1
    message=$(digest_exists "$address") || { problem "$where: $message"; return; }
    message=$(image_entrypoint "$address") || { problem "$where: can't read the configuration of $address"; return; }
    [[ $message != *shell-hook* ]] ||
        problem "$where: $address keeps its tools off PATH until its entrypoint runs, which apptainer exec doesn't"
}

# Checks a file for Apptainer that a registry serves by its SHA-256 is there
check_blob() {
    local url=$1 where=$2
    [[ $url =~ $BLOB_RE ]] || { problem "$where: $url isn't a file named by its SHA-256"; return; }
    [[ -n ${CHECKED[$url]:-} ]] && return
    CHECKED[$url]=1
    curl -sSfIL -o /dev/null "$url" 2> /dev/null || problem "$where: $url isn't there"
}

check_all() {
    local image file pipeline lock name address selector tag config
    local -A CHECKED=()

    IFS= read -r image < "$REPO/IMAGE" || image=""
    image=${image#docker://}
    check_address "$image" IMAGE

    for file in "$REPO"/images/*/Dockerfile; do
        while read -r image; do
            check_address "$image" "${file#$REPO/}" < /dev/null
        done < <(sed -n 's/^FROM[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$file" | sed 's|^\([^/]*\)$|docker.io/library/\1|; s|^\([^./]*/[^/]*\)$|docker.io/\1|; s|:[^/@]*@|@|')
    done

    # gnoto's own modules and workflows
    while IFS=$'\t' read -r name address _ file; do
        [[ $address != "?" ]] || { problem "${file#$REPO/}: process $name names no single image"; continue; }
        check_address "$address" "${file#$REPO/} ($name)"
    done < <(scan_processes "$REPO/modules"; scan_processes "$REPO/workflows")

    for lock in "$REPO"/pipelines/*/lock.yaml; do
        pipeline=$(basename "$(dirname "$lock")")
        while IFS=$'\t' read -r name address; do
            check_address "$address" "pipelines/$pipeline/lock.yaml step_images.$name"
        done < <(yq -o=json '.step_images // {}' "$lock" | jq -r 'to_entries[] | [.key, .value] | @tsv')

        yq -e '.upstream' "$lock" > /dev/null 2>&1 || continue
        config=$(yq '.nextflow_containers // ""' "$lock")
        if [[ -z $config || ! -f $REPO/pipelines/$pipeline/$config ]]; then
            problem "pipelines/$pipeline/lock.yaml names no containers.config that's there"
            continue
        fi
        fetch_upstream "$pipeline"
        pipeline_selectors "$pipeline" > "$WORK/$pipeline.wanted"
        config_entries "$REPO/pipelines/$pipeline/$config" | sort > "$WORK/$pipeline.have"
        while IFS=$'\t' read -r selector address tag; do
            if [[ $address == https://* ]]; then
                check_blob "$address" "pipelines/$pipeline/$config ($selector)"
                grep -qxF -- "$selector"$'\t'"$tag"$'\t'"$address" "$WORK/$pipeline.wanted" ||
                    problem "pipelines/$pipeline/$config ($selector): $address isn't the file its module names for Apptainer"
                continue
            fi
            check_address "$address" "pipelines/$pipeline/$config ($selector)"
            [[ ${address%@*} == "${tag%:*}" ]] || problem "pipelines/$pipeline/$config ($selector): $address isn't $tag"
        done < "$WORK/$pipeline.have"
        if ! diff <(cut -f1,3 "$WORK/$pipeline.have") <(cut -f1,2 "$WORK/$pipeline.wanted") > "$WORK/$pipeline.diff"; then
            problem "pipelines/$pipeline/$config doesn't match the modules at the pinned commit; run lock.sh containers $pipeline:"
            sed 's/^/        /' "$WORK/$pipeline.diff"
        fi
    done

    if (( CHECK_FAILS > 0 )); then
        echo "$CHECK_FAILS problem$( (( CHECK_FAILS == 1 )) || echo s)."
        exit 1
    fi
    echo "Every image is named by digest, and each is in its registry: ${#CHECKED[@]} images."
}

case ${1:-} in
    containers) write_containers "${2:?Usage: lock.sh containers <pipeline>}" ;;
    databases) write_databases "${2:?Usage: lock.sh databases <pipeline>}" ;;
    digest) digest_address "${2:?Usage: lock.sh digest <address>}" && echo ;;
    check) check_all ;;
    *) fail "Usage: lock.sh containers <pipeline> | databases <pipeline> | digest <address> | check" ;;
esac
