# OliveYoung
# 올리브영 글로벌 서비스 프로젝트
프로젝트 기간 : 2025.03 ~ 2025.06

# 1. 프로젝트 개요

- **배경**
    
    해외에서 한국 브랜드(올리브영)에 대한 관심이 높아지면서, 외국인 사용자도 한국과 동일한 혜택(포인트 적립 등)을 제공받을 수 있는 서비스 환경에 대한 수요가 증가하였다.
    
    포인트 적립은 브랜드 충성도와 직결되므로, **글로벌 사용자에게도 일관된 경험**을 제공하는 것이 중요했다.
    
- **목표**
    1. 글로벌 사용자에게 동일한 포인트 적립 및 조회 서비스 제공
    2. 지연 없는 데이터 처리와 안정적인 인프라 구성
    3. 트래픽 증가에 유연하게 대응할 수 있는 자동 확장 운영 체계 구축

---

# 2. 전체 환경 구성

- **네트워크**
    - 리전별 VPC, 퍼블릭·프라이빗 Subnet 구성 (AZ 분리)
    - NAT Gateway 최소화하여 비용 절감
    - Bastion Host를 통해 내부 자원 접근
- **컴퓨팅 / 컨테이너**
    - AWS EKS (한국, 미국, 일본 리전 클러스터)
    - Auto Scaling 그룹으로 트래픽 변화 대응
- **데이터베이스**
    - Amazon Aurora Global Database
    - 한국 리전: Writer / 미국 리전: Reader
    - **Write Forwarding** 기능 활용 → 미국에서도 쓰기 요청 처리 가능
    - Global 모드(Read Consistency)로 데이터 정합성 보장
- **CI/CD**
    - GitHub Actions → Jenkins → ECR → ArgoCD
    - Image Updater를 통한 GitOps 기반 자동 배포
- **보안**
    - GuardDuty + EventBridge + Lambda + WAF
    - 의심 IP 자동 차단 및 실시간 위협 대응
- **아키텍처 다이어그램**

![전체 구성도.png](attachment:cab39161-c687-4203-bff3-d0647ae1d9f8:전체_구성도.png)

| 주차 | 주요 진행 내용 |
| --- | --- |
| **1주차 (03/21)** | 아키텍처 구성도 작성, 역할 분담, To-Do 리스트 정리 |
| **2주차 (03/28)** | 시나리오 변경: 미국 오프라인 진출 + 통합 DB 설계 |
| **3주차 (04/04)** | FE/BE 환경 통합, 도메인 분리 및 DB 세팅 |
| **4주차 (04/11)** | VPC/Subnet/EC2 구성, RDS ↔ Spring 연동 시도 |
| **5~6주차 (04/18~04/25)** | EKS/Fluent Bit/Prometheus 구축 및 아키텍처 완성 |
| **7~9주차 (05/02~05/16)** | 멀티 리전(EKS, Aurora, CloudFront) 확장 및 모니터링 강화 |
| **10~11주차 (05/23~05/30)** | DR 및 보안 강화를 통한 완성, 발표자료 정리 |

---

# 3. 내가 맡은 역할 (EKS + 로깅 & 모니터링)

### A. USER 도메인 개발

- 회원 가입(중복 방지 포함)
- 로그인
- JWT 기반 Access Token 발급 및 검증

---

### B. EKS 클러스터 구성

- eksctl + Helm을 활용한 클러스터 배포 및 관리
- 노드 그룹을 **프라이빗 Subnet 전용**으로 배치 → 보안 강화
- IAM OIDC Provider + IRSA로 서비스 계정별 최소 권한 할당

---

### C. 로깅 파이프라인 구축

- **구성 흐름**
    
    앱 로그 → Fluent Bit → Kinesis Firehose → Lambda(Log Filtering) → CloudWatch Logs
    
    ↓
    
    S3 Backup
    
    ![로깅파이프라인.png](attachment:b2cb65bf-300a-49af-915b-b7fa2a1150c9:로깅파이프라인.png)
    
- **구현**
    - Fluent Bit을 Helm Chart로 배포 → 컨테이너 로그 수집
    - Lambda(Python)로 Memory/Disk/DB/System 오류만 필터링
    - 로그를 CloudWatch + S3에 이중 저장하여 안정성 확보
    - 리전별 동일한 로깅 파이프라인을 **자동 배포 스크립트**로 표준화
- **대시보드**

![대시보드 1.png](attachment:af670d71-06f6-4852-8aae-b7b123a0ff37:대시보드_1.png)

- **알람**
    - Lambda를 이용해 필터링한 로그가 5분동안 5회 이상 발생하면 이메일과 Slack으로 알람을 전송

![알람.png](attachment:0a62e1cb-343d-4a2f-9acb-7fadc1a23c61:알람.png)

---

### D. 모니터링 파이프라인 구축

- **구성 흐름**
    
    애플리케이션 메트릭 → Prometheus (EKS 클러스터) → AMP(Remote Write) → AMG(Grafana)
    
    ![메트릭 파이프라인.png](attachment:1ccea87f-e344-4058-b83b-0948bbd7e797:메트릭_파이프라인.png)
    
- **주요 모니터링 지표**
    - CPU / 메모리 사용률
    - 응답 지연 시간(p95, p99)
    - 오류율, 파드 재시작 수
- **자동화**
    - Helm + Terraform + Bash → Prometheus & Fluent Bit 자동 설치
    - CloudWatch Metric Filter & Alarm 생성 → SNS → Slack 알림
- **대시보드**

![대시보드 2.png](attachment:1d41a253-0692-4c7e-91cf-dbc6fef69654:대시보드_2.png)

---

# 4. 기술 이슈와 해결 전략

## 문제 1.

직접 설치한 Prometheus + Grafana가 AMP 인증 정책(SigV4) 문제로

**로그인 및 대시보드 연동 실패**

### 해결

- 문제 구간을 패킷·로그로 분석하여 SigV4 인증 문제가 원인임을 확인
- 자체 구축 대신 **Amazon Managed Prometheus / Managed Grafana**로 아키텍처 전환
- EKS ServiceAccount(IRSA)에 필요한 IAM 정책을 재정의해 안정적으로 연동

### 결과

- 인증 오류 없이 메트릭 수집·대시보드 구성 가능
- 운영 편의성 증가
- 동일 구조를 **3개 리전에서 자동 배포 가능**한 수준까지 개선
- 관리형 서비스는 편리했지만, **비용 관리 측면에서 미흡**하여 장시간 연결 유지가 어려움

---

## 문제 2.

리전마다 로깅 파일 포맷과 IAM 권한이 달라 **표준화된 로깅 파이프라인 유지가 어려움**

### 해결

- Fluent Bit, Firehose, Lambda(Log Filtering), CloudWatch, S3까지
전체 파이프라인을 **하나의 Bash 자동 배포 스크립트로 통합**
- IAM 역할, 필터링 패턴, LogGroup 생성을 공통 템플릿 기반으로 구성
- 리전별 공통 인프라 리소스(EKS, IRSA Role 등)는 Terraform으로 선행 구성 후
관측 스택은 스크립트로 자동 배포하도록 구조 분리

### 결과

- 일본/미국/한국 리전에서 **완전히 동일한 로깅 파이프라인 재현 가능**
- 운영자가 리전을 변경해도 동일 절차로 배포 가능
- 수동 구성 과정의 설정 누락 및 권한 오류 제거
- Terraform 선행 리소스 생성 후 스크립트 실행 시 5분 이내 관측 스택 구축 가능

---

## 문제 3.

Prometheus·Grafana·Fluent Bit 설치 과정에서

재사용 가능한 IaC가 없어서 **작업이 매번 반복**

### 해결

- Helm + Terraform을 조합해 Prometheus·Fluent Bit 설치 자동화
- Terraform 담당 팀원과 역할 분리 후 리전별 공통 인프라 사전 정의
- IAM 역할 업데이트, SNS 알람 생성, Metric Filter 생성까지 모두 자동화
- REGION 변수 치환 기반 배포 구조 적용

### 결과

- 클러스터 초기화 → 로깅/모니터링 구축까지 전체 자동화
- REIGON 변수 치환 기반으로 리전별 동일 관측 파이프라인 배포 가능
- 인프라(Terraform)와 운영 스택(Helm/Bash) 역할 분리 구조 정립

---

# 5. 성능 및 안정성 검증

## 시나리오 1 — 점진적 증가 (Scalability Test)

트래픽을 단계적으로 증가시키며 시스템 확장성을 검증하였다.

### 초기 구성

- 성공률 4~6%
- 평균 응답시간 45~58초
- HTTP 실패율 90% 이상
- Kafka Consumer Rebalancing 반복 발생
- Lag 급증

![image.png](attachment:1bd1e318-f56a-4bf0-ab9b-70e9af6f91b1:image.png)

→ Total Lag 및 일부 Partition Lag 급증이 관찰되었으며, Partition-Consumer 불균형으로 메시지 처리 지연이 발생함을 확인

### 개선 후 (웹 서버 확장 및 Connection Pool 조정)

- 총 요청: 477,452건
- 성공률: 96.7%
- 평균 응답 시간: 2.08초
- p(95): 637ms
- HTTP 실패율 3.29%

→ HTTP 계층 안정성 개선 및 Lag 감소 패턴 확인

---

## 시나리오 2 — 1만명 부하 (Spike)

이벤트 상황을 가정하여 동시 10,000 VU 부하를 적용하였다.

### 결과

- 성공률: 3.5% ~ 6.8%
- 평균 응답 시간: 45~52초
- HTTP 실패율: 93% 이상
- 대부분 60초 타임아웃 발생
- Kafka Lag 급증 및 connection refused 발생

### 분석

- Consumer Rebalancing과 DB 연결 포화가 동시에 발생
- 메시지 적재 속도가 처리 속도를 크게 초과
- 애플리케이션 계층 이전에 메시지 큐 및 네트워크 계층에서 포화 상태가 발생
- 점진적 증가와 달리, 급격한 트래픽 유입에는 Kafka 및 DB 계층의 처리 한계가 명확히 드러났다.

![한방카.png](attachment:ae57b973-1563-4075-b3f1-4c7ae9b3f752:한방카.png)

## 부하테스트 결과

점진적 확장에는 안정적으로 대응 가능함을 확인하였다.
반면, 급격한 트래픽 폭증 상황에서는 Kafka 및 DB 계층의 처리 한계가 드러났으며,
대규모 동시 요청에 대한 추가적인 아키텍처 보완 필요성을 확인하였다.

---

## Aurora Global DB 일관성 모드 지연 테스트

Aurora Global Database의 Read Consistency 모드(SESSION / EVENTUAL / GLOBAL)에 따른 읽기 지연을 비교하였다.

### 테스트 방식

- Reader Endpoint (미국 리전)에서 실행
- INSERT 직후 SELECT 수행
- `aurora_replica_read_consistency` 설정 변경
- Bash 스크립트로 지연 시간 자동 측정

### 결과 요약

- **EVENTUAL 모드**: 가장 빠르나 직후 읽기 일관성 보장 불완전
- **SESSION 모드**: 세션 단위 일관성 보장, 지연 시간 중간 수준
- **GLOBAL 모드**: 가장 강한 일관성 보장, 상대적으로 높은 지연 발생

![image.png](attachment:0b1d47c4-6b44-4f2b-8855-2a418fb2d533:image.png)

→ 글로벌 환경에서 일관성과 응답 지연 간의 Trade-off 존재 확인

### 추가 확인 사항

- Write Forwarding 환경에서는 DDL 실행 불가 (read-only 오류 발생)
- DDL은 Writer 리전에서만 수행 가능

---

## 6. 성과 및 기술 역량

- Spring Boot 기반 사용자 인증 시스템 개발 경험
- 멀티 리전 인프라 설계 및 운영 경험
- Kubernetes & Helm 활용한 클러스터 운영 능력
- Fluent Bit, Firehose, Lambda, CloudWatch Logs 기반 로그 파이프라인 설계
- Prometheus, AMP, AMG 기반 멀티 리전 모니터링 환경 구축
- Terraform + Helm + Bash 기반 자동화 경험
- 비용 관리 및 최적화의 중요성을 실무적으로 체득
