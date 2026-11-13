#
# systemd.sh - gnoto config systemd: installs gnoto's systemd units as user
# units of the account that runs it; and lint's checks of them.
#
# Sourced by:  lib/config.sh and lib/lint.sh
# Defines:     config_systemd_step, lint_systemd, systemd_units
# Requires:    systemctl and loginctl through their stand-ins; generated_set
#              and config_confirm from lib/config.sh; lint_ok, lint_warn and
#              lint_fail from lib/lint.sh
#
# The units, from the templates beside this file:
#
#   gnoto-daily.timer     always, so an install with neither Wrike nor S3 still
#                         has its results expire
#   gnoto-wrike.timer     with Wrike, unless wrike.poll_minutes is 0
#   gnoto-listener        with SQS, and Wrike or Globus
#
# They run the install directory's launcher, which hands each command to the
# current version, so an upgrade needs no reinstall unless a template changed,
# which lint reports. A user unit doesn't read the login shell, so each gets
# the PATH holding Apptainer and Slurm's commands, and SLURM_CONF, as this
# install found them.
#
# Units and linger belong to one host. generated.yaml records it, as
# systemd.host, with the account, and each unit does nothing on any other.
# This refuses another host unless given --move. The account that owns the
# units runs this from its own login session, since systemctl --user needs that
# session's bus, which sudo -u doesn't give.

SYSTEMD_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user

# The units this install wants, a file a line
systemd_units() {
    echo gnoto-daily.service
    echo gnoto-daily.timer
    if wrike_on && (( ${WRIKE_POLL_MINUTES:-5} > 0 )); then
        echo gnoto-wrike.service
        echo gnoto-wrike.timer
    fi
    if listener_on; then
        echo gnoto-listener.service
    fi
}

# A unit as installed: its template, filled in
systemd_render() {
    local path conf=""
    path=${APPTAINER_BIN_DIR:-${GNOTO_FOUND_APPTAINER_BIN_DIR:-}}
    if [[ ${SLURM_ENABLED:-false} == true ]]; then
        path+=":${SLURM_BIN_DIR:-${GNOTO_FOUND_SLURM_BIN_DIR:-}}"
        conf=${SLURM_CONF:-${GNOTO_FOUND_SLURM_CONF:-}}
    fi
    path=${path#:}
    path=${path%:}
    path+="${path:+:}/usr/local/bin:/usr/bin:/bin"
    LAUNCHER=$INSTALL_DIR/gnoto UNIT_PATH=$path POLL=${WRIKE_POLL_MINUTES:-5} \
        CONF=${conf:+Environment=SLURM_CONF=$conf} UNIT=$1 awk '
        BEGIN { print "# Installed by gnoto config systemd, from service/systemd/" ENVIRON["UNIT"] ". Run that again rather than editing this." }
        /^#/ { next }
        !body && /^$/ { next }
        { body = 1; gsub(/__LAUNCHER__/, ENVIRON["LAUNCHER"]); gsub(/__PATH__/, ENVIRON["UNIT_PATH"])
          gsub(/__POLL_MINUTES__/, ENVIRON["POLL"]) }
        /^__SLURM_CONF__$/ { if (ENVIRON["CONF"] != "") print ENVIRON["CONF"]; next }
        { print }' "$CODE_DIR/service/systemd/$1"
}

# gnoto config systemd [--move] [--dry-run] [--yes]
config_systemd_step() {
    local host user unit wanted installed plan=() old=""
    host=$(uname -n)
    user=$(id -un)
    if [[ -n ${SYSTEMD_HOST:-} && $SYSTEMD_HOST != "$host" ]]; then
        [[ -n ${CONFIG_MOVE:-} ]] ||
            fail "gnoto's units are installed on $SYSTEMD_HOST, as ${SYSTEMD_USER:-another account}. To move them here, add --move, then disable them there."
        old=$SYSTEMD_HOST
        plan+=("Move gnoto's units from $SYSTEMD_HOST to $host, where they then run. Those on $SYSTEMD_HOST do nothing from then on")
    fi
    if [[ -n ${SYSTEMD_USER:-} && $SYSTEMD_USER != "$user" && -z $old ]]; then
        [[ -n ${CONFIG_MOVE:-} ]] ||
            fail "gnoto's units belong to $SYSTEMD_USER. To give them to $user, add --move, then disable them as $SYSTEMD_USER."
        plan+=("Give gnoto's units to $user, from $SYSTEMD_USER")
    fi
    wanted=$(systemd_units)
    for unit in $wanted; do
        if [[ ! -f $SYSTEMD_DIR/$unit ]]; then
            plan+=("Install $unit in $SYSTEMD_DIR")
        elif [[ $(systemd_render "$unit") != "$(cat "$SYSTEMD_DIR/$unit")" ]]; then
            plan+=("Update $unit in $SYSTEMD_DIR")
        fi
    done
    for unit in gnoto-daily.service gnoto-daily.timer gnoto-wrike.service gnoto-wrike.timer gnoto-listener.service; do
        if [[ -f $SYSTEMD_DIR/$unit ]] && ! grep -qx "$unit" <<< "$wanted"; then
            plan+=("Disable and remove $unit, which this install no longer needs")
        fi
    done
    installed=$(loginctl show-user "$user" --property=Linger 2> /dev/null) || installed=""
    [[ $installed == Linger=yes ]] || plan+=("Turn on linger for $user, so the units run while $user isn't logged in")
    if (( ${#plan[@]} == 0 )); then
        echo "gnoto's units are installed on $host, as $user, and up to date."
    else
        config_confirm "on $host, for $user" "${plan[@]}" || exit 0
        mkdir -p "$SYSTEMD_DIR" || fail "Can't create $SYSTEMD_DIR."
        for unit in gnoto-daily.service gnoto-daily.timer gnoto-wrike.service gnoto-wrike.timer gnoto-listener.service; do
            if [[ -f $SYSTEMD_DIR/$unit ]] && ! grep -qx "$unit" <<< "$wanted"; then
                systemctl --user disable --now "$unit" > /dev/null 2>&1 || :
                rm -f "$SYSTEMD_DIR/$unit"
            fi
        done
        for unit in $wanted; do
            systemd_render "$unit" > "$SYSTEMD_DIR/$unit" || fail "Can't write $SYSTEMD_DIR/$unit."
        done
        systemctl --user daemon-reload || fail "systemctl --user couldn't reload. Run this from $user's own login session, not through sudo -u."
        generated_set systemd.host "$host"
        generated_set systemd.user "$user"
        for unit in $wanted; do
            [[ $unit == *.timer || $unit == gnoto-listener.service ]] || continue
            systemctl --user enable "$unit" > /dev/null 2>&1 || fail "systemctl couldn't enable $unit."
            systemctl --user restart "$unit" || fail "systemctl couldn't start $unit."
        done
        if [[ $installed != Linger=yes ]]; then
            loginctl enable-linger "$user" ||
                warn "Linger couldn't be turned on for $user, so the units stop when $user logs out. Ask an admin to run: loginctl enable-linger $user"
        fi
        [[ -z $old ]] || echo "On $old, as ${SYSTEMD_USER:-the old account}, disable the old units: systemctl --user disable --now gnoto-daily.timer gnoto-wrike.timer gnoto-listener.service"
    fi
    LINT_FAILS=0
    lint_systemd
    (( LINT_FAILS == 0 )) || fail "gnoto's units aren't ready, as above."
}

# lint's checks: where the units are, whether they're running, and whether
# this version's templates differ from what's installed, as after an upgrade
lint_systemd() {
    local unit age state changed=()
    if [[ -z ${SYSTEMD_HOST:-} ]]; then
        lint_warn "systemd: gnoto's units aren't installed, so no results expire and Wrike isn't scanned. $(gnoto_command config systemd) installs them"
        return 0
    fi
    age=$(heartbeat_age daily 2> /dev/null) || age=""
    if [[ $(uname -n) != "$SYSTEMD_HOST" || $(id -un) != "${SYSTEMD_USER:-}" ]]; then
        if [[ -n $age ]] && (( age < 2 * 86400 )); then
            lint_ok "systemd: units on $SYSTEMD_HOST, as ${SYSTEMD_USER:-}. The daily check ran $(( age / 3600 )) h ago"
        elif [[ -n $age ]]; then
            lint_warn "systemd: units on $SYSTEMD_HOST, as ${SYSTEMD_USER:-}, and the daily check hasn't run for $(( age / 86400 )) days"
        else
            lint_warn "systemd: units on $SYSTEMD_HOST, as ${SYSTEMD_USER:-}, and the daily check has never run"
        fi
        return 0
    fi
    for unit in $(systemd_units); do
        if [[ ! -f $SYSTEMD_DIR/$unit ]]; then
            changed+=("$unit, missing")
        elif [[ $(systemd_render "$unit") != "$(cat "$SYSTEMD_DIR/$unit")" ]]; then
            changed+=("$unit")
        fi
        [[ $unit == *.timer || $unit == gnoto-listener.service ]] || continue
        state=$(systemctl --user is-active "$unit" 2> /dev/null) || :
        [[ $state == active ]] || lint_fail "systemd: $unit is ${state:-not running}. $(gnoto_command config systemd) starts it"
    done
    if (( ${#changed[@]} > 0 )); then
        lint_warn "systemd: this version's units differ from those installed: $(lint_list "${changed[@]}"). $(gnoto_command config systemd) updates them"
    else
        lint_ok "systemd: units on $SYSTEMD_HOST, as $SYSTEMD_USER, up to date"
    fi
}

# A heartbeat's age in seconds, or nothing when there's none: heartbeat_age
# <unit>, from <data_dir>/logs/<unit>.heartbeat
heartbeat_age() {
    local beat
    beat=$(yq -r '.beat_utc // ""' "$DATA_DIR/logs/$1.heartbeat" 2> /dev/null) || return 0
    [[ -n $beat ]] && echo $(( $(date -u +%s) - $(date -u -d "$beat" +%s) ))
    return 0
}
