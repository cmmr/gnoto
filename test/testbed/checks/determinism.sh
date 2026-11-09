#!/bin/bash
#
# determinism.sh - Phase 6's finish test: an exact re-run reports its core
# tables identical to its record's, and one compared with tables that differ
# reports by how much.
#
# Run by:    a developer, as any user, in the test bed or on the cluster:
#            bash <install>/test/testbed/checks/determinism.sh [--small]
# Requires:  the install's gnoto. gnoto lint --yes fetches the 16s-v4 fixture
#            and the databases the job needs.
#
# Runs ampliseq on the 16s-v4 fixture through gnoto start, then:
#   1. its record, results/record.yaml, again with --inputs, which must report
#      every core table identical, and pass lint --deep
#   2. a copy of its results/ in which one core table has a count raised by
#      one, with the record's checksum for it to match, and another core
#      table's checksum is changed alone: the first must be reported with its
#      largest relative difference and where, the second as differing with no
#      copy to compare its numbers with
# --small uses db:test/pplace-small, for a node that can't hold EPA-NG on the
# full placement reference. Writes in <data_dir>/test/$USER/determinism. Takes
# about 30 minutes in the test bed.

set -u

CODE_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
GNOTO=$CODE_DIR/gnoto
SMALL=false
for ARG in "$@"; do
    case $ARG in
        --small) SMALL=true ;;
        *) echo "Usage: determinism.sh [--small]" >&2; exit 1 ;;
    esac
done
DATA_DIR=$($GNOTO exec printenv GNOTO_DATA_DIR)
DB_DIR=$($GNOTO exec printenv GNOTO_DB_DIR)
FIXTURE=$DB_DIR/fixtures/16s-v4/v1
WORK=$DATA_DIR/test/$USER/determinism
FAILED=0

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

run_status() {
    $GNOTO status "$1" 2> /dev/null | sed -n 's/^  Status     \([^:]*\).*/\1/p'
}

# Waits up to $2 minutes for a run to end, printing its stage as it changes
wait_for() {
    local uid=$1 status stage last=""
    for (( i = 0; i < $2 * 6; i++ )); do
        status=$(run_status "$uid")
        case $status in
            Completed | Failed | Cancelled | "Publish failed" | Lost) printf '%s' "$status"; return ;;
        esac
        stage=$($GNOTO status "$uid" 2> /dev/null | sed -n 's/^  Status     //p')
        [[ $stage == "$last" ]] || echo "      $stage" >&2
        last=$stage
        sleep 10
    done
    printf 'still %s' "$status"
}

# Starts a run, waits for it, and prints its uid: started <gnoto arguments>
started() {
    local out uid
    out=$($GNOTO "$@" 2>&1)
    uid=$(sed -n 's/^Started \([a-z2-7]\{8\}\),.*/\1/p' <<< "$out")
    [[ -n $uid ]] || { printf 'FAIL  gnoto %s:\n%s\n' "$*" "$(sed 's/^/      /' <<< "$out")" >&2; return 1; }
    printf '%s' "$uid"
}

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK" || exit 1
printf '%s\t%s\t%s\n' mock1 "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" > v4.tsv
JOB=(ampliseq --title="16S V4 determinism" --samplesheet=v4.tsv --retention="1 Month" --yes)
if [[ $SMALL == true ]]; then
    JOB+=(--ampliseq.pplace_tree=db:test/pplace-small/bac16s.newick)
    JOB+=(--ampliseq.pplace_aln=db:test/pplace-small/bac16s.alnfna)
fi

echo "The job, to the end"
FIRST=$(started start "${JOB[@]}") || exit 1
check "it ends as Completed" "Completed" "$(wait_for "$FIRST" 120)"
RUN=$DATA_DIR/runs/$FIRST
# The core tables' checksums, as the code measures them, and as the record holds them
MEASURED=$($GNOTO exec bash -c 'source "$GNOTO_CODE_DIR/lib/env.sh" && outputs_measure ampliseq "$1"' _ "$RUN/results")
RECORDED=$($GNOTO exec bash -c 'yq -o=json .outputs "$1" | jq -c .' _ "$RUN/results/record.yaml")
COUNT=$($GNOTO exec jq length <<< "$RECORDED")
check "the record holds the core tables' checksums" "yes" "$( (( COUNT > 0 )) && echo yes)"
check "as they are in results/" "$MEASURED" "$RECORDED"
check "status shows no comparison for a first run" "no" \
    "$($GNOTO status "$FIRST" | grep -q '^  Compared ' && echo yes || echo no)"

echo "Its record, re-run exactly"
SECOND=$(started run --inputs="$FIXTURE" --yes "$RUN/results/record.yaml") || exit 1
check "it ends as Completed" "Completed" "$(wait_for "$SECOND" 120)"
STATUS=$($GNOTO status "$SECOND")
check "status reports every core table identical" "  Compared   with the record's core tables: $COUNT of $COUNT identical" \
    "$(grep '^  Compared ' <<< "$STATUS")"
check "and so do its notes" "  Note       Its $COUNT core tables are identical to the record's." \
    "$(grep "^  Note       Its .* identical" <<< "$STATUS")"
check "lint --deep passes on the record" "0" \
    "$($GNOTO lint --deep --inputs="$FIXTURE" "$RUN/results/record.yaml" > lint-deep.log 2>&1; echo $?)"
check "and its own record's tables are the first's" "$RECORDED" \
    "$($GNOTO exec bash -c 'yq -o=json .outputs "$1" | jq -c .' _ "$DATA_DIR/runs/$SECOND/results/record.yaml")"

echo "A record whose tables differ"
cp -R "$RUN/results" doctored
# The first TSV core table with a whole number above 0 past its first row and column
read -r CHANGED ROW COLUMN VALUE < <(
    for TABLE in $($GNOTO exec jq -r '.[].path' <<< "$RECORDED"); do
        [[ $TABLE == *.tsv ]] || continue
        awk -F '\t' -v table="$TABLE" 'NR == 1 { for (i = 1; i <= NF; i++) head[i] = $i; next }
            { for (i = 2; i <= NF; i++) if ($i ~ /^[1-9][0-9]*$/) { print table, $1, head[i], $i; exit } }' "doctored/$TABLE" |
            grep . && break
    done)
check "a table with a count to change" "yes" "$([[ -n ${CHANGED:-} ]] && echo yes)"
[[ -n ${CHANGED:-} ]] || exit 1
awk -F '\t' -v OFS='\t' -v row="$ROW" -v column="$COLUMN" -v value="$VALUE" '
    NR == 1 { for (i = 1; i <= NF; i++) if ($i == column) at = i; print; next }
    $1 == row && !done && $at == value { $at = value + 1; done = 1 } { print }' "$RUN/results/$CHANGED" > "doctored/$CHANGED"
# Another core table, whose checksum alone changes
ALONE=$($GNOTO exec jq -r --arg changed "$CHANGED" 'map(select(.path != $changed)) | .[0].path' <<< "$RECORDED")
$GNOTO exec bash -c 'source "$GNOTO_CODE_DIR/lib/env.sh" &&
    export OUTPUTS=$(outputs_measure ampliseq "$1" | jq -c --arg alone "$2" "map(if .path == \$alone then .sha256 = (\"0\" * 64) else . end)") &&
    yq -i ".outputs = env(OUTPUTS)" "$1/record.yaml"' _ "$WORK/doctored" "$ALONE"
# As the comparison rounds it, and jq then writes it
EXPECTED=$($GNOTO exec jq -n "$(awk -v v="$VALUE" 'BEGIN { printf "%.3g", 1 / (v + 1) }')")

THIRD=$(started run --inputs="$FIXTURE" --yes "$WORK/doctored/record.yaml") || exit 1
check "it ends as Completed" "Completed" "$(wait_for "$THIRD" 120)"
STATUS=$($GNOTO status "$THIRD")
check "status counts the tables that differ" "  Compared   with the record's core tables: $((COUNT - 2)) of $COUNT identical" \
    "$(grep '^  Compared ' <<< "$STATUS")"
check "the changed count's table, by how much and where" \
    "             $CHANGED: largest relative difference $EXPECTED, at $ROW, $COLUMN: $((VALUE + 1)) then $VALUE (1 of" \
    "$(grep -o "^             $CHANGED: .* (1 of" <<< "$STATUS")"
check "the table with no copy, by its checksum alone" \
    "             $ALONE: differs, with no copy of the record's to compare its numbers with" \
    "$(grep "^             $ALONE: " <<< "$STATUS")"
check "its notes say the same in a sentence" "yes" \
    "$(grep -q "^  Note       2 of its $COUNT core tables differ from the record's: " <<< "$STATUS" && echo yes)"
check "history keeps the comparison" "false" \
    "$($GNOTO exec jq -r '.comparison.identical' "$DATA_DIR/history/$THIRD/state.json")"
check "the record's tables it copied went with the work directory" "no" \
    "$([[ -e $DATA_DIR/runs/$THIRD/recorded-outputs ]] && echo yes || echo no)"

exit $FAILED
