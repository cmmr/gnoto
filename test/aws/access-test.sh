#!/bin/bash
#
# access-test.sh - Tests Get the data's Lambda, service/aws/lambda/access.py, in
# AWS's Lambda image with its Runtime Interface Emulator, ElasticMQ standing in
# for SQS, and test/aws/access-stub.py for Globus Auth and S3.
#
# Run by:    a developer, from any directory, on a machine with Docker
# Usage:     test/aws/access-test.sh
# Requires:  docker, curl and jq. Works from Git Bash on Windows.
#
# Each case posts an API Gateway (HTTP API) event to the function and checks
# its answer, then what reached the queue and what Globus Auth was sent. The
# stub runs inside the Lambda's container, where the function reaches it on
# 127.0.0.1. Removes its containers and network.

set -euo pipefail
export MSYS_NO_PATHCONV=1

REPO=$(cd "$(dirname "$0")/../.." && pwd)
LAMBDA_IMAGE=public.ecr.aws/lambda/python:3.14@sha256:a4f5983a81ac02cc52baf2f7e8e3dd39fb3b8db44b769e407a2344980f2b5107
QUEUE_IMAGE=softwaremill/elasticmq-native:1.7.1@sha256:e4580ab9ad1bd5cd37b4ba04911bc5ccc8cd2d9ab4de56ece65acee71c24e05c
NET=gnoto-access-test
PORT=${PORT:-19002}
QUEUE=http://elasticmq:9324/000000000000/access
RUN=abcdefgh-abcdefghijklmnop
REQUEST=0123456789abcdef0123456789abcdef
VERIFIER=$(printf 'v%.0s' {1..50})
PASS=0
FAIL=0

cleanup() {
    docker rm -f gnoto-access-lambda gnoto-access-queue > /dev/null 2>&1 || :
    docker network rm "$NET" > /dev/null 2>&1 || :
}
trap cleanup EXIT
cleanup

ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

docker network create "$NET" > /dev/null
docker run -d --name gnoto-access-queue --network "$NET" --network-alias elasticmq "$QUEUE_IMAGE" > /dev/null
docker create --name gnoto-access-lambda --network "$NET" -p "127.0.0.1:$PORT:8080" \
    -e AWS_SQS_QUEUE_URL=$QUEUE \
    -e RESULTS_BUCKET=gnoto-results -e RUN_PREFIX=gnoto \
    -e GLOBUS_CLIENT_ID=11111111-1111-1111-1111-111111111111 \
    -e REDIRECT_URI=https://results.example.org/gnoto/access.html \
    -e GLOBUS_AUTH_URL=http://127.0.0.1:8081 \
    -e AWS_ENDPOINT_URL_SQS=http://elasticmq:9324 -e AWS_ENDPOINT_URL_S3=http://127.0.0.1:8081 \
    -e AWS_CONFIG_FILE=/tmp/aws-config \
    -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_REGION=us-east-1 -e AWS_DEFAULT_REGION=us-east-1 \
    "$LAMBDA_IMAGE" access.lambda_handler > /dev/null
tar -c -C "$REPO/service/aws/lambda" access.py | docker cp - gnoto-access-lambda:/var/task
tar -c -C "$REPO/test/aws" access-stub.py | docker cp - gnoto-access-lambda:/tmp
docker start gnoto-access-lambda > /dev/null
docker exec gnoto-access-lambda sh -c 'mkdir -p /tmp/stub && printf "[default]\ns3 =\n    addressing_style = path\n" > /tmp/aws-config'
docker exec -d gnoto-access-lambda python3 /tmp/access-stub.py 8081 /tmp/stub

# Runs Python with boto3 against the queue, in the Lambda's own container
queue_python() {
    docker exec -i gnoto-access-lambda python3 - "$@"
}

for (( i = 0; i < 30; i++ )); do
    queue_python <<'EOF' > /dev/null 2>&1 && break
import boto3
boto3.client('sqs').create_queue(QueueName='access')
EOF
    sleep 1
done

# Takes everything waiting on the queue, a body a line
drain() {
    queue_python <<'EOF'
import boto3
sqs = boto3.client('sqs')
url = 'http://elasticmq:9324/000000000000/access'
while True:
    got = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10, WaitTimeSeconds=1).get('Messages', [])
    if not got:
        break
    for m in got:
        print(m['Body'])
        sqs.delete_message(QueueUrl=url, ReceiptHandle=m['ReceiptHandle'])
EOF
}

# What the stub was last posted at an endpoint: stub_form <token|revoke>
stub_form() {
    docker exec gnoto-access-lambda sh -c "cat /tmp/stub/$1.json 2> /dev/null; rm -f /tmp/stub/$1.json"
}

# invoke <body> [base64]: prints the function's answer
invoke() {
    local body=$1 encoded=false
    if [[ ${2:-} == base64 ]]; then
        body=$(printf '%s' "$body" | base64 | tr -d '\n')
        encoded=true
    fi
    jq -cn --arg body "$body" --argjson encoded "$encoded" \
        '{version: "2.0", routeKey: "POST /access", rawPath: "/access", headers: {"content-type": "text/plain"},
          body: $body, isBase64Encoded: $encoded, requestContext: {http: {method: "POST", path: "/access"}}}' |
        curl -sS -X POST --data-binary @- "http://127.0.0.1:$PORT/2015-03-31/functions/function/invocations"
}

# request <run> <code> [verifier] [request]: the return page's post
request() {
    jq -cn --arg run "$1" --arg code "$2" --arg verifier "${3:-$VERIFIER}" --arg request "${4:-$REQUEST}" \
        '{run: $run, code: $code, verifier: $verifier, request: $request}'
}

status() {
    jq -r .statusCode <<< "$1"
}

for (( i = 0; i < 30; i++ )); do
    invoke '{}' > /dev/null 2>&1 && break
    sleep 1
done

echo "access.py"
answer=$(invoke "$(request "$RUN" good-code)")
[[ $(status "$answer") == 202 ]] && ok "a sign-in for a run on Globus is accepted, 202" || bad "a good sign-in: $answer"
message=$(drain)
[[ $(jq -r '[.gnoto, .run, .request, .identity, .username] | join(" ")' <<< "$message") == \
    "globus_access $RUN $REQUEST aaaaaaaa-0000-4000-8000-000000000001 reader@example.org" ]] &&
    ok "and queues the run, the request and who signed in" || bad "the queued message: $message"
[[ $(jq -r 'keys | join(",")' <<< "$message") == "gnoto,identity,request,run,username" ]] &&
    ok "and nothing else, no token" || bad "the message's keys: $message"
form=$(stub_form token)
[[ $(jq -r '[.grant_type, .code, .code_verifier, .client_id, .redirect_uri] | join(" ")' <<< "$form") == \
    "authorization_code good-code $VERIFIER 11111111-1111-1111-1111-111111111111 https://results.example.org/gnoto/access.html" ]] &&
    ok "the code is exchanged with its verifier, as the app, for its return page" || bad "the token request: $form"
[[ $(stub_form revoke | jq -r .token) == tok-123 ]] && ok "and the token revoked" || bad "the token wasn't revoked"

answer=$(invoke "$(request "$RUN" good-code)" base64)
[[ $(status "$answer") == 202 && -n $(drain) ]] && ok "a base64 body is read" || bad "base64: $answer"
stub_form token > /dev/null

answer=$(invoke "$(request bcdefghi-abcdefghijklmnop good-code)")
[[ $(status "$answer") == 404 ]] && ok "an address with no globus.json is refused, 404" || bad "no globus.json: $answer"
[[ -z $(stub_form token) ]] && ok "before Globus is asked anything" || bad "Globus was asked about a run not on it"

answer=$(invoke "$(request "$RUN" bad)")
[[ $(status "$answer") == 403 ]] && ok "a code Globus refuses is refused, 403" || bad "a refused code: $answer"
answer=$(invoke "$(request "$RUN" nosub)")
[[ $(status "$answer") == 502 ]] && ok "a sign-in that names nobody is refused, 502" || bad "no identity: $answer"
[[ -z $(drain) ]] && ok "and neither is queued" || bad "a refused sign-in was queued"

for body in 'not json' '[]' "$(request "$RUN" "")" "$(request ABCDEFGH-abcdefghijklmnop c)" \
    "$(request "$RUN" c short)" "$(request "$RUN" c "$VERIFIER" not-hex)" "$(request "$RUN" "has space")"; do
    answer=$(invoke "$body")
    [[ $(status "$answer") == 400 ]] && ok "\"${body:0:40}\" is refused, 400" || bad "${body:0:40}: $answer"
done
[[ -z $(drain) ]] && ok "and none is queued" || bad "a malformed request was queued"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
