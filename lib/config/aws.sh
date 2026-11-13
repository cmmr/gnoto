#
# aws.sh - The aws section of config.yaml: the account gnoto's stacks are in,
# with its subsections s3, which publishes results through S3 and CloudFront,
# and sqs, which carries Wrike's webhook and Globus access requests. Each
# subsection has its own enabled, and works only while aws is on too.
#
# Sourced by:  lib/env.sh
#
# gnoto config s3 and sqs ask everything else, offering what the account
# already has, and deploy the stacks, which fill in the settings with no
# question: gnoto's own access keys, and the stacks' addresses, which a site
# that sets up its own bucket, CloudFront or queue gives as --<key>=<value>.

config_section aws "The AWS account that S3 and SQS use, and gnoto's access keys there"
config_setting aws enabled bool false ""
config_setting aws deploy_profile text "" "AWS CLI profile that deploys gnoto's stacks, or none for the CLI's default credentials"
config_setting aws region text "" "AWS region for gnoto's stacks, such as us-east-1"
config_setting aws access_key_id secret "" ""
config_setting aws secret_access_key secret "" ""

config_section aws.s3 "Publish results through S3 and CloudFront"
config_setting aws.s3 enabled bool false ""
config_setting aws.s3 bucket text "" "S3 bucket for published results"
config_setting aws.s3 run_prefix text "" "Folder in the bucket that runs go under, or none for gnoto"
config_setting aws.s3 domain text "" "Domain the dashboards are served at, or none for CloudFront's own address"
config_setting aws.s3 hosted_zone_id text "" "The domain's Route 53 hosted zone, for gnoto to make its DNS records and certificate, or none"
config_setting aws.s3 certificate_arn text "" "The domain's ACM certificate in us-east-1, or none for gnoto to make one in the hosted zone"
config_setting aws.s3 results_base_url text "" ""
config_setting aws.s3 distribution_id text "" ""

config_section aws.sqs "Take Wrike's webhook and Globus access requests through SQS"
config_setting aws.sqs enabled bool false ""
config_setting aws.sqs queue_url text "" ""
config_setting aws.sqs webhook_url text "" ""
config_setting aws.sqs access_url text "" ""
