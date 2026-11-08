#!/bin/bash
#
# config.sh - Checks that gnoto runs without config.yaml, that gnoto init writes
# only an apptainer section, and that gnoto config lists the sections, adds one
# at a time, asks for one's settings or takes them as arguments, and turns one
# on and off, in the test bed.
#
# Run by:  a developer, as alice, on a copy of the install with no config.yaml:
#          docker exec gnoto-testbed runuser -l alice -c 'bash /srv/configtest/gnoto/test/testbed/checks/config.sh'
#
# The host side, on a copy testbed.sh install made, which is a clone. It links
# the image from /data/gnoto/images into the copy's default data directory.
# gnoto config's answers are piped through script, which gives it a terminal.

set -u
umask 002

INSTALL=$(cd "$(dirname "$0")/../../.." && pwd)
GNOTO=$INSTALL/gnoto
CONFIG=$INSTALL/config.yaml
FAILED=0

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Runs gnoto with the arguments after --, answering with the lines before it
answering() {
    local answers=()
    while [[ $1 != -- ]]; do answers+=("$1"); shift; done
    shift
    printf '%s\n' "${answers[@]}" | script -qec "$GNOTO $*" /dev/null
}

suggestions() {
    grep -o '\[[^]]*\]' "$1" | tr '\n' ' ' | sed 's/ $//'
}

section() {
    $GNOTO exec yq -o=json -I=0 ".$1" "$CONFIG"
}

[[ ! -e $CONFIG ]] || { echo "Remove $CONFIG first"; exit 1; }
mkdir -p "$INSTALL/data/images"
ln -sfn "/data/gnoto/images/$(cat "$INSTALL/IMAGE")" "$INSTALL/data/images/"

# The copy is a clone, so its first command makes its own commit current
HEAD=$(git -C "$INSTALL" rev-parse HEAD)
rm -rf "$INSTALL/data/current" "$INSTALL/data/versions"
check "the first command makes the clone's commit current" "$HEAD" \
    "$($GNOTO exec true > first.log 2>&1; sed -n 1p "$INSTALL/data/current" 2> /dev/null)"
check "and runs from its copy in versions/" "$INSTALL/data/versions/$HEAD" \
    "$($GNOTO exec printenv GNOTO_CODE_DIR 2> /dev/null)"

check "without config.yaml: defaults, and Slurm found on PATH" "false $INSTALL/data $INSTALL/data/db /usr/bin" \
    "$($GNOTO exec bash -c 'echo $SLURM_ENABLED $DATA_DIR $DB_DIR $GNOTO_FOUND_SLURM_BIN_DIR' 2>&1)"
check "gnoto config lists the sections" "core apptainer slurm wrike aws globus" \
    "$($GNOTO config | awk '{ print $1 }' | tr '\n' ' ' | sed 's/ $//')"
check "a section off a terminal stops" "yes" \
    "$($GNOTO config slurm < /dev/null 2>&1 | grep -q 'run it from a terminal' && echo yes)"
check "and nothing has written config.yaml" "no" "$([[ -e $CONFIG ]] && echo yes || echo no)"

$GNOTO init --apptainer=/usr/bin/apptainer > init.log 2>&1
check "init writes only the apptainer section" '{"apptainer":{"enabled":true,"bin_dir":"/usr/bin"}}' "$(section '')"
check "at 660, in alice's own group" "660 alice" "$(stat -c '%a %G' "$CONFIG")"

$GNOTO config slurm --on > slurm-on.log 2>&1
check "slurm --on adds the slurm section with what it found" \
    '{"enabled":true,"bin_dir":"/usr/bin","conf":"","partition":"main","account":"","max_cpus":6,"max_memory":"23.GB","max_time":"168.h","job_time":"","min_tmp":"50.GB"}' \
    "$(section slurm)"
check "and says so" "yes" "$(grep -q '^slurm is on' slurm-on.log && echo yes || cat slurm-on.log)"
check "and the image reads it" "true 6 main" "$($GNOTO exec bash -c 'echo $SLURM_ENABLED $SLURM_MAX_CPUS $SLURM_PARTITION')"
$GNOTO config slurm --off > /dev/null 2>&1
check "slurm --off keeps its settings" "false 6" "$($GNOTO exec bash -c 'echo $SLURM_ENABLED $SLURM_MAX_CPUS')"
$GNOTO config slurm --on > /dev/null 2>&1
check "slurm --on again" "true" "$($GNOTO exec bash -c 'echo $SLURM_ENABLED')"
$GNOTO config slurm --max_cpus=4 --max_memory=14.GB --max_time 4.h < /dev/null > slurm-args.log 2>&1
check "slurm settings as arguments, off a terminal" "true 4 14.GB 4.h" \
    "$($GNOTO exec bash -c 'echo $SLURM_ENABLED $SLURM_MAX_CPUS $SLURM_MAX_MEMORY $SLURM_MAX_TIME')"
check "and says so" "yes" "$(grep -q '^slurm is on' slurm-args.log && echo yes || cat slurm-args.log)"
check "an unknown setting is refused" "yes" \
    "$($GNOTO config slurm --max_cpu=4 2>&1 | grep -q 'slurm has no setting max_cpu. Its settings are bin_dir, conf' && echo yes)"

# apptainer: where init said, and one bind, added to the section init wrote
answering "" /srv -- config apptainer > apptainer.log 2>&1
check "config apptainer: suggestions" "[/usr/bin] [none]" "$(suggestions apptainer.log)"
check "config apptainer: answers" '{"enabled":true,"bin_dir":"/usr/bin","binds":"/srv"}' "$(section apptainer)"
check "apptainer can't be turned off" "yes" \
    "$($GNOTO config apptainer --off 2>&1 | grep -q "can't be turned off" && echo yes)"

# core, asked for from nothing: every suggestion
answering "" "" "" "" "" "" -- config core > core.log 2>&1
check "config core: suggestions" "[$INSTALL/data] [$INSTALL/data/db] [none] [none] [14] [14]" "$(suggestions core.log)"
check "config core: the section" \
    "{\"data_dir\":\"$INSTALL/data\",\"db_dir\":\"$INSTALL/data/db\",\"input_roots\":\"\",\"nextflow_config\":\"\",\"expiration_notice_days\":14,\"keep_run_days\":14}" \
    "$(section core)"
check "core has no on or off" "yes" "$($GNOTO config core --on 2>&1 | grep -q 'core is always on' && echo yes)"

# slurm asked for again, suggesting its current values, with a job time
answering "" "" "" "" "" "" "" 2-00:00:00 "" -- config slurm > slurm.log 2>&1
check "config slurm: suggestions" "[/usr/bin] [none] [main] [none] [4] [14.GB] [4.h] [none] [50.GB]" "$(suggestions slurm.log)"
check "config slurm: changed in place" "2-00:00:00 true" "$($GNOTO exec yq '.slurm.job_time + " " + (.slurm.enabled | tostring)' "$CONFIG")"

# wrike off, from nothing, then asked for
$GNOTO config wrike --off > wrike-off.log 2>&1
check "wrike --off adds it off" '{"enabled":false,"api_token":"","webhook_secret":"","poll_minutes":5}' "$(section wrike)"
check "and says how to turn it on" "yes" "$(grep -q 'gnoto config wrike --on' wrike-off.log && echo yes)"
answering t0ken "" "" -- config wrike > wrike.log 2>&1
check "config wrike: a secret, still off" "t0ken false" \
    "$($GNOTO exec yq '.wrike.api_token + " " + (.wrike.enabled | tostring)' "$CONFIG")"

# globus, from nothing, with settings as arguments: on, since --off isn't given
$GNOTO config globus --run_prefix="lab runs" --dir= < /dev/null > globus.log 2>&1
check "globus with settings adds it on" \
    '{"enabled":true,"dir":"","uuid":"","url":"","run_prefix":"lab runs","cli_client_id":"","cli_client_secret":""}' \
    "$(section globus)"

check "only the sections asked for, in that order" "apptainer slurm core wrike globus" \
    "$($GNOTO exec yq 'keys | join(" ")' "$CONFIG")"
check "still 660, in alice's own group" "660 alice" "$(stat -c '%a %G' "$CONFIG")"
echo "      config.yaml:"
sed 's/^/        /' "$CONFIG"

exit $FAILED
