#
# common.sh - What every Present script does around the pages: the run's facts
# from its state, site paths taken out of the results, the deliverables zip, and
# the progress page retired.
#
# Sourced by:  present/ampliseq.sh, taxprofiler.sh and biobakery.sh, and
#              present/progress.sh, and test/present/present-test.sh; and
#              outputs_published in lib/outputs.sh, for present_scrub
# Defines:     present_run_id, present_title, present_sample_count,
#              present_version, present_completed, present_expires,
#              present_site_paths, present_redact, present_site_path_files,
#              present_scrub, present_check_published, present_retire_progress,
#              bundle_name, bundle_href, bundle_zip, bundle_build, bundle_add
# Requires:    zip, GNU find, grep and awk; state_get from lib/run_state.sh, and
#              is_valid_uid, log and warn from lib/utilities.sh
# Env:         DATA_DIR, DB_DIR, CODE_DIR, INSTALL_DIR, NEXTFLOW_CONFIG,
#              EXPIRATION_NOTICE_DAYS and HOME, from lib/env.sh
#
# Runs from the run directory, as every step does.

# The run's uid, from the state or the directory's name. Fails when it isn't
# one, because it names the zip.
present_run_id() {
    local uid
    uid=$(state_get run_id)
    uid=${uid:-${PWD##*/}}
    is_valid_uid "$uid" || return 1
    printf '%s' "$uid"
}

# The title that heads every page: one line, or a generic heading
present_title() {
    local title
    title=$(state_get title)
    title=${title%%$'\n'*}
    printf '%s' "${title:-Sequencing results}"
}

# The sample count, or nothing when the run recorded none
present_sample_count() {
    local count
    count=$(state_get samples.count)
    [[ $count =~ ^[0-9]+$ ]] && printf '%s' "$count"
    return 0
}

# What ran the analysis, for the foot of each page: the version the job asked
# for, a commit cut to 12 characters, and a working tree said so
present_version() {
    local version
    version=$(state_get version)
    [[ -n $version ]] || version=$(state_get pipeline)
    if [[ $version =~ ^(.*@)([0-9a-f]{40})$ ]]; then
        version=${BASH_REMATCH[1]}${BASH_REMATCH[2]:0:12}
    fi
    [[ $(state_get dev) == true ]] && version+=" (working tree)"
    printf '%s' "$version"
}

# When Compute finished, for a reader: Nov 6, 2026. Today, before it has.
present_completed() {
    local finished
    finished=$(state_get stages.compute)
    date -u -d "${finished:-now}" '+%b %-d, %Y' 2> /dev/null || date -u '+%b %-d, %Y'
}

# The date the results are removed, YYYY-MM-DD, or nothing for a run kept for
# good. The followup writes <data_dir>/expiry/<uid> when the run ends, so a
# later Present reads that; before then it's worked out the way the followup
# will: retention from now, and never sooner than expiration_notice_days.
present_expires() {
    local uid=$1 retention months expires floor file=$DATA_DIR/expiry/$1

    if [[ -r $file ]]; then
        expires=$(grep -oE -m 1 '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$file")
        [[ -n $expires ]] && printf '%s' "$expires"
        return 0
    fi
    retention=$(state_get retention)
    [[ $retention =~ ^([0-9]+)\ Months?$ ]] || return 0
    months=${BASH_REMATCH[1]}
    expires=$(date -u -d "+$months months" +%F) || return 0
    floor=$(date -u -d "+${EXPIRATION_NOTICE_DAYS:-14} days" +%F) || return 0
    [[ $floor > $expires ]] && expires=$floor
    printf '%s' "$expires"
}

# The site paths nothing published may hold, a line each: the path, what it
# becomes before a slash, and what it becomes alone. The run directory reads as
# ".", the code as gnoto:, databases as db:, and the rest of the data directory
# as data:. The install's launcher, which a run's message can name in a command,
# reads as gnoto. Each path is listed as the shell spells it and with its
# symlinks resolved, because Nextflow writes the resolved one, and longest
# first, so a path inside another is replaced as the inner one.
present_site_paths() {
    local spec path real
    {
        for spec in "$PWD|./|." "${CODE_DIR:-}|gnoto:|gnoto:" "${INSTALL_DIR:-}|gnoto:|gnoto:" \
            "${INSTALL_DIR:+$INSTALL_DIR/gnoto}|gnoto:gnoto/|gnoto" \
            "${DB_DIR:-}|db:|db:" "${DATA_DIR:-}|data:|data:" "${HOME:-}|~/|~"; do
            path=${spec%%|*}
            path=${path%/}
            [[ $path == /?* ]] || continue
            printf '%s\t%s\n' "$path" "${spec#*|}"
            real=$(realpath -m -- "$path" 2> /dev/null) || continue
            [[ $real != "$path" ]] && printf '%s\t%s\n' "$real" "${spec#*|}"
        done
        if [[ ${NEXTFLOW_CONFIG:-} == /?* ]]; then
            printf '%s\t%s\n' "$NEXTFLOW_CONFIG" "core.nextflow_config|core.nextflow_config"
        fi
    } | awk -F'\t' '!seen[$1]++ { printf "%d\t%s\t%s\n", length($1), $1, $2 }' |
        sort -t$'\t' -k1,1nr | cut -f2- | tr '|' '\t'
}

# Copies stdin to stdout with every site path replaced. A path counts only as a
# whole: not when a name character comes before it or right after it, so
# /data doesn't touch /database or /mnt/data.
present_redact() {
    GNOTO_SITE_PATHS=$(present_site_paths) LC_ALL=C awk '
        BEGIN {
            n = split(ENVIRON["GNOTO_SITE_PATHS"], lines, "\n")
            for (i = 1; i <= n; i++) {
                if (split(lines[i], f, "\t") < 3) continue
                k++
                from[k] = f[1]
                slash[k] = f[2]
                bare[k] = f[3]
            }
        }
        function swap(s, i,   out, p, len, before, after) {
            out = ""
            len = length(from[i])
            while ((p = index(s, from[i])) > 0) {
                before = p > 1 ? substr(s, p - 1, 1) : ""
                after = substr(s, p + len, 1)
                if (before ~ /[A-Za-z0-9._-]/ || after ~ /[A-Za-z0-9._-]/) {
                    out = out substr(s, 1, p + len - 1)
                    s = substr(s, p + len)
                } else if (after == "/") {
                    out = out substr(s, 1, p - 1) slash[i]
                    s = substr(s, p + len + 1)
                } else {
                    out = out substr(s, 1, p - 1) bare[i]
                    s = substr(s, p + len)
                }
            }
            return out s
        }
        {
            line = $0
            for (i = 1; i <= k; i++) {
                if (index(line, from[i])) line = swap(line, i)
            }
            print line
        }
    '
}

# The files under the directories given that hold a site path, a line each.
# Text and binary alike, read as bytes, symlinks followed.
present_site_path_files() {
    local args=() path
    while IFS=$'\t' read -r path _; do
        args+=(-e "$path")
    done < <(present_site_paths)
    (( ${#args[@]} > 0 )) || return 0
    LC_ALL=C grep -RlaF "${args[@]}" -- "$@" 2> /dev/null
}

# Takes the site paths out of every text file in the results: the reports and
# logs the pipeline wrote, such as Nextflow's execution report and MultiQC's
# command line. A file is rewritten beside itself and moved over, keeping its
# mode, so a link into work/ becomes a file and work/ is left alone.
present_scrub() {
    local results=$1 file count=0
    while IFS= read -r file; do
        if LC_ALL=C grep -qI . "$file" 2> /dev/null &&
            present_redact < "$file" > "$file.scrub" &&
            chmod --reference="$file" "$file.scrub" 2> /dev/null &&
            mv -f "$file.scrub" "$file"; then
            count=$((count + 1))
        else
            rm -f "$file.scrub"
        fi
    done < <(present_site_path_files "$results")
    log "Took this site's paths out of $count file(s) in $results."
}

# Warns about every file still holding a site path, which would be published.
# The binary ones can't be rewritten, so a prune.conf should remove them.
present_check_published() {
    local files
    files=$(present_site_path_files "$@")
    [[ -z $files ]] && return 0
    warn "These files still name this site's paths, and would be published:"$'\n'"$files"
    return 1
}

# Leaves progress.json saying final, which sends a browser still on the
# progress page to the dashboard that replaced it
present_retire_progress() {
    printf '{"state":"final"}\n' > "$1/progress.json"
}

# The zip's name: the title cut down to the characters a file name should
# carry, then the uid, so it can be told apart in a downloads folder and still
# be quoted back. A title with nothing left leaves the uid alone.
bundle_name() {
    local uid=$1 slug
    slug=$(printf '%s' "${2:-}" | LC_ALL=C tr -cs '[:alnum:]' '-')
    slug=${slug#-}
    slug=${slug%-}
    slug=${slug:0:60}
    slug=${slug%-}
    printf '%s%s.zip' "${slug:+${slug}_}" "$uid"
}

# Where the pages link the zip: bundle_href <zip> <uid>. Its address on the
# Globus collection or S3, wherever Publish puts it, or else beside results/.
bundle_href() {
    case $(publish_destination) in
        globus) globus_run_url "$2" "$1" ;;
        s3) printf "%s%s" "$(s3_run_url "$2")" "$(escape_url "$1")" ;;
        *) printf "../%s" "$1" ;;
    esac
}

# Zips paths, relative to the run directory, at a compression level, each
# under one folder named after the zip, so it unpacks into that folder:
# Title_uid.zip holds Title_uid/results/... Read through a link to the run
# directory by that name, made in a temporary directory. zip stores what a
# symlink points at, so staged reads go in as data. Prints zip's complaint.
bundle_zip() {
    local archive=$1 top=$2 level=$3 stage output status
    shift 3
    [[ $archive == /* ]] || archive=$PWD/$archive
    stage=$(mktemp -d "${TMPDIR:-/tmp}/gnoto-zip.XXXXXX") || return 1
    if ! output=$(ln -s "$PWD" "$stage/$top" 2>&1); then
        printf '%s' "$output"
        rmdir "$stage"
        return 1
    fi
    set -- "${@#./}"
    output=$(cd "$stage" && zip -r -q "$level" "$archive" "${@/#/$top/}" 2>&1)
    status=$?
    rm -f "$stage/$top"
    rmdir "$stage"
    (( status == 0 )) || printf '%s' "$output"
    return $status
}

# Builds the zip from scratch as <name>.tmp, beside its final name: each part
# is <dir> or <dir>|<level>. Reads are stored as they are (-0), being gzipped
# already, and the rest is deflated. Removes any zip an earlier Present left,
# which may carry another title.
bundle_build() {
    local name=$1 uid=$2 part level
    shift 2
    rm -f -- "$name.tmp" ./*_"$uid".zip "$uid.zip"
    for part in "$@"; do
        level=-9
        [[ $part == *'|'* ]] && level=${part#*|}
        bundle_zip "$name.tmp" "${name%.zip}" "$level" "${part%%|*}" || return 1
    done
}

# Adds paths to the zip being built, replacing what it holds under those names
bundle_add() {
    local name=$1
    shift
    (( $# > 0 )) || return 0
    bundle_zip "$name.tmp" "${name%.zip}" -9 "$@"
}
