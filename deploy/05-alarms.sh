#!/bin/bash
# Observability: the freshness alarm is the one that matters — "no frame
# processed in 15 minutes" catches NOAA silence, subscription breakage, and
# processing failure alike. Plus DLQ depth and Lambda errors. Alarms notify
# an SNS topic; subscribe your email once (printed at the end).
set -euo pipefail
cd "$(dirname "$0")" && source ./00-config.sh

echo "== alarm topic"
TOPIC_ARN=$(aws sns create-topic --name "$ALARM_TOPIC_NAME" --query TopicArn --output text)

echo "== freshness metric (log filter: invocations that produced frames)"
LOG_GROUP="/aws/lambda/${FUNCTION_NAME}"
aws logs create-log-group --log-group-name "$LOG_GROUP" 2>/dev/null || true
# The runtime POSTs {"processed":[...],"skipped":N}; count non-empty processed.
aws logs put-metric-filter --log-group-name "$LOG_GROUP" \
  --filter-name frames-processed \
  --filter-pattern '".rad"' \
  --metric-transformations \
  "metricName=FramesProcessed,metricNamespace=RadarBackend,metricValue=1,defaultValue=0"

echo "== alarms"
aws cloudwatch put-metric-alarm --alarm-name radar-freshness \
  --alarm-description "No RAD frames produced in 15 minutes" \
  --namespace RadarBackend --metric-name FramesProcessed \
  --statistic Sum --period 900 --evaluation-periods 1 \
  --threshold 1 --comparison-operator LessThanThreshold \
  --treat-missing-data breaching \
  --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN"

aws cloudwatch put-metric-alarm --alarm-name radar-dlq-depth \
  --alarm-description "Failed MRMS notifications in the DLQ" \
  --namespace AWS/SQS --metric-name ApproximateNumberOfMessagesVisible \
  --dimensions "Name=QueueName,Value=${DLQ_NAME}" \
  --statistic Maximum --period 300 --evaluation-periods 1 \
  --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$TOPIC_ARN"

aws cloudwatch put-metric-alarm --alarm-name radar-lambda-errors \
  --alarm-description "rad-lambda error rate" \
  --namespace AWS/Lambda --metric-name Errors \
  --dimensions "Name=FunctionName,Value=${FUNCTION_NAME}" \
  --statistic Sum --period 300 --evaluation-periods 2 \
  --threshold 3 --comparison-operator GreaterThanOrEqualToThreshold \
  --alarm-actions "$TOPIC_ARN"

echo "alarms wired to: $TOPIC_ARN"
echo "subscribe your email once:"
echo "  aws sns subscribe --topic-arn $TOPIC_ARN --protocol email --notification-endpoint you@tempest.earth"
