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
| `access-lambda.json` | Get the data's Lambda's role, beside `AWSLambdaBasicExecutionRole` | `<queue_arn>`, `<bucket>`, `<run_prefix>` |

The webhook Lambda is `../lambda/webhook.py`, handler `lambda_handler`, with
`AWS_SQS_QUEUE_URL` and `WRIKE_WEBHOOK_SECRET` set. Get the data's is
`../lambda/access.py`, handler `lambda_handler`, with `AWS_SQS_QUEUE_URL`,
`RESULTS_BUCKET`, `RUN_PREFIX`, `GLOBUS_CLIENT_ID` (`globus.app_client_id`) and
`REDIRECT_URI` (`<results_base_url>/access.html`) set, behind an HTTP API whose CORS
allows only the results' origin, and its address goes in `aws.sqs.access_url`. The CloudFront
function is `../cloudfront/directory-index.js`, on the viewer request of the behavior that
serves results. `aws.s3.results_base_url` is the address that serves the run prefix, as the
stack's distribution does at its root, with the origin path `/<run_prefix>`.
