#!/bin/bash
#
# fetch_files.sh - Fetches a database or fixture that's used as it's downloaded,
# checking every file against pipelines/databases.yaml.
#
# A database entry lists its downloads under files, and a fixture is the list
# under fixtures.<name>. Each item has a url, an md5 and a size in bytes, and
# optionally file, the name to save it as, which is otherwise the last part of
# the url. Each download is written beside its final name, checked for size and
# md5, and only then renamed, so <out_dir> never holds an unchecked file under a
# real name.
#
# The builders source this file for fetch_checked, which does the same for one
# download, and write_manifest. Run as a script, it does the fetch.
#
# Usage:     fetch_files.sh <db path> <out_dir>
#            <db path> is an entry's path, such as dada2/silva-138.2, or
#            fixtures/<name>/v1 for a fixture
# Called by: the database fetch job, as the setup line of an entry that lists
#            files, with <out_dir> appended. <out_dir> is an empty directory the
#            job made. On success the job renames it into place and moves
#            manifest.yaml beside it, as <db path>.manifest.yaml. On failure it
#            removes it.
# Sourced by: build_pplace_reference.sh and build_16s_reference.sh
# Requires:  curl, md5sum, sha256sum, find, yq and jq, from the gnoto image
# Reads:     pipelines/databases.yaml
# Writes:    each file into <out_dir>, and <out_dir>/manifest.yaml
# Env:       CODE_DIR and the log/fail helpers, from lib/env.sh

# The directory a build fills, made absolute. It must be an empty directory the
# caller made, so nothing is ever built over another build.
out_dir_path() {
    [[ -n "${1:-}" ]] || fail "No output directory was given."
    [[ -d "$1" && -w "$1" ]] || fail "$1 isn't a writable directory."
    [[ -z $(ls -A -- "$1") ]] || fail "$1 isn't empty. A build fills an empty directory."
    cd -P -- "$1" && pwd -P
}

# Downloads a url to dest, checks its size and md5 against what
# pipelines/databases.yaml records, and only then gives it its name. curl
# retries only timeouts and some HTTP errors by itself, so a server that
# refuses a connection for a moment, as EBI's did, is retried as well.
fetch_checked() {
    local url="$1" md5="$2" bytes="$3" dest="$4" got

    rm -f "$dest.part"
    if ! curl -sS --fail --location --retry 5 --retry-delay 30 --retry-all-errors --connect-timeout 60 \
            --speed-limit 1024 --speed-time 300 -o "$dest.part" "$url"; then
        rm -f "$dest.part"
        fail "Couldn't download $url."
    fi

    got=$(stat -c %s "$dest.part")
    if [[ "$got" != "$bytes" ]]; then
        rm -f "$dest.part"
        fail "$url gave $got bytes, not the $bytes pipelines/databases.yaml records. Nothing was built from it."
    fi

    got=$(md5sum < "$dest.part")
    got=${got%% *}
    if [[ "$got" != "$md5" ]]; then
        rm -f "$dest.part"
        fail "$url has md5 $got, not the $md5 pipelines/databases.yaml records, so upstream may have changed it. Nothing was built from it."
    fi

    mv -f "$dest.part" "$dest"
}

# Checks a list of downloads, as JSON, before any is fetched: each has a url, an
# md5 and a size, and a file name that's plain and not used twice
check_downloads() {
    local json="$1" what="$2" bad

    [[ $(jq 'length' <<< "$json") -gt 0 ]] || fail "pipelines/databases.yaml lists no downloads for $what."
    bad=$(jq -r 'first(.[] | select(
            (.url | tostring | test("^(https?|file)://") | not)
            or (.md5 | tostring | test("^[0-9a-f]{32}$") | not)
            or (.bytes | tostring | test("^[1-9][0-9]*$") | not)
            or (.file | tostring | test("^[A-Za-z0-9_][A-Za-z0-9._-]*$") | not)
            or .file == "manifest.yaml")
        | .url // "(no url)")' <<< "$json")
    [[ -z "$bad" ]] ||
        fail "pipelines/databases.yaml's download $bad, for $what, needs a url, an md5, a size in bytes and a plain file name."
    bad=$(jq -r 'first(group_by(.file)[] | select(length > 1) | .[0].file)' <<< "$json")
    [[ -z "$bad" ]] || fail "pipelines/databases.yaml saves two of $what's downloads as $bad."
}

# Prints "<files> <bytes> <tree_sha256>" for a directory. The tree digest is the
# SHA-256 of sha256sum's lines for every file, named relative to the directory
# and in byte order, so it's the same wherever the directory sits. manifest.yaml
# is left out, because it moves out of the directory.
tree_summary() {
    local dir="$1" other files bytes digest

    other=$(cd "$dir" && find . ! -type f ! -type d -print -quit) || return 1
    [[ -z "$other" ]] || fail "$dir/${other#./} is neither a file nor a directory."

    files=$(cd "$dir" && find . -type f ! -path ./manifest.yaml | wc -l) || return 1
    [[ "$files" -gt 0 ]] || fail "$dir holds no files."
    bytes=$(cd "$dir" && find . -type f ! -path ./manifest.yaml -printf '%s\n' |
        awk '{ n += $1 } END { printf "%d", n }') || return 1
    digest=$(cd "$dir" && find . -type f ! -path ./manifest.yaml -printf '%P\0' |
        LC_ALL=C sort -z | xargs -0r sha256sum -- | sha256sum) || return 1

    printf '%s %s %s\n' "$files" "$bytes" "${digest%% *}"
}

# Writes <dir>/manifest.yaml: the database's path, its file count, size and
# tree digest, then the fields of a JSON object saying what went in, from where
# and how, then when and by whom it was built
write_manifest() {
    local dir="$1" path="$2" about="$3" summary files bytes digest

    summary=$(tree_summary "$dir") || exit 1
    read -r files bytes digest <<< "$summary"

    jq -n --arg path "$path" --argjson files "$files" --argjson bytes "$bytes" \
        --arg digest "$digest" --argjson about "$about" \
        --arg built_utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg built_by "$(id -un)" '
        {schema: 1, path: $path, files: $files, bytes: $bytes, tree_sha256: $digest}
        + ($about | with_entries(select(.value != null)))
        + {built_utc: $built_utc, built_by: $built_by}' |
        yq -P -o=yaml . > "$dir/manifest.yaml" ||
        fail "Couldn't write $dir/manifest.yaml."
}

# A pipelines/databases.yaml entry, as JSON, with its downloads as files
fetch_entry() {
    local db="$1" databases="$CODE_DIR/pipelines/databases.yaml"

    if [[ "$db" =~ ^fixtures/([^/]+)/v1$ ]]; then
        FETCH_FIXTURE="${BASH_REMATCH[1]}" yq -o=json -e \
            '.fixtures[strenv(FETCH_FIXTURE)] | select(. != null) | {"files": .}' "$databases" 2> /dev/null
    else
        FETCH_PATH="$db" yq -o=json -e \
            '[.databases[] | select(.path == strenv(FETCH_PATH))] | .[0] | select(. != null)' "$databases" 2> /dev/null
    fi
}

fetch_files_main() {
    local db="$1" out_dir entry downloads count total url md5 bytes file about

    out_dir=$(out_dir_path "$2") || exit 1
    # Away from the caller's directory, where fail would write to a run's state
    cd "$out_dir"

    entry=$(fetch_entry "$db") || fail "pipelines/databases.yaml has no database or fixture $db."
    downloads=$(jq -c '[(.files // [])[] | .file = (.file // (.url | tostring | sub("[?#].*$"; "") | split("/") | last))]' \
        <<< "$entry")
    check_downloads "$downloads" "$db"

    count=$(jq 'length' <<< "$downloads")
    total=$(jq 'map(.bytes) | add' <<< "$downloads")
    log "Fetching $db: $count files, $(human_size "$total")..."
    while IFS=$'\t' read -r url md5 bytes file; do
        log "  $file"
        fetch_checked "$url" "$md5" "$bytes" "$out_dir/$file"
    done < <(jq -r '.[] | [.url, .md5, (.bytes | tostring), .file] | @tsv' <<< "$downloads")

    about=$(jq -c --argjson sources "$downloads" '{
            name, release, doi,
            built_with: "steps/fetch_files.sh",
            sources: ($sources | map({file, url, md5, bytes}))
        }' <<< "$entry")
    write_manifest "$out_dir" "$db" "$about"

    log "Fetched $db into $out_dir."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    source "${BASH_SOURCE[0]%/*}/../lib/env.sh"
    [[ $# -eq 2 ]] || fail "Usage: fetch_files.sh <db path> <out_dir>"
    fetch_files_main "$@"
fi
