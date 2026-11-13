#
# aws.sh - The AWS CLI as gnoto's IAM user, and the S3 and SQS calls gnoto
# makes with it.
#
# Sourced by:  lib/env.sh
# Defines:     gnoto_aws, s3_on, sqs_on, listener_on, s3_run_key, s3_run_url, s3_put,
#              s3_upload_results, s3_delete_prefix, s3_count
# Requires:    aws and jq, from the image; warn from lib/utilities.sh
# Env:         AWS_ENABLED, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
#              AWS_REGION, AWS_S3_BUCKET, AWS_RESULTS_BASE_URL, AWS_RUN_PREFIX
#              and AWS_SQS_QUEUE_URL, from config.yaml and generated.yaml
#
# The keys are set only in the environment of the one aws call that needs
# them, since settings that are secrets are never exported. Without keys in
# config.yaml, the AWS CLI finds its own, as on an instance with a role.
#
# A run's results go under <run_prefix>/<folder>/ in the bucket, and are served
# at <results_base_url>/<run_prefix>/<folder>/, where the folder is the run's
# address, <uid>-<token>, from run_address in service/publish.sh.

# Text files a reader opens in the browser rather than downloads: S3 types an
# object from its name, and knows only some of these
S3_TEXT_EXTENSIONS=(txt tsv csv log yaml yml gff fasta fa fna nwk newick sh nf config md)
# The pages that frame the rest, uploaded last, index.html last of all
S3_PAGES=(overview.html deliverables.html methods.html index.html)

gnoto_aws() {
    local keys=()
    if [[ -n ${AWS_ACCESS_KEY_ID:-} ]]; then
        keys=(AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-}")
    fi
    env "${keys[@]}" AWS_DEFAULT_REGION="${AWS_REGION:-}" AWS_PAGER="" AWS_EC2_METADATA_DISABLED=true \
        aws "$@"
}

# S3 publishes results when the aws section is on with a bucket and an address
s3_on() {
    [[ ${AWS_ENABLED:-false} == true && -n ${AWS_S3_BUCKET:-} && -n ${AWS_RESULTS_BASE_URL:-} ]]
}

# SQS carries Wrike's webhook and the dashboards' requests for Globus access
# when the aws section is on with a queue
sqs_on() {
    [[ ${AWS_ENABLED:-false} == true && -n ${AWS_SQS_QUEUE_URL:-} ]]
}

# The listener runs when the queue carries something gnoto acts on: Wrike's
# events, or the dashboards' requests for Globus access
listener_on() {
    sqs_on && { wrike_on || globus_ready; }
}

# s3_run_key <folder> and s3_run_url <folder>: a run's key prefix and address
s3_run_key() {
    printf '%s/%s' "${AWS_RUN_PREFIX:-gnoto}" "$1"
}

s3_run_url() {
    printf '%s/%s/' "${AWS_RESULTS_BASE_URL%/}" "$(s3_run_key "$1")"
}

# s3_put <file, or - for stdin> <bucket> <key> <content type> [cache control]
s3_put() {
    local args=(--content-type "$4")
    [[ -z ${5:-} ]] || args+=(--cache-control "$5")
    gnoto_aws s3 cp --only-show-errors "$1" "s3://$2/$3" "${args[@]}"
}

# s3_upload_results <directory> <bucket> <key prefix>: copies a results folder
# under the prefix, then its pages on top, so nothing the pages frame is still
# arriving when they're read, and index.html replaces a progress page last.
# Text files go up typed as text, so they open in the browser. Prints aws's
# complaint on failure.
s3_upload_results() {
    local src=${1%/} bucket=$2 prefix=${3%/} extension page output other=() text=(--exclude "*")
    for extension in "${S3_TEXT_EXTENSIONS[@]}"; do
        other+=(--exclude "*.$extension")
        text+=(--include "*.$extension")
    done
    for page in "${S3_PAGES[@]}" progress.json; do
        other+=(--exclude "$page")
        text+=(--exclude "$page")
    done
    output=$(gnoto_aws s3 cp --only-show-errors --recursive "$src/" "s3://$bucket/$prefix/" "${other[@]}" 2>&1) ||
        { printf '%s' "$output"; return 1; }
    output=$(gnoto_aws s3 cp --only-show-errors --recursive "$src/" "s3://$bucket/$prefix/" "${text[@]}" \
        --content-type "text/plain; charset=utf-8" 2>&1) || { printf '%s' "$output"; return 1; }
    for page in "${S3_PAGES[@]}"; do
        [[ -f $src/$page ]] || continue
        output=$(s3_put "$src/$page" "$bucket" "$prefix/$page" "text/html; charset=utf-8" no-cache 2>&1) ||
            { printf '%s' "$output"; return 1; }
    done
    if [[ -f $src/progress.json ]]; then
        output=$(s3_put "$src/progress.json" "$bucket" "$prefix/progress.json" application/json no-cache 2>&1) ||
            { printf '%s' "$output"; return 1; }
    fi
}

# The keys under a prefix, one a line
s3_keys() {
    local json
    json=$(gnoto_aws s3api list-objects-v2 --bucket "$1" --prefix "${2%/}/" --output json) || return 1
    jq -r '.Contents[]?.Key' <<< "$json"
}

# s3_count <bucket> <prefix>: how many objects are under it
s3_count() {
    local keys
    keys=$(s3_keys "$1" "$2") || return 1
    grep -c . <<< "$keys" || :
}

# s3_delete_prefix <bucket> <prefix> [<folder to keep>]: deletes every object
# under it, but those in the folder named, a thousand at a time. Returns 1,
# with a warning, if any is left.
s3_delete_prefix() {
    local bucket=$1 prefix=${2%/} keep=${3:-} keys batch output errors
    keys=$(s3_keys "$bucket" "$prefix") || { warn "Couldn't list s3://$bucket/$prefix/."; return 1; }
    [[ -z $keep ]] || keys=$(grep -v -F "$prefix/$keep/" <<< "$keys" || :)
    while [[ -n $keys ]]; do
        batch=$(head -n 1000 <<< "$keys")
        keys=$(tail -n +1001 <<< "$keys")
        output=$(gnoto_aws s3api delete-objects --bucket "$bucket" --output json --delete "$(jq -R -s \
            'split("\n") | map(select(length > 0) | {Key: .}) | {Objects: ., Quiet: true}' <<< "$batch")" 2>&1) ||
            { warn "S3 refused to delete under s3://$bucket/$prefix/: $output"; return 1; }
        errors=$(jq -r '[.Errors[]?] | length' <<< "$output" 2> /dev/null) || errors=0
        if [[ ${errors:-0} != 0 ]]; then
            warn "S3 kept $errors objects under s3://$bucket/$prefix/: $(jq -c '.Errors[0]' <<< "$output")"
            return 1
        fi
    done
}
