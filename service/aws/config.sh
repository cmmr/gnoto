#
# config.sh - gnoto config s3 and gnoto config sqs: ask what S3 and SQS need,
# offering what the AWS account already has, and deploy them as CloudFormation
# stacks; and lint's checks of both.
#
# Sourced by:  lib/config.sh and lib/lint.sh
# Defines:     config_s3_interactive, config_s3_deploy, config_sqs_interactive,
#              config_sqs_deploy, stack_template, lint_s3, lint_sqs
# Requires:    aws, curl, jq and yq; gnoto_aws and the S3 helpers from
#              service/aws/aws.sh; config_set, config_add_section,
#              config_has_section, config_choose, config_text, config_yes,
#              config_proceed and generated_set from lib/config.sh; lint_ok,
#              lint_warn and lint_fail from lib/lint.sh
#
# Two sets of credentials. Deploying uses the person's own AWS CLI
# credentials, from the profile aws.deploy_profile names, or the CLI's default
# ones, which gnoto never stores: they create stacks and an IAM user. Everything
# else uses gnoto's IAM user, a stack of its own, gnoto-iam, which may only
# write under the run prefix and read the queue. Its access key goes into
# config.yaml when a deploy makes it.
#
# gnoto config s3, from a terminal, picks the deploy profile: the only one in
# ~/.aws, or the one chosen from several, or with none, an access key it asks
# for, saved as the profile gnoto in the person's own ~/.aws, which only they
# can read. Then it asks for the region, offers the account's buckets or a new
# one, and offers CloudFront's own address, a name in one of the account's
# Route 53 zones, or a domain elsewhere. A name in a zone gets its DNS records
# from the stack, and a certificate: one already issued in ACM in us-east-1, or
# else one gnoto makes in the stack gnoto-certificate, in us-east-1, the only
# region CloudFront takes certificates from. gnoto config sqs asks only the
# profile and region. --deploy asks nothing, and takes what config.yaml holds.
#
# Each lists every setting it's about to apply and the stacks it creates or
# updates, then asks to go ahead, yes by default. Nothing is written or
# deployed before that: not config.yaml, nor the new profile. --yes answers
# for a script, and --dry-run stops after the list. The stacks are in
# service/aws/stacks/, and their outputs go to generated.yaml, where a value in
# config.yaml wins. A site that runs its own bucket, CloudFront or queue fills
# in aws.s3.results_base_url, aws.sqs.queue_url, webhook_url and access_url
# instead, and its own keys.

STACK_IAM=gnoto-iam
STACK_S3=gnoto-s3
STACK_SQS=gnoto-sqs
STACK_CERTIFICATE=gnoto-certificate

# aws with the deploy profile, or the access key just typed, in DEPLOY_KEY_ID
# and DEPLOY_SECRET until it's saved as one, in the region ADMIN_REGION, or
# aws.region, or before that's chosen, us-east-1. The region goes on the command
# line, and aws.region's exported AWS_REGION is left out, since the CLI reads it
# first. A key goes in the environment of the one call, never a command line.
admin_aws() {
    local options=(--region "${ADMIN_REGION:-${AWS_REGION:-us-east-1}}")
    [[ -n ${DEPLOY_KEY_ID:-} || -z ${AWS_DEPLOY_PROFILE:-} ]] || options+=(--profile "$AWS_DEPLOY_PROFILE")
    (
        unset AWS_REGION
        export AWS_PAGER=""
        if [[ -n ${DEPLOY_KEY_ID:-} ]]; then
            export AWS_ACCESS_KEY_ID=$DEPLOY_KEY_ID AWS_SECRET_ACCESS_KEY=$DEPLOY_SECRET
        else
            unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        fi
        exec aws "${options[@]}" "$@"
    )
}

# A file's lines, each indented: indent <spaces> <file>
indent() {
    sed "s/^/$(printf '%*s' "$1" '')/" "$2"
}

# A Lambda's code from service/aws/lambda/<name>.py, without its comments,
# indented to go inline in a stack: lambda_inline <name>
lambda_inline() {
    local code
    code=$(grep -v '^ *#' "$CODE_DIR/service/aws/lambda/$1.py" | awk 'NF || prev { print } { prev = NF }')
    (( ${#code} <= 4000 )) || fail "service/aws/lambda/$1.py is ${#code} characters without its comments, more than CloudFormation takes inline."
    printf '%s\n' "$code" | indent 10 /dev/stdin
}

# A stack's template with the code it carries filled in: stack_template <name>.
# The Lambdas' comments are left out, since inline code is limited to 4,096
# characters.
stack_template() {
    local name=$1 file=$CODE_DIR/service/aws/stacks/$1.yaml code webhook access
    case $name in
        s3)
            code=$(indent 8 "$CODE_DIR/service/aws/cloudfront/directory-index.js")
            CODE=$code awk '/^ *__DIRECTORY_INDEX_JS__$/ { print ENVIRON["CODE"]; next } { print }' "$file"
            ;;
        sqs)
            webhook=$(lambda_inline webhook) && access=$(lambda_inline access) || exit 1
            WEBHOOK=$webhook ACCESS=$access awk '
                /^ *__WEBHOOK_PY__$/ { print ENVIRON["WEBHOOK"]; next }
                /^ *__ACCESS_PY__$/ { print ENVIRON["ACCESS"]; next }
                { print }' "$file"
            ;;
        *) cat "$file" ;;
    esac
}

# A stack's outputs as "key<tab>value" lines, or nothing when there's no stack
stack_outputs() {
    admin_aws cloudformation describe-stacks --stack-name "$1" --output json 2> /dev/null |
        jq -r '.Stacks[0].Outputs[]? | "\(.OutputKey)\t\(.OutputValue)"'
}

# One output: stack_output <stack> <key>
stack_output() {
    stack_outputs "$1" | awk -F'\t' -v key="$2" '$1 == key { print $2 }'
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
    echo "Deploying the stack $stack. This takes a few minutes, a CloudFront distribution or a certificate up to fifteen." >&2
    if ! admin_aws cloudformation deploy --stack-name "$stack" --template-file "$template" \
        --capabilities CAPABILITY_IAM --no-fail-on-empty-changeset --tags app=gnoto \
        ${params[@]+"${params[@]}"} >&2; then
        rm -f "$template"
        fail "The stack $stack didn't deploy. Its events say why: aws cloudformation describe-stack-events --stack-name $stack${ADMIN_REGION:+ --region $ADMIN_REGION}"
    fi
    rm -f "$template"
}

# Checks the deploy credentials, setting DEPLOY_ACCOUNT and DEPLOY_ARN, or
# fails with how to give them
deploy_identity() {
    local json
    if ! json=$(admin_aws sts get-caller-identity --output json 2>&1); then
        if [[ -n ${AWS_DEPLOY_PROFILE:-} ]]; then
            fail "The AWS CLI profile $AWS_DEPLOY_PROFILE, aws.deploy_profile, can't deploy: $(head -c 300 <<< "$json"). $(gnoto_command config s3) chooses another."
        fi
        fail "No AWS credentials to deploy with: $(head -c 300 <<< "$json"). $(gnoto_command config s3) asks for them."
    fi
    DEPLOY_ACCOUNT=$(jq -r '.Account' <<< "$json")
    DEPLOY_ARN=$(jq -r '.Arn' <<< "$json")
}

# The IAM user's stack, deployed if it isn't there yet, and an access key of the
# user's in config.yaml: the one there if the user still has it, or else a new
# one, written there
iam_deploy() {
    local user json ids count
    if ! stack_exists "$STACK_IAM"; then
        stack_deploy "$STACK_IAM" iam
    fi
    user=$(stack_output "$STACK_IAM" UserName)
    [[ -n $user ]] || fail "The stack $STACK_IAM has no UserName output."
    generated_set aws.iam_user "$user"
    json=$(admin_aws iam list-access-keys --user-name "$user" --output json) || fail "Can't list $user's access keys."
    ids=$(jq -r '.AccessKeyMetadata[].AccessKeyId' <<< "$json")
    if [[ -n ${AWS_ACCESS_KEY_ID:-} && -n ${AWS_SECRET_ACCESS_KEY:-} ]] && grep -qx "$AWS_ACCESS_KEY_ID" <<< "$ids"; then
        return 0
    fi
    count=$(grep -c . <<< "$ids" || :)
    (( count < 2 )) ||
        fail "gnoto's IAM user, $user, has two access keys already, and config.yaml holds neither. Delete one with: aws iam delete-access-key --user-name $user --access-key-id <ID>"
    json=$(admin_aws iam create-access-key --user-name "$user" --output json) || fail "Can't make $user's access key."
    config_set aws access_key_id "$(jq -r .AccessKey.AccessKeyId <<< "$json")"
    config_set aws secret_access_key "$(jq -r .AccessKey.SecretAccessKey <<< "$json")"
    echo "gnoto's IAM user, $user, has a new access key, written to $CONFIG_FILE." >&2
}

# The aws section, there and on, before a subsection's answers go in
config_aws_ready() {
    if ! config_has_section aws; then
        declare -gA CONFIG_NEW=()
        config_add_section aws true
    elif [[ $(config_get aws enabled) != true ]]; then
        config_set aws enabled true
    fi
}

# A subsection of aws, there and on: config_subsection_on <name>
config_subsection_on() {
    if ! config_has_section "aws.$1"; then
        declare -gA CONFIG_NEW=()
        config_add_section "aws.$1" true
    elif [[ $(config_get "aws.$1" enabled) != true ]]; then
        config_set "aws.$1" enabled true
    fi
}

# Asks for an access key, for a person with no AWS CLI profile at all, and
# holds it in DEPLOY_KEY_ID and DEPLOY_SECRET, which admin_aws uses, until
# aws_save_profile saves it as the profile gnoto
aws_ask_key() {
    echo "There's no AWS CLI profile in $HOME/.aws, so give an access key of an AWS account that can create gnoto's stacks and IAM user." >&2
    # Plain reads, as the secret's is, before any of readline's
    while :; do
        read -r -p "Access key ID: " DEPLOY_KEY_ID || fail "No answer, so nothing was written."
        [[ $DEPLOY_KEY_ID =~ ^[A-Z0-9]{16,128}$ ]] && break
        echo "  An access key ID is capital letters and digits, such as AKIAIOSFODNN7EXAMPLE." >&2
    done
    read -r -s -p "Secret access key: " DEPLOY_SECRET || fail "No answer, so nothing was written."
    echo >&2
    [[ -n $DEPLOY_SECRET ]] || fail "No secret access key, so nothing was written."
    AWS_DEPLOY_PROFILE=gnoto
}

# Saves the access key aws_ask_key holds as the profile gnoto in
# ~/.aws/credentials, which only its owner can read. The secret goes through
# printf, a builtin, never a command line.
aws_save_profile() {
    local file=$HOME/.aws/credentials
    [[ -n ${DEPLOY_KEY_ID:-} ]] || return 0
    mkdir -p "$HOME/.aws" && chmod 700 "$HOME/.aws" || fail "Can't create $HOME/.aws."
    ( umask 077 && printf '\n[gnoto]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
        "$DEPLOY_KEY_ID" "$DEPLOY_SECRET" >> "$file" ) || fail "Can't write $file."
    chmod 600 "$file"
    echo "Saved the access key as the AWS CLI profile gnoto, in $file, which only you can read." >&2
    DEPLOY_KEY_ID="" DEPLOY_SECRET=""
}

# Asks what s3 and sqs share: the profile to deploy with, which must work, and
# the region, setting AWS_DEPLOY_PROFILE and AWS_REGION. Writes nothing.
config_aws_ask() {
    local profiles=() default=1 i region
    mapfile -t profiles < <(aws configure list-profiles 2> /dev/null | grep .)
    if (( ${#profiles[@]} == 0 )); then
        aws_ask_key
    elif (( ${#profiles[@]} == 1 )); then
        AWS_DEPLOY_PROFILE=${profiles[0]}
        echo "Deploying with the AWS CLI profile $AWS_DEPLOY_PROFILE, the only one in $HOME/.aws." >&2
    else
        for (( i = 0; i < ${#profiles[@]}; i++ )); do
            [[ ${profiles[i]} != "${AWS_DEPLOY_PROFILE:-default}" ]] || default=$((i + 1))
        done
        config_choose "Which AWS CLI profile deploys gnoto's stacks?" "$default" "${profiles[@]}"
        AWS_DEPLOY_PROFILE=${profiles[CHOICE - 1]}
    fi
    region=$AWS_REGION
    [[ -n $region || -n ${DEPLOY_KEY_ID:-} ]] || region=$(aws configure get region --profile "$AWS_DEPLOY_PROFILE" 2> /dev/null)
    deploy_identity
    echo "Signed in as $DEPLOY_ARN." >&2
    while :; do
        config_text "${CONFIG_QUESTION[aws.region]}" "${region:-us-east-1}"
        [[ $ANSWER =~ ^[a-z]{2}(-[a-z]+)+-[0-9]$ ]] && break
        echo "  A region is written like us-east-1." >&2
    done
    AWS_REGION=$ANSWER
}

# Writes what config_aws_ask chose, once it's confirmed: the access key, as a
# profile, and the aws section, on
config_aws_write() {
    aws_save_profile
    config_aws_ready
    config_set aws deploy_profile "$AWS_DEPLOY_PROFILE"
    config_set aws region "$AWS_REGION"
}

# Prints the settings a deploy applies, "<label>\t<value>" lines in SETTINGS,
# then what it changes, in PLAN: config_show <heading>
config_show() {
    local line item
    printf '%s\n' "$1" >&2
    for line in "${SETTINGS[@]}"; do
        printf '  %-16s %s\n' "${line%%$'\t'*}" "${line#*$'\t'}" >&2
    done
    echo "Deploying:" >&2
    for item in "${PLAN[@]}"; do
        printf '  - %s\n' "$item" >&2
    done
}

# The deploy account and profile, as config_show's first lines
deploy_settings() {
    local profile=${AWS_DEPLOY_PROFILE:-the AWS CLI\'s default credentials}
    [[ -z ${DEPLOY_KEY_ID:-} ]] || profile="gnoto, new in $HOME/.aws/credentials, from the access key given"
    SETTINGS=("AWS account"$'\t'"$DEPLOY_ACCOUNT, signed in as $DEPLOY_ARN"
        "Deploy profile"$'\t'"$profile"
        "Region"$'\t'"$AWS_REGION")
}

# What a bucket name is to the account: mine, free or taken
bucket_state() {
    local out
    out=$(admin_aws s3api head-bucket --bucket "$1" 2>&1) && { echo mine; return 0; }
    if grep -q '404\|Not Found\|NoSuchBucket' <<< "$out"; then
        echo free
    else
        echo taken
    fi
}

# The bucket the S3 stack made, or nothing
s3_stack_bucket() {
    admin_aws cloudformation describe-stack-resource --stack-name "$STACK_S3" --logical-resource-id Bucket \
        --query StackResourceDetail.PhysicalResourceId --output text 2> /dev/null
}

# Why an existing bucket can't take gnoto's results, or nothing: one with a
# policy of its own, which the stack's would replace
bucket_unusable() {
    local out
    [[ $(s3_stack_bucket) != "$1" ]] || return 0
    out=$(admin_aws s3api get-bucket-policy --bucket "$1" --output json 2>&1) && {
        [[ $(admin_aws cloudformation describe-stack-resource --stack-name "$STACK_S3" --logical-resource-id BucketPolicy \
            --query StackResourceDetail.PhysicalResourceId --output text 2> /dev/null) == "$1" ]] && return 0
        echo "it has a bucket policy of its own, which gnoto's would replace"
        return 0
    }
    grep -q 'NoSuchBucketPolicy' <<< "$out" || echo "its policy can't be read: $(head -c 200 <<< "$out")"
}

# Asks for the bucket: one of the account's, or a new one, and sets ANSWER
s3_ask_bucket() {
    local buckets=() default=1 i why
    mapfile -t buckets < <(admin_aws s3api list-buckets --query 'Buckets[].Name' --output text 2> /dev/null | tr '\t' '\n' | grep .)
    for (( i = 0; i < ${#buckets[@]}; i++ )); do
        [[ ${buckets[i]} != "${AWS_S3_BUCKET:-}" ]] || default=$((i + 2))
    done
    while :; do
        config_choose "Which S3 bucket holds the published results?" "$default" "Create a new bucket" "${buckets[@]}"
        if (( CHOICE > 1 )); then
            ANSWER=${buckets[CHOICE - 2]}
            why=$(bucket_unusable "$ANSWER")
            [[ -n $why ]] || return 0
            echo "  $ANSWER can't be used, since $why. Choose another, or a new one." >&2
            continue
        fi
        config_text "Name for the new bucket" "${AWS_S3_BUCKET:-gnoto-results-$DEPLOY_ACCOUNT}"
        if [[ ! $ANSWER =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]]; then
            echo "  A bucket's name is 3 to 63 lowercase letters, digits, dots and hyphens." >&2
            continue
        fi
        case $(bucket_state "$ANSWER") in
            free) return 0 ;;
            mine)
                why=$(bucket_unusable "$ANSWER")
                [[ -n $why ]] || return 0
                echo "  The account has $ANSWER already, and it can't be used, since $why." >&2
                ;;
            *) echo "  $ANSWER belongs to another AWS account. Bucket names are shared by everyone." >&2 ;;
        esac
    done
}

# The certificates issued in ACM in us-east-1 that cover a name, as
# "<arn>\t<domain>" lines
s3_certificates() {
    local name=$1
    ADMIN_REGION=us-east-1 admin_aws acm list-certificates --certificate-statuses ISSUED --output json 2> /dev/null |
        jq -r --arg name "$name" --arg wild "*.${name#*.}" '.CertificateSummaryList[]?
            | select(([.DomainName] + (.SubjectAlternativeNameSummaries // [])) | any(. == $name or . == $wild))
            | "\(.CertificateArn)\t\(.DomainName)"'
}

# Asks where the dashboards are served, and sets DOMAIN, ZONE and CERTIFICATE:
# CloudFront's own address, leaving all three empty; a name in one of the
# account's Route 53 zones, whose certificate is one already issued, chosen, or
# else made by the deploy; or a domain elsewhere, which needs an issued one
s3_ask_address() {
    local zones=() ids=() names=() options=("CloudFront's own address, https://<id>.cloudfront.net") default=1 i
    local certificates=() lines zone="" name
    mapfile -t zones < <(admin_aws route53 list-hosted-zones --output json 2> /dev/null |
        jq -r '.HostedZones[]? | select(.Config.PrivateZone | not) | "\(.Id | sub("^/hostedzone/"; ""))\t\(.Name | rtrimstr("."))"')
    for (( i = 0; i < ${#zones[@]}; i++ )); do
        ids+=("${zones[i]%%$'\t'*}")
        names+=("${zones[i]#*$'\t'}")
        options+=("A name in ${names[i]}, whose DNS is in Route 53")
        [[ ${ids[i]} != "${AWS_S3_HOSTED_ZONE_ID:-}" ]] || default=$((i + 2))
    done
    options+=("A domain whose DNS is elsewhere")
    [[ -z ${AWS_S3_DOMAIN:-} || -n ${AWS_S3_HOSTED_ZONE_ID:-} ]] || default=${#options[@]}
    DOMAIN="" ZONE="" CERTIFICATE=""
    config_choose "Where are the dashboards served?" "$default" "${options[@]}"
    (( CHOICE > 1 )) || return 0
    if (( CHOICE < ${#options[@]} )); then
        zone=${names[CHOICE - 2]}
        ZONE=${ids[CHOICE - 2]}
        name=gnoto.$zone
        [[ ${AWS_S3_DOMAIN:-} != *."$zone" ]] || name=$AWS_S3_DOMAIN
        while :; do
            config_text "The dashboards' domain, in $zone" "$name"
            [[ $ANSWER == "$zone" || $ANSWER == *."$zone" ]] && break
            echo "  Give a name in $zone, such as gnoto.$zone." >&2
        done
    else
        config_text "The dashboards' domain" "${AWS_S3_DOMAIN:-}"
        [[ $ANSWER =~ ^[a-z0-9.-]+\.[a-z]+$ ]] || fail "$ANSWER isn't a domain name."
    fi
    DOMAIN=$ANSWER
    lines=$(s3_certificates "$DOMAIN")
    mapfile -t certificates < <(grep . <<< "$lines")
    if (( ${#certificates[@]} == 0 )); then
        [[ -n $ZONE ]] ||
            fail "ACM in us-east-1 has no issued certificate for $DOMAIN, and gnoto can make one only for a domain whose DNS is in Route 53. Request one there, validate it, then run $(gnoto_command config s3) again."
        echo "There's no certificate for $DOMAIN yet, so deploying makes one, validated in $zone." >&2
        return 0
    fi
    options=()
    [[ -z $ZONE ]] || options+=("Make a new one, validated in $zone")
    default=1
    for (( i = 0; i < ${#certificates[@]}; i++ )); do
        options+=("${certificates[i]#*$'\t'}, ${certificates[i]%%$'\t'*}")
        [[ ${certificates[i]%%$'\t'*} != "${AWS_S3_CERTIFICATE_ARN:-}" ]] || default=$((${#options[@]}))
    done
    config_choose "Which certificate serves $DOMAIN?" "$default" "${options[@]}"
    if [[ -n $ZONE ]]; then
        (( CHOICE == 1 )) || CERTIFICATE=${certificates[CHOICE - 2]%%$'\t'*}
    else
        CERTIFICATE=${certificates[CHOICE - 1]%%$'\t'*}
    fi
}

# gnoto config s3, from a terminal: asks everything, shows the settings and
# what deploying them changes, and on a yes, writes them and deploys
config_s3_interactive() {
    local bucket
    config_aws_ask
    s3_ask_bucket
    bucket=$ANSWER
    s3_ask_address
    AWS_ENABLED=true AWS_S3_ENABLED=true AWS_S3_BUCKET=$bucket AWS_S3_DOMAIN=$DOMAIN
    AWS_S3_HOSTED_ZONE_ID=$ZONE AWS_S3_CERTIFICATE_ARN=$CERTIFICATE
    s3_plan
    config_show "gnoto config s3 is about to write these settings to $CONFIG_FILE, and deploy them:"
    config_proceed || exit 0
    config_aws_write
    config_subsection_on s3
    config_set aws.s3 bucket "$AWS_S3_BUCKET"
    config_set aws.s3 domain "$AWS_S3_DOMAIN"
    config_set aws.s3 hosted_zone_id "$AWS_S3_HOSTED_ZONE_ID"
    config_set aws.s3 certificate_arn "$AWS_S3_CERTIFICATE_ARN"
    s3_apply
}

# gnoto config s3 --deploy: shows the settings in config.yaml and what
# deploying them changes, and on a yes, deploys them
config_s3_deploy() {
    [[ ${AWS_ENABLED:-false} == true && ${AWS_S3_ENABLED:-false} == true ]] ||
        fail "s3 is off. $(gnoto_command config s3) sets it up, or $(gnoto_command config s3 --on) adds what to fill in."
    s3_plan
    config_show "gnoto config s3 --deploy is about to deploy these settings, from $CONFIG_FILE:"
    config_proceed || exit 0
    s3_apply
}

# Works out an S3 deploy from the settings in effect, failing on any it can't
# deploy: sets SETTINGS and PLAN, for config_show, and what s3_apply needs,
# S3_EXISTS, S3_BUCKET_REGION and S3_CERTIFICATE
s3_plan() {
    local owned bucket verb what zone
    S3_EXISTS=false S3_BUCKET_REGION="" S3_CERTIFICATE=${AWS_S3_CERTIFICATE_ARN:-} PLAN=()
    [[ -n ${AWS_REGION:-} ]] || fail "aws.region isn't set. $(gnoto_command config s3) asks for it."
    [[ -n ${AWS_S3_BUCKET:-} ]] || fail "aws.s3.bucket isn't set. $(gnoto_command config s3) asks for it."
    [[ ${AWS_S3_RUN_PREFIX:-gnoto} =~ ^[A-Za-z0-9._-]+$ ]] || fail "aws.s3.run_prefix should be one folder name, such as gnoto."
    if [[ -n ${AWS_S3_DOMAIN:-} && -z $S3_CERTIFICATE && -z ${AWS_S3_HOSTED_ZONE_ID:-} ]]; then
        fail "aws.s3.domain is $AWS_S3_DOMAIN, with neither a certificate_arn nor a hosted_zone_id for gnoto to make one in."
    fi
    deploy_identity
    deploy_settings

    owned=$(s3_stack_bucket)
    if [[ $owned == "$AWS_S3_BUCKET" ]]; then
        bucket="$AWS_S3_BUCKET, the stack's own"
    else
        case $(bucket_state "$AWS_S3_BUCKET") in
            free) bucket="$AWS_S3_BUCKET, new" ;;
            mine)
                what=$(bucket_unusable "$AWS_S3_BUCKET")
                [[ -z $what ]] || fail "The bucket $AWS_S3_BUCKET can't take gnoto's results, since $what."
                S3_EXISTS=true
                S3_BUCKET_REGION=$(admin_aws s3api get-bucket-location --bucket "$AWS_S3_BUCKET" \
                    --query LocationConstraint --output text 2> /dev/null) || S3_BUCKET_REGION=""
                case $S3_BUCKET_REGION in
                    "" | None | null) S3_BUCKET_REGION=us-east-1 ;;
                    EU) S3_BUCKET_REGION=eu-west-1 ;;
                esac
                bucket="$AWS_S3_BUCKET, the account's own, in $S3_BUCKET_REGION"
                ;;
            *) fail "The bucket $AWS_S3_BUCKET belongs to another AWS account. $(gnoto_command config s3) chooses another." ;;
        esac
    fi
    SETTINGS+=("Bucket"$'\t'"$bucket"
        "Run prefix"$'\t'"${AWS_S3_RUN_PREFIX:-gnoto}/, served at the address's root")
    if [[ -z ${AWS_S3_DOMAIN:-} ]]; then
        SETTINGS+=("Address"$'\t'"CloudFront's own, https://<id>.cloudfront.net, which the deploy reports")
    else
        SETTINGS+=("Address"$'\t'"https://$AWS_S3_DOMAIN")
        if [[ -n ${AWS_S3_HOSTED_ZONE_ID:-} ]]; then
            zone=$(admin_aws route53 get-hosted-zone --id "$AWS_S3_HOSTED_ZONE_ID" --query HostedZone.Name \
                --output text 2> /dev/null) || zone=""
            SETTINGS+=("DNS"$'\t'"A and AAAA records in Route 53, hosted zone $AWS_S3_HOSTED_ZONE_ID${zone:+, ${zone%.}}")
        else
            SETTINGS+=("DNS"$'\t'"by hand: point $AWS_S3_DOMAIN at the distribution, as the deploy says")
        fi
        if [[ -n $S3_CERTIFICATE ]]; then
            SETTINGS+=("Certificate"$'\t'"$S3_CERTIFICATE")
        else
            SETTINGS+=("Certificate"$'\t'"made by gnoto, in the stack $STACK_CERTIFICATE in us-east-1, validated in the hosted zone")
            verb=Create
            ADMIN_REGION=us-east-1 stack_exists "$STACK_CERTIFICATE" && verb=Update
            PLAN+=("$verb the stack $STACK_CERTIFICATE, in us-east-1: a certificate for $AWS_S3_DOMAIN")
        fi
    fi
    stack_exists "$STACK_IAM" || PLAN+=("Create the stack $STACK_IAM: gnoto's IAM user, and its access key, written to config.yaml")
    verb=Create
    stack_exists "$STACK_S3" && verb=Update
    what="the bucket's policy, a CloudFront distribution and its function"
    [[ $bucket != *", new" ]] || what="the bucket, its policy, a CloudFront distribution and its function"
    [[ -z ${AWS_S3_DOMAIN:-} || -z ${AWS_S3_HOSTED_ZONE_ID:-} ]] || what+=", the DNS records"
    PLAN+=("$verb the stack $STACK_S3, in $AWS_REGION: $what, and the IAM user's access under ${AWS_S3_RUN_PREFIX:-gnoto}/")
}

# Deploys what s3_plan worked out: the certificate, if the domain needs one
# made, gnoto's IAM user and the S3 stack, with the stacks' outputs to
# generated.yaml, then lint's checks
s3_apply() {
    local certificate=$S3_CERTIFICATE
    if [[ -n ${AWS_S3_DOMAIN:-} && -z $certificate ]]; then
        ADMIN_REGION=us-east-1 stack_deploy "$STACK_CERTIFICATE" certificate \
            "DomainName=$AWS_S3_DOMAIN" "HostedZoneId=$AWS_S3_HOSTED_ZONE_ID"
        certificate=$(ADMIN_REGION=us-east-1 stack_output "$STACK_CERTIFICATE" CertificateArn)
        [[ -n $certificate ]] || fail "The stack $STACK_CERTIFICATE has no CertificateArn output."
    fi
    iam_deploy
    stack_deploy "$STACK_S3" s3 "BucketName=$AWS_S3_BUCKET" "BucketExists=$S3_EXISTS" "BucketRegion=$S3_BUCKET_REGION" \
        "RunPrefix=${AWS_S3_RUN_PREFIX:-gnoto}" "IamStack=$STACK_IAM" "DomainName=${AWS_S3_DOMAIN:-}" \
        "CertificateArn=$certificate" "HostedZoneId=${AWS_S3_HOSTED_ZONE_ID:-}"
    generated_set aws.s3.results_base_url "$(stack_output "$STACK_S3" ResultsBaseUrl)"
    generated_set aws.s3.distribution_id "$(stack_output "$STACK_S3" DistributionId)"
    if [[ -n ${AWS_S3_DOMAIN:-} && -z ${AWS_S3_HOSTED_ZONE_ID:-} ]]; then
        echo "Point $AWS_S3_DOMAIN's DNS at $(stack_output "$STACK_S3" DistributionDomain)." >&2
    fi
    source "$CODE_DIR/lib/env.sh"
    echo "The results are served from $AWS_S3_RESULTS_BASE_URL." >&2
    LINT_FAILS=0
    lint_s3
    (( LINT_FAILS == 0 )) || fail "S3 isn't ready, as above."
    echo "S3 is ready."
}

# The parameters that make Get the data's Lambda, as Key=Value lines: empty
# ones, which leave it out, unless Globus is on with its app and S3 is set up
access_parameters() {
    local client="" bucket="" origin="" redirect="" base=${AWS_S3_RESULTS_BASE_URL%/}
    if [[ ${GLOBUS_ENABLED:-false} == true && -n ${GLOBUS_APP_CLIENT_ID:-} ]] && s3_on; then
        client=$GLOBUS_APP_CLIENT_ID
        bucket=$AWS_S3_BUCKET
        origin=$(sed -E 's#^(https?://[^/]+).*#\1#' <<< "$base")
        redirect=$(s3_access_url)
    fi
    printf '%s\n' "GlobusClientId=$client" "ResultsBucket=$bucket" "RunPrefix=${AWS_S3_RUN_PREFIX:-gnoto}" \
        "ResultsOrigin=$origin" "RedirectUri=$redirect"
}

# gnoto config sqs, from a terminal: the profile and region, then shows the
# settings and what deploying them changes, and on a yes, writes and deploys
config_sqs_interactive() {
    config_aws_ask
    AWS_ENABLED=true AWS_SQS_ENABLED=true
    sqs_plan
    config_show "gnoto config sqs is about to write these settings to $CONFIG_FILE, and deploy them:"
    config_proceed || exit 0
    config_aws_write
    config_subsection_on sqs
    sqs_apply
}

# gnoto config sqs --deploy: shows the settings in config.yaml and what
# deploying them changes, and on a yes, deploys them
config_sqs_deploy() {
    [[ ${AWS_ENABLED:-false} == true && ${AWS_SQS_ENABLED:-false} == true ]] ||
        fail "sqs is off. $(gnoto_command config sqs) sets it up, or $(gnoto_command config sqs --on) adds what to fill in."
    sqs_plan
    config_show "gnoto config sqs --deploy is about to deploy these settings, from $CONFIG_FILE:"
    config_proceed || exit 0
    sqs_apply
}

# Works out an SQS deploy: sets SETTINGS and PLAN, for config_show, and
# SQS_ACCESS, Get the data's parameters
sqs_plan() {
    local what="the queue, the webhook's Lambda and its HTTP API" verb=Create
    PLAN=()
    [[ -n ${AWS_REGION:-} ]] || fail "aws.region isn't set. $(gnoto_command config sqs) asks for it."
    deploy_identity
    deploy_settings
    mapfile -t SQS_ACCESS < <(access_parameters)
    if [[ ${SQS_ACCESS[0]} == GlobusClientId= ]]; then
        SETTINGS+=("Get the data"$'\t'"off, without Globus's app and S3")
    else
        SETTINGS+=("Get the data"$'\t'"on, for Globus's app ${SQS_ACCESS[0]#*=} and the dashboards at $AWS_S3_RESULTS_BASE_URL")
        what+=", Get the data's Lambda and its HTTP API"
    fi
    stack_exists "$STACK_IAM" || PLAN+=("Create the stack $STACK_IAM: gnoto's IAM user, and its access key, written to config.yaml")
    stack_exists "$STACK_SQS" && verb=Update
    PLAN+=("$verb the stack $STACK_SQS, in $AWS_REGION: $what, and the IAM user's access to the queue")
}

# Deploys what sqs_plan worked out: gnoto's IAM user and the SQS stack, with its
# outputs to generated.yaml, then lint's checks
sqs_apply() {
    iam_deploy
    wrike_webhook_secret
    stack_deploy "$STACK_SQS" sqs "WebhookSecret=$WRIKE_WEBHOOK_SECRET" "IamStack=$STACK_IAM" "${SQS_ACCESS[@]}"
    generated_set aws.sqs.queue_url "$(stack_output "$STACK_SQS" QueueUrl)"
    generated_set aws.sqs.webhook_url "$(stack_output "$STACK_SQS" WebhookUrl)"
    generated_set aws.sqs.access_url "$(stack_output "$STACK_SQS" AccessUrl)"
    echo "The queue's addresses are in $DATA_DIR/generated.yaml. $(gnoto_command config wrike) registers the webhook." >&2
    source "$CODE_DIR/lib/env.sh"
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
    local identity name=gnoto-check-$$ key body dir out code url=${AWS_S3_RESULTS_BASE_URL%/}
    key=${AWS_S3_RUN_PREFIX:-gnoto}/$name
    [[ ${AWS_ENABLED:-false} == true && ${AWS_S3_ENABLED:-false} == true ]] || return 0
    if [[ -z ${AWS_S3_BUCKET:-} ]]; then
        lint_fail "s3: is on, and aws.s3.bucket isn't set. $(gnoto_command config s3) sets it up"
        return 0
    fi
    [[ -n ${AWS_S3_RESULTS_BASE_URL:-} ]] ||
        { lint_fail "s3: aws.s3.results_base_url isn't set. $(gnoto_command config s3 --deploy) makes it, or set it to the address that serves the run prefix"; return 0; }
    [[ ${AWS_S3_RUN_PREFIX:-gnoto} =~ ^[A-Za-z0-9._-]+$ ]] || lint_fail "s3: aws.s3.run_prefix should be one folder name, such as gnoto"
    identity=$(aws_identity) || identity=""
    [[ -n $identity ]] || { lint_fail "s3: gnoto's AWS keys don't work. Check aws.access_key_id and secret_access_key"; return 0; }
    body="gnoto lint, $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if ! out=$(printf '%s\n' "$body" | s3_put - "$AWS_S3_BUCKET" "$key.txt" "text/plain; charset=utf-8" no-cache 2>&1); then
        lint_fail "s3: $identity can't write under s3://$AWS_S3_BUCKET/${AWS_S3_RUN_PREFIX:-gnoto}/: $(head -c 200 <<< "$out")"
        return 0
    fi
    dir=$(mktemp -d "${TMPDIR:-/tmp}/gnoto-s3check.XXXXXX")
    printf '<html><head><title>gnoto-check</title></head></html>\n' > "$dir/directory_listing.html"
    s3_put "$dir/directory_listing.html" "$AWS_S3_BUCKET" "$key/directory_listing.html" "text/html; charset=utf-8" no-cache \
        > /dev/null 2>&1 || :
    rm -rf "$dir"
    if [[ $(s3_count "$AWS_S3_BUCKET" "${AWS_S3_RUN_PREFIX:-gnoto}" 2> /dev/null || echo 0) -ge 1 ]]; then
        lint_ok "s3: $identity can write and list under s3://$AWS_S3_BUCKET/${AWS_S3_RUN_PREFIX:-gnoto}/"
    else
        lint_fail "s3: $identity can write under s3://$AWS_S3_BUCKET/${AWS_S3_RUN_PREFIX:-gnoto}/, and can't list it"
    fi
    out=$(curl -sS --max-time 30 "$url/$name.txt" 2>&1) || out=""
    if [[ $out == "$body" ]]; then
        lint_ok "s3: $url/ serves what's under s3://$AWS_S3_BUCKET/${AWS_S3_RUN_PREFIX:-gnoto}/"
    else
        lint_fail "s3: $url/$name.txt didn't serve the test file uploaded to s3://$AWS_S3_BUCKET/$key.txt. aws.s3.results_base_url should serve the run prefix: $(head -c 120 <<< "$out")"
    fi
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "$url/$name" 2> /dev/null) || code=""
    out=$(curl -sS -L --max-time 30 "$url/$name/" 2> /dev/null) || out=""
    if [[ $code == 301 && $out == *gnoto-check* ]]; then
        lint_ok "s3: a folder's address serves its page, through the CloudFront function"
    else
        lint_warn "s3: a folder's address, $url/$name/, doesn't serve its page, so folder links in the pipelines' own reports fail. Attach service/aws/cloudfront/directory-index.js to the distribution"
    fi
    gnoto_aws s3 rm --only-show-errors --recursive "s3://$AWS_S3_BUCKET/$key/" > /dev/null 2>&1 || :
    gnoto_aws s3 rm --only-show-errors "s3://$AWS_S3_BUCKET/$key.txt" > /dev/null 2>&1 ||
        lint_fail "s3: $identity can't delete under s3://$AWS_S3_BUCKET/${AWS_S3_RUN_PREFIX:-gnoto}/, so results would never expire"
}

# lint's SQS checks: the keys work, the queue answers, and how many messages
# are waiting
lint_sqs() {
    local identity waiting
    [[ ${AWS_ENABLED:-false} == true && ${AWS_SQS_ENABLED:-false} == true ]] || return 0
    if [[ -z ${AWS_SQS_QUEUE_URL:-} ]]; then
        lint_fail "sqs: is on, and aws.sqs.queue_url isn't set. $(gnoto_command config sqs --deploy) makes it"
        return 0
    fi
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
    [[ -n ${AWS_SQS_WEBHOOK_URL:-} ]] || lint_warn "sqs: aws.sqs.webhook_url isn't set, so gnoto config wrike can't register the webhook"
}
