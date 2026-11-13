#!/bin/bash
#
# integrations.sh - Phase 7's finish test, against the test bed's stand-ins: a
# job from the command line and a request from the Wrike form, on the same
# samples, both end as tasks, publish to S3 and give the same core tables.
# Then gnoto extend, a date edited in Wrike, the daily expiry check, a deleted
# task through the listener, and, with --publish, gnoto publish after a
# publish that failed.
#
# Run by:  a developer, as alice or bob, in the test bed:
#          bash <install>/test/testbed/checks/integrations.sh [--publish]
# Requires:  testbed.sh services, the stand-ins, with ~/.aws/config pointing the
#            AWS CLI at them, as testbed.sh's notes say; an install whose
#            config.yaml sets core.input_roots to cover its database
#            directory, and the 16s-v4 fixture and the databases job.sh
#            --small needs there
#
# Sets up the aws and wrike sections of the install's config.yaml and its
# Wrike objects in the stub, runs the SQS listener in the background, and
# stops it at the end. Takes about 40 minutes, an hour with --publish.

set -u

CODE_DIR=$(cd "$(dirname "$0")/../../.." && pwd)
GNOTO=$CODE_DIR/gnoto
STUB=http://wrike-stub:8080
S3=http://s3mock:9090/gnoto-results
QUEUE=http://elasticmq:9324/000000000000/gnoto
PUBLISH=false
for ARG in "$@"; do
    case $ARG in
        --publish) PUBLISH=true ;;
        *) echo "Usage: integrations.sh [--publish]" >&2; exit 1 ;;
    esac
done
DATA_DIR=$($GNOTO exec printenv GNOTO_DATA_DIR)
DB_DIR=$($GNOTO exec printenv GNOTO_DB_DIR)
FIXTURE=$DB_DIR/fixtures/16s-v4/v1
WORK=$DATA_DIR/test/$USER/integrations
FAILED=0
LISTENER=""

# The listener is bash inside the image, which a signal to the launcher
# doesn't reach
stop_listener() {
    [[ -n $LISTENER ]] || return 0
    pkill -TERM -u "$(id -un)" -f "main.sh _listen" 2> /dev/null
    wait "$LISTENER" 2> /dev/null
    LISTENER=""
}
trap 'stop_listener' EXIT

check() {
    if [[ $2 == "$3" ]]; then
        printf 'ok    %s\n' "$1"
    else
        printf 'FAIL  %s\n      expected: %q\n      got:      %q\n' "$1" "$2" "$3"
        FAILED=1
    fi
}

# Runs a command in the image, with the install's settings loaded, for jq, yq
# and the AWS CLI as gnoto's user
in_image() {
    $GNOTO exec bash -c 'source "$GNOTO_CODE_DIR/lib/env.sh" && '"$1" 2> /dev/null
}

stub() {
    curl -sS -X "$1" "$STUB$2" "${@:3}"
}

# The image's jq, since a host needs nothing but Apptainer
jq() {
    $GNOTO exec jq "$@" 2> /dev/null
}

run_status() {
    $GNOTO status "$1" 2> /dev/null | sed -n 's/^  Status     \([^:]*\).*/\1/p'
}

wait_for() {
    local uid=$1 status
    for (( i = 0; i < $2 * 6; i++ )); do
        status=$(run_status "$uid")
        case $status in
            Completed | Failed | Cancelled | "Publish failed" | Lost) printf '%s' "$status"; return ;;
        esac
        sleep 10
    done
    printf 'still %s' "$status"
}

# Sends a Wrike event to the queue, as the webhook's Lambda would
send_event() {
    in_image "gnoto_aws sqs send-message --queue-url $QUEUE --message-body '$1' > /dev/null"
}

# The uid of a Wrike task's run
task_uid() {
    in_image "derive_uid $1"
}

# A run's published folder, <uid>-<token>, from its state, wherever it is
address() {
    local file=$DATA_DIR/runs/$1/run_state.json
    [[ -r $file ]] || file=$DATA_DIR/history/$1/state.json
    printf '%s-%s' "$1" "$(jq -r '.address_token // empty' "$file" 2> /dev/null)"
}

mkdir -p "$WORK"
cd "$WORK" || exit 1
printf '%s\t%s\t%s\n' mock1 "$FIXTURE/SRR17380142_1.fastq.gz" "$FIXTURE/SRR17380142_2.fastq.gz" > v4.tsv

echo "setting up the integrations"
curl -sS -X POST "$STUB/_test/reset" > /dev/null || { echo "FAIL  the stand-ins aren't running: testbed.sh services"; exit 1; }
$GNOTO config aws --on --access_key_id=test --secret_access_key=test --region=us-east-1 > config.log 2>&1
$GNOTO config s3 --on --bucket=gnoto-results --results_base_url="$S3/itest" --run_prefix=itest >> config.log 2>&1
$GNOTO config sqs --on --queue_url="$QUEUE" --webhook_url=https://hooks.example.invalid/wrike >> config.log 2>&1
in_image "gnoto_aws sqs create-queue --queue-name gnoto > /dev/null"
in_image "gnoto_aws sqs purge-queue --queue-url $QUEUE > /dev/null"
$GNOTO config wrike --api_url="$STUB/api/v4" --api_token=stub-token --webhook_secret=testbed-secret \
    --poll_minutes=5 --yes >> config.log 2>&1
check "config wrike prints the form's checklist" "yes" "$(grep -q 'create a request form named "gnoto Request"' config.log && echo yes)"
FORM=$(in_image 'wrike_fields_spec() { :; }; source "$GNOTO_CODE_DIR/lib/jobfile.sh"; source "$GNOTO_CODE_DIR/service/wrike/config.sh";
    jq -c --arg space "$WRIKE_SPACE_ID" "{title: \"gnoto Request\", spaceId: \$space,
        pages: [{fields: [.[] | select(.gnoto | not) | {title, items: [.values[] | {title: .}]}]}]}" <<< "$(wrike_fields_spec)"')
check "the checklist's questions can be read" "yes" "$([[ $FORM == *Pipeline* ]] && echo yes)"
stub POST /_test/form -d "$FORM" > /dev/null
$GNOTO config wrike --yes > config2.log 2>&1
check "config wrike finds the form, which matches" "yes" "$(grep -q 'matches gnoto' config2.log && echo yes)"
$GNOTO lint > lint.log 2>&1
check "lint passes Wrike, S3 and SQS" "yes yes yes" \
    "$(grep -q 'OK    wrike: the request form matches' lint.log && echo yes) $(grep -q 'OK    s3: .* serves what' lint.log && echo yes) $(grep -q 'OK    sqs: ' lint.log && echo yes)"
check "and knows every setting gnoto config wrote" "" "$(grep -e "isn't a setting" -e "no section" lint.log)"
$GNOTO _listen > listener.log 2>&1 &
LISTENER=$!

JOB=(ampliseq --title="16S V4 CLI" --samplesheet=v4.tsv --retention="1 Month" --ampliseq.mergepairs_strategy=merge
    --ampliseq.pplace_tree=db:test/pplace-small/bac16s.newick --ampliseq.pplace_aln=db:test/pplace-small/bac16s.alnfna)
echo "a job from the command line"
START=$($GNOTO start "${JOB[@]}" --yes 2>&1)
UID_A=$(sed -n 's/^Started \([a-z2-7]\{8\}\),.*/\1/p' <<< "$START")
[[ -n $UID_A ]] || { echo "FAIL  gnoto start:"; sed 's/^/      /' <<< "$START"; exit 1; }
RUN_A=$(address "$UID_A")
TASK_A=$(sed -n 's/^Its Wrike task is \(.*\)\.$/\1/p' <<< "$START")
check "it gets a Wrike task" "yes" "$([[ -n $TASK_A ]] && echo yes)"
check "and its uid comes from the task" "$UID_A" "$(task_uid "$TASK_A")"
TASKS=$(stub GET /_test/state)
check "the task is Running" "Running" \
    "$(jq -r --arg t "$TASK_A" '.tasks[$t].customStatusId as $s | [.workflows[].customStatuses[] | select(.id == $s) | .name][0]' <<< "$TASKS")"
check "with job.yaml attached" "job.yaml" "$(jq -r --arg t "$TASK_A" '.attachments[] | select(.taskId == $t) | .name' <<< "$TASKS")"
check "and the progress page's address" "$S3/itest/$RUN_A/index.html" \
    "$(jq -r --arg t "$TASK_A" '.tasks[$t].customFields[] | select(.value | startswith("http")) | .value' <<< "$TASKS")"
check "which shows the run" "yes" "$(curl -s "$S3/itest/$RUN_A/index.html" | grep -q '16S V4 CLI' && echo yes)"
check "it ends as Completed" "Completed" "$(wait_for "$UID_A" 120)"
check "the dashboard is on S3" "yes" "$(curl -s "$S3/itest/$RUN_A/index.html" | grep -q 'overview.html' && echo yes)"
ZIP_A=$(in_image "gnoto_aws s3 ls s3://gnoto-results/itest/$RUN_A/ | awk '/\.zip\$/ { print \$4 }'")
check "with the zip beside it" "yes" "$([[ $ZIP_A == *_$UID_A.zip ]] && echo yes)"
check "which the dashboard links" "yes" "$(curl -s "$S3/itest/$RUN_A/overview.html" | grep -qF "$S3/itest/$RUN_A/$ZIP_A" && echo yes)"
check "the run directory went, once published" "no" "$([[ -e $DATA_DIR/runs/$UID_A ]] && echo yes || echo no)"
check "history keeps the record" "yes" "$([[ -s $DATA_DIR/history/$UID_A/record.yaml ]] && echo yes)"
check "status shows the address" "yes" "$($GNOTO status | grep -q "^  $UID_A .*$S3/itest/$RUN_A/index.html" && echo yes)"
TASKS=$(stub GET /_test/state)
check "the task is Completed" "Completed" \
    "$(jq -r --arg t "$TASK_A" '.tasks[$t].customStatusId as $s | [.workflows[].customStatuses[] | select(.id == $s) | .name][0]' <<< "$TASKS")"
check "with a comment linking the results" "yes" \
    "$(jq -r --arg t "$TASK_A" '.tasks[$t].comments[-1].text' <<< "$TASKS" | grep -qF "Complete: $S3/itest/$RUN_A/index.html" && echo yes)"
check "and its Expiration date" "$(grep -o 'remove_utc: "[0-9-]*' "$DATA_DIR/expiry/$UID_A" | cut -c14-)" \
    "$(jq -r --arg t "$TASK_A" '.tasks[$t].customFields[] | select(.value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | .value' <<< "$TASKS")"

echo "a request from the Wrike form, repeating it on the same samples"
FIELDS=$(jq -c '.fields | to_entries | map({(.value.title): .key}) | add' <<< "$TASKS")
TASK_B=$(stub POST "/api/v4/folders/$(in_image 'printf %s "$WRIKE_FOLDER_ID"')/tasks" -H 'Authorization: bearer stub-token' \
    --data-urlencode "title=16S V4 form" --data-urlencode "customStatus=$(in_image 'wrike_status_id submitted')" \
    --data-urlencode "_author=KUREQUEST" --data-urlencode "customFields=$(jq -cn --argjson f "$FIELDS" --arg uid "$UID_A" \
        '[{id: $f.Pipeline, value: "Repeat an earlier run"}, {id: $f["Previous Run"], value: $uid}]')" | jq -r '.data[0].id')
stub POST "/api/v4/tasks/$TASK_B/attachments" -H 'Authorization: bearer stub-token' -H 'X-File-Name: samples.tsv' \
    -H 'Content-Type: application/octet-stream' --data-binary @v4.tsv > /dev/null
send_event "[{\"taskId\":\"$TASK_B\",\"eventType\":\"TaskCreated\",\"webhookId\":\"x\",\"eventAuthorId\":\"KUREQUEST\"}]"
UID_B=$(task_uid "$TASK_B")
for (( i = 0; i < 60; i++ )); do
    [[ -e $DATA_DIR/runs/$UID_B ]] && break
    sleep 5
done
check "the listener starts it" "yes" "$([[ -e $DATA_DIR/runs/$UID_B || -e $DATA_DIR/history/$UID_B ]] && echo yes)"
RUN_B=$(address "$UID_B")
check "and its task moves to Running" "Running" \
    "$(stub GET /_test/state | jq -r --arg t "$TASK_B" '.tasks[$t].customStatusId as $s | [.workflows[].customStatuses[] | select(.id == $s) | .name][0]')"
check "it runs as a form request, at the earlier run's version" "true $(sed -n 's/^pipeline: *"*\([^"]*\)"*$/\1/p' "$DATA_DIR/history/$UID_A/job.yaml")" \
    "$(jq -r '.form' "$DATA_DIR/runs/$UID_B/run_state.json" 2> /dev/null) $(jq -r '.version' "$DATA_DIR/runs/$UID_B/run_state.json" 2> /dev/null)"
check "it ends as Completed" "Completed" "$(wait_for "$UID_B" 120)"
OUT_A=$(curl -s "$S3/itest/$RUN_A/record.yaml" | in_image 'yq -o=json ".outputs" /dev/stdin')
OUT_B=$(curl -s "$S3/itest/$RUN_B/record.yaml" | in_image 'yq -o=json ".outputs" /dev/stdin')
check "its core tables are the command-line job's" "yes" "$([[ -n $OUT_A && $OUT_A != null && $OUT_A == "$OUT_B" ]] && echo yes)"
check "and its task is Completed" "Completed" \
    "$(stub GET /_test/state | jq -r --arg t "$TASK_B" '.tasks[$t].customStatusId as $s | [.workflows[].customStatuses[] | select(.id == $s) | .name][0]')"

echo "expiry"
$GNOTO extend "$UID_A" 2030-01-02 > /dev/null
check "gnoto extend moves the date" "2030-01-02" "$(grep -o 'remove_utc: "[0-9-]*' "$DATA_DIR/expiry/$UID_A" | cut -c14-)"
check "and the task's" "yes" "$(stub GET /_test/state | jq -r --arg t "$TASK_A" '.tasks[$t].customFields[].value' | grep -qx 2030-01-02 && echo yes)"
EXP=$(jq -r '.fields | to_entries[] | select(.value.title == "Expiration") | .key' <<< "$(stub GET /_test/state)")
stub PUT "/api/v4/tasks/$TASK_B" -H 'Authorization: bearer stub-token' \
    --data-urlencode "customFields=[{\"id\":\"$EXP\",\"value\":\"2031-02-03\"}]" > /dev/null
send_event "[{\"taskId\":\"$TASK_B\",\"eventType\":\"TaskCustomFieldChanged\",\"customFieldId\":\"$EXP\"}]"
for (( i = 0; i < 12; i++ )); do
    grep -q '2031-02-03' "$DATA_DIR/expiry/$UID_B" 2> /dev/null && break
    sleep 5
done
check "a date edited in Wrike reaches the expiry file through the listener" "yes" \
    "$(grep -q 'remove_utc: "2031-02-03' "$DATA_DIR/expiry/$UID_B" 2> /dev/null && echo yes)"
# Run A as though it ended a month ago, so today is past its floor
jq --arg ended "$(date -u -d '-30 days' '+%Y-%m-%dT%H:%M:%SZ')" '.ended_utc = $ended' \
    "$DATA_DIR/history/$UID_A/state.json" > state.tmp && cat state.tmp > "$DATA_DIR/history/$UID_A/state.json"
printf 'remove_utc: "%s"\n' "$(date -u '+%Y-%m-%dT00:00:00Z')" > "$DATA_DIR/expiry/$UID_A"
stub PUT "/api/v4/tasks/$TASK_A" -H 'Authorization: bearer stub-token' \
    --data-urlencode "customFields=[{\"id\":\"$EXP\",\"value\":\"$(date -u +%F)\"}]" > /dev/null
$GNOTO _daily > daily.log 2>&1
check "the daily check removes a run whose date has come" "yes" \
    "$(jq -e '.removed_utc' "$DATA_DIR/history/$UID_A/state.json" > /dev/null 2>&1 && echo yes)"
check "leaving the expired page at its address" "yes" "$(curl -s "$S3/itest/$RUN_A/index.html" | grep -q 'Data No Longer Available' && echo yes)"
check "and nothing else of its results" "no" "$(curl -s -o /dev/null -w '%{http_code}' "$S3/itest/$RUN_A/$ZIP_A" | grep -q 200 && echo yes || echo no)"
check "its task moves to Expired" "Expired" \
    "$(stub GET /_test/state | jq -r --arg t "$TASK_A" '.tasks[$t].customStatusId as $s | [.workflows[].customStatuses[] | select(.id == $s) | .name][0]')"
check "it writes the health file" "yes" "$(grep -q 'name: "wrike"' "$DATA_DIR/logs/health.yaml" 2> /dev/null && echo yes)"
check "which status shows" "yes" "$($GNOTO status | grep -q '^Integrations, checked by the daily lint' && echo yes)"

echo "a deleted task"
stub DELETE "/api/v4/tasks/$TASK_B" -H 'Authorization: bearer stub-token' > /dev/null
send_event "[{\"taskId\":\"$TASK_B\",\"eventType\":\"TaskDeleted\"}]"
for (( i = 0; i < 12; i++ )); do
    jq -e '.removed_utc' "$DATA_DIR/history/$UID_B/state.json" > /dev/null 2>&1 && break
    sleep 5
done
check "the listener removes its run" "yes" "$(jq -e '.removed_utc' "$DATA_DIR/history/$UID_B/state.json" > /dev/null 2>&1 && echo yes)"
check "and its results on S3" "yes" "$(curl -s "$S3/itest/$RUN_B/index.html" | grep -q 'Data No Longer Available' && echo yes)"
check "the listener deleted each message it handled" "0" \
    "$(in_image "gnoto_aws sqs get-queue-attributes --queue-url $QUEUE --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text")"

if [[ $PUBLISH == true ]]; then
    echo "gnoto publish, after a publish that failed"
    $GNOTO config s3 --bucket=no-such-bucket > /dev/null 2>&1
    START=$($GNOTO start "${JOB[@]/--title=16S V4 CLI/--title=16S V4 publish}" --yes 2>&1)
    UID_C=$(sed -n 's/^Started \([a-z2-7]\{8\}\),.*/\1/p' <<< "$START")
    [[ -n $UID_C ]] || { echo "FAIL  gnoto start:"; sed 's/^/      /' <<< "$START"; exit 1; }
    RUN_C=$(address "$UID_C")
    check "a run whose publish fails ends so" "Publish failed" "$(wait_for "$UID_C" 120)"
    check "and keeps its results" "yes" "$([[ -s $DATA_DIR/runs/$UID_C/results/index.html ]] && echo yes)"
    $GNOTO config s3 --bucket=gnoto-results > /dev/null 2>&1
    $GNOTO publish "$UID_C" > publish.log 2>&1
    check "gnoto publish publishes it" "Completed" "$(wait_for "$UID_C" 30)"
    check "to S3" "yes" "$(curl -s "$S3/itest/$RUN_C/index.html" | grep -q 'overview.html' && echo yes)"
    check "and the run directory goes" "no" "$([[ -e $DATA_DIR/runs/$UID_C ]] && echo yes || echo no)"
fi

stop_listener
check "the listener stops when asked" "yes" "$(grep -q 'Stopped listening' listener.log && echo yes)"
exit $FAILED
