#!/bin/bash
#
# outputs-test.sh - Tests lib/outputs.sh in the real image: a pipeline's core
# tables from stable-files, with globs, sorted rows, stripped lines and gzip;
# the numeric comparison of two tables; comparing two runs' outputs; the
# sentence a run's notes get; and keeping a record's own tables for a re-run.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/lib/outputs-test.sh
# Requires:  the gnoto image
#
# Works in a scratch directory, with a pipeline of its own, t, whose
# stable-files it writes.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test-outputs.XXXXXX")
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

source "$CODE/lib/env.sh" || exit 1
source "$CODE/lib/runs.sh"
CODE_DIR=$WORK/code
mkdir -p "$CODE_DIR/pipelines/t"
cat > "$CODE_DIR/pipelines/t/stable-files" << 'EOF'
# Core tables, for the test
table.tsv
order.tsv sort
dated.txt strip ^# (made|written) on
per-sample/*.tsv
packed.tsv.gz
none/*.tsv
EOF

A=$WORK/a
mkdir -p "$A/per-sample" "$A/other"
printf 'id\tS1\tS2\nASV_1\t100\t0\nASV_2\t5\t2.5e-3\nASV_3\t-4\t7\n' > "$A/table.tsv"
printf 'x\t1\ny\t2\nz\t3\n' > "$A/order.tsv"
printf '# made on 2026-11-09 10:00:00\nkept\t1\n' > "$A/dated.txt"
printf 'k\t1\n' > "$A/per-sample/S1.tsv"
printf 'k\t2\n' > "$A/per-sample/S2.tsv"
printf 'not a core table\n' > "$A/other/log.txt"
printf 'a\t1\n' | gzip > "$A/packed.tsv.gz"

sum() { sha256sum | cut -d' ' -f1; }

# 1. The checksums, of what's read
OUT=$(outputs_measure t "$A")
check "every core table found, in path order" \
    "dated.txt order.tsv packed.tsv.gz per-sample/S1.tsv per-sample/S2.tsv table.tsv" \
    "$(jq -r 'map(.path) | join(" ")' <<< "$OUT")"
check "a plain table's checksum is its bytes'" "$(sum < "$A/table.tsv")" \
    "$(jq -r '.[] | select(.path == "table.tsv") | .sha256' <<< "$OUT")"
check "a sorted one's is its sorted lines'" "$(LC_ALL=C sort "$A/order.tsv" | sum)" \
    "$(jq -r '.[] | select(.path == "order.tsv") | .sha256' <<< "$OUT")"
check "a stripped one's leaves out the matching lines" "$(printf 'kept\t1\n' | sum)" \
    "$(jq -r '.[] | select(.path == "dated.txt") | .sha256' <<< "$OUT")"
check "a gzipped one's is its content's" "$(printf 'a\t1\n' | sum)" \
    "$(jq -r '.[] | select(.path == "packed.tsv.gz") | .sha256' <<< "$OUT")"

B=$WORK/b
cp -R "$A" "$B"
printf 'z\t3\nx\t1\ny\t2\n' > "$B/order.tsv"
printf '# written on 2026-11-10 11:11:11\nkept\t1\n' > "$B/dated.txt"
sleep 1
printf 'a\t1\n' | gzip > "$B/packed.tsv.gz"
check "rows in another order, another timestamp and gzip's time change nothing" "$OUT" "$(outputs_measure t "$B")"
check "a directory with no core tables gives none" "[]" "$(outputs_measure t "$WORK/code")"

# 2. Two tables, cell by cell
T=$WORK/tables
mkdir -p "$T"
printf 'id\tS1\tS2\nASV_1\t100\t0\nASV_2\t5\t2.5e-3\nASV_3\t-4\t7\n' > "$T/one.tsv"
FIG=$(compare_tables "$T/one.tsv" "$T/one.tsv" one.tsv)
check "identical tables: 3 numbers each in 3 rows, none differing" "4 0 0 6 0 0" \
    "$(jq -r '"\(.rows) \(.only_recorded) \(.only_new) \(.numbers) \(.numbers_differing) \(.text_differing)"' <<< "$FIG")"
printf 'id\tS1\tS2\nASV_2\t5\t0.0025\nASV_1\t101\t0\nASV_3\t-4\t7.0000007\n' > "$T/two.tsv"
FIG=$(compare_tables "$T/one.tsv" "$T/two.tsv" two.tsv)
check "rows matched by their first field, and 2.5e-3 equal to 0.0025" "2" "$(jq .numbers_differing <<< "$FIG")"
check "the largest relative difference" "0.0099" "$(jq .largest_relative_difference <<< "$FIG")"
check "and where it is" "ASV_1 S1 100 101" "$(jq -r '"\(.row) \(.column) \(.recorded) \(.new)"' <<< "$FIG")"
printf 'id\tS1\tS2\nASV_1\t100\t0\nASV_2\t5\tlow\nASV_9\t1\t1\n' > "$T/three.tsv"
FIG=$(compare_tables "$T/one.tsv" "$T/three.tsv" three.tsv)
check "a row only in each, and a text cell differing" "1 1 1 0" \
    "$(jq -r '"\(.only_recorded) \(.only_new) \(.text_differing) \(.numbers_differing)"' <<< "$FIG")"
check "with nothing to report as largest" "null" "$(jq .largest_relative_difference <<< "$FIG")"
printf 'id,S1\nASV_1,-2\nASV_1,4\n' > "$T/four.csv"
printf 'id,S1\nASV_1,-2\nASV_1,5\n' > "$T/five.csv"
FIG=$(compare_tables "$T/four.csv" "$T/five.csv" five.csv)
check "comma-separated, a repeated first field matched in order, a negative" "3 0.2 ASV_1" \
    "$(jq -r '"\(.rows) \(.largest_relative_difference) \(.row)"' <<< "$FIG")"
printf '>ASV_1\nACGT\n' > "$T/one.fasta"
printf '>ASV_1\nACGA\n' > "$T/two.fasta"
FIG=$(compare_tables "$T/one.fasta" "$T/two.fasta" two.fasta)
check "a FASTA's changed sequence is a line only in each" "1 1 0" \
    "$(jq -r '"\(.only_recorded) \(.only_new) \(.numbers)"' <<< "$FIG")"
: > "$T/empty.tsv"
FIG=$(compare_tables "$T/empty.tsv" "$T/one.tsv" one.tsv)
check "an empty table against a full one" "0 0 4" "$(jq -r '"\(.rows) \(.only_recorded) \(.only_new)"' <<< "$FIG")"

# 3. Two runs' outputs
C=$WORK/c
cp -R "$A" "$C"
printf 'id\tS1\tS2\nASV_1\t100\t0\nASV_2\t5\t2.5e-3\nASV_3\t-4\t8\n' > "$C/table.tsv"
rm "$C/per-sample/S2.tsv"
printf 'k\t3\n' > "$C/per-sample/S3.tsv"
RESULT=$(outputs_compare t "$OUT" "$OUT" "$A" "$B")
check "the same outputs are identical" "true 6" "$(jq -r '"\(.identical) \(.tables | length)"' <<< "$RESULT")"
check "and say so" "Its 6 core tables are identical to the record's." "$(outputs_summary "$RESULT" "the record's")"
RESULT=$(outputs_compare t "$OUT" "$(outputs_measure t "$C")" "$A" "$C")
check "one missing, one new, one differing, in path order" "false missing new differs" \
    "$(jq -r '[.identical, (.tables[] | select(.result != "identical") | .result)] | map(tostring) | join(" ")' <<< "$RESULT")"
check "the differing one's figures" "0.125 ASV_3 S2" \
    "$(jq -r '.tables[] | select(.result == "differs") | .figures | "\(.largest_relative_difference) \(.row) \(.column)"' <<< "$RESULT")"
check "in one sentence" "3 of its 7 core tables differ from the record's: per-sample/S2.tsv, not made this time; per-sample/S3.tsv, not in the record's; table.tsv, largest relative difference 0.125, at ASV_3, S2." \
    "$(outputs_summary "$RESULT" "the record's")"
LINES=$(comparison_lines "$RESULT" "the record's")
check "status shows a line for each table that isn't identical" "4" "$(wc -l <<< "$LINES")"
check "with the values that differ" "yes" \
    "$(grep -qF 'table.tsv: largest relative difference 0.125, at ASV_3, S2: 7 then 8 (1 of 6 numbers differ)' <<< "$LINES" && echo yes)"
RESULT=$(outputs_compare t "$OUT" "$(outputs_measure t "$C")" "" "$C")
check "with no copy of the other's tables, a difference has no figures" "null" \
    "$(jq -c '.tables[] | select(.result == "differs") | .figures' <<< "$RESULT")"
check "and says so" "yes" \
    "$(outputs_summary "$RESULT" "the record's" | grep -qF 'table.tsv, no copy to compare its numbers with' && echo yes)"
check "nothing to compare" "There were no core tables to compare with the record's." \
    "$(outputs_summary "$(outputs_compare t "[]" "[]" "" "$A")" "the record's")"

# 4. Columns left out, as Nonpareil's are
mkdir -p "$CODE_DIR/pipelines/u" "$WORK/d1" "$WORK/d2"
printf 'alpha.tsv drop noisy,also\nalpha.csv drop noisy\n' > "$CODE_DIR/pipelines/u/stable-files"
printf 'sample\treads\tnoisy\tkept\talso\nS1\t100\t0.51\t7\t1.5\n' > "$WORK/d1/alpha.tsv"
printf 'sample\treads\tnoisy\tkept\talso\nS1\t100\t0.49\t7\t1.6\n' > "$WORK/d2/alpha.tsv"
printf 'sample,noisy,kept\nS1,3,4\n' > "$WORK/d1/alpha.csv"
printf 'sample,noisy,kept\nS1,9,4\n' > "$WORK/d2/alpha.csv"
DROPPED=$(outputs_measure u "$WORK/d1")
check "a dropped column's checksum is of the other columns" "$(printf 'sample\treads\tkept\nS1\t100\t7\n' | sum)" \
    "$(jq -r '.[] | select(.path == "alpha.tsv") | .sha256' <<< "$DROPPED")"
check "so values that vary there change nothing, comma-separated too" "true" \
    "$(jq -r .identical <<< "$(outputs_compare u "$DROPPED" "$(outputs_measure u "$WORK/d2")" "$WORK/d1" "$WORK/d2")")"
printf 'sample\treads\tnoisy\tkept\talso\nS1\t100\t0.49\t8\t1.6\n' > "$WORK/d2/alpha.tsv"
RESULT=$(outputs_compare u "$DROPPED" "$(outputs_measure u "$WORK/d2")" "$WORK/d1" "$WORK/d2")
check "a kept column that differs is compared alone" "1 kept 2" \
    "$(jq -r '.tables[] | select(.path == "alpha.tsv") | .figures | "\(.numbers_differing) \(.column) \(.numbers)"' <<< "$RESULT")"

# 5. Numbers rounded, as HUMAnN's are
printf 'sums.tsv round 12\n' >> "$CODE_DIR/pipelines/u/stable-files"
mkdir -p "$WORK/r1" "$WORK/r2" "$WORK/r3"
printf 'pathway\tS1\tS2\nUNMAPPED\t30226.9081424064\t7\nPWY-1\t1.5e-3\tlow\n' > "$WORK/r1/sums.tsv"
printf 'pathway\tS1\tS2\nUNMAPPED\t30226.9081424065\t7\nPWY-1\t1.5e-3\tlow\n' > "$WORK/r2/sums.tsv"
printf 'pathway\tS1\tS2\nUNMAPPED\t30226.9081\t7\nPWY-1\t1.5e-3\tlow\n' > "$WORK/r3/sums.tsv"
ROUNDED=$(outputs_measure u "$WORK/r1")
check "a number's last digit changes nothing at 12 digits" "true" \
    "$(jq -r .identical <<< "$(outputs_compare u "$ROUNDED" "$(outputs_measure u "$WORK/r2")" "$WORK/r1" "$WORK/r2")")"
check "but its sixth does" "false" \
    "$(jq -r .identical <<< "$(outputs_compare u "$ROUNDED" "$(outputs_measure u "$WORK/r3")" "$WORK/r1" "$WORK/r3")")"
check "and text and whole numbers are read as they are" "$(printf 'pathway\tS1\tS2\nUNMAPPED\t30226.9081424\t7\nPWY-1\t0.0015\tlow\n' | sum)" \
    "$(jq -r '.[] | select(.path == "sums.tsv") | .sha256' <<< "$ROUNDED")"
printf 'bad.tsv round x\n' > "$CODE_DIR/pipelines/u/stable-files"
cp "$WORK/r1/sums.tsv" "$WORK/r1/bad.tsv"
check "round takes a number of digits" "1" "$(outputs_measure u "$WORK/r1" > /dev/null 2>&1; echo $?)"

# 6. Columns and rows in any order, as taxprofiler's merges of samples are
mkdir -p "$CODE_DIR/pipelines/w" "$WORK/u1" "$WORK/u2" "$WORK/u3"
printf 'metaphlan.txt unordered\nmotus.txt unordered\ntaxpasta.tsv unordered\n' > "$CODE_DIR/pipelines/w/stable-files"
printf '#mpa_vJun23\nclade_name\tsingle\tmock\nUNCLASSIFIED\t15.96246\t0.0\nk__Bacteria\t84.03754\t100.0\n' > "$WORK/u1/metaphlan.txt"
printf '#mpa_vJun23\nclade_name\tmock\tsingle\nUNCLASSIFIED\t0.0\t15.96246\nk__Bacteria\t100.0\t84.03754\n' > "$WORK/u2/metaphlan.txt"
printf '# motus version 3.1.0\n# call: motus merge -i mock.out,single.out\n#consensus_taxonomy\tNCBI_tax_id\tmock\tsingle\nE. coli\t562\t8\t0\nunassigned\tNA\t3\t5\n' > "$WORK/u1/motus.txt"
printf '# motus version 3.1.0\n# call: motus merge -i single.out,mock.out\n#consensus_taxonomy\tNCBI_tax_id\tsingle\tmock\nunassigned\tNA\t5\t3\nE. coli\t562\t0\t8\n' > "$WORK/u2/motus.txt"
printf 'taxonomy_id\tname\tmock\tsingle\n562\tE. coli\t1\t0\n328814\tA. shahii\t0\t1\n' > "$WORK/u1/taxpasta.tsv"
printf 'taxonomy_id\tname\tsingle\tmock\n328814\tA. shahii\t1\t0\n562\tE. coli\t0\t1\n' > "$WORK/u2/taxpasta.tsv"
UNORDERED=$(outputs_measure w "$WORK/u1")
check "samples merged in another order, rows and provenance lines too, change nothing" "true" \
    "$(jq -r .identical <<< "$(outputs_compare w "$UNORDERED" "$(outputs_measure w "$WORK/u2")" "$WORK/u1" "$WORK/u2")")"
check "it reads the header and then the sorted rows, each with its columns in order" \
    "$(printf '#consensus_taxonomy\tNCBI_tax_id\tmock\tsingle\nE. coli\t562\t8\t0\nunassigned\tNA\t3\t5\n' | sum)" \
    "$(jq -r '.[] | select(.path == "motus.txt") | .sha256' <<< "$UNORDERED")"
cp "$WORK/u2/"* "$WORK/u3/"
printf '#mpa_vJun23\nclade_name\tmock\tsingle\nUNCLASSIFIED\t0.0\t15.96246\nk__Bacteria\t100.0\t80.03754\n' > "$WORK/u3/metaphlan.txt"
RESULT=$(outputs_compare w "$UNORDERED" "$(outputs_measure w "$WORK/u3")" "$WORK/u1" "$WORK/u3")
check "a value that differs is found under its own sample's name" "k__Bacteria single 84.03754 80.03754 1" \
    "$(jq -r '.tables[] | select(.path == "metaphlan.txt") | .figures | "\(.row) \(.column) \(.recorded) \(.new) \(.numbers_differing)"' <<< "$RESULT")"
: > "$WORK/u3/taxpasta.tsv"
check "an empty table reads as empty" "$(sum < /dev/null)" \
    "$(outputs_measure w "$WORK/u3" | jq -r '.[] | select(.path == "taxpasta.tsv") | .sha256')"

# 7. A record's own tables, kept for a re-run
KEEP=$WORK/keep
printf 'id\tS1\tS2\nASV_1\t1\t1\n' > "$B/table.tsv"
check "only the tables matching the record's checksums are kept" "5" \
    "$(outputs_keep_recorded t "$OUT" "$B" "$KEEP")"
check "under their paths" "yes no yes" \
    "$( [[ -f $KEEP/per-sample/S1.tsv ]] && printf yes || printf no; printf ' '
        [[ -f $KEEP/table.tsv ]] && printf yes || printf no; printf ' '
        [[ -f $KEEP/order.tsv ]] && printf yes || printf no)"
check "a path leaving the directory is never followed" "0" \
    "$(outputs_keep_recorded t '[{"path": "../a/table.tsv", "sha256": "x"}]' "$B" "$WORK/keep2")"

exit $FAILED
