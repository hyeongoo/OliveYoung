import os
import json
import base64
import boto3
import time

REGION = os.environ.get('AWS_REGION', 'us-east-1')

# CloudWatch Logs 클라이언트
logs_client = boto3.client('logs')

# 로그 그룹 및 스트림 설정
LOG_GROUP_NAME = f"oliveyoung-log-{REGION}"
LOG_STREAM_NAME = "filtered-errors"

# 로그 스트림의 최신 sequence token 조회
def get_sequence_token():
    response = logs_client.describe_log_streams(
        logGroupName=LOG_GROUP_NAME,
        logStreamNamePrefix=LOG_STREAM_NAME
    )
    log_streams = response.get("logStreams", [])
    if not log_streams:
        raise Exception("Log stream not found.")
    return log_streams[0].get("uploadSequenceToken")

# CloudWatch Logs에 로그 전송
def put_log_to_cloudwatch(log_data):
    token = get_sequence_token()
    logs_client.put_log_events(
        logGroupName=LOG_GROUP_NAME,
        logStreamName=LOG_STREAM_NAME,
        logEvents=[
            {
                'timestamp': int(time.time() * 1000),
                'message': json.dumps(log_data)
            }
        ],
        sequenceToken=token
    )

# 키워드 정의
MEMORY_KEYWORDS = [
    "OutOfMemoryError", "Cannot allocate memory", "MemoryError", "Memory exhausted",
    "Process killed", "Memory leak", "Possible memory leak detected", "Potential memory leak", "Leak detected",
    "Garbage Collection overhead limit exceeded", "GC overhead limit exceeded",
    "Container killed due to memory usage", "OOMKilled", "memory cgroup limit exceeded",
    "Native memory allocation (malloc) failed", "unable to create new native thread",
    "Resource temporarily unavailable"
]

DISK_KEYWORDS = [
    "Disk quota exceeded", "No space left on device"
]

DB_KEYWORDS = [
    "DB connection failed", "Deadlock found", "Lock wait timeout", "SQL error"
]

SYSTEM_KEYWORDS = [
    "Kernel panic", "Segmentation fault", "core dumped"
]

ERROR_KEYWORDS = [
    "ERROR", "Exception", "Fail", "fatal"
]

def classify_log(log_message):
    if any(keyword in log_message for keyword in MEMORY_KEYWORDS):
        return "memory_issue"
    elif any(keyword in log_message for keyword in DISK_KEYWORDS):
        return "disk_issue"
    elif any(keyword in log_message for keyword in DB_KEYWORDS):
        return "db_issue"
    elif any(keyword in log_message for keyword in SYSTEM_KEYWORDS):
        return "system_crash"
    elif any(keyword in log_message for keyword in ERROR_KEYWORDS):
        return "error"
    else:
        return "other"

def lambda_handler(event, context):
    output = []
    for record in event['records']:
        payload = json.loads(base64.b64decode(record['data']))
        log_message = payload.get('log', '')

        log_type = classify_log(log_message)

        if log_type == "other":
            output_record = {
                'recordId': record['recordId'],
                'result': 'Dropped',
                'data': record['data']
            }
        else:
            payload['log_type'] = log_type

            try:
                put_log_to_cloudwatch(payload)
            except Exception as e:
                print(f"[LOGGING ERROR] CloudWatch 전송 실패: {str(e)}")

            encoded_data = base64.b64encode(json.dumps(payload).encode('utf-8')).decode('utf-8')
            output_record = {
                'recordId': record['recordId'],
                'result': 'Ok',
                'data': encoded_data
            }

        output.append(output_record)

    return {'records': output}
