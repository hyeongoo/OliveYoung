#!/bin/bash
set -e

# Usage: REGION=<region> ./install.sh
if [ -z "$REGION" ]; then
  echo "REGION 변수가 필요합니다. 예: REGION=us-east-1 ./install.sh"
  exit 1
fi

# 페이저 비활성화
export AWS_PAGER=""

ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
CLUSTER_NAME="foreveryoung-cluster-${REGION}"

# 1. Helm repo 등록
helm repo add fluent https://fluent.github.io/helm-charts || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo update

# 2. OIDC URL 추출
OIDC_URL=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_DOMAIN=${OIDC_URL#https://}

# 3. IRSA 신뢰관계 업데이트 함수
patch_irsa_trust() {
  ROLE_NAME=$1; SA_NAMESPACE=$2; SA_NAME=$3; TMP="trust-${ROLE_NAME}.json"
  cat > "$TMP" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_DOMAIN}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_DOMAIN}:sub": "system:serviceaccount:${SA_NAMESPACE}:${SA_NAME}"
      }
    }
  }]
}
EOF
  aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document file://"$TMP"
  rm -f "$TMP"
}

patch_irsa_trust FluentBitToKinesisRole-${REGION} logging fluent-bit-sa
patch_irsa_trust IRSA-AMP-Role-${REGION} monitoring amp-irsa-sa


# 4. ServiceAccount 생성 및 IRSA 연결
kubectl get ns logging >/dev/null 2>&1 || kubectl create ns logging
kubectl get sa fluent-bit-sa -n logging >/dev/null 2>&1 || kubectl create sa fluent-bit-sa -n logging
kubectl annotate sa fluent-bit-sa -n logging \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/FluentBitToKinesisRole-${REGION} \
  --overwrite

kubectl get ns monitoring >/dev/null 2>&1 || kubectl create ns monitoring
kubectl get sa amp-irsa-sa -n monitoring >/dev/null 2>&1 || kubectl create sa amp-irsa-sa -n monitoring
kubectl annotate sa amp-irsa-sa -n monitoring \
  eks.amazonaws.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/IRSA-AMP-Role-${REGION} \
  --overwrite

kubectl patch sa amp-irsa-sa -n monitoring --type merge -p '{
  "metadata": {
    "labels": {
      "app.kubernetes.io/managed-by": "Helm"
    },
    "annotations": {
      "meta.helm.sh/release-name": "prometheus",
      "meta.helm.sh/release-namespace": "monitoring"
    }
  }
}'

echo "IRSA 연동 완료"

# 5. AMP Workspace 생성 및 ID 추출
aws amp create-workspace --alias "oliveyoung-monitoring-${REGION}" \
  --region "$REGION" >/dev/null 2>&1 || true
AMP_WS_ID=$(aws amp list-workspaces --region "$REGION" \
  --query "workspaces[?alias=='oliveyoung-monitoring-${REGION}'].workspaceId" --output text)

# 6. Lambda 함수 배포
ZIP_NAME="fluentbit-log-filter-${REGION}.zip"
zip -j "$ZIP_NAME" lambda_function.py
aws lambda create-function \
  --region "$REGION" \
  --function-name "fluentbit-log-filter-${REGION}" \
  --runtime python3.9 \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://"$ZIP_NAME" \
  --role arn:aws:iam::${ACCOUNT_ID}:role/FirehoseDeliveryRoleWithLambda || true

# 7. S3 버킷 생성 및 수명주기 설정
BUCKET="oliveyoung-log-${REGION}"
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" || true
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint=$REGION || true
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Suspended
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration '{"Rules":[{"ID":"auto-delete-1-day","Prefix":"","Status":"Enabled","Expiration":{"Days":1}}]}'

# 8. Firehose Stream 생성
STREAM_NAME="${REGION}-oliveyoung-log-stream"
cat > firehose-config.json <<EOF
{
  "DeliveryStreamName": "$STREAM_NAME",
  "DeliveryStreamType": "DirectPut",
  "ExtendedS3DestinationConfiguration": {
    "RoleARN": "arn:aws:iam::${ACCOUNT_ID}:role/FirehoseDeliveryRoleWithLambda",
    "BucketARN": "arn:aws:s3:::${BUCKET}",
    "Prefix": "",
    "BufferingHints": {"SizeInMBs":5,"IntervalInSeconds":300},
    "CompressionFormat": "UNCOMPRESSED",
    "CloudWatchLoggingOptions": {"Enabled": false},
    "ProcessingConfiguration": {
      "Enabled": true,
      "Processors": [{
        "Type":"Lambda",
        "Parameters":[{"ParameterName":"LambdaArn","ParameterValue":"arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:fluentbit-log-filter-${REGION}"}]
      }]
    }
  }
}
EOF
aws firehose create-delivery-stream --cli-input-json file://firehose-config.json || true
rm -f firehose-config.json

# 9. Fluent Bit & Prometheus values 생성
sed -e "s|__FLUENT_IRSA_ROLE__|arn:aws:iam::${ACCOUNT_ID}:role/FluentBitToKinesisRole-${REGION}|g" \
    -e "s|\${REGION}|${REGION}|g" \
    fluent-bit-values.yaml.template > fluent-bit-values.yaml

sed -e "s|__PROMETHEUS_IRSA_ROLE__|arn:aws:iam::${ACCOUNT_ID}:role/IRSA-AMP-Role-${REGION}|g" \
    -e "s|__AMP_WORKSPACE_ID__|${AMP_WS_ID}|g" \
    -e "s|\${REGION}|${REGION}|g" \
    prometheus-values.yaml.template > prometheus-values.yaml

# 10. Helm 설치
helm upgrade --install fluent-bit fluent/fluent-bit \
  -f fluent-bit-values.yaml --namespace logging --create-namespace
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -f prometheus-values.yaml --namespace monitoring --create-namespace

# 11. 로그 그룹 사전 생성
aws logs create-log-group --log-group-name oliveyoung-log-${REGION} --region ${REGION} || true
aws logs create-log-stream --log-group-name oliveyoung-log-${REGION} --log-stream-name filtered-errors --region ${REGION} || true

# 12. Metric Filter + Alarm 생성
for TYPE in memory_issue disk_issue db_issue system_crash error; do
  aws logs put-metric-filter \
    --log-group-name oliveyoung-log-${REGION} \
    --filter-name "filter-${TYPE}" \
    --filter-pattern "{ $.log_type = \"${TYPE}\" }" \
    --metric-transformations metricName=${TYPE}_count,metricNamespace=LogMetrics,metricValue=1

  aws cloudwatch put-metric-alarm \
    --alarm-name "High${TYPE^}Issues" \
    --metric-name "${TYPE}_count" \
    --namespace "LogMetrics" \
    --statistic Sum \
    --period 300 \
    --evaluation-periods 1 \
    --threshold 5 \
    --comparison-operator GreaterThanOrEqualToThreshold \
    --alarm-actions arn:aws:sns:${REGION}:${ACCOUNT_ID}:oliveyoung-alert-${REGION}
done

# 13. SNS 주제 및 이메일 구독
aws sns create-topic --name oliveyoung-alert-${REGION} >/dev/null 2>&1 || true
TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT_ID}:oliveyoung-alert-${REGION}"
EXISTING_CONFIRMED=$(aws sns list-subscriptions-by-topic \
  --topic-arn "$TOPIC_ARN" \
  --region "$REGION" \
  --query "Subscriptions[?Endpoint=='hgk5445@naver.com' && SubscriptionArn!='PendingConfirmation'].SubscriptionArn" \
  --output text)

if [ -z "$EXISTING_CONFIRMED" ]; then
  aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email --notification-endpoint hgk5445@naver.com
fi

echo "설치 완료: REGION=${REGION}"
