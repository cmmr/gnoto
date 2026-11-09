#
# databases.sh - The databases a job needs: which are missing, offering to fetch
# them, and the fetch job itself.
#
# Sourced by:  lib/main.sh, for lint, run, start and the _fetch job
# Defines:     databases_check, databases_offer, databases_wait, fetch_main
# Requires:    yq, jq and flock; the settings and helpers from lib/env.sh, and
#              lint_ok, lint_warn and lint_fail from lib/lint.sh
#
# Each database is an entry in pipelines/databases.yaml, by its path under
# core.db_dir, and a fixture is fixtures/<name>/v1. An entry's setup is a
# command that fills an empty directory: the fetch job runs it with
# <path>.tmp.<job> appended, moves the manifest.yaml it writes to
# <path>.manifest.yaml, and only then renames the directory into place, so a
# database appears whole or not at all. A failed fetch leaves nothing.
#
# A fetch runs as a job, through the scheduler. While it runs, <path>.fetching
# names it, so a second lint reports it rather than starting another, and a run
# waits for it: with Slurm through --dependency=afterok, and on this machine by
# watching the marker.

# The pipelines/databases.yaml entry a db: name falls under, as its path, or
# nothing
db_entry_for() {
    local name=${1#db:}
    yq -o=json '[(.databases[].path), (.fixtures | keys | .[] | "fixtures/" + . + "/v1")]' \
        "$CODE_DIR/pipelines/databases.yaml" | jq -r --arg name "$name" '
        map(select(. as $path | $name == $path or ($name | startswith($path + "/"))
            or ($name | startswith($path + "."))))
        | .[0] // ""'
}

# The command that fetches or builds an entry, without the directory it fills
db_setup_for() {
    local path=$1
    if [[ $path == fixtures/*/v1 ]]; then
        # These are made from their downloads, which fetch_files.sh alone
        # doesn't do until phase 6: the shotgun fixtures are cut to their first
        # 100,000 reads, and 16s-v5v6 converted from NCBI's .sra file
        case $path in
            fixtures/wgs-*/v1 | fixtures/16s-v5v6/v1) return 0 ;;
        esac
        printf 'steps/fetch_files.sh %s' "$path"
    else
        P=$path yq -r '.databases[] | select(.path == strenv(P)) | .setup // ""' "$CODE_DIR/pipelines/databases.yaml"
    fi
}

# The resources an entry's fetch job asks for, as "<cpus> <memory> <time>":
# its fetch_job, or 2 CPUs, 8G and 24 hours
db_fetch_job_for() {
    P=$1 yq -r '[.databases[] | select(.path == strenv(P)) | .fetch_job][0] // {}
        | [.cpus // 2, .mem // "8G", .time // "24:00:00"] | join(" ")' "$CODE_DIR/pipelines/databases.yaml"
}

# What an entry downloads, in bytes, as the entry records it
db_bytes_for() {
    local path=$1 fixture=${1#fixtures/}
    yq -o=json . "$CODE_DIR/pipelines/databases.yaml" | jq -r --arg path "$path" --arg fixture "${fixture%/v1}" '
        if ($path | startswith("fixtures/")) then .fixtures[$fixture] // []
        else .databases[] | select(.path == $path) | (.files // []) + (.sources // []) end
        | map(.bytes // 0) | add // 0'
}

# The job named by an entry's fetch marker, when it's still queued or running:
# a Slurm job ID, or "local". Removes a marker whose job has gone.
db_fetching() {
    local path=$1 marker kind id host pid state
    marker=$DB_DIR/$path.fetching
    [[ -r $marker ]] || return 0
    read -r kind id host pid < "$marker" || :
    case $kind in
        slurm)
            state=$(scheduler_job_state "$id")
            case $state in
                PENDING | RUNNING | CONFIGURING | COMPLETING | SUSPENDED) printf '%s' "$id"; return 0 ;;
            esac
            ;;
        local)
            if [[ -z ${pid:-} ]] || scheduler_local_alive "$host" "$pid"; then
                printf 'local'
                return 0
            fi
            ;;
    esac
    rm -f "$marker"
}

# A database's lock entry, as JSON {files, bytes, tree_sha256}, or nothing when
# the pipeline's lock.yaml doesn't pin it
db_lock_entry() {
    local lock=$CODE_DIR/pipelines/$1/lock.yaml
    [[ -f $lock ]] || return 0
    K="db:$2" yq -o=json -I0 '.databases[strenv(K)] // ""' "$lock" 2> /dev/null | grep -v '^""$' || :
}

# "<files> <bytes>" under a path, following links, since a site may link a
# database in
db_measure() {
    find -L "$1" -type f -printf '%s\n' 2> /dev/null | awk '{ n++; b += $1 } END { printf "%d %d\n", n, b }'
}

# A database directory's tree digest, as steps/fetch_files.sh writes it in a
# manifest: the SHA-256 of sha256sum's lines for every file, named relative to
# the directory and sorted bytewise
db_tree_digest() {
    local sum
    sum=$(cd "$1" && find -L . -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0r sha256sum -- | sha256sum) ||
        return 1
    printf '%s' "${sum%% *}"
}

# Checks the databases a job reads against its pipeline's lock.yaml, and prints
# a line for each: "<db: name><tab>ok, unpinned or wrong<tab><its record
# entry, as JSON><tab><what's wrong>", last because read collapses an empty
# field between tabs. A database the lock pins, by its
# pipelines/databases.yaml entry, must have the lock's file count and bytes,
# and, when deep is true, its tree digest, and its record entry is the lock's.
# Any other is measured, and its entry is its file count and bytes. A missing
# one is left to databases_check and the job.
databases_verify() {
    local pipeline=$1 names=$2 deep=${3:-false} name entry key path pinned files bytes want digest
    local -A seen=()
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        entry=$(db_entry_for "$name")
        key=db:${entry:-${name#db:}}
        [[ -z ${seen[$key]:-} ]] || continue
        seen[$key]=1
        path=$DB_DIR/${key#db:}
        [[ -e $path ]] || continue
        read -r files bytes < <(db_measure "$path")
        pinned=""
        [[ -z $entry ]] || pinned=$(db_lock_entry "$pipeline" "$entry")
        if [[ -z $pinned ]]; then
            printf '%s\tunpinned\t{"files":%s,"bytes":%s}\t\n' "$key" "$files" "$bytes"
            continue
        fi
        want=$(jq -r '"\(.files) \(.bytes)"' <<< "$pinned")
        if [[ "$files $bytes" != "$want" ]]; then
            printf '%s\twrong\t%s\t%s\n' "$key" "$pinned" \
                "$key holds $files files and $bytes bytes, where $pipeline's lock.yaml pins ${want% *} files and ${want#* } bytes"
            continue
        fi
        if [[ $deep == true ]]; then
            echo "Computing the tree digest of $key, $(human_size "$bytes")..." >&2
            digest=$(db_tree_digest "$path") || digest="unreadable"
            want=$(jq -r .tree_sha256 <<< "$pinned")
            if [[ $digest != "$want" ]]; then
                printf '%s\twrong\t%s\t%s\n' "$key" "$pinned" "$key's tree digest is $digest, where $pipeline's lock.yaml pins $want"
                continue
            fi
        fi
        printf '%s\tok\t%s\t\n' "$key" "$pinned"
    done <<< "$names"
}

# Run by the job once its databases are there: fails on one that isn't what
# the lock pins, or on an exact re-run, what the record holds, and keeps each
# one's record entry in the run's state. An exact re-run checks each pinned
# database by its tree digest.
databases_job_check() {
    local names=$1 exact=$2 recorded=${3:-null} key status message entry was record='{}'
    [[ $exact != true ]] || set_run_stage "Checking the databases against their digests."
    while IFS=$'\t' read -r key status entry message; do
        [[ $status != wrong ]] || fail "$message. A database's path never changes what it holds, so this isn't the database the run's commit pins."
        [[ $exact != true || $status != ok ]] || log "$key matches its tree digest."
        if [[ $exact == true && $status == unpinned ]]; then
            was=$(jq -c --arg key "$key" '.[$key] // empty' <<< "$recorded")
            [[ -z $was ]] || jq -en --argjson was "$was" --argjson now "$entry" '$was == $now' > /dev/null ||
                fail "$key holds $(jq -r '"\(.files) files and \(.bytes) bytes"' <<< "$entry"), where the record has $(jq -r '"\(.files) files and \(.bytes) bytes"' <<< "$was")."
        fi
        record=$(jq -c --arg key "$key" --argjson entry "$entry" '.[$key] = $entry' <<< "$record")
    done < <(databases_verify "$(state_get pipeline)" "$names" "$exact")
    state_set_json database_record "$record" || fail "Can't write the run's state."
}

# Checks every database a job needs, from what pipeline_eval found. Missing
# ones being fetched are WARNs; the rest FAIL. Sets JOB_MISSING_DATABASES, the
# count of FAILs that a fetch could fix, JOB_FETCHABLE, their entries, and
# JOB_FETCH_AFTER, the Slurm jobs a run must wait for. Those present are
# checked against the lock, by tree digest when LINT_DEEP is true.
databases_check() {
    local names=$1 name path entry setup job count=0 unfetchable=0 key status message pinned=0 wrong=0 total=0
    local -A entries=()

    JOB_MISSING_DATABASES=0
    JOB_FETCHABLE=()
    JOB_FETCH_AFTER=""
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        count=$((count + 1))
        path=$(db_path "$name" 2> /dev/null) || { lint_fail "$name isn't a usable database name"; continue; }
        [[ ! -e $path ]] || continue
        entry=$(db_entry_for "$name")
        if [[ -z $entry ]]; then
            lint_fail "$name is missing, at $path, and pipelines/databases.yaml has no entry to fetch it from"
            unfetchable=$((unfetchable + 1))
            continue
        fi
        [[ -z ${entries[$entry]:-} ]] || continue
        entries[$entry]=1
        job=$(db_fetching "$entry")
        if [[ -n $job ]]; then
            lint_warn "db:$entry is being fetched$([[ $job == local ]] && echo " on this machine" || echo " by job $job")"
            [[ $job == local ]] || JOB_FETCH_AFTER+="${JOB_FETCH_AFTER:+:}$job"
            continue
        fi
        setup=$(db_setup_for "$entry")
        if [[ -z $setup ]]; then
            lint_fail "db:$entry is missing, and pipelines/databases.yaml says nothing that fetches it"
            unfetchable=$((unfetchable + 1))
            continue
        fi
        if [[ ! -f $CODE_DIR/${setup%% *} ]]; then
            lint_fail "db:$entry is missing, and gnoto can't fetch it yet: its setup, ${setup%% *}, isn't built"
            unfetchable=$((unfetchable + 1))
            continue
        fi
        lint_fail "db:$entry is missing, at $DB_DIR/$entry. gnoto can fetch it"
        JOB_FETCHABLE+=("$entry")
        JOB_MISSING_DATABASES=$((JOB_MISSING_DATABASES + 1))
    done <<< "$names"
    [[ -z $JOB_FETCH_AFTER ]] || JOB_FETCH_AFTER=afterok:$JOB_FETCH_AFTER

    while IFS=$'\t' read -r key status _ message; do
        total=$((total + 1))
        case $status in
            ok) pinned=$((pinned + 1)) ;;
            unpinned) lint_warn "$key isn't pinned by $JOB_PIPELINE's lock.yaml, so the record keeps only its size" ;;
            wrong) lint_fail "$message"; wrong=$((wrong + 1)) ;;
        esac
    done < <(databases_verify "$JOB_PIPELINE" "$names" "${LINT_DEEP:-false}")
    if (( ${#entries[@]} == 0 && unfetchable == 0 && wrong == 0 && count > 0 )); then
        lint_ok "databases: all $total present, $pinned as lock.yaml pins them$([[ ${LINT_DEEP:-false} == true ]] && echo ", by tree digest")"
    elif (( count == 0 )); then
        lint_ok "databases: none needed"
    fi
}

# Offers to fetch JOB_FETCHABLE, asking on the terminal unless yes is given,
# and submits a job for each. Prints the Slurm dependency a run should wait on.
# Fails when the offer is declined or can't be asked.
databases_offer() {
    local yes=${1:-false} entry bytes=0 free answer id after=$JOB_FETCH_AFTER marker cpus mem time

    (( ${#JOB_FETCHABLE[@]} > 0 )) || { printf '%s' "$after"; return 0; }
    for entry in "${JOB_FETCHABLE[@]}"; do
        bytes=$((bytes + $(db_bytes_for "$entry")))
    done
    free=$(df -P -B1 "$DB_DIR" 2> /dev/null | awk 'NR == 2 { print $4 }') || free=0
    if [[ $yes != true ]]; then
        if [[ ! -t 0 ]]; then
            fail "Not started: ${#JOB_FETCHABLE[@]} database$( (( ${#JOB_FETCHABLE[@]} == 1 )) || echo s) to fetch, and no terminal to ask on. Add --yes to fetch them."
        fi
        printf 'Fetch %d database%s as %s? They download %s, and %s is free in %s. [y/N] ' \
            "${#JOB_FETCHABLE[@]}" "$( (( ${#JOB_FETCHABLE[@]} == 1 )) || echo s)" \
            "$([[ $(scheduler_kind) == slurm ]] && echo "Slurm jobs" || echo "jobs on this machine")" \
            "$(human_size "$bytes")" "$(human_size "${free:-0}")" "$DB_DIR" >&2
        read -r answer || answer=""
        [[ $answer == [yY]* ]] || fail "Not fetched, so not started."
    fi
    for entry in "${JOB_FETCHABLE[@]}"; do
        mkdir -p "$(dirname "$DB_DIR/$entry")" || fail "Can't create $(dirname "$DB_DIR/$entry")."
        marker=$DB_DIR/$entry.fetching
        read -r cpus mem time < <(db_fetch_job_for "$entry")
        id=$(scheduler_submit --name "gnoto-fetch-${entry//\//-}" --dir "$DB_DIR" \
            --log "$DB_DIR/$entry.fetch.log" --cpus "$cpus" --mem "$mem" --time "$time" -- _fetch "$entry") ||
            fail "Couldn't submit the fetch of db:$entry."
        if [[ $id == local ]]; then
            printf 'local\n' > "$marker"
            echo "Fetching db:$entry on this machine. Its log is $DB_DIR/$entry.fetch.log." >&2
        else
            printf 'slurm %s\n' "$id" > "$marker"
            after+="${after:+:}$id"
            echo "Fetching db:$entry as job $id. Its log is $DB_DIR/$entry.fetch.log." >&2
        fi
    done
    after=${after#afterok:}
    printf '%s' "${after:+afterok:$after}"
}

# Run by the job before its work: waits while a database it needs is being
# fetched on this machine, then checks that it arrived
databases_wait() {
    local names=$1 name entry waited=0
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        if [[ ! -d $DB_DIR ]]; then
            [[ -z ${SLURMD_NODENAME:-} ]] ||
                ! printf '+%s\t%s\n' "$SLURMD_NODENAME" "a job there couldn't see $DB_DIR" | excluded_nodes_update 2> /dev/null ||
                fail "The job ran on $SLURMD_NODENAME, which can't see $DB_DIR, where the run's databases are, so gnoto's jobs avoid it from now on, until $(gnoto_command lint) finds it working."
            fail "The job ran on $(uname -n), which can't see $DB_DIR, where the run's databases are. Until its mounts are fixed, jobs that run there will fail the same way."
        fi
        entry=$(db_entry_for "$name")
        [[ -n $entry ]] || continue
        while [[ -n $(db_fetching "$entry") ]]; do
            (( waited > 0 )) || set_run_stage "Waiting for db:$entry to be fetched."
            waited=1
            sleep 30
        done
        [[ -e $(db_path "$name") ]] && continue
        [[ ! -e $DB_DIR/$entry.fetch.log ]] ||
            fail "$name isn't in $DB_DIR, as $(uname -n) sees it. If a fetch was making it, its log is $DB_DIR/$entry.fetch.log."
        fail "$name isn't in $DB_DIR, as $(uname -n) sees it, though it was there when the run was started."
    done <<< "$names"
}

# The _fetch job: fetches or builds one entry into place, under its lock
fetch_main() {
    local entry=${1:-} setup dir tmp status=0 job
    [[ -n $entry && $entry != /* && "/$entry/" != */../* ]] || fail "Usage: _fetch <database path>"
    setup=$(db_setup_for "$entry")
    [[ -n $setup ]] || fail "pipelines/databases.yaml has no way to fetch $entry."
    dir=$DB_DIR/$entry
    job=${SLURM_JOB_ID:-$$}
    [[ -n ${SLURM_JOB_ID:-} ]] || printf 'local - %s %s\n' "$(uname -n)" "$$" > "$dir.fetching"
    (
        flock -w 60 9 || fail "Another fetch of $entry holds its lock."
        if [[ -e $dir ]]; then
            log "$dir is already there."
            exit 0
        fi
        tmp=$dir.tmp.$job
        rm -rf "$tmp"
        mkdir "$tmp" || fail "Can't create $tmp."
        log "Fetching $entry with: $setup"
        # Unquoted: the setup line is a command and its arguments
        # shellcheck disable=SC2086
        if ! bash "$CODE_DIR/"$setup "$tmp"; then
            rm -rf "$tmp"
            fail "The fetch of $entry failed. Nothing was put in place."
        fi
        if [[ -f $tmp/manifest.yaml ]]; then
            mv -f "$tmp/manifest.yaml" "$dir.manifest.yaml" || fail "Can't move $entry's manifest into place."
        fi
        mv "$tmp" "$dir" || fail "Can't move $entry into place."
        chmod -R g+rwX "$dir" "$dir.manifest.yaml" 2> /dev/null || :
        log "Fetched $entry into $dir."
    ) 9>> "$dir.lock" || status=$?
    rm -f "$dir.fetching"
    return $status
}
