# AWS DRS (Elastic Disaster Recovery) 테스트 환경

온프레미스 → AWS 재해 복구 시나리오를 시뮬레이션하는 Terraform 프로젝트.
EC2를 온프레미스 서버로 가정하고, VPC Peering을 VPN/DirectConnect 대안으로 사용하여 Private IP 기반 복제를 구성한다.

---

## 네트워크 아키텍처

```
┌─── Source Region: ap-northeast-2 (서울) ─────────────────────────────────────┐
│                                                                               │
│  VPC 10.100.0.0/16                                                           │
│  ┌─ Public Subnet (10.100.1.0/24) ─────────────────────────────────────────┐ │
│  │                                                                          │ │
│  │  EC2 Source Server (t3.micro, Amazon Linux 2)                            │ │
│  │  ├─ nginx (워크로드)                                                     │ │
│  │  ├─ DRS Agent (커널 드라이버 + Java 에이전트)                             │ │
│  │  │   └─ 블록 변경 감지 → TCP 1500 으로 전송                              │ │
│  │  └─ Instance Profile: drs-source-server-role                             │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
└───────────────────────────────────┬───────────────────────────────────────────┘
                                    │
                        ┌───────────┴───────────┐
                        │   VPC Peering          │
                        │   (VPN/DX 대안)        │
                        │                        │
                        │   TCP 1500: 복제 데이터│
                        │   HTTPS 443: API 통신  │
                        └───────────┬────────────┘
                                    │
┌───────────────────────────────────┴───────────────────────────────────────────┐
│                                                                               │
│  DR Region: ap-northeast-1 (도쿄)                                             │
│  VPC 10.200.0.0/16                                                           │
│                                                                               │
│  ┌─ Private Subnet (10.200.11.0/24) - Staging Area ────────────────────────┐ │
│  │                                                                          │ │
│  │  Replication Server (t3.small, DRS 관리형)                                │ │
│  │  ├─ 소스 블록 데이터 수신                                                 │ │
│  │  ├─ Staging EBS에 실시간 기록                                             │ │
│  │  └─ PIT 스냅샷 생성 (10분/1시간/1일 주기)                                 │ │
│  │                                                                          │ │
│  │  VPC Endpoints:                                                          │ │
│  │  ├─ S3 Gateway    → 에이전트 바이너리 다운로드                            │ │
│  │  ├─ DRS Interface → DRS API 통신                                         │ │
│  │  └─ EC2 Interface → EBS/인스턴스 관리                                     │ │
│  │                                                                          │ │
│  │  Route: 0.0.0.0/0 → NAT Gateway                                         │ │
│  │  Route: 10.100.0.0/16 → VPC Peering                                     │ │
│  │  Route: S3 prefix list → S3 VPC Endpoint                                │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
│  ┌─ Public Subnet (10.200.1.0/24) - Recovery ──────────────────────────────┐ │
│  │                                                                          │ │
│  │  Recovery Instance (DR 발동 시에만 생성)                                  │ │
│  │  └─ Staging EBS 스냅샷으로부터 부팅                                       │ │
│  │                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────┘ │
│                                                                               │
└───────────────────────────────────────────────────────────────────────────────┘
```

### 통신 흐름

| 출발 | 도착 | 포트 | 경로 | 용도 |
|------|------|------|------|------|
| DRS Agent (소스) | Replication Server (DR) | TCP 1500 | VPC Peering (Private IP) | 디스크 블록 복제 데이터 |
| DRS Agent (소스) | DRS API | HTTPS 443 | Internet | 에이전트 등록, 상태 보고 |
| Replication Server | S3 | HTTPS 443 | S3 VPC Endpoint | 바이너리 다운로드 |
| Replication Server | DRS API | HTTPS 443 | DRS VPC Endpoint | 복제 상태 보고 |
| Replication Server | EC2 API | HTTPS 443 | EC2 VPC Endpoint | EBS 볼륨 관리 |

### 보안 그룹 정책

| SG | Inbound | 용도 |
|----|---------|------|
| source-server-sg | 80/tcp (0.0.0.0/0), 22/tcp (0.0.0.0/0) | nginx 확인, SSH |
| drs-staging-sg | 1500/tcp (10.100.0.0/16), 443/tcp (10.200.0.0/16, 10.100.0.0/16) | 복제 데이터, VPC Endpoint |
| drs-recovery-sg | 80/tcp (0.0.0.0/0), 22/tcp (0.0.0.0/0) | 복구 인스턴스 확인 |

---

## DRS 설정 레이어

DRS는 3가지 독립적인 설정이 있다:

| 설정 | 적용 시점 | 제어 대상 | Terraform 관리 |
|------|-----------|-----------|----------------|
| **Replication Settings** | 복제 중 (상시) | 복제 서버 위치, 통신 방식, PIT 정책 | Yes (`aws_drs_replication_configuration_template`) |
| **Launch Settings** | DR 드릴/Failover 시 | Recovery Instance 서브넷, SG, 인스턴스 타입 | 콘솔/CLI만 |
| **DRS Initialize** | 최초 1회 | 서비스 활성화, SLR 생성 | 콘솔에서 수동 |

### Replication Configuration (현재 설정)

| 항목 | 값 |
|------|-----|
| Staging Subnet | Private (NAT + Endpoints 있는 서브넷) |
| Data Plane Routing | **PRIVATE_IP** (피어링 경유) |
| Create Public IP | **No** |
| Replication Server | t3.small |
| EBS Encryption | DEFAULT |
| Dedicated Server | No (소스 서버 간 공유) |

### PIT (Point-in-Time) Policy

| Rule | 간격 | 보관 | 용도 |
|------|------|------|------|
| 1 | 10분 | 60분 | 최근 1시간 세밀 복구 |
| 2 | 1시간 | 24시간 | 최근 1일 복구 |
| 3 | 1일 | 7일 | 최근 1주 복구 |

---

## 프로젝트 구조

```
.
├── providers.tf         # 듀얼 프로바이더 (source: ap-northeast-2, dr: ap-northeast-1)
├── variables.tf         # 변수 정의
├── versions.tf          # Terraform >= 1.5, AWS Provider ~> 5.0
├── locals.tf            # 공통 태그
├── source.tf            # 소스 리전: VPC, SG, EC2 (Amazon Linux 2 + nginx)
├── dr.tf                # DR 리전: VPC, SG, DRS Replication Configuration Template
├── peering.tf           # VPC Peering (서울 ↔ 도쿄, VPN/DX 대안)
├── endpoints.tf         # DR VPC Endpoints (S3, DRS, EC2)
├── iam.tf               # IAM Role (Instance Profile) + IAM User (온프레미스용 Access Key)
├── outputs.tf           # 출력값
├── terraform.tfvars.example  # 변수 예시
├── scripts/
│   ├── source_userdata.sh    # EC2 부팅 스크립트 (nginx + agent 다운로드)
│   ├── 01_init_drs.sh        # DRS 초기화 + 에이전트 설치 가이드
│   ├── 02_dr_drill.sh        # DR 드릴 (비침습 테스트)
│   ├── 03_failover.sh        # 실제 Failover
│   └── 04_failback.sh        # Failback (소스 복귀)
└── AWS_DRS_학습노트.md        # Obsidian 학습 노트
```

### 사용 모듈

| 모듈/리소스 | 버전 | 용도 |
|-------------|------|------|
| terraform-aws-modules/vpc/aws | ~> 5.0 | VPC 2개 (소스/DR) |
| terraform-aws-modules/security-group/aws | ~> 5.0 | SG 3개 |
| terraform-aws-modules/ec2-instance/aws | ~> 5.0 | 소스 서버 |
| aws_drs_replication_configuration_template | native | DRS 복제 템플릿 (계정당 1개) |
| aws_vpc_peering_connection | native | 리전 간 피어링 |
| aws_vpc_endpoint | native | S3/DRS/EC2 엔드포인트 |

---

## 실행 가이드

### 사전 조건

- Terraform >= 1.5
- AWS CLI v2
- DR 리전(ap-northeast-1)에서 DRS 서비스 초기화 (콘솔에서 1회)

### Step 1: DRS 서비스 초기화

AWS 콘솔에서 수행 (CLI로는 SLR 생성 문제 발생 가능):
1. 리전을 **ap-northeast-1** 로 변경
2. **Elastic Disaster Recovery** 서비스 진입
3. **Set up Elastic Disaster Recovery** 클릭 (기본값으로 진행)

> 이 단계에서 Replication Configuration Template이 1개 생성됨 (계정당 1개 제한)

### Step 2: 인프라 배포

```bash
terraform init
terraform apply

# 콘솔에서 만든 기존 Template을 import
aws drs describe-replication-configuration-templates --region ap-northeast-1 \
  --query 'items[0].replicationConfigurationTemplateID' --output text

terraform import aws_drs_replication_configuration_template.this <template-id>
terraform apply
```

### Step 3: DRS 에이전트 설치

```bash
# 소스 서버 접속 (SSM)
aws ssm start-session --target $(terraform output -raw source_server_instance_id) --region ap-northeast-2

# root 전환
sudo su -

# 에이전트 설치 (Instance Profile 인증 사용)
cd /tmp
./aws-replication-installer-init --region ap-northeast-1
# 디스크 선택: Enter (전체)
# 키 입력: Instance Profile 사용 시 불필요
```

**온프레미스 환경에서는** EC2 Instance Profile이 없으므로 IAM User Access Key 필요:
```bash
./aws-replication-installer-init --region ap-northeast-1 \
  --aws-access-key-id <KEY> \
  --aws-secret-access-key '<SECRET>'
```

### Step 4: 복제 상태 확인

```bash
aws drs describe-source-servers --region ap-northeast-1 \
  --query 'items[0].dataReplicationInfo.dataReplicationState' --output text
```

복제 상태 진행 순서:
```
INITIATING → INITIAL_SYNC → CREATING_SNAPSHOT → CONTINUOUS_REPLICATION
```

`CONTINUOUS_REPLICATION` 도달 시 DR 드릴 가능.

### Step 5: Launch Settings 설정 (콘솔)

DR 드릴 전에 Recovery Instance 배치 설정 필요:
1. DRS 콘솔 → Source servers → 소스 서버 선택
2. **Launch settings** → Edit
3. Subnet: **public subnet** 선택 (Recovery Instance에 퍼블릭 IP 부여)
4. Security groups: **drs-recovery-sg** 선택

### Step 6: DR 드릴

```bash
./scripts/02_dr_drill.sh
```

또는 콘솔에서:
1. Source servers → 소스 서버 체크 → **Initiate recovery job** → **Initiate drill**
2. 몇 분 후 Recovery Instance 생성됨
3. 퍼블릭 IP로 nginx 접속하여 복구 확인

### Step 7: 정리

```bash
# DR 드릴 인스턴스 종료
aws drs terminate-recovery-instances --region ap-northeast-1 --recovery-instance-ids <id>

# 전체 인프라 제거
terraform destroy
```

---

## 설치 프로세스 상세

### 전체 설치 흐름

```
[DRS 서비스 초기화] → [Terraform 배포] → [Template Import] → [에이전트 설치] → [복제 완료 대기] → [Launch Settings] → [DR 드릴]
```

### 1. DRS 서비스 초기화

> CLI(`aws drs initialize-service`)는 SLR 생성 권한 문제로 실패할 수 있다. 콘솔 권장.

```
콘솔 → 리전: ap-northeast-1 → Elastic Disaster Recovery → Set up
- 서브넷: 아무거나 (Terraform이 덮어씀)
- 나머지: 기본값
```

이 단계에서 생성되는 것:
- Service-Linked Role (`AWSServiceRoleForElasticDisasterRecovery`)
- Instance Profile (DRS용)
- Replication Configuration Template 1개

### 2. Terraform 배포 + Template Import

```bash
terraform init
terraform apply
# → Template 생성 시 ServiceQuotaExceededException 발생 (정상)
#    계정당 1개만 허용되므로 콘솔에서 만든 것을 import

# Template ID 확인
aws drs describe-replication-configuration-templates --region ap-northeast-1 \
  --query 'items[0].replicationConfigurationTemplateID' --output text

# Import
terraform import aws_drs_replication_configuration_template.this <template-id>

# Terraform 설정으로 동기화
terraform apply
```

### 3. 에이전트 설치

```bash
# 소스 서버 접속
aws ssm start-session --target $(terraform output -raw source_server_instance_id) --region ap-northeast-2

sudo su -
cd /tmp

# 설치 (인터랙티브 모드)
./aws-replication-installer-init --region ap-northeast-1
```

설치 중 프롬프트:
1. **디스크 선택** → Enter (전체 복제)
2. **Access Key** → Instance Profile 사용 시 자동 건너뜀. 온프레미스면 직접 입력.

설치 성공 메시지:
```
The AWS Replication Agent was successfully installed.
```

### 4. 복제 진행 확인

```bash
# 상태 확인 (로컬에서)
aws drs describe-source-servers --region ap-northeast-1 \
  --query 'items[0].dataReplicationInfo.dataReplicationState' --output text

# 상세 단계 확인
aws drs describe-source-servers --region ap-northeast-1 \
  --query 'items[0].dataReplicationInfo.dataReplicationInitiation.steps'
```

정상 진행 순서:
```
✅ WAIT
✅ CREATE_SECURITY_GROUP (또는 SKIPPED)
✅ LAUNCH_REPLICATION_SERVER
✅ BOOT_REPLICATION_SERVER
✅ AUTHENTICATE_WITH_SERVICE
✅ DOWNLOAD_REPLICATION_SOFTWARE
✅ CREATE_STAGING_DISKS
✅ ATTACH_STAGING_DISKS
✅ PAIR_REPLICATION_SERVER_WITH_AGENT
✅ CONNECT_AGENT_TO_REPLICATION_SERVER
✅ START_DATA_TRANSFER
```

이후 상태 전이:
```
INITIATING → INITIAL_SYNC → CREATING_SNAPSHOT → CONTINUOUS_REPLICATION
```

### 5. Launch Settings 설정

DR 드릴/Failover 시 Recovery Instance가 생성될 위치를 지정해야 한다.
미설정 시 `VPCIdNotSpecified` 에러 발생.

```
DRS 콘솔 → Source servers → 소스 서버 → Launch settings → Edit
- Subnet: public subnet (퍼블릭 IP 부여됨)
- Security groups: drs-recovery-sg
```

### 6. DR 드릴

```bash
# CLI
./scripts/02_dr_drill.sh

# 또는 콘솔
Source servers → 체크 → Initiate recovery job → Initiate drill
```

**Drill vs Recovery:**
- Drill: 복제 유지 + 테스트 인스턴스 생성 (비침습)
- Recovery: 복제 중단 + 실제 복구 (Failback 필요)

---

## 삭제 프로세스 상세

### 삭제 순서 (의존관계)

DRS 리소스는 **아래에서 위로** 삭제해야 한다:

```
[Recovery Instance] → [Job] → [Source Server] → [Template] → [Terraform Infra]
```

### 전체 삭제 절차

```bash
# 1. Recovery Instance 종료 (있는 경우)
aws drs describe-recovery-instances --region ap-northeast-1 \
  --query 'items[*].recoveryInstanceID' --output text
aws drs terminate-recovery-instances --region ap-northeast-1 \
  --recovery-instance-ids <recovery-instance-id>

# 2. Job 삭제
aws drs describe-jobs --region ap-northeast-1 \
  --query 'items[*].{ID:jobID,Status:status}' --output table
aws drs delete-job --region ap-northeast-1 --job-id <job-id>

# 3. Source Server 삭제
aws drs describe-source-servers --region ap-northeast-1 \
  --query 'items[*].sourceServerID' --output text
aws drs disconnect-source-server --region ap-northeast-1 --source-server-id <id>
aws drs delete-source-server --region ap-northeast-1 --source-server-id <id>

# 4. Terraform 인프라 삭제
terraform destroy
```

> `terraform destroy`에서 Template 삭제 실패 시 → 위 1~3 단계가 남아있는 것.
> 모든 Job과 Source Server가 삭제된 후에만 Template 삭제 가능.

### 에이전트만 제거 (인프라 유지)

소스 서버에서 에이전트만 제거하고 싶을 때:

```bash
# 방법 1: 공식 제거 스크립트
sudo /var/lib/aws-replication-agent/uninstall-agent.sh

# 방법 2: 수동 제거 (스크립트 실행 불가 시)
kill -9 $(pgrep -f replication) 2>/dev/null
sudo rm -rf /var/lib/aws-replication-agent
sudo rm -f /etc/systemd/system/aws-replication-agent.service
sudo systemctl daemon-reload
sudo systemctl reset-failed
rm -f /tmp/aws-replication-installer-64bit
```

에이전트 제거 후 DRS 측 정리:
```bash
aws drs disconnect-source-server --region ap-northeast-1 --source-server-id <id>
aws drs delete-source-server --region ap-northeast-1 --source-server-id <id>
```

### Source Server disconnect 시 주의사항

- disconnect하면 복제 서버(Replication Server EC2)가 **자동 종료**됨
- disconnect만으로 소스 서버가 삭제될 수도 있음
- 재등록하려면 에이전트 완전 제거 후 재설치 필요 (기존 `agent.config`에 이전 ID 잔존)
- 소스 서버가 0개가 되면 DRS 서비스 자체가 비활성화될 수 있음 → 콘솔에서 재초기화

---

## 에이전트 관리

### 상태 확인

```bash
systemctl status aws-replication-agent
```

### 파일 구조

| 경로 | 용도 |
|------|------|
| `/var/lib/aws-replication-agent/` | 에이전트 설치 디렉토리 |
| `/var/lib/aws-replication-agent/agent.config` | 에이전트 설정 (Source Server ID 등) |
| `/var/lib/aws-replication-agent/agent.log.0` | 실행 로그 |
| `/var/lib/aws-replication-agent/aws-replication-driver.ko` | 커널 드라이버 (블록 변경 감지) |
| `/var/lib/aws-replication-agent/uninstall-agent.sh` | 공식 제거 스크립트 |
| `/var/lib/aws-replication-agent/jre/` | 내장 Java Runtime |

### 재설치 절차

```bash
# 1. DRS 측 정리 (로컬에서)
aws drs disconnect-source-server --region ap-northeast-1 --source-server-id <id>

# 2. 소스 서버에서 에이전트 완전 제거
sudo /var/lib/aws-replication-agent/uninstall-agent.sh
# 또는 수동 제거 (위 참고)

# 3. 잔여 프로세스 확인 (중요!)
ps aux | grep replication | grep -v grep
# 남아있으면: kill -9 $(pgrep -f replication)

# 4. 재설치
cd /tmp
./aws-replication-installer-init --region ap-northeast-1
```

### 재설치 시 주의사항

- **반드시** 이전 프로세스/파일을 완전 제거한 뒤 재설치
- 잔여 프로세스가 있으면 `Text file busy` 에러 발생
- 잔여 `agent.config`가 있으면 삭제된 Source Server ID로 연결 시도 → 404 에러
- `/tmp/aws-replication-installer-64bit` 파일이 남아있어도 충돌 발생

---

## 트러블슈팅

| 증상 | 원인 | 해결 |
|------|------|------|
| `UninitializedAccountException` | DRS 서비스 미초기화 | 콘솔에서 Set up 수행 |
| `ServiceQuotaExceededException` | Template 이미 존재 (계정당 1개) | `terraform import`로 기존 Template 관리 |
| `AccessDeniedException: CreateSourceServerForDrs` | IAM 정책 누락 | `drs:CreateSourceServerForDrs` 권한 추가 |
| `FAILED_TO_CONNECT_AGENT_TO_REPLICATION_SERVER` | SG/네트워크 문제 | TCP 1500 인바운드 허용 확인 |
| `Failed Downloading the AWS Replication Agent` | 복제 서버의 S3 접근 불가 | 스테이징 서브넷 라우트 테이블에 NAT/S3 Endpoint 확인 |
| `Text file busy` / `Unexpected Error` | 이전 프로세스/파일 잔존 | 에이전트 완전 제거 후 재설치 |
| `agent.config (No such file or directory)` | 설치 미완료 상태에서 서비스 시작 | 에이전트 완전 제거 후 재설치 |
| `VPCIdNotSpecified` (Drill 실패) | Launch Settings 미설정 | 콘솔에서 서브넷/SG 지정 |
| kernel-devel 미제공 (AL2023) | 최신 커널에 대한 패키지 미출시 | Amazon Linux 2 사용 또는 커널 다운그레이드 |

---

## 비용

| 항목 | 예상 비용 | 비고 |
|------|-----------|------|
| 소스 EC2 (t3.micro) | ~$0.013/hr | 테스트 서버 |
| Replication Server (t3.small) | ~$0.026/hr | 복제 중 상시 실행 |
| EBS Staging Disk (30GB x2) | ~$0.19/월 | standard 타입 |
| NAT Gateway | ~$0.062/hr | DR VPC용 |
| VPC Endpoints (Interface x2) | ~$0.014/hr 각 | DRS + EC2 |
| VPC Peering 전송 | ~$0.01/GB | 리전 간 |
| Recovery Instance | DR 시에만 과금 | |

> 테스트 완료 후 반드시 `terraform destroy`

---

## 실제 온프레미스 환경과의 차이

| 항목 | 이 테스트 | 실제 온프레미스 |
|------|-----------|----------------|
| 소스 → DR 연결 | VPC Peering | Site-to-Site VPN / Direct Connect |
| 에이전트 인증 | EC2 Instance Profile | IAM User Access Key (필수) |
| DNS 해석 | VPC 내부 자동 | Route53 Resolver / 온프레미스 DNS 설정 필요 |
| 네트워크 보안 | Security Group | 방화벽 + VPN 터널 암호화 |

---

## 참고 문서

- [AWS DRS 서비스 할당량](https://docs.aws.amazon.com/general/latest/gr/drs.html)
- [DRS 지원 OS 목록](https://docs.aws.amazon.com/drs/latest/userguide/Supported-Operating-Systems-Linux.html)
- [DRS 에이전트 설치 요구사항](https://docs.aws.amazon.com/drs/latest/userguide/installation-requirements.html)
- [DRS 트러블슈팅](https://docs.aws.amazon.com/drs/latest/userguide/Troubleshooting-Agent-Issues.html)
- [DRS API Reference](https://docs.aws.amazon.com/drs/latest/APIReference/API_CreateReplicationConfigurationTemplate.html)
