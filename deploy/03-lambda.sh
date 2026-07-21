#!/bin/bash
# The processing Lambda: ECR image (built from ../Dockerfile), IAM role,
# function create-or-update, SQS event-source mapping (batch size 1).
# PREREQ: lib_gdal pushed to github (Dockerfile resolves it from there).
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

echo "== ECR repo + image"
aws ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1 || \
  aws ecr create-repository --repository-name "$ECR_REPO" >/dev/null
aws ecr get-login-password | docker login --username AWS --password-stdin "$ECR_URI" >/dev/null
docker build --platform linux/arm64 -t "$ECR_URI:latest" ..
docker push "$ECR_URI:latest"

echo "== IAM role"
ROLE_NAME="${FUNCTION_NAME}-role"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || \
  aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE_NAME" --policy-name inline --policy-document "{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {\"Effect\":\"Allow\",\"Action\":[\"sqs:ReceiveMessage\",\"sqs:DeleteMessage\",\"sqs:GetQueueAttributes\"],\"Resource\":\"${QUEUE_ARN}\"},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${NOAA_BUCKET}\",\"arn:aws:s3:::${NOAA_BUCKET}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:PutObject\",\"s3:ListBucket\"],\"Resource\":[\"arn:aws:s3:::${RAD_BUCKET}\",\"arn:aws:s3:::${RAD_BUCKET}/*\"]},
    {\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"}
  ]}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
sleep 8   # new-role propagation before create-function

echo "== function"
ENV_VARS="Variables={RAD_OUTPUT=/vsis3/${RAD_BUCKET}/${RAD_PREFIX},RAD_URL_PREFIX=/${RAD_PREFIX}}"
if aws lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  aws lambda update-function-code --function-name "$FUNCTION_NAME" \
    --image-uri "$ECR_URI:latest" >/dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME"
  aws lambda update-function-configuration --function-name "$FUNCTION_NAME" \
    --memory-size "$LAMBDA_MEMORY_MB" --timeout "$LAMBDA_TIMEOUT_S" \
    --environment "$ENV_VARS" >/dev/null
else
  aws lambda create-function --function-name "$FUNCTION_NAME" \
    --package-type Image --code "ImageUri=${ECR_URI}:latest" \
    --role "$ROLE_ARN" --architectures arm64 \
    --memory-size "$LAMBDA_MEMORY_MB" --timeout "$LAMBDA_TIMEOUT_S" \
    --environment "$ENV_VARS" >/dev/null
fi
aws lambda wait function-active-v2 --function-name "$FUNCTION_NAME"
aws lambda put-function-concurrency --function-name "$FUNCTION_NAME" \
  --reserved-concurrent-executions "$LAMBDA_RESERVED_CONCURRENCY" >/dev/null

echo "== event-source mapping (batch size 1: one grib per invocation)"
EXISTING=$(aws lambda list-event-source-mappings --function-name "$FUNCTION_NAME" \
  --event-source-arn "$QUEUE_ARN" --query 'EventSourceMappings[0].UUID' --output text)
if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
  aws lambda create-event-source-mapping --function-name "$FUNCTION_NAME" \
    --event-source-arn "$QUEUE_ARN" --batch-size 1 >/dev/null
fi
echo "lambda: $FUNCTION_NAME ($ECR_URI:latest)"
