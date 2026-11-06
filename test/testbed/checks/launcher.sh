#!/bin/bash
#
# launcher.sh - Checks the launcher, helper and stand-ins with real Apptainer
# and Slurm, in the test bed or on a cluster.
#
# Run by:  a developer, as any user:
#          docker exec gnoto-testbed runuser -l alice -c 'bash /opt/gnoto/test/testbed/checks/launcher.sh'
# Env:     TEST_SBATCH_ARGS, optional sbatch options such as "-p short -A lab"
#
# This script is the host side, so it may use host tools. Everything after
# "gnoto exec" runs in the image.

set -u
umask 002

GNOTO=$(cd "$(dirname "$0")/../../.." && pwd)/gnoto
OUT=$($GNOTO exec printenv GNOTO_DATA_DIR)/test/$USER/launcher
SBATCH_ARGS=${TEST_SBATCH_ARGS:-}
FAILED=0

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$OUT"

$GNOTO exec true
check "exit 0" 0 $?
$GNOTO exec bash -c 'exit 42'
check "exit 42" 42 $?

check "arguments" "$(printf '[%s]\n' "a b" "it's" "" '$HOME')" \
    "$($GNOTO exec printf '[%s]\n' "a b" "it's" "" '$HOME')"

check "stdin reaches the image" "hello" "$(echo hello | $GNOTO exec cat)"

check "user name inside the image" "$USER $USER" \
    "$($GNOTO exec bash -c 'id -un; java -XshowSettings:properties -version 2>&1 | sed -n "s/^ *user.name = //p"' | tr '\n' ' ' | sed 's/ $//')"

check "tools come from the image" "/bin/awk /bin/jq /bin/java /bin/nextflow" \
    "$($GNOTO exec bash -c 'command -v awk jq java nextflow' | tr '\n' ' ' | sed 's/ $//')"

check "stand-ins come first" "sbatch squeue scancel sinfo sacct apptainer systemctl loginctl" \
    "$($GNOTO exec bash -c 'for c in sbatch squeue scancel sinfo sacct apptainer systemctl loginctl; do [[ $(command -v $c) == $GNOTO_HELPER_DIR/bin/$c ]] && printf "%s " $c; done' | sed 's/ $//')"

MARK=host-only APPTAINERENV_MARK=leaked SINGULARITYENV_MARK2=leaked \
    $GNOTO exec env > "$OUT/image_env.txt"
check "host variables stay out" "" "$(grep -E '^MARK2?=' "$OUT/image_env.txt")"
echo "      image environment: $(cut -d= -f1 "$OUT/image_env.txt" | sort | tr '\n' ' ')"

check "sinfo through the helper" "0" "$($GNOTO exec sinfo -h -o %P > /dev/null; echo $?)"

JOB=$(TMPDIR=/tmp/caller-tmpdir $GNOTO exec sbatch --parsable $SBATCH_ARGS --wrap 'env | LC_ALL=C sort > job_env.txt; sleep 2')
check "sbatch through the helper returns a job ID" "yes" "$([[ $JOB =~ ^[0-9]+$ ]] && echo yes || echo "$JOB")"
for (( i = 0; i < 900; i++ )); do [[ -s job_env.txt ]] && break; sleep 1; done
check "the job ran" "yes" "$([[ -s job_env.txt ]] && echo yes || echo no)"
echo "      job environment: $(cut -d= -f1 job_env.txt 2> /dev/null | grep -v '^SLURM_' | tr '\n' ' ')"
check "the job didn't inherit the caller's TMPDIR" "" "$(grep '^TMPDIR=/tmp/caller-tmpdir' job_env.txt 2> /dev/null)"

# A job submitted from inside another job doesn't inherit its Slurm variables
NESTED=$($GNOTO exec sbatch --parsable $SBATCH_ARGS --mem-per-cpu=100M \
    --wrap "exec $GNOTO exec sbatch --parsable $SBATCH_ARGS --wrap 'env | LC_ALL=C sort > nested_env.txt'" )
for (( i = 0; i < 900; i++ )); do [[ -s nested_env.txt ]] && break; sleep 1; done
check "the nested job ran" "yes" "$([[ -s nested_env.txt ]] && echo yes || echo no)"
check "nested job doesn't inherit the outer job's SLURM_MEM_PER_CPU" "" \
    "$(grep '^SLURM_MEM_PER_CPU=100$' nested_env.txt 2> /dev/null)"
check "nested job isn't the outer job" "no" "$(grep -q "^SLURM_JOB_ID=$NESTED\$" nested_env.txt 2> /dev/null && echo yes || echo no)"

# SIGTERM to the launcher reaches the image, then the helper and directory go
$GNOTO exec bash -c 'trap "echo got TERM > term.txt; kill \$!; exit 0" TERM; echo $$ > inner.pid; sleep 300 & wait' &
LAUNCHER=$!
for (( i = 0; i < 100; i++ )); do [[ -s inner.pid ]] && break; sleep 0.1; done
PRIVATE=$(tr '\0' '\n' < /proc/"$(cat inner.pid)"/environ | sed -n 's/^GNOTO_HELPER_DIR=//p')
kill -TERM "$LAUNCHER"
wait "$LAUNCHER"
check "launcher passes SIGTERM on" "got TERM" "$(cat term.txt 2> /dev/null)"
check "private directory removed" "gone" "$([[ -e $PRIVATE ]] && echo there || echo gone)"
check "helper stopped" "" "$(pgrep -u "$USER" -f "helper.sh $PRIVATE")"

exit $FAILED
