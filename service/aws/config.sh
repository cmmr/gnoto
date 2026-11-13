#
# config.sh - gnoto config s3 and gnoto config sqs: checks the bucket and the
# queue, or with --deploy, builds them as CloudFormation stacks; and lint's
# checks of both.
#
# Sourced by:  lib/config.sh and lib/lint.sh
# Defines:     config_s3_step, config_sqs_step, stack_template, lint_s3,
#              lint_sqs
# Requires:    aws, curl, jq and yq; gnoto_aws and the S3 helpers from
#              service/aws/aws.sh; generated_set and config_confirm from
#              lib/config.sh; lint_ok, lint_warn and lint_fail from lib/lint.sh
#
# A site that runs its own bucket, CloudFront and queue fills in aws.s3_bucket,
# results_base_url, sqs_queue_url and webhook_url, and config only checks them.
# --deploy builds the same pieces instead, as the stacks in service/aws/stacks/:
# gnoto-iam, gnoto's IAM user, deployed by whichever runs first; gnoto-s3; and
# gnoto-sqs. They're deployed with the admin credentials of --profile, used for
# nothing else, and their outputs go to generated.yaml, where a value in
# config.yaml wins. The first deploy makes the IAM user's access key and prints
# it once, to put in config.yaml with gnoto config aws, since config never
# writes keys there itself. Each step shows its plan and asks before changing
# anything, and --dry-run stops after the plan.

STACK_IAM=gnoto-iam
STACK_S3=gnoto-s3
STACK_SQS=gnoto-sqs

# aws with the admin profile --profile named, or the CLI's own credentials
admin_aws() {
    local profile=()
    [[ -z ${CONFIG_PROFILE:-} ]] || profile=(--profile "$CONFIG_PROFILE")
    env AWS_DEFAULT_REGION="${AWS_REGION:-}" AWS_PAGER="" aws "${profile[@]}" "$@"
}

# A file's lines, each indented: indent <spaces> <file>
indent() {
    sed "s/^/$(printf '%*s' "$1" '')/" "$2"
}

# A stack's template with the code it carries filled in: stack_template <name>.
# The Lambda's comments are left out, since inline code is limited to 4,096
# characters.
stack_template() {
    local name=$1 file=$CODE_DIR/service/aws/stacks/$1.yaml code
    case $name in
        s3)
            code=$(sed "s/^var RUN_PREFIX = 'gnoto';/var RUN_PREFIX = '${AWS_RUN_PREFIX:-gnoto}';/" \
                "$CODE_DIR/service/aws/cloudfront/directory-index.js" | indent 8 /dev/stdin)
            CODE=$code awk '/^ *__DIRECTORY_INDEX_JS__$/ { print ENVIRON["CODE"]; next } { print }' "$file"
            ;;
        sqs)
            code=$(grep -v '^ *#' "$CODE_DIR/service/aws/lambda/webhook.py" | awk 'NF || prev { print } { prev = NF }')
            (( ${#code} <= 4000 )) || fail "service/aws/lambda/webhook.py is ${#code} characters without its comments, more than CloudFormation takes inline."
            code=$(printf '%s\n' "$code" | indent 10 /dev/stdin)
            CODE=$code awk '/^ *__WEBHOOK_PY__$/ { print ENVIRON["CODE"]; next } { print }' "$file"
            ;;
        *) cat "$file" ;;
    esac
}

# A stack's outputs as "key<tab>value" lines, or nothing when there's no stack
stack_outputs() {
    admin_aws cloudformation describe-stacks --stack-name "$1" --output json 2> /dev/null |
        jq -r '.Stacks[0].Outputs[]? | "\(.OutputKey)\t\(.OutputValue)"'
}

stack_exists() {
    admin_aws cloudformation describe-stacks --stack-name "$1" > /dev/null 2>&1
}

# stack_deploy <stack> <template name> [Key=Value ...]: creates or updates it,
# and waits
stack_deploy() {
    local stack=$1 name=$2 template params=()
    shift 2
    (( $# == 0 )) || params=(--parameter-overrides "$@")
    template=$(mktemp "${TMPDIR:-/tmp}/gnoto-$name.XXXXXX") || fail "Can't write a template in ${TMPDIR:-/tmp}."
    stack_template "$name" > "$template" || { rm -f "$template"; exit 1; }
    echo "Deploying the stack $stack. This takes a few minutes, a CloudFront distribution up to fifteen." >&2
    if ! admin_aws cloudformation deploy --stack-name "$stack" --template-file "$template" \
        --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --tags app=gnoto \
        ${params[@]+"${params[@]}"} >&2; then
        rm -f "$template"
        fail "The stack $stack didn't deploy. Its events say why: aws cloudformation describe-stack-events --stack-name $stack"
    fi
    rm -f "$template"
}

# The IAM user's stack, deployed if it isn't there yet, and the user's first
# access key, printed once
iam_deploy() {
    local user keys json
    if ! stack_exists "$STACK_IAM"; then
        stack_deploy "$STACK_IAM" iam
    fi
    user=$(stack_outputs "$STACK_IAM" | awk -F'\t' '$1 == "UserName" { print $2 }')
    [[ -n $user ]] || fail "The stack $STACK_IAM has no UserName output."
    generated_set aws.iam_user "$user"
    keys=$(admin_aws iam list-access-keys --user-name "$user" --output json | jq '.AccessKeyMetadata | length') ||
        fail "Can't list $user's access keys."
    if (( keys == 0 )); then
        json=$(admin_aws iam create-access-key --user-name "$user" --output json) || fail "Can't make $user's access key."
        echo
        echo "gnoto's IAM user, $user, has a new access key. It's shown this once:"
        echo "  access_key_id:     $(jq -r .AccessKey.AccessKeyId <<< "$json")"
        echo "  secret_access_key: $(jq -r .AccessKey.SecretAccessKey <<< "$json")"
        echo "Put both in config.yaml with: $(gnoto_command config aws)"
        echo
    fi
}

# The plan's confirmation, from config_confirm, then deploys
deploy_confirm() {
    config_confirm "$@" || exit 0
}

# gnoto config s3 [--deploy [--profile=<name>] [--domain=<name> --certificate=<arn>]] [--dry-run] [--yes]
config_s3_step() {
    local plan=() outputs url
    [[ ${AWS_ENABLED:-false} == true ]] || fail "The aws section is off. $(gnoto_command config aws --on) turns it on."
    if [[ -n ${CONFIG_DEPLOY:-} ]]; then
        [[ -n ${AWS_REGION:-} ]] || fail "Set aws.region first: $(gnoto_command config aws --region=us-east-1)"
        [[ -n ${AWS_S3_BUCKET:-} ]] || fail "Set aws.s3_bucket first, to the name the bucket is to have: $(gnoto_command config aws "--s3_bucket=<name>")"
        [[ ${AWS_RUN_PREFIX:-gnoto} =~ ^[A-Za-z0-9._-]+$ ]] || fail "aws.run_prefix should be one folder name, such as gnoto."
        [[ -z ${CONFIG_DOMAIN:-} || -n ${CONFIG_CERTIFICATE:-} ]] ||
            fail "A custom domain needs its certificate, an ACM certificate in us-east-1, as --certificate=<arn>."
        stack_exists "$STACK_IAM" || plan+=("Create the stack $STACK_IAM: gnoto's IAM user, and its access key")
        if stack_exists "$STACK_S3"; then
            plan+=("Update the stack $STACK_S3: the bucket $AWS_S3_BUCKET, its CloudFront distribution and function, and the user's access under $AWS_RUN_PREFIX/")
        else
            plan+=("Create the stack $STACK_S3: the bucket $AWS_S3_BUCKET, a CloudFront distribution${CONFIG_DOMAIN:+ at $CONFIG_DOMAIN} with its function, and the user's access under ${AWS_RUN_PREFIX:-gnoto}/")
        fi
        deploy_confirm "in AWS account $(admin_aws sts get-caller-identity --query Account --output text 2> /dev/null || echo "(unknown)"), region $AWS_REGION" "${plan[@]}"
        iam_deploy
        stack_deploy "$STACK_S3" s3 "BucketName=$AWS_S3_BUCKET" "RunPrefix=${AWS_RUN_PREFIX:-gnoto}" \
            "IamStack=$STACK_IAM" ${CONFIG_DOMAIN:+"DomainName=$CONFIG_DOMAIN"} \
            ${CONFIG_CERTIFICATE:+"CertificateArn=$CONFIG_CERTIFICATE"}
        outputs=$(stack_outputs "$STACK_S3")
        url=$(awk -F'\t' '$1 == "ResultsBaseUrl" { print $2 }' <<< "$outputs")
        generated_set aws.results_base_url "$url"
        generated_set aws.distribution_id "$(awk -F'\t' '$1 == "DistributionId" { print $2 }' <<< "$outputs")"
        [[ -z ${CONFIG_DOMAIN:-} ]] || echo "Point $CONFIG_DOMAIN's DNS at $(awk -F'\t' '$1 == "DistributionDomain" { print $2 }' <<< "$outputs")."
        echo "The results are served from $url, in $DATA_DIR/generated.yaml."
        # This command's own settings, read again with the stack's outputs
        source "$CODE_DIR/lib/env.sh"
    fi
    LINT_FAILS=0
    lint_s3
    (( LINT_FAILS == 0 )) || fail "S3 isn't ready, as above."
    echo "S3 is ready."
}

# gnoto config sqs [--deploy [--profile=<name>]] [--dry-run] [--yes]
config_sqs_step() {
    local plan=() outputs
    [[ ${AWS_ENABLED:-false} == true ]] || fail "The aws section is off. $(gnoto_command config aws --on) turns it on."
    if [[ -n ${CONFIG_DEPLOY:-} ]]; then
        [[ -n ${AWS_REGION:-} ]] || fail "Set aws.region first: $(gnoto_command config aws --region=us-east-1)"
        stack_exists "$STACK_IAM" || plan+=("Create the stack $STACK_IAM: gnoto's IAM user, and its access key")
        if stack_exists "$STACK_SQS"; then
            plan+=("Update the stack $STACK_SQS: the queue, the webhook's Lambda and its HTTP API, and the user's access to the queue")
        else
            plan+=("Create the stack $STACK_SQS: a queue, the webhook's Lambda and its HTTP API, and the user's access to the queue")
        fi
        deploy_confirm "in AWS account $(admin_aws sts get-caller-identity --query Account --output text 2> /dev/null || echo "(unknown)"), region $AWS_REGION" "${plan[@]}"
        iam_deploy
        wrike_webhook_secret
        stack_deploy "$STACK_SQS" sqs "WebhookSecret=$WRIKE_WEBHOOK_SECRET" "IamStack=$STACK_IAM"
        outputs=$(stack_outputs "$STACK_SQS")
        generated_set aws.sqs_queue_url "$(awk -F'\t' '$1 == "QueueUrl" { print $2 }' <<< "$outputs")"
        generated_set aws.webhook_url "$(awk -F'\t' '$1 == "WebhookUrl" { print $2 }' <<< "$outputs")"
        echo "The queue and the webhook's address are in $DATA_DIR/generated.yaml. $(gnoto_command config wrike) registers the webhook."
        source "$CODE_DIR/lib/env.sh"
    fi
    LINT_FAILS=0
    lint_sqs
    (( LINT_FAILS == 0 )) || fail "SQS isn't ready, as above."
    echo "SQS is ready."
}

# Who gnoto's keys are, for a check's message, or nothing
aws_identity() {
    gnoto_aws sts get-caller-identity --query Arn --output text 2> /dev/null
}

# lint's S3 checks: the keys work, gnoto can write, read and delete under the
# run prefix, and results_base_url serves what's there, a folder's page too
lint_s3() {
    local identity key=${AWS_RUN_PREFIX:-gnoto}/gnoto-check-$$ body dir out code
    if [[ ${AWS_ENABLED:-false} != true ]]; then
        return 0
    fi
    if [[ -z ${AWS_S3_BUCKET:-} && -z ${AWS_RESULTS_BASE_URL:-} ]]; then
        lint_ok "s3: not set up, so results stay where they're made"
        return 0
    fi
    [[ -n ${AWS_S3_BUCKET:-} ]] || { lint_fail "s3: aws.results_base_url is set, and aws.s3_bucket isn't. $(gnoto_command config aws) sets it"; return 0; }
    [[ -n ${AWS_RESULTS_BASE_URL:-} ]] ||
        { lint_fail "s3: aws.s3_bucket is set, and aws.results_base_url isn't. $(gnoto_command config s3 --deploy) makes both, or set it to the address that serves the bucket"; return 0; }
    [[ ${AWS_RUN_PREFIX:-gnoto} =~ ^[A-Za-z0-9._-]+$ ]] || lint_fail "s3: aws.run_prefix should be one folder name, such as gnoto"
    identity=$(aws_identity) || identity=""
    [[ -n $identity ]] || { lint_fail "s3: gnoto's AWS keys don't work. Check aws.access_key_id and secret_access_key"; return 0; }
    body="gnoto lint, $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if ! out=$(printf '%s\n' "$body" | s3_put - "$AWS_S3_BUCKET" "$key.txt" "text/plain; charset=utf-8" no-cache 2>&1); then
        lint_fail "s3: $identity can't write under s3://$AWS_S3_BUCKET/${AWS_RUN_PREFIX:-gnoto}/: $(head -c 200 <<< "$out")"
        return 0
    fi
    dir=$(mktemp -d "${TMPDIR:-/tmp}/gnoto-s3check.XXXXXX")
    printf '<html><head><title>gnoto-check</title></head></html>\n' > "$dir/directory_listing.html"
    s3_put "$dir/directory_listing.html" "$AWS_S3_BUCKET" "$key/directory_listing.html" "text/html; charset=utf-8" no-cache \
        > /dev/null 2>&1 || :
    rm -rf "$dir"
    if [[ $(s3_count "$AWS_S3_BUCKET" "${AWS_RUN_PREFIX:-gnoto}" 2> /dev/null || echo 0) -ge 1 ]]; then
        lint_ok "s3: $identity can write and list under s3://$AWS_S3_BUCKET/${AWS_RUN_PREFIX:-gnoto}/"
    else
        lint_fail "s3: $identity can write under s3://$AWS_S3_BUCKET/${AWS_RUN_PREFIX:-gnoto}/, and can't list it"
    fi
    out=$(curl -sS --max-time 30 "${AWS_RESULTS_BASE_URL%/}/$key.txt" 2>&1) || out=""
    if [[ $out == "$body" ]]; then
        lint_ok "s3: ${AWS_RESULTS_BASE_URL%/}/ serves what's in the bucket"
    else
        lint_fail "s3: ${AWS_RESULTS_BASE_URL%/}/$key.txt didn't serve the test file uploaded there: $(head -c 120 <<< "$out")"
    fi
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "${AWS_RESULTS_BASE_URL%/}/$key" 2> /dev/null) || code=""
    out=$(curl -sS -L --max-time 30 "${AWS_RESULTS_BASE_URL%/}/$key/" 2> /dev/null) || out=""
    if [[ $code == 301 && $out == *gnoto-check* ]]; then
        lint_ok "s3: a folder's address serves its page, through the CloudFront function"
    else
        lint_warn "s3: a folder's address, ${AWS_RESULTS_BASE_URL%/}/$key/, doesn't serve its page, so folder links in the pipelines' own reports fail. Attach service/aws/cloudfront/directory-index.js to the distribution"
    fi
    gnoto_aws s3 rm --only-show-errors --recursive "s3://$AWS_S3_BUCKET/$key/" > /dev/null 2>&1 || :
    gnoto_aws s3 rm --only-show-errors "s3://$AWS_S3_BUCKET/$key.txt" > /dev/null 2>&1 ||
        lint_fail "s3: $identity can't delete under s3://$AWS_S3_BUCKET/${AWS_RUN_PREFIX:-gnoto}/, so results would never expire"
}

# lint's SQS checks: the keys work, the queue answers, and how many messages
# are waiting
lint_sqs() {
    local identity waiting
    [[ ${AWS_ENABLED:-false} == true && -n ${AWS_SQS_QUEUE_URL:-} ]] || return 0
    identity=$(aws_identity) || identity=""
    [[ -n $identity ]] || { lint_fail "sqs: gnoto's AWS keys don't work. Check aws.access_key_id and secret_access_key"; return 0; }
    if waiting=$(gnoto_aws sqs get-queue-attributes --queue-url "$AWS_SQS_QUEUE_URL" \
        --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text 2>&1); then
        if [[ $waiting =~ ^[0-9]+$ ]] && (( waiting > 20 )); then
            lint_warn "sqs: $waiting messages waiting, so the listener may not be running"
        else
            lint_ok "sqs: $waiting messages waiting"
        fi
    else
        lint_fail "sqs: $identity can't read $AWS_SQS_QUEUE_URL: $(head -c 200 <<< "$waiting")"
    fi
    [[ -n ${AWS_WEBHOOK_URL:-} ]] || lint_warn "sqs: aws.webhook_url isn't set, so gnoto config wrike can't register the webhook"
}
