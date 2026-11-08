#!/bin/bash
#
# job-test.sh - Tests the job core's pieces that need no scheduler: gnoto new,
# the job file checks, record.yaml, the database lookups, the expiry file,
# Nextflow's failure reports, jobs that die at launch, the nodes gnoto's jobs
# avoid and the checks that find them, local queueing and the scheduler's
# quoting, in the real image. Slurm is stubbed where it's asked.
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
    "$(has "$OUT" "its task TAXPASTA_STANDARDISE (metaphlan|db) never ran. Slurm put it on node01 as job 5, and node01 couldn't write the task's log. node01 probably can't reach $WORK/run, so gnoto's jobs avoid it from now on, until gnoto lint finds it working.")"
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
check "which the message names" "yes" "$(has "$(no_node_left)" "gnoto's jobs avoid every node in partition main, as $WORK/data/excluded-nodes says")"
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
    *) echo "ssh: connect to host $host port 22: Connection refused" >&2; exit 255 ;;
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
check "a node ssh can't reach" "yes" \
    "$(has "$OUT" "WARN  compute nodes: ssh couldn't reach far (ssh: connect to host far port 22: Connection refused), so they weren't checked")"
check "a drained node isn't checked" "yes" "$(has "$OUT" "not checked, as Slurm isn't starting jobs there: old (drained)")"
check "and each node once" "1" "$(grep -o good1 <<< "$OUT" | wc -l)"
check "leaves them avoiding the right nodes" "old bad" "$(excluded_nodes | cut -f1 | paste -sd ' ')"
OUT=$(PATH=$WORK/bin:$PATH SLURM_MIN_TMP=999999.TB SLURM_ENABLED=true LINT_SLURM_OK=true LINT_PARTITION=p nodes_lint)
check "a node with less free in /tmp than slurm.min_tmp" "yes" \
    "$(grep -qE "WARN  compute node good1: has [0-9.]+ [KMGT]B free in /tmp, less than slurm.min_tmp, 999999.TB. gnoto's jobs avoid it" <<< "$OUT" && echo yes || echo no)"
OUT=$(PATH=$WORK/bin:$PATH SLURM_ENABLED=true SLURM_PARTITION=p nodes_prescan)
check "the check before a job takes it off once /tmp has room" "yes" \
    "$(has "$OUT" "OK    compute node good1: works now, so gnoto's jobs use it again")"
check "and counts the nodes that pass" "yes" "$(has "$OUT" "OK    compute nodes: the 2 that ssh reached can run gnoto's jobs")"
check "and still reports a node that fails" "yes" "$(has "$OUT" "WARN  compute node bad: can't see /data/x.")"
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
    "$(has "$OUT" "WARN  compute nodes: not checked, as they have no CPU free now: full, tight. gnoto config slurm --probe checks every node")"
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
    "$(has "$(SLURM_ENABLED=false nodes_probe 2>&1)" "Slurm is off in gnoto, so there are no nodes to probe.")"
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
    "$(has "$OUT" "Why        The followup never ran. Slurm put it on node01 as job 5, and node01 couldn't write its log, followup.out. node01 probably can't reach $WORK/data/runs/abcdefgh. gnoto lint checks every node")"
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
