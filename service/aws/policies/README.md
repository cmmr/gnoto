# IAM policies, for a site that sets up its own bucket and queue

`gnoto config s3 --deploy` and `gnoto config sqs --deploy` make these as part of their
stacks, in `../stacks/`. A site that runs its own bucket, CloudFront distribution and
queue attaches them by hand instead, with each `<placeholder>` filled in:

| File | Attach to | Placeholders |
| --- | --- | --- |
| `s3-user.json` | gnoto's IAM user, whose keys go in `config.yaml` | `<bucket>`, `<run_prefix>` |
| `s3-bucket.json` | the bucket, as its policy, for CloudFront's origin access control | `<bucket>`, `<account>`, `<distribution>` |
| `sqs-user.json` | gnoto's IAM user | `<queue_arn>` |
| `sqs-lambda.json` | the webhook Lambda's role, beside `AWSLambdaBasicExecutionRole` | `<queue_arn>` |

The Lambda is `../lambda/webhook.py`, handler `lambda_handler`, with `AWS_SQS_QUEUE_URL`
and `WRIKE_WEBHOOK_SECRET` set. The CloudFront function is
`../cloudfront/directory-index.js`, with `RUN_PREFIX` set to `aws.run_prefix`.
