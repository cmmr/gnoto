#!/bin/bash
#
# lib-test.sh - Tests lib/env.sh and the helpers it sources, against fixture
# configs, in the real image.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/lib/lib-test.sh
# Requires:  the gnoto image, and network access for one image pull
#
# Each case sources env.sh in a subshell with GNOTO_INSTALL_DIR pointing at a
# scratch install directory, so config.yaml can vary.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "$GNOTO_DATA_DIR/test-lib.XXXXXX")
FAILED=0
trap 'rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Makes an install directory holding config.yaml, and generated.yaml if given
install() {
    local dir=$WORK/$1
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/config.yaml"
    if [[ -n ${3:-} ]]; then
        mkdir -p "$dir/data"
        printf '%s\n' "$3" > "$dir/data/generated.yaml"
    fi
    echo "$dir"
}

# Runs a command with env.sh loaded from an install directory
with_env() {
    local dir=$1
    shift
    (GNOTO_INSTALL_DIR=$dir; source "$CODE/lib/env.sh" || exit 1; eval "$*")
}

DIR=$(install defaults 'core:
  data_dir: ""')
check "data_dir default" "$DIR/data" "$(with_env "$DIR" 'echo $DATA_DIR')"
check "db_dir default" "$DIR/data/db" "$(with_env "$DIR" 'echo $DB_DIR')"
check "defaults from lib/config/" "false true 14 14 5" \
    "$(with_env "$DIR" 'echo $SLURM_ENABLED $APPTAINER_ENABLED $KEEP_RUN_DAYS $EXPIRATION_NOTICE_DAYS $WRIKE_POLL_MINUTES')"
check "run prefixes default" "gnoto gnoto" "$(with_env "$DIR" 'echo $AWS_RUN_PREFIX $GLOBUS_RUN_PREFIX')"
check "NXF_HOME" "$DIR/data/nextflow" "$(with_env "$DIR" 'echo $NXF_HOME')"
check "umask" "0002" "$(with_env "$DIR" 'umask')"

DIR=$(install values 'core:
  data_dir: "/elsewhere"   # a comment
  path: "/not/a/path"
slurm:
  max_cpus: 32
  partition: "short"
apptainer:
  binds: "/a,/b"
wrike:
  api_token: "t0k'"'"'en"
aws:
  region: "us-east-1"
  sqs_queue_url: "from-config"
PATH: "bad"' 'core:
  run_id_salt: "salty"
wrike:
  ids:
    folder: "F1"
aws:
  sqs_queue_url: "from-generated"
  webhook_url: "hook"')
mkdir -p "$DIR/data"
check "values" "/elsewhere 32 short /a,/b us-east-1" \
    "$(with_env "$DIR" 'echo $DATA_DIR $SLURM_MAX_CPUS $SLURM_PARTITION $APPTAINER_BINDS $AWS_REGION')"
check "unknown keys ignored" "$PATH" "$(with_env "$DIR" 'echo $PATH')"
check "secret set" "t0k'en" "$(with_env "$DIR" 'echo "$WRIKE_API_TOKEN"')"
check "secret not exported" "unset" "$(with_env "$DIR" 'bash -c "echo \${WRIKE_API_TOKEN-unset}"')"
check "setting exported" "32" "$(with_env "$DIR" 'bash -c "echo \$SLURM_MAX_CPUS"')"
check "generated.yaml lives in data_dir" "" "$(with_env "$DIR" 'echo ${WRIKE_IDS_FOLDER-}')"
mv "$DIR/data/generated.yaml" "$WORK/generated.yaml"
mkdir -p "$WORK/elsewhere-data"
sed -i 's|/elsewhere|'"$WORK"'/elsewhere-data|' "$DIR/config.yaml"
mv "$WORK/generated.yaml" "$WORK/elsewhere-data/generated.yaml"
check "generated.yaml nested key" "F1" "$(with_env "$DIR" 'echo $WRIKE_IDS_FOLDER')"
check "config.yaml wins over generated.yaml" "from-config hook" \
    "$(with_env "$DIR" 'echo $AWS_SQS_QUEUE_URL $AWS_WEBHOOK_URL')"
check "generated secret not exported" "salty unset" \
    "$(with_env "$DIR" 'echo $RUN_ID_SALT $(bash -c "echo \${RUN_ID_SALT-unset}")')"

DIR=$(install broken 'core:
  data_dir: "unterminated')
OUT=$(with_env "$DIR" 'echo loaded' 2>&1)
check "syntax error stops loading" "0" "$(grep -c '^loaded$' <<< "$OUT")"
check "and gives the line" "yes" "$(grep -q 'line' <<< "$OUT" && echo yes || echo "$OUT")"

rm "$DIR/config.yaml"
check "missing config.yaml: defaults" "false $DIR/data $DIR/data/db" "$(with_env "$DIR" 'echo $SLURM_ENABLED $DATA_DIR $DB_DIR')"

# config_set changes a   key: "value"   line in place, keeping its comment's
# column, and leaves every other line alone
LONG='  db_dir: "/a-very-long-path/that/reaches/past/the/comment"'
DIR=$(install config-set "core:
  data_dir: \"/old\"                   # Runs
$LONG  # Databases
slurm:
  bin_dir: \"\"                        # Where sbatch is
  partition:   short   # Untouched
apptainer:
  binds: \"\"")
with_env "$DIR" 'source "$CODE/lib/config.sh"
    config_set core data_dir /new
    config_set core db_dir /db
    config_set slurm bin_dir /opt/slurm/a-long-directory-name/bin
    config_set apptainer binds "/a\b"'
check "config_set: in place, comments kept in their column" \
    "$(printf '%s\n' 'core:' "$(printf '%-37s# Runs' '  data_dir: "/new"')" \
        "$(printf "%-$(( ${#LONG} + 2 ))s# Databases" '  db_dir: "/db"')" 'slurm:' \
        '  bin_dir: "/opt/slurm/a-long-directory-name/bin"  # Where sbatch is' \
        '  partition:   short   # Untouched' 'apptainer:' '  binds: "/a\b"')" \
    "$(cat "$DIR/config.yaml")"

# Anything else goes through yq, still double-quoted for the launcher
DIR=$(install config-set-yq 'slurm:
  partition: short')
with_env "$DIR" 'source "$CODE/lib/config.sh"
    config_set slurm partition main
    config_set apptainer bin_dir /usr/bin'
check "config_set: through yq" $'slurm:\n  partition: "main"\napptainer:\n  bin_dir: "/usr/bin"' "$(cat "$DIR/config.yaml")"

# A whole number and enabled go in bare, a missing enabled goes first, and any
# other missing key last in its section
DIR=$(install config-set-bare 'slurm:
  bin_dir: "/x"
  max_cpus: 4          # Cap

core:
  data_dir: "/d"')
with_env "$DIR" 'source "$CODE/lib/config.sh"
    config_set slurm enabled true
    config_set slurm max_cpus 6
    config_set slurm account lab'
check "config_set: enabled first, a number bare, a new key last" \
    $'slurm:\n  enabled: true\n  bin_dir: "/x"\n  max_cpus: 6          # Cap\n  account: "lab"\n\ncore:\n  data_dir: "/d"' \
    "$(cat "$DIR/config.yaml")"
with_env "$DIR" 'source "$CODE/lib/config.sh"; config_set slurm enabled false'
check "config_set: enabled in place" "  enabled: false" "$(grep enabled "$DIR/config.yaml")"
check "config: lists the sections and steps" "core apptainer slurm wrike aws globus s3 sqs systemd" \
    "$(with_env "$DIR" 'source "$CODE/lib/args.sh"; source "$CODE/lib/config.sh"; config_main' |
        awk '{ print $1 }' | tr '\n' ' ' | sed 's/ $//')"

# Runs gnoto config with arguments and no terminal, printing what it says,
# without the date. The launcher names itself by its path, as it does when
# gnoto on the user's PATH isn't this install's.
config_args() {
    local dir=$1
    shift
    (GNOTO_INSTALL_DIR=$dir; GNOTO_LAUNCHER=$dir/gnoto; source "$CODE/lib/env.sh" || exit 1
        source "$CODE/lib/args.sh"; source "$CODE/lib/config.sh"; config_main "$@") < /dev/null 2>&1 |
        sed 's/^\[[^]]*\] ERROR: //'
}

# How a message names a command: as the launcher says, or by the install's
# launcher's path without it
DIR=$(install hints 'core:
  data_dir: ""')
check "gnoto_command: the launcher by its path" "$DIR/gnoto status abcdefgh" \
    "$(with_env "$DIR" 'GNOTO_LAUNCHER=$INSTALL_DIR/gnoto gnoto_command status abcdefgh')"
check "gnoto_command: gnoto, when that's what PATH runs" "gnoto lint <job file>" \
    "$(with_env "$DIR" "GNOTO_LAUNCHER=gnoto gnoto_command lint '<job file>'")"
check "gnoto_command: a path the launcher quoted" "'/a b/gnoto' config" \
    "$(with_env "$DIR" "GNOTO_LAUNCHER=\"'/a b/gnoto'\" gnoto_command config")"
check "gnoto_command: without the launcher's word, the install's launcher" "$DIR/gnoto upgrade main" \
    "$(with_env "$DIR" 'unset GNOTO_LAUNCHER; gnoto_command upgrade main')"

# gnoto config with settings as arguments: each set in place, nothing asked,
# and a section that's missing added whole
DIR=$(install config-args 'slurm:
  enabled: false
  partition: "short"     # Queue
  account: "lab"')
OUT=$(config_args "$DIR" slurm --account="my lab=2" --partition= --max_cpus 4)
check "config: settings in place, with a space and = in one, and one emptied" \
    "$(printf '%s\n' 'slurm:' '  enabled: false' "$(printf '%-25s# Queue' '  partition: ""')" \
        '  account: "my lab=2"' '  max_cpus: 4')" "$(cat "$DIR/config.yaml")"
check "config: and enabled left as it was" "yes" "$(grep -q '^slurm is off' <<< "$OUT" && echo yes || echo "$OUT")"
check "config: and how to turn it on, with the install's launcher" \
    "slurm is off, in $DIR/config.yaml. To turn it on, run: $DIR/gnoto config slurm --on" "$OUT"
config_args "$DIR" slurm --on --job_time=48.h > /dev/null
check "config: --on with a setting" "true 48.h" "$(yq '(.slurm.enabled | tostring) + " " + .slurm.job_time' "$DIR/config.yaml")"
config_args "$DIR" wrike --poll_minutes=0 > /dev/null
check "config: a new section with a setting is on" '{"enabled":true,"api_token":"","webhook_secret":"","poll_minutes":0,"api_url":"https://www.wrike.com/api/v4"}' \
    "$(yq -o=json -I=0 .wrike "$DIR/config.yaml")"
config_args "$DIR" globus --off --run_prefix=lab > /dev/null
check "config: unless --off says otherwise" "false lab" \
    "$(yq '(.globus.enabled | tostring) + " " + .globus.run_prefix' "$DIR/config.yaml")"
config_args "$DIR" core --data_dir="$WORK/d2" > /dev/null
check "config: a given value shapes the suggestions after it" "$WORK/d2 $WORK/d2/db 14" \
    "$(yq '.core.data_dir + " " + .core.db_dir + " " + (.core.keep_run_days | tostring)' "$DIR/config.yaml")"
cp "$DIR/config.yaml" "$WORK/config-before.yaml"
for case in "slurm --max_cpu=4|--max_cpu: slurm has no setting max_cpu. Its settings are bin_dir, conf, partition, account, max_cpus, max_memory, max_time, job_time, min_tmp." \
    "slurm --max_cpus=four|--max_cpus: Give a whole number." \
    "slurm --bin_dir=bin|--bin_dir: Give an absolute path." \
    "slurm --account=a\"b|--account: A double quote or a line break can't go in config.yaml." \
    "slurm --enabled=true|--enabled: turn slurm on or off with --on or --off." \
    "slurm --on --off|Give --on or --off, not both." \
    "core --on|core is always on. Run $DIR/gnoto config core to change its settings." \
    "slurm --account|--account needs a value, as --account=<value>. Usage: gnoto config [<section> [--on|--off] [--<key>=<value> ...] [--dry-run] [--yes]], gnoto config s3|sqs [--deploy], gnoto config systemd [--move], or gnoto config slurm --probe" \
    "slurm|$DIR/gnoto config slurm asks questions, so run it from a terminal, or give --on, --off or its settings as --<key>=<value>." \
    "core --probe|--probe is for $DIR/gnoto config slurm, which checks every compute node." \
    "nothing|gnoto config has no section nothing. Run $DIR/gnoto config to list them." \
    "slurm --probe --on|gnoto config slurm --probe takes nothing else." \
    "--account=x|Usage: gnoto config [<section> [--on|--off] [--<key>=<value> ...] [--dry-run] [--yes]], gnoto config s3|sqs [--deploy], gnoto config systemd [--move], or gnoto config slurm --probe"; do
    read -r -a args <<< "${case%%|*}"
    check "config: refuses ${case%%|*}" "${case#*|}" "$(config_args "$DIR" "${args[@]}")"
done
check "config: and wrote nothing" "" "$(diff "$WORK/config-before.yaml" "$DIR/config.yaml")"

# Parameters
DIR=$(install params 'core:
  data_dir: ""
  db_dir: "/dbs"')
cat > "$WORK/layer.yaml" << 'EOF'
dada_ref_taxonomy: "silva=138.2"
trunclenf: 230
list_param: [a, b]
skip_x: true
EOF
OUT=$(with_env "$DIR" '
    params_set input samplesheet.tsv
    params_set run_kraken2 true
    params_set max_len 255
    params_set pplace_tree db:pplace/v1/bac16s.newick
    params_set quoted "it'"'"'s \"x\" \\ y"
    params_load '"$WORK"'/layer.yaml
    params_set input again.tsv
    params_json | jq -c .
    params_write '"$WORK"'/params.yaml
    cat '"$WORK"'/params.yaml')
check "params_json keeps order, types and db: names" \
    '{"input":"again.tsv","run_kraken2":true,"max_len":255,"pplace_tree":"db:pplace/v1/bac16s.newick","quoted":"it'"'"'s \"x\" \\ y","dada_ref_taxonomy":"silva=138.2","trunclenf":230,"list_param":["a","b"],"skip_x":true}' \
    "$(head -1 <<< "$OUT")"
check "params_write resolves db: names" "pplace_tree: /dbs/pplace/v1/bac16s.newick" "$(grep '^pplace_tree:' <<< "$OUT")"
check "params_write round-trips" "it's \"x\" \\ y" "$(yq '.quoted' "$WORK/params.yaml")"
check "params_get" "silva=138.2 [\"a\",\"b\"]" "$(with_env "$DIR" "params_load $WORK/layer.yaml; echo \$(params_get dada_ref_taxonomy) \$(params_get list_param)")"
check "db: name leaving db_dir refused" "1" "$(with_env "$DIR" 'db_path db:../etc' > /dev/null 2>&1; echo $?)"

# Run state
mkdir -p "$WORK/run"
OUT=$(cd "$WORK/run" && with_env "$DIR" '
    state_init abcdefgh
    state_set samples.count 3
    state_set_number reads 12
    state_set_json flag false
    for i in $(seq 20); do state_append notes "note $i" & done; wait
    echo "$(state_get samples.count) $(state_get reads) $(state_get flag) $(state_get_json notes | jq length) $(state_get run_id)"')
check "run state, false, 20 concurrent appends" "3 12 false 20 abcdefgh" "$OUT"
OUT=$(cd "$WORK/run" && with_env "$DIR" '
    RUN_STATE_LOCK_WAIT=1 RUN_STATE_TRIES=2
    flock .run_state.lock sleep 10 &
    sleep 0.5
    state_set held yes; echo "status=$? value=$(state_get held)"' 2> /dev/null)
check "a write that can't get the lock fails" "status=1 value=" "$OUT"

# Utilities
check "escape_html" "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;" \
    "$(with_env "$DIR" 'escape_html "<a href=\"x\">Tom & Jerry'"'"'s</a>"')"
check "escape_url" "a%20b/c%26d" "$(with_env "$DIR" 'escape_url "a b/c&d"')"
check "human_size" "1.5 MB" "$(with_env "$DIR" 'human_size 1572864')"
check "human_count" $'\03416600\03517k\036' "$(with_env "$DIR" 'human_count 16600')"
check "group_count" "4,404,860" "$(with_env "$DIR" 'group_count 4404860')"
check "derive_uid" "yes" "$(with_env "$DIR" 'RUN_ID_SALT=salt; is_valid_uid "$(derive_uid 1234)" && echo yes')"
check "fail records the message" "it broke" \
    "$(cd "$WORK/run" && with_env "$DIR" 'fail "it broke"' 2> /dev/null; cd "$WORK/run" && jq -r .message run_state.json)"

# Containers, run from the home directory, which Apptainer would otherwise mount
mkdir -p "$WORK/cdata" "$WORK/cdb"
DIR=$(install containers "core:
  data_dir: \"$WORK/cdata\"
  db_dir: \"$WORK/cdb\"")
touch "$HOME/.gnoto-lib-test-marker"
check "an image by tag is refused" "1" "$(with_env "$DIR" 'container_sif docker://ubuntu:26.04' > /dev/null 2>&1; echo $?)"
UBUNTU=docker.io/library/ubuntu@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
OUT=$(cd "$HOME" && with_env "$DIR" "container_exec $UBUNTU bash -c 'echo HOME=\$HOME; ls -A \$HOME | wc -l; env | grep -c -v -E \"^(HOME|LC_ALL|TZ|PATH|PWD|OLDPWD|SHLVL|_|LANG|LD_LIBRARY_PATH|PROMPT_COMMAND|TERM|USER_PATH|APPTAINER_[A-Z_]*|SINGULARITY_[A-Z_]*)=\"; echo \$LC_ALL \$TZ'")
rm -f "$HOME/.gnoto-lib-test-marker"
check "step container: fixed empty home, clean environment" $'HOME=/home/gnoto\n0\n0\nC.UTF-8 UTC' "$OUT"
check "image pulled once into images/" "1" "$(ls "$WORK/cdata/images" | grep -c '\.sif$')"
check "a failing command's status comes back" "3" \
    "$(with_env "$DIR" "container_exec $UBUNTU bash -c 'exit 3'; echo \$?")"

exit $FAILED
