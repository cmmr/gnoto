#
# daily.sh - What gnoto's systemd units run: the daily timer's work, the poll
# timer's scan, and the heartbeats and host check they share with the listener.
#
# Sourced by:  lib/main.sh, for _daily, _poll and _listen
# Defines:     service_start, service_beat, daily_main, poll_main,
#              health_write
# Requires:    the settings and helpers from lib/env.sh; wrike_replay from
#              service/wrike/api.sh; expire_check from service/expire.sh;
#              wrike_scan from service/wrike/task_handler.sh; lint_config from
#              lib/lint.sh
#
# Units belong to one host, which gnoto config systemd records in
# generated.yaml as systemd.host. A unit started anywhere else does nothing,
# so after a move the old host's units can't race the new one's. Each writes a
# heartbeat in <data_dir>/logs/, which any user's gnoto status reads, though
# the units belong to one account, and logs to <data_dir>/logs/<unit>.log as
# well as to the journal.
#
# The daily timer, in order: replays the Wrike changes that failed; runs the
# expiry check, which copies Wrike's dates and removes what's due; runs lint
# and writes its summary to logs/health.yaml, which gnoto status shows; and
# rotates the logs.

LOG_ROTATE_BYTES=$((10 * 1024 * 1024))
LOG_KEEP=3

# service_start <name>: checks this is the units' host, says so in the log,
# and sends what follows to logs/<name>.log too. Returns 1 elsewhere.
service_start() {
    local name=$1 host
    host=$(uname -n)
    if [[ -n ${SYSTEMD_HOST:-} && $SYSTEMD_HOST != "$host" ]]; then
        log "gnoto's units belong to $SYSTEMD_HOST, not $host, so this $name does nothing."
        return 1
    fi
    mkdir -p "$DATA_DIR/logs" && chmod 2775 "$DATA_DIR/logs" 2> /dev/null || :
    exec > >(tee -a "$DATA_DIR/logs/$name.log") 2>&1
    SERVICE_STARTED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    service_beat "$name"
}

# The heartbeat: when the service started and last beat, where, and as whom
service_beat() {
    local file=$DATA_DIR/logs/$1.heartbeat
    printf 'host: "%s"\nuser: "%s"\npid: %s\nstarted_utc: "%s"\nbeat_utc: "%s"\n' "$(uname -n)" "$(id -un)" \
        "$$" "${SERVICE_STARTED:-}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$file.tmp" 2> /dev/null &&
        chmod 664 "$file.tmp" && mv -f "$file.tmp" "$file" 2> /dev/null || :
}


# Seconds as days, hours or minutes
age_words() {
    local s=$1
    if (( s >= 86400 )); then echo "$((s / 86400)) days"
    elif (( s >= 3600 )); then echo "$((s / 3600)) h"
    else echo "$((s / 60)) min"
    fi
}

# lint's checks of the settings, summed up an integration a line in
# logs/health.yaml: its worst result, and that result's message
health_write() {
    local out file=$DATA_DIR/logs/health.yaml tmp age started
    out=$( (lint_config) 2>&1) || :
    tmp=$(mktemp "$file.XXXXXX") || return 1
    {
        printf 'checked_utc: "%s"\nintegrations:\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        awk '
            /^  (OK|WARN|FAIL) / {
                label = $1; sub(/^  (OK|WARN|FAIL) +/, "")
                name = $0; sub(/[.:].*/, "", name)
                if (name !~ /^(slurm|wrike|s3|sqs|globus|systemd)$/) next
                rank = (label == "FAIL") ? 3 : (label == "WARN") ? 2 : 1
                if (!(name in worst)) order[++n] = name
                if (rank > worst[name]) { worst[name] = rank; text[name] = $0; sub(/^[^:]*: */, "", text[name]) }
            }
            END {
                split("ok warn fail", word, " ")
                for (i = 1; i <= n; i++) {
                    gsub(/"/, "\\\"", text[order[i]])
                    printf "  - {name: \"%s\", status: \"%s\", message: \"%s\"}\n", order[i], word[worst[order[i]]], text[order[i]]
                }
            }' <<< "$out"
        if sqs_on && wrike_on; then
            age=$(heartbeat_age listener)
            started=$(yq -r '.started_utc // ""' "$DATA_DIR/logs/listener.heartbeat" 2> /dev/null)
            if [[ -n $age ]] && (( age < 300 )); then
                printf '  - {name: "listener", status: "ok", message: "active for %s"}\n' \
                    "$(age_words $(( $(date -u +%s) - $(date -u -d "${started:-now}" +%s) )))"
            elif [[ -n $age ]]; then
                printf '  - {name: "listener", status: "fail", message: "no heartbeat for %s"}\n' "$(age_words "$age")"
            else
                printf '  - {name: "listener", status: "fail", message: "never started"}\n'
            fi
        fi
    } > "$tmp" && chmod 664 "$tmp" && mv -f "$tmp" "$file"
}

# Keeps each log under LOG_ROTATE_BYTES, with LOG_KEEP older copies
logs_rotate() {
    local file i
    for file in "$DATA_DIR"/logs/*.log; do
        [[ -f $file ]] && (( $(stat -c %s "$file") > LOG_ROTATE_BYTES )) || continue
        rm -f "$file.$LOG_KEEP"
        for (( i = LOG_KEEP - 1; i >= 1; i-- )); do
            [[ ! -e $file.$i ]] || mv -f "$file.$i" "$file.$((i + 1))"
        done
        cp "$file" "$file.1" && : > "$file"
    done
}

daily_main() {
    local counts
    service_start daily || return 0
    log "The daily check starts."
    if wrike_on; then
        counts=$(wrike_replay)
        log "Wrike: tried ${counts% *} waiting changes again, and ${counts#* } went through."
    fi
    expire_check
    health_write || warn "Couldn't write $DATA_DIR/logs/health.yaml."
    logs_rotate
    service_beat daily
    log "The daily check is done."
}

poll_main() {
    service_start wrike || return 0
    wrike_scan
    service_beat wrike
}
