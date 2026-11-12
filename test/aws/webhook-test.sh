#!/bin/bash
#
# webhook-test.sh - Tests the webhook Lambda, service/aws/lambda/webhook.py, in
# AWS's Lambda image with its Runtime Interface Emulator, and ElasticMQ
# standing in for SQS.
#
# Run by:    a developer, from any directory, on a machine with Docker
# Usage:     test/aws/webhook-test.sh
# Requires:  docker, curl, openssl and jq. Works from Git Bash on Windows.
#
# Each case posts an API Gateway (HTTP API) event to the function and checks
# its answer, then what reached the queue. Removes its containers and network.

set -euo pipefail
export MSYS_NO_PATHCONV=1

REPO=$(cd "$(dirname "$0")/../.." && pwd)
LAMBDA_IMAGE=public.ecr.aws/lambda/python:3.14@sha256:a4f5983a81ac02cc52baf2f7e8e3dd39fb3b8db44b769e407a2344980f2b5107
QUEUE_IMAGE=softwaremill/elasticmq-native:1.7.1@sha256:e4580ab9ad1bd5cd37b4ba04911bc5ccc8cd2d9ab4de56ece65acee71c24e05c
NET=gnoto-webhook-test
SECRET=test-secret-$RANDOM
PORT=${PORT:-19001}
PASS=0
FAIL=0

cleanup() {
    docker rm -f gnoto-webhook-lambda gnoto-webhook-queue > /dev/null 2>&1 || :
    docker network rm "$NET" > /dev/null 2>&1 || :
}
trap cleanup EXIT
cleanup

ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

docker network create "$NET" > /dev/null
docker run -d --name gnoto-webhook-queue --network "$NET" --network-alias elasticmq "$QUEUE_IMAGE" > /dev/null
docker create --name gnoto-webhook-lambda --network "$NET" -p "127.0.0.1:$PORT:8080" \
    -e AWS_SQS_QUEUE_URL=http://elasticmq:9324/000000000000/webhook \
    -e WRIKE_WEBHOOK_SECRET="$SECRET" \
    -e AWS_ENDPOINT_URL_SQS=http://elasticmq:9324 \
    -e AWS_ACCESS_KEY_ID=test -e AWS_SECRET_ACCESS_KEY=test -e AWS_REGION=us-east-1 -e AWS_DEFAULT_REGION=us-east-1 \
    "$LAMBDA_IMAGE" webhook.lambda_handler > /dev/null
tar -c -C "$REPO/service/aws/lambda" webhook.py | docker cp - gnoto-webhook-lambda:/var/task
docker start gnoto-webhook-lambda > /dev/null

# Runs Python with boto3 against the queue, in the Lambda's own container
queue_python() {
    docker exec -i gnoto-webhook-lambda python3 - "$@"
}

for (( i = 0; i < 30; i++ )); do
    queue_python <<'EOF' > /dev/null 2>&1 && break
import boto3
boto3.client('sqs').create_queue(QueueName='webhook')
EOF
    sleep 1
done

# Takes everything waiting on the queue, a body a line
drain() {
    queue_python <<'EOF'
import boto3, json
sqs = boto3.client('sqs')
url = 'http://elasticmq:9324/000000000000/webhook'
while True:
    got = sqs.receive_message(QueueUrl=url, MaxNumberOfMessages=10, WaitTimeSeconds=1).get('Messages', [])
    if not got:
        break
    for m in got:
        print(json.dumps(m['Body']))
        sqs.delete_message(QueueUrl=url, ReceiptHandle=m['ReceiptHandle'])
EOF
}

sign() {
    printf '%s' "$1" | openssl dgst -sha256 -hmac "$SECRET" | sed 's/^.* //'
}

# invoke <body> <headers as JSON> [base64]: prints the function's answer
invoke() {
    local body=$1 headers=$2 encoded=false
    if [[ ${3:-} == base64 ]]; then
        body=$(printf '%s' "$body" | base64 | tr -d '\n')
        encoded=true
    fi
    jq -cn --arg body "$body" --argjson headers "$headers" --argjson encoded "$encoded" \
        '{version: "2.0", routeKey: "POST /wrike", rawPath: "/wrike", headers: $headers, body: $body,
          isBase64Encoded: $encoded, requestContext: {http: {method: "POST", path: "/wrike"}}}' |
        curl -sS -X POST --data-binary @- "http://127.0.0.1:$PORT/2015-03-31/functions/function/invocations"
}

for (( i = 0; i < 30; i++ )); do
    invoke '{}' '{}' > /dev/null 2>&1 && break
    sleep 1
done

echo "webhook.py"
EVENT='[{"taskId":"MAAAAAEtest01","webhookId":"IEAAAAAA","eventAuthorId":"KUAAAAAA","eventType":"TaskCreated","lastUpdatedDate":"2026-11-12T00:00:00Z"}]'

answer=$(invoke "$EVENT" "$(jq -cn --arg s "$(sign "$EVENT")" '{"X-Hook-Signature": $s}')")
[[ $(jq -r .statusCode <<< "$answer") == 200 ]] && ok "a signed event is accepted" || bad "a signed event: $answer"
[[ $(drain) == "$(jq -cn --arg b "$EVENT" '$b')" ]] && ok "and reaches the queue as it came" || bad "the signed event didn't reach the queue"

answer=$(invoke "$EVENT" "$(jq -cn --arg s "$(sign "$EVENT")" '{"x-hook-signature": ($s | ascii_upcase)}')")
[[ $(jq -r .statusCode <<< "$answer") == 200 ]] && ok "a signature in capitals, under a lowercase header, is accepted" ||
    bad "upper-case signature: $answer"
drain > /dev/null

answer=$(invoke "$EVENT" '{}')
[[ $(jq -r .statusCode <<< "$answer") == 401 ]] && ok "an unsigned event is refused, 401" || bad "unsigned: $answer"
answer=$(invoke "$EVENT" "$(jq -cn --arg s "$(sign "x$EVENT")" '{"X-Hook-Signature": $s}')")
[[ $(jq -r .statusCode <<< "$answer") == 403 ]] && ok "a wrongly signed event is refused, 403" || bad "wrong signature: $answer"
[[ -z $(drain) ]] && ok "and neither reaches the queue" || bad "a refused event reached the queue"

HANDSHAKE='{"requestType":"WebHook secret verification"}'
answer=$(invoke "$HANDSHAKE" "$(jq -cn --arg s "$(sign "$HANDSHAKE")" '{"X-Hook-Signature": $s, "X-Hook-Secret": "abc123XYZ"}')")
[[ $(jq -r .statusCode <<< "$answer") == 200 && $(jq -r '.headers["X-Hook-Secret"]' <<< "$answer") == "$(sign abc123XYZ)" ]] &&
    ok "the handshake is answered with HMAC(secret, challenge)" || bad "handshake: $answer"
[[ -z $(drain) ]] && ok "and isn't queued" || bad "the handshake was queued"

answer=$(invoke "$EVENT" "$(jq -cn --arg s "$(sign "$EVENT")" '{"X-Hook-Signature": $s, "X-Hook-Secret": "chal42"}')")
[[ $(jq -r .statusCode <<< "$answer") == 200 && $(jq -r '.headers["X-Hook-Secret"]' <<< "$answer") == "$(sign chal42)" ]] &&
    ok "an event with a challenge is answered and queued" || bad "event with a challenge: $answer"
[[ -n $(drain) ]] && ok "and reaches the queue" || bad "the event with a challenge wasn't queued"

for challenge in '{"a":1}' "$(printf 'a%.0s' {1..101})" 'abc def'; do
    answer=$(invoke "$EVENT" "$(jq -cn --arg s "$(sign "$EVENT")" --arg c "$challenge" '{"X-Hook-Signature": $s, "X-Hook-Secret": $c}')")
    [[ $(jq -r .statusCode <<< "$answer") == 400 ]] && ok "a challenge of \"${challenge:0:12}\" is refused, 400" ||
        bad "challenge ${challenge:0:12}: $answer"
done
[[ -z $(drain) ]] && ok "and none reaches the queue" || bad "an event with a bad challenge was queued"

answer=$(invoke "$EVENT" "$(jq -cn --arg s "$(sign "$EVENT")" '{"X-Hook-Signature": $s}')" base64)
[[ $(jq -r .statusCode <<< "$answer") == 200 && $(drain) == "$(jq -cn --arg b "$EVENT" '$b')" ]] &&
    ok "a base64 body is checked and queued decoded" || bad "base64: $answer"

echo
echo "$PASS passed, $FAIL failed"
(( FAIL == 0 ))
