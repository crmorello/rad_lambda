# Deploy: plain aws-cli scripts (deliberately no IaC framework)

One file per concern, idempotent, run in order on first deploy:

    ./01-ingest.sh     # SQS + DLQ + NOAA SNS subscription (region filter)
    ./02-bucket.sh     # output bucket + 48h lifecycle
    ./03-lambda.sh     # ECR build/push + IAM + function + event mapping
    ./04-cdn.sh        # CloudFront (OAC, CORS, manifest TTL) — prints the URL
    ./05-alarms.sh     # freshness / DLQ / error alarms (subscribe email once)
    ./bootstrap.sh [h] # backfill last N hours (default 3) through the Lambda

Names/sizing in 00-config.sh (change RAD_BUCKET first — S3 names are global).
Day-to-day redeploy of code = just 03-lambda.sh.

PREREQS: docker running; lib_gdal pushed to github (the image build pulls it);
aws cli authed to the target account (us-east-1).
