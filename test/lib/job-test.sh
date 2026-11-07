#!/bin/bash
#
# job-test.sh - Tests the job core's pieces that need no scheduler: gnoto new,
# the job file checks, record.yaml, the database lookups, the expiry file,
# local queueing and the scheduler's quoting, in the real image.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec bash <install>/test/lib/job-test.sh
# Requires:  the gnoto image; the 16s-v4 fixture in <db_dir>/fixtures/16s-v4/v1;
#            and network access, for ampliseq's nextflow_schema.json
#
# Its own data and database directories are scratch directories, with the
# fixture, SILVA and the pplace and 16S references linked in from the real
# ones when they're there.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
REAL_DB=$GNOTO_DB_DIR
WORK=$(mktemp -d "$GNOTO_DATA_DIR/test-job.XXXXXX")
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

# True when a check's output holds a line
has() {
    grep -qF -- "$2" <<< "$1" && echo yes || echo no
}

FIXTURE=$REAL_DB/fixtures/16s-v4/v1
[[ -r $FIXTURE/SRR17380142_1.fastq.gz ]] || { echo "No 16s-v4 fixture in $FIXTURE"; exit 1; }

mkdir -p "$WORK/install" "$WORK/data" "$WORK/db/fixtures/16s-v4" "$WORK/db/dada2" "$WORK/db/pplace" \
    "$WORK/db/16s" "$WORK/jobs"
printf 'core:\n  data_dir: "%s"\n  db_dir: "%s"\n' "$WORK/data" "$WORK/db" > "$WORK/install/config.yaml"
ln -s "$FIXTURE" "$WORK/db/fixtures/16s-v4/v1"
for ref in dada2/silva-138.2 pplace/v1 16s/v1; do
    [[ ! -e $REAL_DB/$ref ]] || ln -s "$REAL_DB/$ref" "$WORK/db/$ref"
done
export GNOTO_INSTALL_DIR=$WORK/install
source "$CODE/lib/env.sh" || exit 1
source "$CODE/lib/lint.sh"
source "$CODE/lib/jobfile.sh"
source "$CODE/lib/databases.sh"
source "$CODE/lib/followup.sh"
cd "$WORK/jobs" || exit 1

echo "gnoto new"
job_new ampliseq > /dev/null 2>&1
check "writes ampliseq.yaml" "yes" "$([[ -f ampliseq.yaml ]] && echo yes)"
check "with every option" "title samplesheet retention dada_ref_taxonomy picrust exclude_taxa mergepairs_strategy" \
    "$(yq -o=json . ampliseq.yaml | jq -r '[keys_unsorted[] | select(. != "pipeline" and . != "ampliseq")]
        + (.ampliseq | keys_unsorted) | join(" ")')"
check "retention defaults to 3 Months" "3 Months" "$(yq .retention ampliseq.yaml)"
check "refuses to overwrite" "1" "$( (job_new ampliseq) > /dev/null 2>&1; echo $?)"
check "refuses an unknown pipeline" "1" "$( (job_new nothing) > /dev/null 2>&1; echo $?)"

printf '%s\t%s\t%s\n' S1 "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" > good.tsv
cat > good.yaml << EOF
pipeline: ampliseq
title: "Test run"
samplesheet: "good.tsv"
ampliseq:
  picrust: true
  trunclenf: 230
  trunclenr: 160
EOF

# Runs job_check on a file, printing its lines and the failure count last
lint_job() {
    (
        LINT_FAILS=0
        LINT_WARNS=0
        job_check "$1"
        echo "fails=$LINT_FAILS"
    ) 2>&1
}

echo "lint, a good job file"
OUT=$(lint_job good.yaml)
check "no failures" "yes" "$(has "$OUT" "fails=0")"
check "answers read" "yes" "$(has "$OUT" "picrust true")"
check "the samplesheet is counted" "yes" "$(has "$OUT" "1 sample, 2 FASTQ files")"

echo "lint, mistakes"
cat > bad.yaml << EOF
pipeline: ampliseq
title: "-bad title"
samplesheet: "missing.tsv"
retention: "Forever"
colour: blue
taxprofiler:
  x: 1
ampliseq:
  picrust: maybe
  exclude_taxa: "chloroplast, nothing"
  trunclenf: "x"
  input: other.tsv
  not_a_parameter: 1
  config_profile_name: mine
  pplace_tree: /some/path.newick
  qiime_ref_taxonomy: silva=138
EOF
OUT=$(lint_job bad.yaml)
for line in "colour: isn't an option" "taxprofiler: this job runs ampliseq" "title: use up to 100" \
    "retention: \"Forever\" isn't one of" "picrust: \"maybe\" isn't one of" \
    "exclude_taxa: \"nothing\" isn't one of" "ampliseq.trunclenf: takes a whole number" \
    "ampliseq.input: gnoto sets this itself" "ampliseq.not_a_parameter: isn't a parameter" \
    "ampliseq.config_profile_name: nf-core's generic" "ampliseq.pplace_tree: names a file, so it must be a db: name" \
    "samplesheet: can't read"; do
    check "reports $line" "yes" "$(has "$OUT" "$line")"
done
check "with a failure count" "yes" "$(has "$OUT" "fails=12")"

cat > ref.yaml << EOF
pipeline: ampliseq
title: "Reference"
samplesheet: "good.tsv"
ampliseq:
  qiime_ref_taxonomy: silva=138
EOF
check "a reference choice with no database entry" "yes" \
    "$(has "$(lint_job ref.yaml)" "No database in conf/databases.yaml provides qiime_ref_taxonomy silva=138")"

echo "lint, samplesheets"
: > empty.fq.gz
printf '%s\t%s\t%s\n' "1-bad#name" "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" \
    S2 "$FIXTURE/SRR17380142_1.fastq.gz" "" > sheet1.tsv
printf '%s\t%s\n' S3 empty.fq.gz S4 nowhere.fq.gz >> sheet1.tsv
sed 's/good.tsv/sheet1.tsv/' good.yaml > sheet1.yaml
OUT=$(lint_job sheet1.yaml)
check "a bad sample name" "yes" "$(has "$OUT" "the sample name \"1-bad#name\"")"
check "mixed layouts, which ampliseq refuses" "yes" "$(has "$OUT" "and ampliseq runs every sample one way")"
check "an empty file" "yes" "$(has "$OUT" "empty.fq.gz is empty")"
check "a missing file, relative to the sheet" "yes" "$(has "$OUT" "$WORK/jobs/nowhere.fq.gz doesn't exist")"

echo "lint, databases"
mv "$WORK/db/fixtures/16s-v4/v1" "$WORK/db/fixtures/16s-v4/v1.away"
sed "s|  trunclenr: 160|  trunclenr: 160\n  pplace_tree: db:fixtures/16s-v4/v1/SRR17380142_1.fastq.gz|" good.yaml > db.yaml
OUT=$(lint_job db.yaml)
check "a missing fixture can be fetched" "yes" "$(has "$OUT" "db:fixtures/16s-v4/v1 is missing, at $WORK/db/fixtures/16s-v4/v1. gnoto can fetch it")"
printf 'slurm 999999999\n' > "$WORK/db/fixtures/16s-v4/v1.fetching"
check "a marker whose job has gone is removed" "no" \
    "$(has "$(lint_job db.yaml)" "being fetched")$([[ -e $WORK/db/fixtures/16s-v4/v1.fetching ]] && echo " still there")"
mv "$WORK/db/fixtures/16s-v4/v1.away" "$WORK/db/fixtures/16s-v4/v1"
check "entries by db: name" "pplace/v1 fixtures/16s-v4/v1 hostremoval/phix  " \
    "$(for n in db:pplace/v1/bac16s.newick db:fixtures/16s-v4/v1/x db:hostremoval/phix.fa db:nothing/here; do
        printf '%s ' "$(db_entry_for "$n")"; done)"
check "a fixture's download size" "2924900" "$(db_bytes_for fixtures/16s-v4/v1)"
check "a fixture's setup" "steps/fetch_files.sh fixtures/16s-v4/v1" "$(db_setup_for fixtures/16s-v4/v1)"

echo "record.yaml"
mkdir -p "$WORK/run" && cd "$WORK/run" || exit 1
state_init abcdefgh > /dev/null
state_update '. + $f' --argjson f '{"pipeline": "ampliseq", "version": "ampliseq", "commit": "",
    "repository": "https://github.com/cmmr/gnoto", "dev": true, "title": "T", "retention": "1 Month",
    "answers": {"picrust": "true"}, "params": {"input": "x.tsv", "pplace_tree": "db:pplace/v1/bac16s.newick"},
    "inputs": [{"sample": "S1", "fastq1": "a.fq.gz", "bytes_1": 1, "sha256_1": "00"}]}'
record_write
check "keys in order, inputs last" "schema pipeline repository commit dev title retention ampliseq outputs inputs" \
    "$(yq -o=json . record.yaml | jq -r 'keys_unsorted | join(" ")')"
check "db: names kept" "db:pplace/v1/bac16s.newick" "$(yq .ampliseq.pplace_tree record.yaml)"
check "no site paths" "no" "$(grep -qE "$WORK|$CODE" record.yaml && echo yes || echo no)"
check "mode 664" "664" "$(stat -c %a record.yaml)"

echo "expiry"
EXPIRATION_NOTICE_DAYS=14 KEEP_RUN_DAYS=14 write_expiry abcdefgh Completed 2026-11-06T12:00:00Z
check "1 Month from the end" "2026-12-06T12:00:00Z" "$(yq .remove_utc "$WORK/data/expiry/abcdefgh")"
state_set retention Unlimited
rm -f "$WORK/data/expiry/abcdefgh"
write_expiry abcdefgh Completed 2026-11-06T12:00:00Z
check "Unlimited writes nothing" "no" "$([[ -e $WORK/data/expiry/abcdefgh ]] && echo yes || echo no)"
state_set debug true
write_expiry abcdefgh Completed 2026-11-06T12:00:00Z
check "but --debug still has its cleanup" "none 2026-11-20T12:00:00Z" \
    "$(yq '.remove_utc // "none"' "$WORK/data/expiry/abcdefgh") $(yq .cleanup_utc "$WORK/data/expiry/abcdefgh")"
write_expiry abcdefgh Failed 2026-11-06T12:00:00Z
check "a failed run goes after keep_run_days" "2026-11-20T12:00:00Z" "$(yq .remove_utc "$WORK/data/expiry/abcdefgh")"

echo "Nextflow's failure reports"
# As taxprofiler's ended on the cluster: other tasks were let finish, so the
# log has no "Session aborted", and the command's error is only warnings
cat > nf.out << 'EOF'
[7e/e056d6] Submitted process > NFCORE_TAXPROFILER:TAXPROFILER:STANDARDISATION_PROFILES:TAXPASTA_STANDARDISE (motus|db)
ERROR ~ Error executing process > 'NFCORE_TAXPROFILER:TAXPROFILER:STANDARDISATION_PROFILES:TAXPASTA_STANDARDISE (metaphlan|db)'

Caused by:
  Process `NFCORE_TAXPROFILER:TAXPROFILER:STANDARDISATION_PROFILES:TAXPASTA_STANDARDISE (metaphlan|db)` terminated with an error exit status (1)

Command output:
  CRITICAL Unexpected report format. It has 5 columns but only 4 are expected.

Command error:
  FutureWarning: Importing pandas-specific classes and functions from the

Work dir:
  /data/runs/x/work/be/518582

Tip: you can replicate the issue by changing to the process work dir
Execution cancelled -- Finishing pending tasks before exit
ERROR ~ Pipeline failed. Please refer to troubleshooting docs for common issues
EOF
: > nf.log
check "the cause, from Caused by: when the log has none" \
    "Process \`NFCORE_TAXPROFILER:TAXPROFILER:STANDARDISATION_PROFILES:TAXPASTA_STANDARDISE (metaphlan|db)\` terminated with an error exit status (1)" \
    "$(nextflow_cause nf.out nf.log)"
echo "Session aborted -- Cause: from the log" > nf.log
check "or from the log when it has one" "from the log" "$(nextflow_cause nf.out nf.log)"
BLOCK=$(nextflow_error_block nf.out)
check "the error report holds the tool's own message" "yes" "$(has "$BLOCK" "CRITICAL Unexpected report format")"
check "and ends at the work directory" "  /data/runs/x/work/be/518582" "$(tail -n 1 <<< "$BLOCK")"
check "and is empty without a failed task" "" "$(nextflow_error_block nf.log)"

echo "the scheduler"
check "sh_quote round trip" "it's a \"test\" \$HOME" "$(sh -c "printf '%s' $(sh_quote "it's a \"test\" \$HOME")")"
mkdir -p "$WORK/helper"
OUT=$(GNOTO_HELPER_DIR=$WORK/helper SLURM_ENABLED=false scheduler_submit --name x --dir "$WORK/run" \
    --log "$WORK/run/job.out" -- _local "$WORK/run")
check "local jobs are queued for the launcher" "local" "$OUT"
check "as one line" "$WORK/run	$WORK/run/job.out	_local $WORK/run" "$(cat "$WORK/helper/detach")"
check "a word with a space is refused" "1" \
    "$( (GNOTO_HELPER_DIR=$WORK/helper SLURM_ENABLED=false scheduler_submit --name x --dir "$WORK/run" \
        --log "$WORK/run/job.out" -- _local "$WORK/a b") > /dev/null 2>&1; echo $?)"
check "lint_hours reads both forms" "48 168 2" "$(lint_hours 48.h) $(lint_hours 7-00:00:00) $(lint_hours 2:00:00)"
check "slurm_time turns Nextflow's form into Slurm's" "2-00:00:00 0-01:30:00 3-00:00:00" \
    "$(slurm_time 48.h) $(slurm_time 90.m) $(slurm_time 3.d)"
check "and passes Slurm's own as they are" "2-00:00:00|48:00:00|90|UNLIMITED|" \
    "$(slurm_time 2-00:00:00)|$(slurm_time 48:00:00)|$(slurm_time 90)|$(slurm_time UNLIMITED)|$(slurm_time "")"
check "and refuses anything else" "1 1 1" \
    "$(slurm_time 48h > /dev/null; echo $?) $(slurm_time 1.5.h > /dev/null; echo $?) $(slurm_time 'two days' > /dev/null; echo $?)"

exit $FAILED
