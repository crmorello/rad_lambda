#!/bin/bash
# Ingest: DLQ + queue (redrive after 3 attempts) + NOAA SNS subscription with
# the region filter. Idempotent — create-or-update throughout.
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

echo "== DLQ"
DLQ_URL=$(aws sqs create-queue --queue-name "$DLQ_NAME" \
  --attributes '{"MessageRetentionPeriod":"1209600"}' \
  --query QueueUrl --output text)

echo "== queue (redrive -> DLQ after 3)"
QUEUE_URL=$(aws sqs create-queue --queue-name "$QUEUE_NAME" \
  --attributes "{
    \"VisibilityTimeout\": \"$((LAMBDA_TIMEOUT_S * 6))\",
    \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"
  }" --query QueueUrl --output text)

echo "== queue policy (allow NOAA topic to send)"
POLICY=$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"sns.amazonaws.com"},
"Action":"sqs:SendMessage","Resource":"${QUEUE_ARN}",
"Condition":{"ArnEquals":{"aws:SourceArn":"${NOAA_TOPIC_ARN}"}}}]}
EOF
)
aws sqs set-queue-attributes --queue-url "$QUEUE_URL" \
  --attributes "{\"Policy\": $(echo "$POLICY" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"

echo "== SNS subscription (scope+filter set atomically at subscribe)"
SUB_ARN=$(aws sns subscribe --region "$AWS_REGION" \
  --topic-arn "$NOAA_TOPIC_ARN" \
  --protocol sqs --notification-endpoint "$QUEUE_ARN" \
  --attributes "{\"FilterPolicyScope\":\"MessageBody\",\"FilterPolicy\":$(filter_policy | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
  --return-subscription-arn --query SubscriptionArn --output text)

echo "queue: $QUEUE_URL"
echo "sub:   $SUB_ARN"
echo "NOTE: if a manual probe subscription for this queue already exists, unsubscribe it."
