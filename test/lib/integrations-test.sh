#!/bin/bash
#
# integrations-test.sh - Tests phase 7's integrations in the real image,
# against the test bed's stand-ins: Wrike's calls and their replay, gnoto config
# wrike, a task's answers made into a job file, the listener's events,
# Publish to S3 and Globus, the progress page on S3, the teardown with its
# expired page, gnoto extend, the daily expiry check, gnoto remove of a
# published run, the health summary and the systemd units.
#
# Run by:    a developer, as alice or bob in the test bed, through the launcher,
#            once testbed.sh services has started the stand-ins:
#            gnoto exec --dev bash <install>/test/lib/integrations-test.sh
# Requires:  the gnoto image; the Wrike stub at http://wrike-stub:8080, s3mock
#            at http://s3mock:9090 with the bucket gnoto-results, which
#            ~/.aws/config points the AWS CLI at, as testbed.sh's notes say
#
# Its data directory is a scratch directory, and it resets the Wrike stub.

set -u

CODE=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "$GNOTO_DATA_DIR/test-integrations.XXXXXX")
STUB=http://wrike-stub:8080
S3=http://s3mock:9090/gnoto-results
FAILED=0
trap 'chmod -R u+rwX "$WORK" 2> /dev/null; rm -rf "$WORK"' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

has() {
    grep -qF -- "$2" <<< "$1" && echo yes || echo no
}

exists() {
    [[ -e $1 ]] && echo yes || echo no
}

stub() {
    curl -sS -X "$1" "$STUB$2" "${@:3}"
}

curl -sS -X POST "$STUB/_test/reset" > /dev/null || { echo "FAIL  the Wrike stub isn't running: testbed.sh services"; exit 1; }
mkdir -p "$WORK/install" "$WORK/data" "$WORK/globus"
PREFIX=itest$RANDOM
cat > "$WORK/install/config.yaml" << EOF
core:
  data_dir: "$WORK/data"
  input_roots: "$WORK/inputs"

wrike:
  enabled: true
  api_token: "stub-token"
  webhook_secret: "itest-secret"
  poll_minutes: 5
  api_url: "$STUB/api/v4"

aws:
  enabled: true
  access_key_id: "test"
  secret_access_key: "test"
  region: "us-east-1"
  s3_bucket: "gnoto-results"
  results_base_url: "$S3"
  run_prefix: "$PREFIX"
  sqs_queue_url: "http://elasticmq:9324/000000000000/itest"
  webhook_url: "https://hooks.example.invalid/wrike"
  access_url: "https://access.example.invalid/access"

globus:
  enabled: true
  dir: "$WORK/globus"
  uuid: "00000000-0000-0000-0000-000000000000"
  url: "https://globus.example.invalid"
  run_prefix: "gnoto"
  cli_client_id: "test-client"
  cli_client_secret: "test-secret"
  app_client_id: "11111111-1111-1111-1111-111111111111"
EOF
chmod 660 "$WORK/install/config.yaml"

# A stand-in for globus-cli's permission calls, which keeps the rules in
# $GLOBUS_STANDIN/globus-rules, a "<id>\t<principal type>\t<path>\t<principal>"
# line each, and records the client it was called as
mkdir -p "$WORK/globusbin"
cat > "$WORK/globusbin/globus" << 'EOF'
#!/bin/bash
RULES=$GLOBUS_STANDIN/globus-rules
touch "$RULES"
echo "${GLOBUS_CLI_CLIENT_ID:-}" > "$GLOBUS_STANDIN/globus-client"
case "$1 $2 $3" in
    "endpoint show "*) echo '{"display_name": "stand-in"}' ;;
    "endpoint permission create")
        path=${4#*:}
        type=anonymous
        principal=""
        args=("$@")
        for (( i = 4; i < ${#args[@]}; i++ )); do
            case ${args[i]} in
                --all-authenticated) type=all_authenticated_users ;;
                --identity) type=identity; principal=${args[i + 1]} ;;
            esac
        done
        if grep -qF "$(printf '\t%s\t%s\t%s' "$type" "$path" "$principal")" "$RULES"; then
            echo '{"code": "Exists", "message": "A permission for that principal and path exists"}'
            exit 1
        fi
        id=rule-$RANDOM$RANDOM
        printf '%s\t%s\t%s\t%s\n' "$id" "$type" "$path" "$principal" >> "$RULES"
        echo "{\"access_id\": \"$id\", \"code\": \"Created\"}"
        ;;
    "endpoint permission delete")
        grep -q "^$5	" "$RULES" || { echo "AccessRuleNotFound" >&2; exit 1; }
        grep -v "^$5	" "$RULES" > "$RULES.tmp"; mv "$RULES.tmp" "$RULES"
        ;;
    "endpoint permission list")
        jq -R -s '{DATA: [split("\n")[] | select(length > 0) | split("\t")
            | {id: .[0], principal_type: .[1], path: .[2], principal: (.[3] // "")}]}' "$RULES"
        ;;
    *) echo "the stand-in has no $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$WORK/globusbin/globus"
export GLOBUS_STANDIN=$WORK
export PATH=$WORK/globusbin:$PATH
export GNOTO_INSTALL_DIR=$WORK/install
export GNOTO_LAUNCHER=$WORK/install/gnoto
export WRIKE_TRIES=3 WRIKE_WAIT=0
source "$CODE/lib/env.sh" || exit 1
source "$CODE/lib/args.sh"
source "$CODE/lib/config.sh"
source "$CODE/lib/runs.sh"
source "$CODE/lib/followup.sh"
source "$CODE/lib/start.sh"
source "$CODE/service/expire.sh"
source "$CODE/service/daily.sh"
source "$CODE/service/wrike/task_handler.sh"
source "$CODE/service/access.sh"
source "$CODE/service/wrike/listener.sh"
source "$CODE/present/dashboard.sh"
source "$CODE/present/common.sh"
RUNS=$WORK/data/runs
HISTORY=$WORK/data/history
EXPIRY=$WORK/data/expiry

echo "Wrike's calls"
check "a call answers Wrike's data" "KUSTUBBOT" "$(wrike_call GET contacts -G --data-urlencode me=true | jq -r '.data[0].id')"
stub POST "/_test/fail?count=2&code=429" > /dev/null
check "a 429 is retried until it goes through" "KUSTUBBOT" "$(wrike_call GET contacts 2> /dev/null | jq -r '.data[0].id')"
stub POST "/_test/fail?count=5&code=503" > /dev/null
out=$(wrike_call GET contacts 2>&1)
check "a 503 that lasts fails, saying so" "yes" "$(has "$out" "failed: Wrike answered 503")"
stub POST "/_test/fail?count=0" > /dev/null
status=0
wrike_call GET tasks/NOSUCHTASK > /dev/null 2>&1 || status=$?
check "a 404 returns 2" "2" "$status"
out=$(ps -ef | grep -c '[s]tub-token')
check "the token isn't on any command line" "0" "$out"

echo "gnoto config wrike"
CONFIG_YES=1
out=$(config_wrike_step 2>&1)
source "$CODE/lib/env.sh"
check "it makes the folder" "yes" "$([[ -n ${WRIKE_FOLDER_ID:-} ]] && echo yes)"
check "and the six statuses" "6" "$(yq '.wrike.statuses | length' "$WORK/data/generated.yaml")"
check "and a field for each option, with gnoto's own" "yes" \
    "$([[ -n $(wrike_field_id pipeline) && -n $(wrike_field_id expiration) && -n $(wrike_field_id results) &&
        -n $(wrike_field_id mergepairs_strategy) && -n $(wrike_field_id hostremoval_reference) ]] && echo yes)"
check "one field for a question two pipelines ask" "1" \
    "$(stub GET /_test/state | jq '[.fields[] | select(.title == "Host Removal")] | length')"
check "a dropdown takes no other answers" "false" \
    "$(stub GET /_test/state | jq -r --arg id "$(wrike_field_id picrust)" '.fields[$id].settings.allowOtherValues')"
check "the webhook, for the listener's events" "TaskCreated,TaskCustomFieldChanged,TaskDeleted" \
    "$(stub GET /_test/state | jq -r '[.webhooks[]] | .[0].events | sort | join(",")')"
check "the salt" "yes" "$([[ -n ${RUN_ID_SALT:-} ]] && echo yes)"
check "generated.yaml is 660" "660" "$(stat -c %a "$WORK/data/generated.yaml")"
check "it prints the form's checklist" "yes" "$(has "$out" 'create a request form named "gnoto Request"')"
check "the checklist lists Pipeline's answers" "yes" "$(has "$out" "Pipeline: a dropdown, answers: ampliseq, biobakery, taxprofiler, Repeat an earlier run")"
spec=$(wrike_fields_spec)
form=$(jq -c --arg space "$WRIKE_SPACE_ID" '{title: "gnoto Request", spaceId: $space,
    pages: [{fields: [.[] | select(.gnoto | not) | {title, items: [.values[] | {title: .}]}]}]}' <<< "$spec")
stub POST /_test/form -d "$form" > /dev/null
calls=$(stub GET /_test/state | jq '[.calls[] | select(.verb != "GET")] | length')
out=$(config_wrike_step 2>&1)
check "run again, it changes nothing" "$calls" "$(stub GET /_test/state | jq '[.calls[] | select(.verb != "GET")] | length')"
check "and finds the form, which matches" "yes" "$(has "$out" 'matches gnoto')"
source "$CODE/lib/env.sh"
check "and records it" "yes" "$([[ -n ${WRIKE_FORM_ID:-} ]] && echo yes)"
LINT_FAILS=0 LINT_WARNS=0
out=$(lint_wrike)
check "lint: Wrike is set up" "yes" "$(has "$out" "OK    wrike: the request form matches options.yaml")"
check "lint: the webhook" "yes" "$(has "$out" "OK    wrike: webhook Active")"

echo "a task's answers, as a job file"
mkdir -p "$WORK/inputs"
printf 'mock1\t%s\t%s\n' "$WORK/inputs/a_1.fastq.gz" "$WORK/inputs/a_2.fastq.gz" > "$WORK/sheet.tsv"
# new_form_task <title> <fields as JSON>: a request, as the form makes it
new_form_task() {
    local id
    id=$(stub POST "/api/v4/folders/$WRIKE_FOLDER_ID/tasks" -H 'Authorization: bearer stub-token' \
        --data-urlencode "title=$1" --data-urlencode "customStatus=$(wrike_status_id submitted)" \
        --data-urlencode "customFields=$2" --data-urlencode "_author=KUREQUEST" | jq -r '.data[0].id')
    stub POST "/api/v4/tasks/$id/attachments" -H 'Authorization: bearer stub-token' -H 'X-File-Name: samples.tsv' \
        -H 'Content-Type: application/octet-stream' --data-binary "@$WORK/sheet.tsv" > /dev/null
    printf '%s' "$id"
}
field() {
    jq -cn --arg id "$(wrike_field_id "$1")" --arg v "$2" '{id: $id, value: $v}'
}
TASK=$(new_form_task "Form mock" "[$(field pipeline ampliseq),$(field retention "6 Months"),$(field picrust Yes),$(field exclude_taxa '["mitochondria","chloroplast"]'),$(field mergepairs_strategy concatenate)]")
JSON=$(wrike_call GET "tasks/$TASK")
mkdir -p "$WORK/job1"
wrike_job_file "$TASK" "$JSON" "$WORK/job1" > "$WORK/job1/why" 2>&1
check "it's written" "0" "$?"
check "with the task's title" "Form mock" "$(yq -r .title "$WORK/job1/job.yaml")"
check "and its retention" "6 Months" "$(yq -r .retention "$WORK/job1/job.yaml")"
check "a label as its value" "true" "$(yq -r .ampliseq.picrust "$WORK/job1/job.yaml")"
check "several answers, comma-separated" "mitochondria,chloroplast" "$(yq -r .ampliseq.exclude_taxa "$WORK/job1/job.yaml")"
check "an answer in the pipeline's section" "concatenate" "$(yq -r .ampliseq.mergepairs_strategy "$WORK/job1/job.yaml")"
check "the samplesheet attached, beside it" "samplesheet.tsv" "$(yq -r .samplesheet "$WORK/job1/job.yaml")"
check "as it was attached" "$(cat "$WORK/sheet.tsv")" "$(cat "$WORK/job1/samplesheet.tsv")"
TASK2=$(new_form_task "Bad" "[$(field pipeline ampliseq),$(field picrust Maybe)]")
mkdir -p "$WORK/job2"
out=$(wrike_job_file "$TASK2" "$(wrike_call GET "tasks/$TASK2")" "$WORK/job2" 2>&1)
check "an answer the form doesn't offer is turned down" "yes" "$(has "$out" "\"Maybe\" isn't an answer the form offers for picrust")"
TASK3=$(new_form_task "Repeat" "[$(field pipeline "Repeat an earlier run"),$(field previous_run "$S3/$PREFIX/abcdefgh/index.html")]")
mkdir -p "$HISTORY/abcdefgh" "$WORK/job3"
printf 'pipeline: ampliseq@%s\ntitle: "Old"\nsamplesheet: "/old/sheet.tsv"\nretention: "1 Month"\nampliseq:\n  picrust: true\n' \
    "0123456789012345678901234567890123456789" > "$HISTORY/abcdefgh/job.yaml"
wrike_job_file "$TASK3" "$(wrike_call GET "tasks/$TASK3")" "$WORK/job3" > /dev/null 2>&1
check "a repeat takes the earlier run's job, named by its address" "true" "$(yq -r .ampliseq.picrust "$WORK/job3/job.yaml" 2> /dev/null)"
TASK3T=$(new_form_task "Repeat by token" "[$(field pipeline "Repeat an earlier run"),$(field previous_run "$S3/$PREFIX/abcdefgh-abcdefghijklmnop/index.html")]")
mkdir -p "$WORK/job3t"
wrike_job_file "$TASK3T" "$(wrike_call GET "tasks/$TASK3T")" "$WORK/job3t" > /dev/null 2>&1
check "or by an address with its token" "true" "$(yq -r .ampliseq.picrust "$WORK/job3t/job.yaml" 2> /dev/null)"
check "at its version" "ampliseq@0123456789012345678901234567890123456789" "$(yq -r .pipeline "$WORK/job3/job.yaml" 2> /dev/null)"
check "with the new title and samplesheet" "Repeat samplesheet.tsv" "$(yq -r '.title + " " + .samplesheet' "$WORK/job3/job.yaml" 2> /dev/null)"
check "a request is waiting" "yes" "$(wrike_waiting "$JSON" "$(derive_uid "$TASK")" && echo yes)"
mkdir -p "$RUNS/$(derive_uid "$TASK")"
check "and isn't once it has a run directory" "no" "$(wrike_waiting "$JSON" "$(derive_uid "$TASK")" && echo yes || echo no)"
rmdir "$RUNS/$(derive_uid "$TASK")"
out=$(wrike_reject "$TASK2" "a test reason." 2>&1)
check "a rejection moves the task to Failed" "$(wrike_status_id failed)" "$(wrike_call GET "tasks/$TASK2" | jq -r '.data[0].customStatusId')"
check "with why in a comment" "yes" "$(stub GET /_test/state | jq -r --arg t "$TASK2" '.tasks[$t].comments[-1].text' | grep -q 'a test reason' && echo yes)"

echo "Wrike changes that fail, and their replay"
CLI=$(wrike_cli_task "CLI mock" ampliseq alice)
check "a command-line job's task starts Running" "$(wrike_status_id running)" "$(wrike_call GET "tasks/$CLI" | jq -r '.data[0].customStatusId')"
stub POST "/_test/fail?count=10&code=500" > /dev/null
wrike_set_status "$CLI" Completed 2> /dev/null
wrike_comment "$CLI" "First comment" 2> /dev/null
stub POST "/_test/fail?count=10&code=500" > /dev/null
wrike_set_status "$CLI" Failed 2> /dev/null
stub POST "/_test/fail?count=0" > /dev/null
check "a failed change waits to be replayed" "2" "$(ls "$WORK/data/logs/wrike-replay/" | wc -l)"
check "a later status replaces an earlier one waiting" "$(wrike_status_id failed)" \
    "$(jq -r '.[]' "$WORK/data/logs/wrike-replay/$CLI.status.json" | grep -o '[A-Z0-9]\{16\}$' | head -1)"
check "replayed, both go through" "2 2" "$(wrike_replay 2> /dev/null)"
check "and leave nothing waiting" "0" "$(ls "$WORK/data/logs/wrike-replay/" | wc -l)"
check "the task has the latest status" "$(wrike_status_id failed)" "$(wrike_call GET "tasks/$CLI" | jq -r '.data[0].customStatusId')"
wrike_set_status "$CLI" Running
stub DELETE "/api/v4/tasks/$CLI" -H 'Authorization: bearer stub-token' > /dev/null
wrike_set_status "$CLI" Completed 2> /dev/null
check "a change to a deleted task is dropped, not replayed" "0" "$(ls "$WORK/data/logs/wrike-replay/" | wc -l)"

# A finished run, as its followup leaves it: finished_run <uid> <task> <status>
# [pipeline]
finished_run() {
    local dir=$RUNS/$1
    mkdir -p "$dir/results/assets" "$HISTORY/$1"
    (
        cd "$dir" || exit 1
        state_init "$1" > /dev/null
        state_update '. + $f' --argjson f "$(jq -n --arg task "$2" --arg status "$3" --arg pipeline "${4:-ampliseq}" \
            --arg ended "$(date -u -d '-20 days' '+%Y-%m-%dT%H:%M:%SZ')" '
            {pipeline: $pipeline, version: ($pipeline + "@1.1.0"), title: "Mock run", retention: "1 Month",
             owner: "alice", status: $status, ended_utc: $ended, stages: {compute: $ended},
             samples: {count: 3}, scheduler: {kind: "local"}}
            + (if $task != "" then {wrike: {task_id: $task}} else {} end)')"
        echo '<html>dashboard</html>' > results/index.html
        echo 'a,b' > results/table.csv
        echo 'css' > results/assets/gnoto.css
        echo zip > "Mock-run_$1.zip"
        printf 'pipeline: ampliseq\n' > job.yaml
        printf 'schema: 1\n' > record.yaml
    )
}

echo "Publish"
# A run's published folder, <uid>-<token>, from its state
addr() {
    printf '%s-%s' "$1" "$(jq -r '.address_token' "$(run_state_path "$1")")"
}

UID1=$(derive_uid "MATESTRUN001")
finished_run "$UID1" "" Completed taxprofiler
A1=$(addr "$UID1")
check "a run's state has an address token" "yes" "$([[ $A1 =~ ^${UID1}-[a-z2-7]{16}$ ]] && echo yes)"
(cd "$RUNS/$UID1" && publish_run "$UID1" > "$WORK/publish.out" 2>&1)
check "it publishes" "0" "$?"
check "a pipeline in globus.pipelines puts its zip on Globus alone" "yes no" \
    "$(exists "$WORK/globus/gnoto/$UID1/Mock-run_$UID1.zip") $(curl -s -o /dev/null -w '%{http_code}' "$S3/$PREFIX/$A1/Mock-run_$UID1.zip" | grep -q 200 && echo yes || echo no)"
check "and grants nobody anything" "0" "$(cat "$WORK/globus-rules" 2> /dev/null | grep -c . || :)"
check "the results to S3, under the run's address" "<html>dashboard</html>" "$(curl -s "$S3/$PREFIX/$A1/index.html")"
check "and nothing at its uid alone" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$S3/$PREFIX/$UID1/index.html")"
check "a table typed as text, to open in the browser" "yes" \
    "$(curl -sI "$S3/$PREFIX/$A1/table.csv" | grep -qi '^content-type: text/plain' && echo yes)"
check "a page uncached" "yes" "$(curl -sI "$S3/$PREFIX/$A1/index.html" | grep -qi '^cache-control: no-cache' && echo yes)"
check "globus.json beside the dashboard, for the access Lambda" "$UID1" "$(curl -s "$S3/$PREFIX/$A1/globus.json" | jq -r .uid)"
check "the sign-in's return page, with the access address" "yes" \
    "$(curl -s "$S3/$PREFIX/access.html" | grep -qF 'var ACCESS = "https://access.example.invalid/access";' && echo yes)"
check "readable through the collection" "r" "$(stat -c %A "$WORK/globus/gnoto/$UID1/Mock-run_$UID1.zip" | cut -c8)"
check "and gone from the run directory" "no" "$(exists "$RUNS/$UID1/Mock-run_$UID1.zip")"
check "the state records where, and that it was checked" "yes" \
    "$(cd "$RUNS/$UID1" && [[ -n $(state_get published.verified_utc) && $(state_get published.s3_prefix) == "$PREFIX/$A1" &&
        $(state_get published.globus_dir) == "$WORK/globus/gnoto/$UID1" && $(state_get published.globus_path) == "/gnoto/$UID1/" ]] && echo yes)"
check "the dashboard's address" "$S3/$PREFIX/$A1/index.html" "$(cd "$RUNS/$UID1" && state_get published.url)"
check "the zip's" "https://globus.example.invalid/gnoto/$UID1/Mock-run_$UID1.zip?download" "$(cd "$RUNS/$UID1" && state_get published.zip_url)"
UIDS=$(derive_uid "MATESTRUN0S")
finished_run "$UIDS" "" Completed
AS=$(addr "$UIDS")
(cd "$RUNS/$UIDS" && publish_run "$UIDS" > /dev/null 2>&1)
check "any other pipeline's zip goes to S3, with Globus set" "zip no" \
    "$(curl -s "$S3/$PREFIX/$AS/Mock-run_$UIDS.zip") $(exists "$WORK/globus/gnoto/$UIDS")"
check "with no globus.json" "404" "$(curl -s -o /dev/null -w '%{http_code}' "$S3/$PREFIX/$AS/globus.json")"
check "taxprofiler and biobakery go to Globus, and ampliseq to S3" "globus globus s3" \
    "$(cd "$RUNS/$UIDS" && echo "$(zip_destination taxprofiler) $(zip_destination biobakery) $(zip_destination ampliseq)")"
check "as globus.pipelines says" "globus s3" \
    "$(cd "$RUNS/$UIDS" && GLOBUS_PIPELINES=ampliseq; echo "$(zip_destination ampliseq) $(zip_destination taxprofiler)")"
check "Globus isn't ready without its app, or Get the data's address" "s3 s3" \
    "$(cd "$RUNS/$UIDS" && echo "$(GLOBUS_APP_CLIENT_ID="" zip_destination taxprofiler) $(AWS_ACCESS_URL="" zip_destination taxprofiler)")"
check "S3 alone takes every zip, and neither leaves it here" "s3 local" \
    "$(cd "$RUNS/$UIDS" && echo "$(GLOBUS_ENABLED=false zip_destination taxprofiler) $(AWS_ENABLED=false zip_destination taxprofiler)")"
UID2=$(derive_uid "MATESTRUN002")
finished_run "$UID2" "" Completed taxprofiler
A2=$(addr "$UID2")
(cd "$RUNS/$UID2" && GLOBUS_ENABLED=false publish_run "$UID2" > /dev/null 2>&1)
check "without Globus, the zip goes to S3" "zip" "$(curl -s "$S3/$PREFIX/$A2/Mock-run_$UID2.zip")"
check "and its address is S3's" "$S3/$PREFIX/$A2/Mock-run_$UID2.zip" "$(cd "$RUNS/$UID2" && state_get published.zip_url)"
(cd "$RUNS/$UID2" && GLOBUS_ENABLED=false AWS_S3_BUCKET=no-such-bucket publish_run "$UID2" > "$WORK/fail.out" 2>&1)
check "a bucket it can't write fails the stage" "1" "$?"
check "with the reason" "yes" "$(grep -q "couldn't be copied to s3://no-such-bucket" "$WORK/fail.out" && echo yes)"
check "a taxprofiler zip's href names Globus" "https://globus.example.invalid/gnoto/$UID1/x.zip?download" \
    "$(cd "$RUNS/$UID1" && bundle_href x.zip "$UID1")"
check "and records where it goes, for Publish" "globus" "$(cd "$RUNS/$UID1" && state_get published.zip_destination)"
check "an ampliseq zip's, S3's, at the run's address" "$S3/$PREFIX/$AS/x.zip" "$(cd "$RUNS/$UIDS" && bundle_href x.zip "$UIDS")"
check "which Publish then follows" "s3" "$(cd "$RUNS/$UIDS" && publish_destination)"
check "or the run directory, without either" "../x.zip" \
    "$(cd "$RUNS/$UID1" && GLOBUS_ENABLED=false AWS_ENABLED=false bundle_href x.zip "$UID1")"
(cd "$RUNS/$UID1" && state_set published.zip_destination globus > /dev/null)
out=$(cd "$RUNS/$UID1" && dashboard_bundle "https://globus.example.invalid/gnoto/$UID1/x.zip?download" 1048576 &&
    dashboard_zip_button)
check "a zip on Globus gets Get the data, not a plain link" "yes no" \
    "$(has "$out" '<span id="get-data-label">Get the data</span>') $(has "$out" 'id="download-all"')"
check "with the run's address, the app and the return page" "$A1 11111111-1111-1111-1111-111111111111 $S3/$PREFIX/access.html" \
    "$(sed -n 's/^  var C = \(.*\);$/\1/p' <<< "$out" | jq -r '[.run, .client, .callback] | join(" ")')"
check "and the zip's size" "yes" "$(has "$out" '(1.0 MB)')"

echo "Get the data"
# access_event <run> <request> <identity>: the access Lambda's message
access_event() {
    jq -cn --arg run "$1" --arg request "$2" --arg identity "$3" \
        '{gnoto: "globus_access", run: $run, request: $request, identity: $identity, username: "reader@example.org"}'
}
answer() {
    curl -s "$S3/$PREFIX/$1/access/$2.json" | jq -r '.status // empty' 2> /dev/null
}
ID_A=aaaaaaaa-0000-4000-8000-000000000001
ID_B=bbbbbbbb-0000-4000-8000-000000000002
REQ=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
out=$(listen_event "$(access_event "$A1" "$REQ" "$ID_A")" 2>&1)
check "the listener grants the identity read on the run's folder" "identity /gnoto/$UID1/ $ID_A" \
    "$(cut -f2-4 "$WORK/globus-rules" | tr '\t' ' ')"
check "as gnoto's client" "test-client" "$(cat "$WORK/globus-client")"
check "and answers the dashboard" "granted" "$(answer "$A1" "$REQ")"
check "logging who" "yes" "$(has "$out" "gave reader@example.org ($ID_A) read on Globus")"
REQ2=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
access_request "$(access_event "$A1" "$REQ2" "$ID_A")" > /dev/null 2>&1
check "asked again, it keeps the one permission" "1 granted" "$(grep -c . "$WORK/globus-rules") $(answer "$A1" "$REQ2")"
REQ3=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
GLOBUS_MAX_PEOPLE=1 access_request "$(access_event "$A1" "$REQ3" "$ID_B")" > /dev/null 2>&1
check "past globus.max_people, it's full" "1 full" "$(grep -c . "$WORK/globus-rules") $(answer "$A1" "$REQ3")"
access_request "$(access_event "$A1" "$REQ3" "$ID_B")" > /dev/null 2>&1
check "below it, a second identity gets in" "2 granted" "$(grep -c . "$WORK/globus-rules") $(answer "$A1" "$REQ3")"
REQ4=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
out=$(access_request "$(access_event "$UID1-abcdefghijklmnop" "$REQ4" "$ID_B")" 2>&1)
check "an address with the wrong token is ignored, unanswered" "yes " \
    "$(has "$out" "at an address that isn't its own") $(answer "$UID1-abcdefghijklmnop" "$REQ4")"
out=$(access_request "$(access_event "$AS" "$REQ4" "$ID_B")" 2>&1)
check "a run whose zip isn't on Globus is gone" "gone" "$(answer "$AS" "$REQ4")"
out=$(access_request '{"gnoto":"globus_access","run":"x","request":"y","identity":"z"}' 2>&1)
check "a malformed request is ignored" "yes" "$(has "$out" "isn't well formed")"
out=$(GLOBUS_APP_CLIENT_ID="" listen_event "$(access_event "$A1" "$REQ4" "$ID_B")" 2>&1)
check "without Globus ready, the listener ignores one" "yes" "$(has "$out" "since Globus isn't set up")"

echo "the progress page on S3"
UID3=$(derive_uid "MATESTRUN003")
mkdir -p "$RUNS/$UID3/results/assets"
(cd "$RUNS/$UID3" && state_init "$UID3" > /dev/null && echo live > results/index.html && echo '{}' > results/progress.json &&
    echo css > results/assets/gnoto.css && progress_publish)
A3=$(addr "$UID3")
check "it's uploaded, at the run's address" "live" "$(curl -s "$S3/$PREFIX/$A3/index.html")"
check "with its assets" "css" "$(curl -s "$S3/$PREFIX/$A3/assets/gnoto.css")"
check "the state records where, for the teardown" "$PREFIX/$A3" "$(cd "$RUNS/$UID3" && state_get published.s3_prefix)"
puts=$(cd "$RUNS/$UID3" && progress_publish; cat .progress-digests | wc -l)
check "a page that hasn't changed isn't uploaded again" "2" "$puts"
(cd "$RUNS/$UID3" && state_set stages.present now && echo dashboard > results/index.html && progress_publish)
check "nor once Present has replaced it" "live" "$(curl -s "$S3/$PREFIX/$A3/index.html")"

echo "the teardown"
(cd "$RUNS/$UID1" && cp run_state.json "$HISTORY/$UID1/state.json")
write_expiry_file() {
    printf 'remove_utc: "%s"\n' "$2" > "$EXPIRY/$1"
}
mkdir -p "$EXPIRY"
TASK_T=$(wrike_cli_task "Teardown mock" ampliseq alice)
(cd "$RUNS/$UID1" && state_set wrike.task_id "$TASK_T" && cp run_state.json "$HISTORY/$UID1/state.json")
write_expiry_file "$UID1" "$(date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ')"
printf 'rule-other\tidentity\t/gnoto/zzzzzzzz/\t%s\n' "$ID_A" >> "$WORK/globus-rules"
( run_lock "$UID1" && teardown_run "$UID1" "Results removed in a test." ) > "$WORK/teardown.out" 2>&1
check "it succeeds" "0" "$?"
check "S3 keeps only the expired page and its assets" "assets/gnoto.css index.html" \
    "$(s3_keys gnoto-results "$PREFIX/$A1" | sed "s|^$PREFIX/$A1/||" | sort | paste -sd ' ')"
check "which names the run" "yes" "$(curl -s "$S3/$PREFIX/$A1/index.html" | grep -q "$UID1" && echo yes)"
check "and its sample count" "yes" "$(curl -s "$S3/$PREFIX/$A1/index.html" | grep -q '3 samples' && echo yes)"
check "the Globus folder went" "no" "$(exists "$WORK/globus/gnoto/$UID1")"
check "and every permission on it, first, and no other" "rule-other" "$(cut -f1 "$WORK/globus-rules" | paste -sd ' ')"
: > "$WORK/globus-rules"
LINT_FAILS=0 LINT_WARNS=0
out=$(lint_globus)
check "lint: Globus is set up, with no run shared" "yes" \
    "$(has "$out" "OK    globus: 0 runs shared, with 0 Globus identities, each by a permission of its own")"
printf 'rule-a\tidentity\t/gnoto/run1/\t%s\nrule-b\tidentity\t/gnoto/run1/\t%s\nrule-c\tidentity\t/gnoto/run2/\t%s\n' \
    "$ID_A" "$ID_B" "$ID_A" > "$WORK/globus-rules"
out=$(lint_globus)
check "and counts the runs shared, and with whom" "yes" "$(has "$out" "OK    globus: 2 runs shared, with 3 Globus identities")"
printf 'rule-open\tall_authenticated_users\t/gnoto/\t\n' > "$WORK/globus-rules"
LINT_FAILS=0
out=$(lint_globus)
check "lint fails on a permission that opens the run folder" "yes" \
    "$(has "$out" "FAIL  globus: a permission lets anyone signed in to Globus list the runs and download them: rule-open on /gnoto/")"
printf 'rule-root\tanonymous\t/\t\n' > "$WORK/globus-rules"
out=$(lint_globus)
check "or anything above it" "yes" "$(has "$out" "rule-root on /")"
printf 'rule-run\tanonymous\t/gnoto/run1/\t\n' > "$WORK/globus-rules"
out=$(lint_globus)
check "or any run in it" "yes" "$(has "$out" "rule-run on /gnoto/run1/")"
for (( i = 0; i < 905; i++ )); do printf 'rule-%s\tidentity\t/gnoto/run%s/\t%s\n' "$i" "$i" "$ID_A"; done > "$WORK/globus-rules"
out=$(lint_globus)
check "lint warns as the permissions near the 1000 a collection holds" "yes" \
    "$(has "$out" "WARN  globus: the collection has 905 permissions")"
: > "$WORK/globus-rules"
out=$(GLOBUS_APP_CLIENT_ID="" lint_globus)
check "lint fails without the dashboards' app" "yes" "$(has "$out" "FAIL  globus: globus.app_client_id isn't set")"
out=$(AWS_ACCESS_URL="" lint_globus)
check "or Get the data's address" "yes" "$(has "$out" "which needs S3, the queue and aws.access_url")"
out=$(GLOBUS_PIPELINES=ampliseq,nosuch lint_globus)
check "or with a pipeline that isn't one" "yes no" \
    "$(has "$out" "globus.pipelines names nosuch") $(has "$out" "names ampliseq")"
check "the run directory and expiry file went" "no no" "$(exists "$RUNS/$UID1") $(exists "$EXPIRY/$UID1")"
check "history says when" "yes" "$(jq -e '.removed_utc' "$HISTORY/$UID1/state.json" > /dev/null && echo yes)"
check "the task moved to Expired" "$(wrike_status_id expired)" "$(wrike_call GET "tasks/$TASK_T" | jq -r '.data[0].customStatusId')"
check "with a comment saying so" "yes" "$(stub GET /_test/state | jq -r --arg t "$TASK_T" '.tasks[$t].comments[-1].text' | grep -q 'Results removed in a test' && echo yes)"
finished_run "$UID2" "" Completed
(cd "$RUNS/$UID2" && state_set published.s3_bucket no-such-bucket && state_set published.s3_prefix "$PREFIX/$UID2" &&
    cp run_state.json "$HISTORY/$UID2/state.json")
( run_lock "$UID2" && teardown_run "$UID2" "" ) > /dev/null 2>&1
check "a copy it can't delete keeps the expiry file, for tomorrow" "yes" "$(exists "$EXPIRY/$UID2")"
check "due now" "yes" "$([[ $(expiry_get "$UID2" remove_utc) < $(date -u -d '+1 minute' '+%Y-%m-%dT%H:%M:%SZ') ]] && echo yes)"
check "and history doesn't call it removed" "null" "$(jq -r '.removed_utc' "$HISTORY/$UID2/state.json")"
rm -f "$EXPIRY/$UID2"

echo "gnoto remove, of a published run with no run directory"
UID4=$(derive_uid "MATESTRUN004")
finished_run "$UID4" "" Completed
(cd "$RUNS/$UID4" && GLOBUS_ENABLED=false publish_run "$UID4" > /dev/null 2>&1 && cp run_state.json "$HISTORY/$UID4/state.json")
A4=$(addr "$UID4")
run_dir_delete "$UID4"
check "it's still published" "yes" "$(published_elsewhere "$UID4" && echo yes)"
out=$(remove_main --yes "$UID4" 2>&1)
check "remove takes its results off S3" "index.html" \
    "$(s3_keys gnoto-results "$PREFIX/$A4" | sed "s|^$PREFIX/$A4/||" | grep -v '^assets/' | paste -sd ' ')"
check "and says so" "yes" "$(has "$out" "Removed run $UID4's results.")"
check "after which it isn't published" "no" "$(published_elsewhere "$UID4" && echo yes || echo no)"

echo "gnoto extend"
TASK5=$(wrike_cli_task "Extend mock" ampliseq alice)
UID5=$(derive_uid "$TASK5")
finished_run "$UID5" "$TASK5" Completed
(cd "$RUNS/$UID5" && cp run_state.json "$HISTORY/$UID5/state.json")
write_expiry_file "$UID5" "$(date -u -d '+10 days' '+%Y-%m-%dT%H:%M:%SZ')"
out=$(extend_main "$UID5" 2030-01-02 2>&1)
check "a date moves the removal" "2030-01-02T00:00:00Z" "$(expiry_get "$UID5" remove_utc)"
check "and the task's Expiration" "2030-01-02" "$(wrike_task_field "$(wrike_call GET "tasks/$TASK5")" expiration)"
out=$( (extend_main "$UID5" "$(date -u -d '-30 days' +%F)") 2>&1)
check "a date before the floor is refused" "yes" "$(has "$out" "can't be removed sooner")"
out=$(extend_main "$UID5" never 2>&1)
check "never keeps them for good" "no" "$(exists "$EXPIRY/$UID5")"
check "and clears the task's date" "" "$(wrike_task_field "$(wrike_call GET "tasks/$TASK5")" expiration)"
out=$( (extend_main "$UID5" 20300102) 2>&1)
check "a date written otherwise is refused" "yes" "$(has "$out" "isn't a date written YYYY-MM-DD")"

echo "Wrike's Expiration dates, copied in"
write_expiry_file "$UID5" "$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"
wrike_set_field "$TASK5" expiration 2031-03-04
check "a date set in Wrike wins" "yes" "$(has "$(wrike_sync_dates)" "removed on 2031-03-04")"
check "in the expiry file" "2031-03-04T00:00:00Z" "$(expiry_get "$UID5" remove_utc)"
wrike_set_field "$TASK5" expiration "$(date -u -d '-30 days' +%F)"
wrike_sync_dates > /dev/null
check "a date before the floor becomes the floor" "$(expiry_floor "$UID5")" "$(expiry_get "$UID5" remove_utc | cut -c1-10)"
check "in Wrike too" "$(expiry_floor "$UID5")" "$(wrike_task_field "$(wrike_call GET "tasks/$TASK5")" expiration)"
wrike_set_field "$TASK5" expiration ""
mkdir -p "$WORK/data/logs/wrike-replay"
echo '[]' > "$WORK/data/logs/wrike-replay/$TASK5.field.$(wrike_field_id expiration).json"
wrike_sync_dates > /dev/null
check "an empty date with gnoto's own write still waiting changes nothing" "yes" "$(exists "$EXPIRY/$UID5")"
rm -f "$WORK/data/logs/wrike-replay/"*
wrike_sync_dates > /dev/null
check "an empty date is Unlimited" "no" "$(exists "$EXPIRY/$UID5")"
event=$(jq -cn --arg t "$TASK5" --arg f "$(wrike_field_id expiration)" '{eventType: "TaskCustomFieldChanged", taskId: $t, customFieldId: $f}')
write_expiry_file "$UID5" "$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')"
wrike_set_field "$TASK5" expiration 2032-05-06
listen_event "$event" > /dev/null 2>&1
check "the listener copies an edited date at once" "2032-05-06T00:00:00Z" "$(expiry_get "$UID5" remove_utc)"

echo "the daily expiry check"
UID6=$(derive_uid "MATESTRUN006")
TASK6=$(wrike_cli_task "Notice mock" ampliseq alice)
finished_run "$UID6" "$TASK6" Completed
(cd "$RUNS/$UID6" && cp run_state.json "$HISTORY/$UID6/state.json")
write_expiry_file "$UID6" "$(date -u -d '+5 days' '+%Y-%m-%dT%H:%M:%SZ')"
UID7=$(derive_uid "MATESTRUN007")
finished_run "$UID7" "" Completed
(cd "$RUNS/$UID7" && mkdir work && state_set_json debug true && cp run_state.json "$HISTORY/$UID7/state.json")
printf 'remove_utc: "%s"\ncleanup_utc: "%s"\n' "$(date -u -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ')" \
    "$(date -u -d '-1 day' '+%Y-%m-%dT%H:%M:%SZ')" > "$EXPIRY/$UID7"
UID8=$(derive_uid "MATESTRUN008")
finished_run "$UID8" "" Completed
(cd "$RUNS/$UID8" && cp run_state.json "$HISTORY/$UID8/state.json")
write_expiry_file "$UID8" "$(date -u '+%Y-%m-%dT00:00:00Z')"
rm -f "$EXPIRY/$UID5"
out=$(expire_check 2>&1)
check "a run whose date has come is removed" "no yes" "$(exists "$RUNS/$UID8") $(jq -e .removed_utc "$HISTORY/$UID8/state.json" > /dev/null && echo yes)"
check "a --debug run's leftovers are deleted when their time comes" "no yes" "$(exists "$RUNS/$UID7/work") $(exists "$RUNS/$UID7/results/index.html")"
check "and their time leaves the file" "" "$(expiry_get "$UID7" cleanup_utc)"
check "a run a few days off is warned of, on its task" "yes" \
    "$(stub GET /_test/state | jq -r --arg t "$TASK6" '.tasks[$t].comments[-1].text' | grep -q 'results are removed on' && echo yes)"
check "mentioning its followers" "yes" \
    "$(stub GET /_test/state | jq -r --arg t "$TASK6" '.tasks[$t].comments[-1].text' | grep -q '@followers' && echo yes)"
check "once" "$(date -u -d '+5 days' +%F)" "$(expiry_get "$UID6" noticed)"
comments=$(stub GET /_test/state | jq --arg t "$TASK6" '.tasks[$t].comments | length')
expire_check > /dev/null 2>&1
check "not again the next day" "$comments" "$(stub GET /_test/state | jq --arg t "$TASK6" '.tasks[$t].comments | length')"
check "it sums up what it did" "yes" "$(has "$out" "Expiry: 1 runs' results removed, 1 runs' leftovers deleted, 1 Wrike tasks warned.")"

echo "the followup's report"
UID9=$(derive_uid "MATESTRUN009")
TASK9=$(wrike_cli_task "Report mock" ampliseq alice)
finished_run "$UID9" "$TASK9" Completed
(cd "$RUNS/$UID9" && state_set published.url "$S3/$PREFIX/$UID9/index.html" && cp run_state.json "$HISTORY/$UID9/state.json")
write_expiry_file "$UID9" "2027-01-02T03:04:05Z"
wrike_report_end "$UID9" Completed
json=$(wrike_call GET "tasks/$TASK9")
check "a completed run's task moves to Completed" "$(wrike_status_id completed)" "$(jq -r '.data[0].customStatusId' <<< "$json")"
check "with its results address" "$S3/$PREFIX/$UID9/index.html" "$(wrike_task_field "$json" results)"
check "and Expiration date" "2027-01-02" "$(wrike_task_field "$json" expiration)"
check "and a comment with the link" "yes" "$(stub GET /_test/state | jq -r --arg t "$TASK9" '.tasks[$t].comments[-1].text' | grep -qF "Complete: $S3/$PREFIX/$UID9/index.html" && echo yes)"
(cd "$RUNS/$UID9" && state_set message "DADA2 removed every read." && cp run_state.json "$HISTORY/$UID9/state.json")
wrike_report_end "$UID9" Failed
check "a failed run's moves to Failed, saying why" "$(wrike_status_id failed) yes" \
    "$(wrike_call GET "tasks/$TASK9" | jq -r '.data[0].customStatusId') $(stub GET /_test/state | jq -r --arg t "$TASK9" '.tasks[$t].comments[-1].text' | grep -q 'DADA2 removed every read' && echo yes)"

echo "the listener's deleted task"
TASK10=$(wrike_cli_task "Deleted mock" ampliseq alice)
UID10=$(derive_uid "$TASK10")
finished_run "$UID10" "$TASK10" Completed
(cd "$RUNS/$UID10" && cp run_state.json "$HISTORY/$UID10/state.json")
listen_event "$(jq -cn --arg t "$TASK10" '{eventType: "TaskDeleted", taskId: $t}')" > /dev/null 2>&1
check "a deleted task's run is removed" "no" "$(exists "$RUNS/$UID10")"
out=$(listen_event '{"eventType":"TaskTitleChanged","taskId":"MAXYZ"}' 2>&1)
check "an event it doesn't act on is said so" "yes" "$(has "$out" "Ignored a TaskTitleChanged event")"

echo "the health summary"
mkdir -p "$WORK/data/logs"
lint_config() {
    printf '  OK    slurm: sinfo answers\n  OK    wrike: the bot account is gnoto Bot\n  WARN  wrike: webhook Suspended\n  FAIL  s3: oops "quoted"\n  OK    version: x\n'
}
health_write
check "it's YAML, an integration a line, at its worst" "wrike warn webhook Suspended" \
    "$(yq -r '.integrations[] | select(.name == "wrike") | [.name, .status, .message] | join(" ")' "$WORK/data/logs/health.yaml")"
check "a message with quotes survives" 's3: oops "quoted"' \
    "$(yq -r '.integrations[] | select(.name == "s3") | "s3: " + .message' "$WORK/data/logs/health.yaml")"
check "a line that isn't an integration is left out" "slurm wrike s3" \
    "$(yq -r '[.integrations[] | select(.name != "listener") | .name] | join(" ")' "$WORK/data/logs/health.yaml")"
out=$(status_health)
check "status shows it" "yes" "$(has "$out" "Integrations, checked by the daily lint")"
check "aligned" "yes" "$(grep -qE '^  wrike +warn +webhook Suspended$' <<< "$out" && echo yes)"

echo "gnoto config s3 and sqs --deploy, with CloudFormation faked"
# A stand-in aws for the admin calls, which records them, and hands every
# other call to the real one
REAL_AWS=$(command -v aws)
mkdir -p "$WORK/fakebin" "$WORK/fake"
cat > "$WORK/fakebin/aws" << EOF
#!/bin/bash
FAKE=$WORK/fake
case "\$*" in
    *"sts get-caller-identity"*) echo 123456789012 ;;
    *"cloudformation describe-stacks"*)
        stack=\$(sed -n 's/.*--stack-name \([^ ]*\).*/\1/p' <<< "\$*")
        [[ -e \$FAKE/\$stack ]] || exit 255
        case \$stack in
            gnoto-iam) echo '{"Stacks":[{"Outputs":[{"OutputKey":"UserName","OutputValue":"gnoto-User-ABC"}]}]}' ;;
            gnoto-s3) echo '{"Stacks":[{"Outputs":[{"OutputKey":"ResultsBaseUrl","OutputValue":"$S3"},{"OutputKey":"DistributionId","OutputValue":"E123"},{"OutputKey":"DistributionDomain","OutputValue":"d1.cloudfront.net"}]}]}' ;;
            gnoto-sqs) echo '{"Stacks":[{"Outputs":[{"OutputKey":"QueueUrl","OutputValue":"http://elasticmq:9324/000000000000/itest"},{"OutputKey":"WebhookUrl","OutputValue":"https://abc.execute-api.us-east-1.amazonaws.com/wrike"},{"OutputKey":"AccessUrl","OutputValue":"https://def.execute-api.us-east-1.amazonaws.com/access"}]}]}' ;;
        esac
        ;;
    *"cloudformation deploy"*)
        stack=\$(sed -n 's/.*--stack-name \([^ ]*\).*/\1/p' <<< "\$*")
        template=\$(sed -n 's/.*--template-file \([^ ]*\).*/\1/p' <<< "\$*")
        cp "\$template" "\$FAKE/\$stack.yaml"
        printf '%s\n' "\$@" > "\$FAKE/\$stack.args"
        touch "\$FAKE/\$stack"
        ;;
    *"iam list-access-keys"*) [[ -e \$FAKE/key ]] && echo '{"AccessKeyMetadata":[{}]}' || echo '{"AccessKeyMetadata":[]}' ;;
    *"iam create-access-key"*) touch "\$FAKE/key"; echo '{"AccessKey":{"AccessKeyId":"AKIAFAKE","SecretAccessKey":"fake-secret"}}' ;;
    *) exec "$REAL_AWS" "\$@" ;;
esac
EOF
chmod +x "$WORK/fakebin/aws"
out=$(PATH=$WORK/fakebin:$PATH; CONFIG_DEPLOY=1 CONFIG_DRY_RUN=1 CONFIG_PROFILE=admin; config_s3_step 2>&1)
check "--dry-run shows the plan" "yes yes" "$(has "$out" "Create the stack gnoto-iam") $(has "$out" "Create the stack gnoto-s3: the bucket gnoto-results")"
check "and deploys nothing" "no" "$(exists "$WORK/fake/gnoto-s3")"
out=$( (PATH=$WORK/fakebin:$PATH; CONFIG_DEPLOY=1 CONFIG_YES=1 CONFIG_PROFILE=admin; config_s3_step) 2>&1)
check "it deploys the IAM user's stack, then the S3 stack" "yes yes" "$(exists "$WORK/fake/gnoto-iam") $(exists "$WORK/fake/gnoto-s3")"
check "with the bucket and run prefix" "yes yes" \
    "$(grep -qx 'BucketName=gnoto-results' "$WORK/fake/gnoto-s3.args" && echo yes) $(grep -qx "RunPrefix=$PREFIX" "$WORK/fake/gnoto-s3.args" && echo yes)"
check "and the admin profile" "yes" "$(grep -qx -- --profile "$WORK/fake/gnoto-s3.args" && grep -qx admin "$WORK/fake/gnoto-s3.args" && echo yes)"
check "the CloudFront function's code, with the run prefix, in the template" "yes" \
    "$(grep -q "        var RUN_PREFIX = '$PREFIX';" "$WORK/fake/gnoto-s3.yaml" && echo yes)"
check "and no placeholder left" "no" "$(grep -q '__DIRECTORY_INDEX_JS__' "$WORK/fake/gnoto-s3.yaml" && echo yes || echo no)"
check "the IAM user's key, printed once" "yes yes" "$(has "$out" "access_key_id:     AKIAFAKE") $(has "$out" "secret_access_key: fake-secret")"
check "the stack's outputs in generated.yaml" "E123" "$(yq -r '.aws.distribution_id' "$WORK/data/generated.yaml")"
out=$( (PATH=$WORK/fakebin:$PATH; CONFIG_DEPLOY=1 CONFIG_YES=1; config_sqs_step) 2>&1)
check "the SQS stack, with the webhook's secret" "yes" "$(grep -qx 'WebhookSecret=itest-secret' "$WORK/fake/gnoto-sqs.args" && echo yes)"
check "and Get the data's app, bucket, origin and return page" "yes yes yes yes yes" \
    "$(for line in GlobusClientId=11111111-1111-1111-1111-111111111111 ResultsBucket=gnoto-results "RunPrefix=$PREFIX" \
        ResultsOrigin=http://s3mock:9090 "RedirectUri=$S3/$PREFIX/access.html"; do
        grep -qx "$line" "$WORK/fake/gnoto-sqs.args" && echo yes || echo "no:$line"; done | paste -sd ' ')"
check "and both Lambdas' code, without comments or placeholders" "2 yes no no" \
    "$(grep -c '^          def lambda_handler(event, context):$' "$WORK/fake/gnoto-sqs.yaml") $(grep -q '^          def auth(path, form=None, token=None):$' "$WORK/fake/gnoto-sqs.yaml" && echo yes) $(grep -q 'webhook.py - The Lambda\|access.py - The Lambda' "$WORK/fake/gnoto-sqs.yaml" && echo yes || echo no) $(grep -q '__[A-Z]*_PY__' "$WORK/fake/gnoto-sqs.yaml" && echo yes || echo no)"
check "its plan names Get the data" "yes" "$(has "$out" "Get the data's Lambda and its HTTP API")"
check "a second key isn't made" "no" "$(has "$out" "has a new access key")"
check "the queue, webhook and access addresses in generated.yaml" "https://abc.execute-api.us-east-1.amazonaws.com/wrike https://def.execute-api.us-east-1.amazonaws.com/access" \
    "$(yq -r '.aws.webhook_url + " " + .aws.access_url' "$WORK/data/generated.yaml")"
out=$( (PATH=$WORK/fakebin:$PATH; CONFIG_DEPLOY=1 CONFIG_YES=1 GLOBUS_APP_CLIENT_ID=""; config_sqs_step) 2>&1)
check "without the app, Get the data's parameters are empty, which leaves it out" "yes yes" \
    "$(grep -qx 'GlobusClientId=' "$WORK/fake/gnoto-sqs.args" && echo yes) $(grep -qx 'ResultsBucket=' "$WORK/fake/gnoto-sqs.args" && echo yes)"

echo "settings gnoto fills in"
mkdir -p "$WORK/fill/install" "$WORK/fill/data"
printf 'core:\n  data_dir: "%s"\n\naws:\n  enabled: true\n  sqs_queue_url: ""\n  webhook_url: "mine"\n\nwrike:\n  enabled: true\n  webhook_secret: ""\n' \
    "$WORK/fill/data" > "$WORK/fill/install/config.yaml"
printf 'aws:\n  sqs_queue_url: "from-the-stack"\n  webhook_url: "from-the-stack"\n' > "$WORK/fill/data/generated.yaml"
out=$(GNOTO_INSTALL_DIR=$WORK/fill/install bash -c 'source "$1/lib/env.sh" && echo "$AWS_SQS_QUEUE_URL $AWS_WEBHOOK_URL"' _ "$CODE")
check "an empty value in config.yaml doesn't hide generated.yaml's, and a value wins" "from-the-stack mine" "$out"
out=$(GNOTO_INSTALL_DIR=$WORK/fill/install bash -c 'source "$1/lib/env.sh" && source "$1/lib/args.sh" &&
    source "$1/lib/config.sh" && wrike_webhook_secret && first=$WRIKE_WEBHOOK_SECRET &&
    source "$1/lib/env.sh" && wrike_webhook_secret && echo "$first $WRIKE_WEBHOOK_SECRET"' _ "$CODE")
check "the webhook secret is made random, once, in generated.yaml" "yes yes" \
    "$([[ ${out% *} =~ ^[0-9a-f]{64}$ ]] && echo yes) $([[ ${out#* } == "${out% *}" ]] && echo yes)"
check "and kept there" "${out% *}" "$(yq -r .wrike.webhook_secret "$WORK/fill/data/generated.yaml")"

echo "the systemd units"
out=$(INSTALL_DIR=/opt/gnoto APPTAINER_BIN_DIR=/opt/apptainer/bin SLURM_ENABLED=true SLURM_BIN_DIR=/opt/slurm/bin SLURM_CONF=/etc/slurm.conf systemd_render gnoto-daily.service)
check "a unit runs the install's launcher" "yes" "$(has "$out" "ExecStart=/opt/gnoto/gnoto _daily")"
check "with Apptainer and Slurm on its PATH" "yes" "$(has "$out" "Environment=PATH=/opt/apptainer/bin:/opt/slurm/bin:/usr/local/bin:/usr/bin:/bin")"
check "and SLURM_CONF" "yes" "$(has "$out" "Environment=SLURM_CONF=/etc/slurm.conf")"
out=$(SLURM_ENABLED=false systemd_render gnoto-daily.service)
check "without Slurm, no SLURM_CONF line" "no" "$(grep -q '^Environment=SLURM_CONF' <<< "$out" && echo yes || echo no)"
check "the poll timer's interval" "yes" "$(has "$(WRIKE_POLL_MINUTES=7 systemd_render gnoto-wrike.timer)" "OnUnitActiveSec=7min")"
check "the units for Wrike and SQS" "gnoto-daily.service gnoto-daily.timer gnoto-wrike.service gnoto-wrike.timer gnoto-listener.service" \
    "$(systemd_units | paste -sd ' ')"
check "the listener for Globus alone" "gnoto-daily.service gnoto-daily.timer gnoto-listener.service" \
    "$(WRIKE_ENABLED=false systemd_units | paste -sd ' ')"
check "only the daily timer without Wrike or Globus" "gnoto-daily.service gnoto-daily.timer" \
    "$(WRIKE_ENABLED=false GLOBUS_ENABLED=false systemd_units | paste -sd ' ')"
SYSTEMD_HOST=elsewhere
out=$(service_start daily 2>&1; echo "status $?")
check "a unit on another host does nothing" "yes status 1" "$(has "$out" "belong to elsewhere") $(tail -n 1 <<< "$out")"

s3_delete_prefix gnoto-results "$PREFIX" > /dev/null 2>&1
echo
(( FAILED == 0 )) && echo "All passed." || echo "Some failed."
exit $FAILED
