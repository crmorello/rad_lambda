# Shared config for the deploy scripts. Source this; never run it.
# Everything lives in us-east-1 (NOAA's bucket + topic are there; S3 reads free).

export AWS_REGION="us-east-1"

# --- names (as deployed 2026-07-31: ops named bucket, function, and ECR repo
# all "tempest-radar-output") ------------------------------------------------
export RAD_BUCKET="tempest-radar-output"        # output bucket
export RAD_PREFIX="rads"                        # key prefix for .rad + manifest
export QUEUE_NAME="mrms-seamlesshsr"
export DLQ_NAME="mrms-seamlesshsr-dlq"
export FUNCTION_NAME="tempest-radar-output"
export ECR_REPO="tempest-radar-output"
export ALARM_TOPIC_NAME="radar-backend-alarms"  # SNS topic for alarm emails

# --- upstream (verified 2026-07-14/15) ---------------------------------------
export NOAA_TOPIC_ARN="arn:aws:sns:us-east-1:123901341784:NewMRMSObject"
export NOAA_BUCKET="noaa-mrms-pds"
export REGION_PREFIXES=(CONUS ALASKA HAWAII CARIB GUAM)

# --- lambda sizing (spec §13.2 ballpark) --------------------------------------
export LAMBDA_MEMORY_MB=2048
export LAMBDA_TIMEOUT_S=120
export LAMBDA_RESERVED_CONCURRENCY=5            # cost guardrail vs publish storms

# --- derived ------------------------------------------------------------------
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export QUEUE_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${QUEUE_NAME}"
export DLQ_ARN="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${DLQ_NAME}"
export ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

# Filter policy: prefix-match the SeamlessHSR path per region inside the S3
# event body (FilterPolicyScope=MessageBody — probe-verified shape).
filter_policy() {
  local entries=""
  for r in "${REGION_PREFIXES[@]}"; do
    entries+="{\"prefix\":\"${r}/SeamlessHSR_00.00/\"},"
  done
  echo "{\"Records\":{\"s3\":{\"object\":{\"key\":[${entries%,}]}}}}"
}
