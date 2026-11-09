#!/bin/bash
#
# selftest.sh - Tests gnoto selftest --dev end to end, on a copy of the
# install whose ampliseq selftest has one job, on the 16s-v4 fixture: first
# with no reference tables, then against the tables that run made, committed
# to the test bed's repository, which must report them identical.
#
# Run by:    a developer, as alice or bob, in the test bed:
#            bash <install>/test/testbed/checks/selftest.sh [--small]
# Requires:  an install testbed.sh install made, cloned from the test bed's
#            repository, /tmp/gnoto.git, and git. It pushes a test commit to
#            that repository's main, so don't run testbed.sh commit or install
#            while it runs.
#
# --small gives the job db:test/pplace-small, for a node that can't hold
# EPA-NG on the full placement reference. Writes in
# <data_dir>/test/$USER/selftest. Takes about 25 minutes.

set -u

CODE_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
SMALL=false
for ARG in "$@"; do
    case $ARG in
        --small) SMALL=true ;;
        *) echo "Usage: selftest.sh [--small]" >&2; exit 1 ;;
    esac
done
DATA_DIR=$("$CODE_DIR/gnoto" exec printenv GNOTO_DATA_DIR)
WORK=$DATA_DIR/test/$USER/selftest
COPY=$WORK/install
GNOTO=$COPY/gnoto
REPO=/tmp/gnoto.git
FAILED=0

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Starts a selftest from the copy, and waits up to $1 minutes for its report.
# Prints its directory.
selftest_run() {
    local out id dir
    out=$($GNOTO selftest --dev --yes ampliseq 2>&1)
    id=$(sed -n 's/^Selftest \([a-z2-7]\{8\}\), against .*/\1/p' <<< "$out")
    if [[ -z $id ]]; then
        printf 'FAIL  gnoto selftest:\n%s\n' "$(sed 's/^/      /' <<< "$out")" >&2
        return 1
    fi
    sed 's/^/      /' <<< "$out" >&2
    dir=$DATA_DIR/selftest/$id
    for (( i = 0; i < $1 * 6; i++ )); do
        [[ -s $dir/report.txt ]] && break
        sleep 10
    done
    printf '%s' "$dir"
}

rm -rf "$WORK"
mkdir -p "$WORK"
cp -a "$CODE_DIR" "$COPY"
cat > "$COPY/pipelines/ampliseq/selftest.yaml" << EOF
schema: 1
jobs:
  - name: v4
    samples:
      - [mock, fixtures/16s-v4/v1/SRR17380142_1.fastq.gz, fixtures/16s-v4/v1/SRR17380142_2.fastq.gz]
EOF
if [[ $SMALL == true ]]; then
    printf '    args: [--ampliseq.pplace_tree=db:test/pplace-small/bac16s.newick, --ampliseq.pplace_aln=db:test/pplace-small/bac16s.alnfna]\n' \
        >> "$COPY/pipelines/ampliseq/selftest.yaml"
fi
rm -rf "$COPY/pipelines/ampliseq/selftest"

echo "Refusals"
check "a pipeline with no selftest" "yes" \
    "$($GNOTO selftest --dev nothing 2>&1 | grep -q 'There.s no selftest for "nothing"' && echo yes)"
check "an option it doesn't take" "yes" \
    "$($GNOTO selftest --dev --colour=red 2>&1 | grep -q 'takes --dev and --yes, not --colour' && echo yes)"

echo "With no reference tables"
DIR=$(selftest_run 60) || exit 1
check "the report is written" "yes" "$([[ -s $DIR/report.txt && -s $DIR/report.yaml ]] && echo yes)"
STATE=$($GNOTO exec yq -o=json . "$DIR/state.yaml")
UID_=$($GNOTO exec jq -r '.runs[0].uid' <<< "$STATE")
check "its state says it's reported" "Reported 1" "$($GNOTO exec jq -r '"\(.status) \(.runs | length)"' <<< "$STATE")"
check "against main's tip, as there's no release" "yes" \
    "$($GNOTO exec jq -r .against <<< "$STATE" | grep -q "^main's reference tables, at [0-9a-f]\{7\}, as there's no release yet$" && echo yes)"
check "the run completed, with nothing to compare with" "yes" \
    "$(grep -q "^ampliseq v4, run $UID_: Completed. There are no reference tables for this job" "$DIR/report.txt" && echo yes)"
TABLES=$(cd "$DIR/tables/ampliseq/v4" 2> /dev/null && find . -type f | wc -l)
check "its core tables are kept for the reference" "yes" "$( (( TABLES > 0 )) && echo yes)"
check "as many as its record's checksums" "$TABLES" \
    "$($GNOTO exec bash -c 'yq ".outputs | length" "$1"' _ "$DATA_DIR/history/$UID_/record.yaml")"
check "the run carried the selftest's id" "${DIR##*/}" "$($GNOTO exec jq -r .selftest "$DATA_DIR/history/$UID_/state.json")"
check "and was removed, keeping its history" "no yes" \
    "$([[ -e $DATA_DIR/runs/$UID_ ]] && echo yes || echo no) $([[ -n $($GNOTO exec jq -r '.removed_utc // empty' "$DATA_DIR/history/$UID_/state.json") ]] && echo yes || echo no)"
check "with no expiry file" "no" "$([[ -e $DATA_DIR/expiry/$UID_ ]] && echo yes || echo no)"
check "status lists the selftest" "yes" \
    "$($GNOTO status | grep -q "^  ${DIR##*/}  .*0 identical, 1 differing, 0 not completed  $DIR/report.txt$" && echo yes)"

echo "Against the tables it made, committed to main"
rm -rf "$WORK/clone"
git clone -q "$REPO" "$WORK/clone" || exit 1
mkdir -p "$WORK/clone/pipelines/ampliseq/selftest"
cp -R "$DIR/tables/ampliseq/v4" "$WORK/clone/pipelines/ampliseq/selftest/v4"
cp "$COPY/pipelines/ampliseq/selftest.yaml" "$WORK/clone/pipelines/ampliseq/selftest.yaml"
(
    cd "$WORK/clone" &&
        git add -A &&
        git -c user.name='gnoto test bed' -c user.email=testbed@localhost commit -q -m 'selftest.sh: reference tables' &&
        git push -q origin HEAD:main
) || exit 1
DIR=$(selftest_run 60) || exit 1
UID_=$($GNOTO exec yq -r '.runs[0].uid' "$DIR/state.yaml")
check "the run's tables are identical to the reference" "yes" \
    "$(grep -q "^ampliseq v4, run $UID_: Completed. Its $TABLES core tables are identical to the reference.$" "$DIR/report.txt" && echo yes)"
check "and the report says so" "true" \
    "$($GNOTO exec bash -c 'yq -o=json . "$1" | jq -r ".[0].comparison.identical"' _ "$DIR/report.yaml")"

exit $FAILED
