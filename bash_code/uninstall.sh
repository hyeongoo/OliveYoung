#!/bin/bash
set -e

# Usage: REGION=<region> ./uninstall.sh
if [ -z "$REGION" ]; then
  echo "REGION 변수가 필요합니다. 예: REGION=us-east-1 ./uninstall.sh"
  exit 1
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

echo "[1] Helm 릴리스 제거"
helm uninstall fluent-bit --namespace logging || true
helm uninstall prometheus --namespace monitoring || true

echo "[2] AMP 워크스페이스 제거"
AMP_WS_ID=$(aws amp list-workspaces --region "${REGION}" \
  --query "workspaces[?alias=='oliveyoung-monitoring-${REGION}'].workspaceId" --output text)
if [ -n "$AMP_WS_ID" ]; then
  aws amp delete-workspace --workspace-id $AMP_WS_ID --region "${REGION}" || true
fi

echo "[3] Lambda 함수 제거"
aws lambda delete-function \
  --function-name fluentbit-log-filter-${REGION} \
  --region $REGION || true

echo "[4] CloudWatch 로그 그룹 제거"
aws logs delete-log-group \
  --log-group-name oliveyoung-log-${REGION} \
  --region $REGION || true

echo "[5] CloudWatch Metric Filters 및 알람 제거"
if aws logs describe-log-groups \
  --log-group-name-prefix oliveyoung-log-${REGION} \
  --region $REGION \
  --query 'logGroups' --output text | grep -q oliveyoung-log-${REGION}; then

  FILTERS=$(aws logs describe-metric-filters \
    --log-group-name oliveyoung-log-${REGION} \
    --region $REGION \
    --query "metricFilters[].filterName" --output text)

  for filter in $FILTERS; do
    aws logs delete-metric-filter \
      --log-group-name oliveyoung-log-${REGION} \
      --filter-name "$filter" \
      --region $REGION || true
  done

  ALARMS=$(aws cloudwatch describe-alarms \
    --region $REGION \
    --query "MetricAlarms[?starts_with(AlarmName, 'High')].AlarmName" --output text)

  for alarm in $ALARMS; do
    aws cloudwatch delete-alarm \
      --alarm-name "$alarm" \
      --region $REGION || true
  done
fi

echo "[6] SNS 주제 제거"
aws sns delete-topic \
  --topic-arn arn:aws:sns:${REGION}:${ACCOUNT_ID}:oliveyoung-alert-${REGION} || true

echo "[7] S3 버킷 및 객체 제거"
BUCKET=oliveyoung-log-${REGION}
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  aws s3 rm s3://$BUCKET --recursive
  aws s3api delete-bucket --bucket $BUCKET --region $REGION
fi

echo "[8] Firehose Delivery Stream 제거"
aws firehose delete-delivery-stream \
  --delivery-stream-name "${REGION}-oliveyoung-log-stream" \
  --region "$REGION" \
  --allow-force-delete || true

echo "삭제 완료: REGION=${REGION}"
x`