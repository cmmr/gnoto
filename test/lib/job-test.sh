#!/bin/bash
#
# job-test.sh - Tests the job core's pieces that need no scheduler: gnoto new,
# the job file checks, record.yaml, the database lookups, the expiry file,
# Nextflow's failure reports, jobs that die at launch, the nodes gnoto's jobs
# avoid and the checks that find them, local queueing and the scheduler's
# quoting, in the real image. Slurm is stubbed where it's asked.
#
# Run by:    a developer, as any user, through the launcher:
#            gnoto exec --dev bash <install>/test/lib/job-test.sh
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
# What the launcher passes when gnoto on the user's PATH isn't this install's
export GNOTO_LAUNCHER=$WORK/install/gnoto
source "$CODE/lib/env.sh" || exit 1
source "$CODE/lib/args.sh"
source "$CODE/lib/lint.sh"
source "$CODE/lib/jobfile.sh"
source "$CODE/lib/databases.sh"
source "$CODE/lib/followup.sh"
cd "$WORK/jobs" || exit 1

# gnoto new's message when it refuses, without the date
new_error() {
    (job_new "$@" 2>&1 > /dev/null) | sed 's/^\[[^]]*\] ERROR: //'
}

echo "gnoto new"
(job_new ampliseq) > ampliseq.yaml 2> new.err
check "prints the job file, and nothing else" "ampliseq.yaml new.err" "$(ls | paste -sd ' ')"
check "with every option" "title samplesheet retention dada_ref_taxonomy picrust exclude_taxa mergepairs_strategy" \
    "$(yq -o=json . ampliseq.yaml | jq -r '[keys_unsorted[] | select(. != "pipeline" and . != "ampliseq")]
        + (.ampliseq | keys_unsorted) | join(" ")')"
check "retention defaults to 3 Months" "3 Months" "$(yq .retention ampliseq.yaml)"
check "and its help as comments" "yes" "$(has "$(cat ampliseq.yaml)" "# The default is silva=138.2")"
check "refuses an unknown pipeline" "1" "$( (job_new nothing) > /dev/null 2>&1; echo $?)"
check "needs a pipeline" "Usage: gnoto new <pipeline>[@<version>] [--dev] [--<key>=<value> ...] > job.yaml" "$(new_error)"

echo "gnoto new, with values"
(job_new ampliseq --title="Mock = 16S, run 2" --samplesheet good.tsv --retention "1 Month" \
    --ampliseq.picrust=true --ampliseq.exclude_taxa=mitochondria,chloroplast --ampliseq.mergepairs_strategy= \
    --ampliseq.trunclenf=230 --ampliseq.trunclenr 160 --ampliseq.skip_fastqc=true) > set.yaml 2> new.err
check "a space and = in a value" "Mock = 16S, run 2" "$(yq .title set.yaml)"
check "the space form" "1 Month" "$(yq .retention set.yaml)"
check "a relative samplesheet made absolute" "$WORK/jobs/good.tsv" "$(yq .samplesheet set.yaml)"
check "nothing on stderr" "" "$(cat new.err)"
check "the section, typed: options as their values are, parameters as the schema says, after the options" \
    "picrust true boolean|exclude_taxa mitochondria,chloroplast string|mergepairs_strategy  string|trunclenf 230 number|trunclenr 160 number|skip_fastqc true boolean" \
    "$(yq -o=json .ampliseq set.yaml | jq -r 'to_entries[1:][] | "\(.key) \(.value) \(.value | type)"' | paste -sd '|')"
check "numbers and booleans bare, an empty value quoted" '  picrust: true|  mergepairs_strategy: ""|  trunclenf: 230|  skip_fastqc: true' \
    "$(grep -E '^  (picrust|mergepairs_strategy|trunclenf|skip_fastqc):' set.yaml | paste -sd '|')"
(job_new ampliseq --title "Mock 16S" --samplesheet="$WORK/jobs/good.tsv" --ampliseq.picrust false) > set2.yaml
check "an absolute samplesheet as given, and a false" "$WORK/jobs/good.tsv false" \
    "$(yq '.samplesheet + " " + (.ampliseq.picrust | tostring)' set2.yaml)"

echo "gnoto new, refused"
check "an unknown key" "--colour isn't an option for ampliseq. Its options are --title, --samplesheet, --retention, --ampliseq.dada_ref_taxonomy, --ampliseq.picrust, --ampliseq.exclude_taxa, --ampliseq.mergepairs_strategy, and any ampliseq parameter goes as --ampliseq.<parameter>." \
    "$(new_error ampliseq --colour=blue)"
check "a section option without its section" "--picrust goes in ampliseq's section, as --ampliseq.picrust." \
    "$(new_error ampliseq --picrust=true)"
check "another pipeline's parameter" "--taxprofiler.x: this job runs ampliseq, so its parameters go as --ampliseq.<parameter>." \
    "$(new_error ampliseq --taxprofiler.x=1)"
check "an unknown parameter" "--ampliseq.not_a_parameter: ampliseq has no parameter not_a_parameter at its pinned commit." \
    "$(new_error ampliseq --ampliseq.not_a_parameter=1)"
check "a word for a number" "--ampliseq.trunclenf takes a whole number." "$(new_error ampliseq --ampliseq.trunclenf=x)"
check "an empty value for a boolean" "--ampliseq.skip_fastqc takes true or false." "$(new_error ampliseq --ampliseq.skip_fastqc=)"
check "a value the option doesn't offer" "--ampliseq.picrust takes one of: false, true, not maybe" \
    "$(new_error ampliseq --ampliseq.picrust=maybe)"
check "one of several it doesn't offer" \
    "--ampliseq.exclude_taxa takes some of: mitochondria, chloroplast, Francisella, not nothing" \
    "$(new_error ampliseq --ampliseq.exclude_taxa="chloroplast, nothing")"
check "a key with no value" "--title needs a value, as --title=<value>. Usage: gnoto new <pipeline>[@<version>] [--dev] [--<key>=<value> ...] > job.yaml" \
    "$(new_error ampliseq --title)"
check "a value after a space can't start with --" "yes" \
    "$(has "$(new_error ampliseq --title --ampliseq.picrust=true)" "--title needs a value")"
check "a key given twice" "--title is given twice." "$(new_error ampliseq --title=a --title=b)"
check "a single dash" "yes" "$(has "$(new_error ampliseq -t x)" "-t isn't an option.")"
check "two pipelines" "yes" "$(has "$(new_error ampliseq taxprofiler)" "Usage: gnoto new")"

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
check "gnoto new's job file, with values, passes" "yes" "$(has "$(lint_job set.yaml)" "fails=0")"

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
printf 'title: "No pipeline"\n' > no-pipeline.yaml
check "a hint names the install's launcher, so it runs as written" "yes" \
    "$(has "$(lint_job no-pipeline.yaml)" "FAIL  pipeline: is missing. $WORK/install/gnoto new <pipeline> writes a job file with it filled in")"

cat > ref.yaml << EOF
pipeline: ampliseq
title: "Reference"
samplesheet: "good.tsv"
ampliseq:
  qiime_ref_taxonomy: silva=138
EOF
check "a reference choice with no database entry" "yes" \
    "$(has "$(lint_job ref.yaml)" "No database in pipelines/databases.yaml provides qiime_ref_taxonomy silva=138")"

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
printf '%s\t%s\t%s\n' mock "$WORK/db/fixtures/16s-v4/v1/SRR17380142_1.fastq.gz" \
    "$WORK/db/fixtures/16s-v4/v1/SRR17380142_2.fastq.gz" > fixture.tsv
sed 's/good.tsv/fixture.tsv/' good.yaml > fixture.yaml
OUT=$(lint_job fixture.yaml)
check "a samplesheet naming a missing fixture's files doesn't fail on them" "no" "$(has "$OUT" "doesn't exist")"
check "the fixture is a database to fetch" "yes" \
    "$(has "$OUT" "db:fixtures/16s-v4/v1 is missing, at $WORK/db/fixtures/16s-v4/v1. gnoto can fetch it")"
check "the only failure, which fetching fixes" "1 1" \
    "$(LINT_FAILS=0; job_check fixture.yaml > /dev/null 2>&1; echo "$LINT_FAILS $JOB_MISSING_DATABASES")"
check "a file in the database directory with no entry still fails" "yes" \
    "$(printf 'S\t%s\n' "$WORK/db/nothing/x.fastq.gz" > nowhere.tsv
        sed 's/good.tsv/nowhere.tsv/' good.yaml > nowhere.yaml
        has "$(lint_job nowhere.yaml)" "$WORK/db/nothing/x.fastq.gz doesn't exist")"
mv "$WORK/db/fixtures/16s-v4/v1.away" "$WORK/db/fixtures/16s-v4/v1"
check "once it's there, its files are the job's databases" "db:fixtures/16s-v4/v1/SRR17380142_1.fastq.gz db:fixtures/16s-v4/v1/SRR17380142_2.fastq.gz" \
    "$(LINT_FAILS=0; job_check fixture.yaml > /dev/null 2>&1; grep '^db:fixtures/' <<< "$JOB_DATABASES" | paste -sd ' ')"
cat > virus-on.yaml << EOF
pipeline: biobakery
title: "Viruses"
samplesheet: "good.tsv"
biobakery:
  run_esviritu: true
EOF
sed 's/run_esviritu: true/run_esviritu: false/' virus-on.yaml > virus-off.yaml
# What lint checks for and offers to fetch, and the names run passes to the record
lint_databases() {
    (
        LINT_FAILS=0
        LINT_WARNS=0
        job_check "$1" > /dev/null 2>&1
        printf '%s\n' "$JOB_DATABASES" ${JOB_FETCHABLE[@]+"${JOB_FETCHABLE[@]}"}
    ) | grep -cxE "(db:)?esviritu/v3.2.4"
}
OUT=$(lint_job virus-on.yaml)
check "a biobakery job that turns EsViritu on needs its database" "yes" \
    "$(has "$OUT" "db:esviritu/v3.2.4 is missing, at $WORK/db/esviritu/v3.2.4. gnoto can fetch it")"
check "which lint offers to fetch, and the record names" "2" "$(lint_databases virus-on.yaml)"
check "one that turns it off doesn't" "no 0" \
    "$(has "$(lint_job virus-off.yaml)" "db:esviritu") $(lint_databases virus-off.yaml)"
check "entries by db: name" "pplace/v1 fixtures/16s-v4/v1 hostremoval/phix/v1  " \
    "$(for n in db:pplace/v1/bac16s.newick db:fixtures/16s-v4/v1/x db:hostremoval/phix/v1/phix.fa db:nothing/here; do
        printf '%s ' "$(db_entry_for "$n")"; done)"
check "a fixture's download size" "2924900" "$(db_bytes_for fixtures/16s-v4/v1)"
check "a fixture's setup" "steps/fetch_files.sh fixtures/16s-v4/v1" "$(db_setup_for fixtures/16s-v4/v1)"
check "and those made from their downloads" "steps/fetch_fixture.sh fixtures/wgs-mock/v1|steps/fetch_fixture.sh fixtures/16s-v5v6/v1" \
    "$(db_setup_for fixtures/wgs-mock/v1)|$(db_setup_for fixtures/16s-v5v6/v1)"
check "a fetch job's resources, from fetch_job or the defaults" "16 64G 24:00:00|2 8G 24:00:00" \
    "$(db_fetch_job_for hostremoval/chm13v2phix/v1)|$(db_fetch_job_for pplace/v1)"

echo "databases against the lock"
# A database at an entry's path, with the lock read from a scratch file
source "$CODE/steps/fetch_files.sh"
TEST_DB=esviritu/v3.2.4
mkdir -p "$WORK/db/$TEST_DB/sub"
printf 'genomes\n' > "$WORK/db/$TEST_DB/a.fna"
printf 'meta\n' > "$WORK/db/$TEST_DB/sub/b.tsv"
read -r FILES BYTES DIGEST <<< "$(tree_summary "$WORK/db/$TEST_DB")"
TEST_LOCK=$WORK/test-lock.json
printf '{"db:%s": {"files": %s, "bytes": %s, "tree_sha256": "%s"}}\n' "$TEST_DB" "$FILES" "$BYTES" "$DIGEST" > "$TEST_LOCK"
db_lock_entry() {
    jq -c --arg key "db:$2" '.[$key] // empty' "$TEST_LOCK"
}
verify() {
    databases_verify biobakery "$1" "${2:-false}" | cut -f1,2,4 | tr '\t' '|'
}
check "the tree digest is the one a manifest records" "$DIGEST" "$(db_tree_digest "$WORK/db/$TEST_DB")"
check "a pinned database that matches" "db:$TEST_DB|ok|" "$(verify "db:$TEST_DB/a.fna")"
check "and by its tree digest" "db:$TEST_DB|ok|" "$(verify "db:$TEST_DB/a.fna" true)"
check "its record entry is the lock's" "$(jq -c ".\"db:$TEST_DB\"" "$TEST_LOCK")" \
    "$(databases_verify biobakery "db:$TEST_DB" | cut -f3)"
check "each entry once" "1" "$(databases_verify biobakery "db:$TEST_DB/a.fna"$'\n'"db:$TEST_DB/sub/b.tsv" | wc -l)"
printf 'x' >> "$WORK/db/$TEST_DB/a.fna"
check "a byte more is wrong, by size" "db:$TEST_DB|wrong|db:$TEST_DB holds 2 files and $((BYTES + 1)) bytes, where biobakery's lock.yaml pins 2 files and $BYTES bytes" \
    "$(verify "db:$TEST_DB")"
printf 'genomez\n' > "$WORK/db/$TEST_DB/a.fna"
check "the same size with other bytes passes by size" "db:$TEST_DB|ok|" "$(verify "db:$TEST_DB")"
check "and fails by tree digest" "db:$TEST_DB|wrong|db:$TEST_DB's tree digest is $(db_tree_digest "$WORK/db/$TEST_DB"), where biobakery's lock.yaml pins $DIGEST" \
    "$(verify "db:$TEST_DB" true 2> /dev/null)"
printf 'genomes\n' > "$WORK/db/$TEST_DB/a.fna"
mkdir -p "$WORK/db/test/small"
printf 'tree\n' > "$WORK/db/test/small/t.newick"
check "a database no entry or lock pins is measured" "db:test/small/t.newick|unpinned|{\"files\":1,\"bytes\":5}|" \
    "$(databases_verify biobakery db:test/small/t.newick | tr '\t' '|')"
check "a missing one is left to the presence check" "" "$(verify db:test/nothing)"
OUT=$(JOB_PIPELINE=biobakery databases_check "db:$TEST_DB"$'\n'db:test/small/t.newick)
check "lint: pinned and unpinned" "yes yes" \
    "$(has "$OUT" "databases: all 2 present, 1 as lock.yaml pins them") $(has "$OUT" "db:test/small/t.newick isn't pinned by biobakery's lock.yaml, so the record keeps only its size")"
OUT=$(JOB_PIPELINE=biobakery LINT_DEEP=true databases_check "db:$TEST_DB" 2> /dev/null)
check "lint --deep" "yes" "$(has "$OUT" "databases: all 1 present, 1 as lock.yaml pins them, by tree digest")"
printf 'x' >> "$WORK/db/$TEST_DB/a.fna"
OUT=$(JOB_PIPELINE=biobakery databases_check "db:$TEST_DB"; echo "fails=$LINT_FAILS")
check "lint fails on one that doesn't match" "yes no" \
    "$(has "$OUT" "FAIL  db:$TEST_DB holds 2 files") $(has "$OUT" "fails=0")"
printf 'genomes\n' > "$WORK/db/$TEST_DB/a.fna"

mkdir -p "$WORK/dbrun" && cd "$WORK/dbrun" || exit 1
state_init dbrunabc > /dev/null
state_set pipeline biobakery > /dev/null
(databases_job_check "db:$TEST_DB"$'\n'db:test/small/t.newick "" null) > /dev/null 2>&1
check "the job keeps each one's record entry" "$(jq -c ".\"db:$TEST_DB\"" "$TEST_LOCK") {\"files\":1,\"bytes\":5}" \
    "$(state_get_json database_record | jq -c ".\"db:$TEST_DB\", .\"db:test/small/t.newick\"" | paste -sd' ')"
OUT=$( (databases_job_check db:test/small/t.newick true '{"db:test/small/t.newick": {"files": 1, "bytes": 6}}') 2>&1 )
check "an exact re-run fails on an unpinned one that changed" "1 yes" \
    "$? $(has "$OUT" "db:test/small/t.newick holds 1 files and 5 bytes, where the record has 1 files and 6 bytes.")"
printf 'genomez\n' > "$WORK/db/$TEST_DB/a.fna"
OUT=$( (databases_job_check "db:$TEST_DB" true null) 2>&1 )
check "an exact re-run checks the tree digest" "1 yes" "$? $(has "$OUT" "tree digest is")"
OUT=$( (databases_job_check "db:$TEST_DB" "" null) 2>&1 )
check "an ordinary run checks the size" "0" "$?"
printf 'genomes\n' > "$WORK/db/$TEST_DB/a.fna"
unset -f db_lock_entry
source "$CODE/lib/databases.sh"
cd "$WORK/jobs" || exit 1

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
state_set_json database_record '{"db:pplace/v1": {"files": 2, "bytes": 3, "tree_sha256": "ab"}}' > /dev/null
record_write
check "the databases the job read, before the outputs" "schema pipeline repository commit dev title retention ampliseq databases outputs inputs" \
    "$(yq -o=json . record.yaml | jq -r 'keys_unsorted | join(" ")')"
check "each by its lock entry or size" "2 ab" \
    "$(yq -o=json .databases record.yaml | jq -r '."db:pplace/v1" | "\(.files) \(.tree_sha256)"')"

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

echo "jobs that die at launch"
# As on the cluster, where a node without the data directory's mount failed
# each job Slurm put there before its script ran, leaving no log
cat > nf.log << 'EOF'
Nov-07 18:46:33.700 [Task submitter] DEBUG n.executor.GridTaskHandler - [SLURM] submitted process X (y) > jobId: 4; workDir: /data/runs/x/work/be/5185820
Nov-07 18:46:33.701 [Task submitter] DEBUG n.executor.GridTaskHandler - [SLURM] submitted process NFCORE_TAXPROFILER:TAXPROFILER:STANDARDISATION_PROFILES:TAXPASTA_STANDARDISE (metaphlan|db) > jobId: 5; workDir: /data/runs/x/work/be/518582
EOF
check "a task's job, by its work directory" "5" "$(nextflow_task_job /data/runs/x/work/be/518582 nf.log)"
check "not one whose directory only starts the same" "4" "$(nextflow_task_job /data/runs/x/work/be/5185820 nf.log)"
check "the failing task, and its short name" "/data/runs/x/work/be/518582|TAXPASTA_STANDARDISE (metaphlan|db)" \
    "$(nextflow_failed_task nf.out | paste -sd '|')"

# Slurm as the stand-ins would answer: squeue while it remembers a job, then sacct
declare -A STUB_STATE=([4]=FAILED [5]=FAILED [6]=FAILED [7]=COMPLETED [9]=FAILED [10]=COMPLETED
    [11]=CANCELLED [12]=FAILED)
declare -A STUB_NODE=([4]=node09 [5]=node01 [6]=node03 [7]=node02 [9]=node04 [12]="None assigned")
stub_id() {
    while [[ $# -gt 0 && $1 != -j ]]; do shift; done
    printf '%s' "${2:-}"
}
stub_squeue() {
    local id
    id=$(stub_id "$@")
    [[ -n $id && -n ${STUB_STATE[$id]:-} && $id != 6 ]] || return 0
    if [[ $* == *%N* ]]; then echo "${STUB_STATE[$id]}|${STUB_NODE[$id]:-}"; else echo "${STUB_STATE[$id]}"; fi
}
squeue() { stub_squeue "$@"; }
sacct() {
    local id
    id=$(stub_id "$@")
    [[ $id == 6 ]] || return 0
    if [[ $* == *NodeList* ]]; then echo "FAILED|node03"; else echo FAILED; fi
}
check "the node a job failed on with no log" "node01" "$(slurm_launch_node 5 nowhere.log)"
check "from sacct once squeue forgets it" "node03" "$(slurm_launch_node 6 nowhere.log)"
check "none when the log was written" "" "$(slurm_launch_node 5 nf.out)"
check "or the job completed" "" "$(slurm_launch_node 7 nowhere.log)"
check "or never reached a node" "" "$(slurm_launch_node 12 nowhere.log)"
check "or there's no job" "" "$(slurm_launch_node "" nowhere.log)"

source "$CODE/lib/job.sh"
cp nf.out nextflow.out
cp nf.log nextflow.log
state_set scheduler.kind slurm
OUT=$(task_launch_failure)
check "the pipeline's message names the task, node and job" "yes" \
    "$(has "$OUT" "its task TAXPASTA_STANDARDISE (metaphlan|db) never ran. Slurm put it on node01 as job 5, and node01 couldn't write the task's log. node01 probably can't reach $WORK/run, so gnoto's jobs avoid it from now on, until $WORK/install/gnoto lint finds it working.")"
state_set scheduler.kind local
check "and says nothing without Slurm" "" "$(task_launch_failure)"
check "the followup's, for a head job that never ran" "yes" \
    "$(has "$(slurm_end_message 9)" "The job never ran. Slurm put it on node04 as job 9, and node04 couldn't write its log, job.out. node04 probably can't reach $WORK/run, so gnoto's jobs avoid it from now on")"
state_set scheduler.after afterok:10:12
check "and for one cancelled because a fetch failed" "yes" \
    "$(has "$(slurm_end_message 11)" "a database fetch it waited for didn't complete: job 12, FAILED.")"
: > job.out
check "but not for one cancelled after it ran" "The job was cancelled in Slurm." "$(slurm_end_message 11)"
rm -f job.out nextflow.out nextflow.log

echo "the nodes gnoto's jobs avoid"
check "each node a job died at launch on" "node01 node04" "$(excluded_nodes | cut -f1 | paste -sd ' ')"
printf '+node01\tagain\n+node02\tlint found it can\x27t see /x\n-node04\n' | excluded_nodes_update
check "adds and takes off nodes, keeping a node's first why" \
    "node01|a job there couldn't reach $WORK/run node02|lint found it can't see /x" \
    "$(excluded_nodes | cut -f1,3 | tr '\t' '|' | paste -sd ' ')"
check "with the date each was added" "$(date -u +%Y-%m-%d)" "$(excluded_nodes | cut -f2 | sort -u)"
check "in a file gnoto's group can change" "664" "$(stat -c %a "$WORK/data/excluded-nodes")"
sinfo() {
    case $* in
        *'%N %P'*) printf '%s\n' 'node01 main*' 'node02 main*' 'node03 main*' 'node03 big' 'gpu1 gpu' ;;
        *%P*) printf '%s\n' 'main*' big gpu ;;
    esac
}
printf '+ghost\tgone\n' | excluded_nodes_update
check "sbatch is given those Slurm has" "node01,node02 0" "$(out=$(slurm_exclude_list); echo "$out $?")"
check "in any partition" "node01,node02 0" "$(out=$(SLURM_PARTITION=big slurm_exclude_list); echo "$out $?")"
printf '+gpu1\tx\n' | excluded_nodes_update
check "and none is left when they're every node in the partition" "node01,node02,gpu1 3" \
    "$(out=$(SLURM_PARTITION=gpu slurm_exclude_list); echo "$out $?")"
printf '+node03\tx\n' | excluded_nodes_update
check "or in the default one" "3" "$(slurm_exclude_list > /dev/null; echo $?)"
check "which the message names" "yes" "$(has "$(no_node_left)" "gnoto's jobs avoid every node in partition main, as $WORK/data/excluded-nodes says, so none can run. Once they're fixed, $WORK/install/gnoto lint takes them off.")"
printf -- '-node03\n' | excluded_nodes_update
sbatch() { printf '%s\n' "$@" > "$WORK/sbatch.args"; echo "77;cluster"; }
OUT=$(SLURM_ENABLED=true scheduler_submit --name x --dir "$WORK/run" --log "$WORK/run/job.out" -- _job "$WORK/run")
check "gnoto's own jobs avoid them" "77 --exclude=node01,node02,gpu1" "$OUT $(grep -- --exclude "$WORK/sbatch.args")"
rm -f "$WORK/sbatch.args"
OUT=$(SLURM_ENABLED=true SLURM_PARTITION=gpu scheduler_submit --name x --dir "$WORK/run" \
    --log "$WORK/run/job.out" -- _job "$WORK/run" 2>&1 && echo submitted)
check "and none is submitted when no node is left" "yes no no" \
    "$(has "$OUT" "avoid every node in partition gpu") $(has "$OUT" submitted) $([[ -e $WORK/sbatch.args ]] && echo yes || echo no)"
mkdir -p "$WORK/site"
(cd "$WORK/site" && SLURM_ENABLED=true SLURM_ACCOUNT=lab write_site_config)
check "Nextflow's tasks avoid them too" "    clusterOptions = ['--account=lab', '--exclude=node01,node02,gpu1']" \
    "$(grep clusterOptions "$WORK/site/site.config")"
printf -- '-node01\n-node02\n-gpu1\n-ghost\n' | excluded_nodes_update
(cd "$WORK/site" && SLURM_ENABLED=true write_site_config)
check "and with none to avoid, Nextflow is given no options" "0" "$(grep -c clusterOptions "$WORK/site/site.config")"
check "nor sbatch" "" \
    "$(SLURM_ENABLED=true scheduler_submit --name x --dir "$WORK/run" --log "$WORK/run/job.out" -- _job "$WORK/run" > /dev/null; grep -- --exclude "$WORK/sbatch.args")"
rm -f "$WORK/sbatch.args"
unset -f sbatch

echo "the node checks"
# ssh as a cluster's would answer, first on PATH, since timeout runs it as a
# command: a good node runs the check itself
mkdir -p "$WORK/bin"
cat > "$WORK/bin/ssh" << 'EOF'
#!/bin/bash
host=${@: -2:1}
case $host in
    good*) exec bash -c "${@: -1}" ;;
    bad) echo "missing /data/x"; exit 1 ;;
    *) printf 'ssh: connect to host %s port 22: Connection refused\r\n' "$host" >&2; exit 255 ;;
esac
EOF
chmod 755 "$WORK/bin/ssh"
check "the check is one line, with nothing a csh login shell would change" "1 0" \
    "$(node_check_script | grep -c '') $(node_check_script | tr -cd "'!" | wc -c | tr -d ' ')"
check "and checks /tmp only while slurm.min_tmp is set" "1 0" \
    "$(node_check_script | grep -c 'df -Pk /tmp') $(SLURM_MIN_TMP="" node_check_script | grep -c df)"
sinfo() {
    case $* in
        *'%N %n %T'*) printf 'good1 good1 idle\nbad bad mixed\nfar far allocated\nold old drained\ngood1 good1 idle\nsame good2 idle\n' ;;
        *'%N %P'*) printf '%s\n' 'good1 p*' 'bad p*' 'far p*' 'old p*' 'same p*' ;;
        *%N*) printf '%s\n' good1 bad far old same ;;
        *%P*) echo 'p*' ;;
    esac
}
printf '+same\tx\n+old\tgnoto lint found it can\x27t see /data/x\n+node09\tx\n' | excluded_nodes_update
OUT=$(PATH=$WORK/bin:$PATH SLURM_ENABLED=true LINT_SLURM_OK=true LINT_PARTITION=p nodes_lint)
check "lint: nodes that can run gnoto's jobs, asked by host name" "yes" \
    "$(has "$OUT" "OK    compute nodes: good1, same can run gnoto's jobs: they see $WORK/data and $WORK/db, flock works there, and /tmp has 50.GB free")"
check "a node that can't, which gnoto's jobs then avoid" "yes" \
    "$(has "$OUT" "WARN  compute node bad: can't see /data/x. gnoto's jobs avoid it until a check finds it working")"
check "a node they avoided that works now" "yes" \
    "$(has "$OUT" "OK    compute node same: works now, so gnoto's jobs use it again")"
check "one they avoid still, as it wasn't checked" "yes" \
    "$(has "$OUT" "WARN  compute node old: not checked this time, so gnoto's jobs still avoid it. On $(date -u +%Y-%m-%d), gnoto lint found it can't see /data/x")"
check "and one Slurm no longer has" "yes" \
    "$(has "$OUT" "OK    compute node node09: Slurm no longer has it, so gnoto's jobs no longer avoid it")"
check "a node ssh can't reach, when it reaches others, which gnoto's jobs then avoid" "yes" \
    "$(has "$OUT" "WARN  compute node far: couldn't be reached over ssh, which reaches the other nodes (ssh: connect to host far port 22: Connection refused). gnoto's jobs avoid it until a check finds it working")"
check "without the carriage return ssh ends its message with" "0" "$(grep -c $'\r' <<< "$OUT")"
check "a drained node isn't checked" "yes" "$(has "$OUT" "not checked, as Slurm isn't starting jobs there: old (drained)")"
check "and each node once" "1" "$(grep -o good1 <<< "$OUT" | wc -l)"
check "leaves them avoiding the right nodes" "old bad far" "$(excluded_nodes | cut -f1 | paste -sd ' ')"
OUT=$(PATH=$WORK/bin:$PATH SLURM_MIN_TMP=999999.TB SLURM_ENABLED=true LINT_SLURM_OK=true LINT_PARTITION=p nodes_lint)
check "a node with less free in /tmp than slurm.min_tmp" "yes" \
    "$(grep -qE "WARN  compute node good1: has [0-9.]+ [KMGT]B free in /tmp, less than slurm.min_tmp, 999999.TB. gnoto's jobs avoid it" <<< "$OUT" && echo yes || echo no)"
OUT=$(PATH=$WORK/bin:$PATH SLURM_ENABLED=true SLURM_PARTITION=p nodes_prescan)
check "the check before a job takes it off once /tmp has room" "yes" \
    "$(has "$OUT" "OK    compute node good1: works now, so gnoto's jobs use it again")"
check "and counts the nodes that pass" "yes" "$(has "$OUT" "OK    compute nodes: the 2 that ssh reached can run gnoto's jobs")"
check "and still reports a node that fails" "yes" "$(has "$OUT" "WARN  compute node bad: can't see /data/x.")"
check "and one ssh can't reach" "yes" "$(has "$OUT" "WARN  compute node far: couldn't be reached over ssh")"
check "and the ones still avoided, on one line" "yes" \
    "$(has "$OUT" "OK    compute nodes: gnoto's jobs still avoid old, which weren't checked this time")"
check "but not the drained ones" "no" "$(has "$OUT" "isn't starting jobs there")"
check "and says nothing where ssh reaches no node" "" "$(SLURM_ENABLED=true SLURM_PARTITION=p nodes_prescan)"
check "or without Slurm" "" "$(SLURM_ENABLED=false nodes_prescan)"

# Slurm as it answers the check jobs: sinfo with the nodes and their free CPUs
# and memory, sbatch submitting a job that ends at once or stays pending, and
# squeue and scancel for those jobs
sinfo() {
    case $* in
        *-O*)
            printf '%s\n' 'far 0/4/0/4 8000 0 idle' 'dead 0/4/0/4 8000 0 idle' 'nope 0/4/0/4 8000 0 idle' \
                'small 0/4/0/4 8000 0 idle' 'full 4/0/0/4 8000 2000 allocated' 'tight 1/3/0/4 8000 7900 mixed' ;;
        *'%N %n %T'*)
            printf '%s\n' 'far far idle' 'dead dead idle' 'nope nope idle' 'small small idle' \
                'full full allocated' 'tight tight mixed' ;;
        *'%N %P'*) printf '%s\n' 'far p*' 'dead p*' 'nope p*' 'small p*' 'full p*' 'tight p*' ;;
        *%N*) printf '%s\n' far dead nope small full tight ;;
        *%P*) echo 'p*' ;;
    esac
}
sbatch() {
    local arg out="" node="" name="" id
    for arg in "$@"; do
        case $arg in
            --output=*) out=${arg#--output=} ;;
            --nodelist=*) node=${arg#--nodelist=} ;;
            --job-name=*) name=${arg#--job-name=} ;;
        esac
    done
    echo "$node" >> "$WORK/submitted"
    [[ $node != nope ]] || { echo "sbatch: error: Invalid account or account/partition combination specified"; return 1; }
    id=$(cksum <<< "$node" | cut -c1-7)
    case $node in
        dead) echo "$id FAILED" >> "$WORK/stub-jobs" ;;
        small) echo "lowtmp 1048576" > "$out"; echo "$id FAILED" >> "$WORK/stub-jobs" ;;
        full | tight) echo "$id PENDING" >> "$WORK/stub-jobs" ;;
        *) echo gnoto-lint-ok > "$out"; echo "$id COMPLETED" >> "$WORK/stub-jobs" ;;
    esac
    echo "$id"
}
squeue() {
    if [[ $* == *--name=* ]]; then
        cat "$WORK/stub-jobs" 2> /dev/null
    else
        stub_squeue "$@"
    fi
}
scancel() { echo "$*" >> "$WORK/cancelled"; }
OUT=$(PATH=$WORK/bin:$PATH SLURM_ENABLED=true LINT_SLURM_OK=true LINT_PARTITION=p nodes_lint)
check "where ssh reaches no node, lint's Slurm jobs check those with CPUs free" "yes yes" \
    "$(has "$OUT" "OK    compute nodes: ssh doesn't reach them from here") $(has "$OUT" "OK    compute nodes: far can run gnoto's jobs: they see $WORK/data and $WORK/db, flock works there, and /tmp has 50.GB free, by a Slurm job on each")"
check "a node whose job left no log" "yes" \
    "$(has "$OUT" "WARN  compute node dead: couldn't write a job's log in $WORK/data. dead probably can't reach it. gnoto's jobs avoid it until a check finds it working")"
check "a node whose job found too little free in /tmp" "yes" \
    "$(has "$OUT" "WARN  compute node small: has 1.0 GB free in /tmp, less than slurm.min_tmp, 50.GB.")"
check "a node whose job sbatch refused, which isn't the node's doing" "yes" \
    "$(has "$OUT" "FAIL  compute node nope: sbatch refused its check job: sbatch: error: Invalid account")"
check "and busy nodes, left to the probe" "yes" \
    "$(has "$OUT" "WARN  compute nodes: not checked, as they have no CPU free now: full, tight. $WORK/install/gnoto config slurm --probe checks every node")"
check "with no job to a node without a CPU and memory free" "dead far nope small" "$(sort "$WORK/submitted" | paste -sd ' ')"
check "which leaves gnoto avoiding the nodes that failed" "dead small" "$(excluded_nodes | cut -f1 | paste -sd ' ')"
rm -f "$WORK/submitted" "$WORK/stub-jobs"
OUT=$(SLURM_ENABLED=true LINT_SLURM_OK=true LINT_PARTITION=p nodes_lint)
check "and through the stand-in, where the host's ssh can't reach them either" "yes yes" \
    "$(has "$OUT" "OK    compute nodes: ssh doesn't reach them from here") $(has "$OUT" "OK    compute nodes: far can run")"
rm -f "$WORK/submitted" "$WORK/stub-jobs"
OUT=$(LINT_FAILS=0 LINT_WARNS=0 NODES_PROBE_WAIT=4 SLURM_ENABLED=true SLURM_PARTITION=p nodes_probe 2>&1)
check "the probe sends a job to every node taking jobs, busy or not" "dead far full nope small tight" \
    "$(sort "$WORK/submitted" | paste -sd ' ')"
check "and says so" "yes" "$(has "$OUT" "Probing the 6 nodes taking jobs in partition p, with a Slurm job on each.")"
check "and cancels the jobs still waiting at its limit" "yes 2" \
    "$(has "$OUT" "WARN  compute nodes: not checked, as their check jobs hadn't run after 0 minutes, so they were cancelled: full, tight") $(wc -l < "$WORK/cancelled")"
check "and reports the rest as lint does" "yes yes" \
    "$(has "$OUT" "OK    compute nodes: far can run gnoto's jobs") $(has "$OUT" "WARN  compute node small: has 1.0 GB free in /tmp")"
check "and ends with a count" "1 failed, 3 warned." "$(tail -1 <<< "$OUT")"
check "and refuses without Slurm" "yes" \
    "$(has "$(SLURM_ENABLED=false nodes_probe 2>&1)" "Slurm is off in gnoto, so there are no nodes to probe. To turn it on: $WORK/install/gnoto config slurm --on")"
rm -f "$WORK/submitted" "$WORK/stub-jobs" "$WORK/cancelled"
sinfo() {
    case $* in
        *-O*) echo 'full 4/0/0/4 8000 2000 allocated' ;;
        *'%N %n %T'*) echo 'full full allocated' ;;
        *'%N %P'*) echo 'full p*' ;;
        *%N*) echo full ;;
        *%P*) echo 'p*' ;;
    esac
}
OUT=$(PATH=$WORK/bin:$PATH SLURM_ENABLED=true LINT_SLURM_OK=true LINT_PARTITION=p nodes_lint)
check "and lint checks none when no node has CPUs free" "yes no" \
    "$(has "$OUT" "WARN  compute nodes: not checked, as they have no CPU free now: full.") $(has "$OUT" "by a Slurm job")"
check "and nothing is left behind" "" "$(ls -A "$WORK/data" | grep node-check)"
rm -f "$WORK/submitted"

echo "status, for a run whose followup never ran"
source "$CODE/lib/runs.sh"
rm -f "$WORK/data/excluded-nodes"
set_run_status Running
state_set scheduler.kind slurm
state_set scheduler.job_id 9
state_set scheduler.followup_id 5
mkdir -p "$WORK/data/runs/abcdefgh"
cp "$RUN_STATE_FILE" "$WORK/data/runs/abcdefgh/"
OUT=$(status_one abcdefgh 2>&1)
check "is lost" "yes" "$(has "$OUT" "Status     Lost")"
check "and says where the job died" "yes" \
    "$(has "$OUT" "Why        The job never ran. Slurm put it on node04 as job 9, and node04 couldn't write its log, job.out.")"
check "and the followup" "yes" \
    "$(has "$OUT" "Why        The followup never ran. Slurm put it on node01 as job 5, and node01 couldn't write its log, followup.out. node01 probably can't reach $WORK/data/runs/abcdefgh. $WORK/install/gnoto lint checks every node")"
check "but leaves the nodes gnoto avoids alone, since the run may be old" "no" \
    "$([[ -e $WORK/data/excluded-nodes ]] && echo yes || echo no)"
rm -rf "$WORK/data/runs/abcdefgh"
unset -f squeue stub_squeue sacct sinfo sbatch scancel stub_id

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
