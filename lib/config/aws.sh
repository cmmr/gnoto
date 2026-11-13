#
# aws.sh - The aws section of config.yaml: S3 and CloudFront for published
# results, and SQS for Wrike's webhook and the dashboards' requests for Globus
# access. Each is used only when its own settings are filled in.
#
# Sourced by:  lib/env.sh

config_section aws "Publish results through S3 and CloudFront, and take Wrike's webhook and Globus access requests through SQS"
config_setting aws enabled bool false ""
config_setting aws access_key_id secret "" "Access key ID of gnoto's IAM user, shared by S3 and SQS"
config_setting aws secret_access_key secret "" "Its secret access key"
config_setting aws region text "" "AWS region, such as us-east-1"
config_setting aws s3_bucket text "" "S3 bucket for published results, or none"
config_setting aws results_base_url text "" "Address that serves the bucket, such as https://d1234abcd.cloudfront.net, or none"
config_setting aws run_prefix text "" "Prefix for runs in the bucket, or none for gnoto"
config_setting aws sqs_queue_url text "" "SQS queue URL for Wrike's webhook, or none"
config_setting aws webhook_url text "" "Address Wrike posts to, in front of the queue, or none"
config_setting aws access_url text "" "Address a dashboard posts a Globus sign-in to, in front of the queue, or none"
