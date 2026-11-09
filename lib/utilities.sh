#
# utilities.sh - The log, warn and fail helpers every script reports through,
# how a message names a gnoto command, the uid helpers, and text formatting for
# the pages.
#
# Sourced by:  lib/env.sh
# Defines:     log, warn, fail, gnoto_command, escape_html, escape_url,
#              human_size, human_count, group_count, nextflow_cause,
#              nextflow_error_block, nextflow_task_job, nextflow_failed_task,
#              nextflow_session, is_valid_uid, derive_uid
# Requires:    state_present and state_set from lib/run_state.sh, for fail; openssl,
#              for derive_uid
# Env:         RUN_ID_SALT, from generated.yaml, for derive_uid; GNOTO_LAUNCHER,
#              from the launcher, and INSTALL_DIR, for gnoto_command
#
# log writes to stdout and warn and fail to stderr, so stdout stays free for a
# function's return value.

log() {
    echo "[$(date)] $*"
}

warn() {
    echo "[$(date)] WARNING: $*" >&2
}

# Also records the message as the run's .message, when there's a run state.
# Overwritten rather than appended: the first failure explains the run.
fail() {
    echo "[$(date)] ERROR: $*" >&2
    if state_present; then
        state_set message "$*" > /dev/null 2>&1 || true
    fi
    exit 1
}

# A gnoto command as a message tells the user to run it, so it runs as written:
# gnoto_command <command> [arguments]. The launcher says how to name itself,
# as gnoto when that's what gnoto on the user's PATH runs, or else by its path.
gnoto_command() {
    printf '%s' "${GNOTO_LAUNCHER:-$INSTALL_DIR/gnoto}"
    (( $# == 0 )) || printf ' %s' "$@"
}

# Makes a string safe in HTML text. Each ampersand in a replacement is
# backslashed, because bash 5.2 reads a bare one as the text that matched.
escape_html() {
    local s="$1"
    s="${s//&/\&amp;}"
    s="${s//</\&lt;}"
    s="${s//>/\&gt;}"
    s="${s//\"/\&quot;}"
    s="${s//\'/\&#39;}"
    printf '%s' "$s"
}

# Percent-encodes a path for an href, byte by byte. Slashes are left alone.
escape_url() {
    local LC_ALL=C
    local s="$1" out="" i c

    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        case "$c" in
            [A-Za-z0-9._~/-]) out+="$c" ;;
            *) out+=$(printf '%%%02X' "'$c") ;;
        esac
    done
    printf '%s' "$out"
}

# Bytes, in the units a download is read in
human_size() {
    LC_ALL=C awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB PB", unit, " ")
        i = 1
        while (b >= 1024 && i < 6) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, unit[i]
        else        printf "%.1f %s", b, unit[i]
    }'
}

# A count to at least two significant digits: 16600 is 17k, 4404860 is 4.4M.
# Under a thousand, it's written out. A shortened count carries its exact figure
# as \034<count>\035<shortened>\036, which the pages turn into a tooltip.
human_count() {
    LC_ALL=C awk -v n="$1" 'BEGIN {
        split("k M G", unit, " ")
        if (n < 1000) { printf "%d", n; exit }

        exact = sprintf("%d", n)
        i = 0
        while (n >= 1000 && i < 3) { n /= 1000; i++ }

        if (n < 9.95) {
            text = sprintf("%.1f", n)
        } else {
            text = sprintf("%d", n + 0.5)
            if (text + 0 >= 1000 && i < 3) {
                n /= 1000
                i++
                text = sprintf("%.1f", n)
            }
        }
        printf "\034%s\035%s%s\036", exact, text, unit[i]
    }'
}

# A count in full, grouped in threes: 2906 is 2,906
group_count() {
    LC_ALL=C awk -v n="$1" 'BEGIN {
        digits = sprintf("%d", n)
        out = ""
        while (length(digits) > 3) {
            out = "," substr(digits, length(digits) - 2) out
            digits = substr(digits, 1, length(digits) - 3)
        }
        printf "%s%s", digits, out
    }'
}

# Why a Nextflow run failed, in one line: the cause its log gives when the run
# aborted, or else the line after "Caused by:" in its console output, which a
# run that lets its other tasks finish first writes alone. Prints nothing when
# neither says: nextflow_cause <console output> <log>
nextflow_cause() {
    local cause
    cause=$(sed -n 's/.*Session aborted -- Cause: //p' "$2" 2> /dev/null | head -1) || cause=""
    [[ -n "$cause" ]] ||
        cause=$(awk '/^Caused by:/ { getline; sub(/^ +/, ""); print; exit }' "$1" 2> /dev/null) || cause=""
    printf '%s' "${cause:0:300}"
}

# Nextflow's report on the task that failed, from its console output: from
# "ERROR ~ Error executing process" to the task's work directory, at most 60
# lines. Its command's output and error come before the work directory, so this
# holds the task's own message. Prints nothing when there's no such report.
nextflow_error_block() {
    awk '
        /^ERROR ~ Error executing process/ { on = 1 }
        on { print; n++ }
        on && /^Work dir:/ { if ((getline line) > 0) print line; exit }
        n >= 60 { exit }
    ' "$1" 2> /dev/null
}

# The scheduler's job ID for the task in a work directory, from Nextflow's
# log: nextflow_task_job <work dir> <log>
nextflow_task_job() {
    awk -v want="workDir: $1" '
        {
            i = index($0, want)
            if (i == 0) next
            after = substr($0, i + length(want), 1)
            if (after != "" && after != ";" && after != " " && after != "]") next
            if (match($0, /jobId: [0-9]+/)) { print substr($0, RSTART + 7, RLENGTH - 7); exit }
        }
    ' "$2" 2> /dev/null
}

# The failing task's work directory, then its short name, such as
# MOTUS_PROFILE (db|mock), on two lines, from Nextflow's console output
nextflow_failed_task() {
    local dir name proc
    dir=$(awk '/^Work dir:/ { getline; sub(/^ +/, ""); print; exit }' "$1" 2> /dev/null) || dir=""
    name=$(sed -n "s/^ERROR ~ Error executing process > '\(.*\)'\$/\1/p" "$1" 2> /dev/null | head -1) || name=""
    proc=${name%% (*}
    printf '%s\n%s\n' "$dir" "${proc##*:}${name#"$proc"}"
}

# The session of the last Nextflow run in this directory whose command line
# holds a word, such as the pipeline it ran, from .nextflow/history, so a
# resumed run can name it with -resume: nextflow_session <word>. Several
# Nextflow runs can share a directory, as HUMAnN's does the main one's.
nextflow_session() {
    [[ -r .nextflow/history ]] || return 0
    awk -F'\t' -v word="$1" '
        index($7, word) && $6 ~ /^[0-9a-f-]+$/ { id = $6 }
        END { if (id != "") print id }
    ' .nextflow/history
}

# A uid names a run everywhere but Wrike: eight lowercase base32 characters.
# Checked before it reaches a path, because several paths built from one are
# deleted recursively.
is_valid_uid() {
    [[ "$1" =~ ^[a-z2-7]{8}$ ]]
}

# A Wrike task ID's uid. An HMAC, so knowing a task ID isn't enough to find
# where its results are published. Warns and returns rather than failing,
# because callers read it through $(...).
derive_uid() {
    if [[ -z "${RUN_ID_SALT:-}" ]]; then
        warn "RUN_ID_SALT isn't set, so there's no uid for task $1."
        return 1
    fi

    local uid
    uid=$(printf '%s' "$1" |
        openssl dgst -sha256 -hmac "$RUN_ID_SALT" -binary |
        base32 -w 0 |
        tr 'A-Z' 'a-z' |
        cut -c1-8)

    if ! is_valid_uid "$uid"; then
        warn "Derived an unusable uid from \"$1\"."
        return 1
    fi
    printf '%s' "$uid"
}
