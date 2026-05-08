# AWS Elastic Disaster Recovery (DRS) 실습

#terraform #aws #drs #disaster-recovery #high-availability

## 📋 개요

### 실습 목표
- AWS DRS를 활용한 재해 복구(Disaster Recovery) 환경 구축
- 온프레미스 환경 시뮬레이션 (ap-northeast-2 Seoul)
- DR 환경 구성 (ap-northeast-1 Tokyo)
- 블록 레벨 연속 복제 및 복구 테스트

### 사용되는 AWS 서비스
- **AWS DRS (Elastic Disaster Recovery)**: 재해 복구 서비스
- **EC2**: 소스 서버 및 복구 인스턴스
- **VPC**: 네트워크 격리 (소스/DR 각각)
- **IAM**: DRS 에이전트 권한 관리
- **Systems Manager (SSM)**: 원격 서버 접근

### 핵심 개념
- **에이전트 기반 복제**: 소스 서버에 DRS 에이전트 설치 필요
- **블록 레벨 복제**: 파일이 아닌 디스크 블록 단위 복제
- **RPO (Recovery Point Objective)**: 초 단위 - 거의 실시간 복제
- **RTO (Recovery Time Objective)**: 분 단위 - 빠른 복구 시간
- **경량 스테이징**: 평상시 최소 비용, DR 시 프로덕션급 인스턴스 시작

## 🏗️ 아키텍처

### 리소스 구성도

```
┌──────────────────────────────────────┐    ┌──────────────────────────────────────┐
│   SOURCE REGION (ap-northeast-2)     │    │     DR REGION (ap-northeast-1)       │
│   "온프레미스 시뮬레이션"             │    │                                      │
├──────────────────────────────────────┤    ├──────────────────────────────────────┤
│                                      │    │                                      │
│  VPC: 10.100.0.0/16                  │    │  VPC: 10.200.0.0/16                  │
│  ┌────────────────────────────────┐  │    │  ┌────────────────────────────────┐  │
│  │ Public Subnet (a/c)            │  │    │  │ Private Subnet (staging)       │  │
│  │                                │  │    │  │ - DRS Replication Server       │  │
│  │  ┏━━━━━━━━━━━━━━━━━━━━┓        │  │    │  │ - Port 1500 (replication)      │  │
│  │  ┃ Source EC2         ┃        │  │====┼══┼>│ - Security Group: staging    │  │
│  │  ┃ - nginx            ┃        │  │    │  └────────────────────────────────┘  │
│  │  ┃ - DRS Agent        ┃        │  │    │                                      │
│  │  ┃ - IAM Role         ┃        │  │    │  ┌────────────────────────────────┐  │
│  │  ┗━━━━━━━━━━━━━━━━━━━━┛        │  │    │  │ Public Subnet (recovery)       │  │
│  │                                │  │    │  │                                │  │
│  └────────────────────────────────┘  │    │  │  ┏━━━━━━━━━━━━━━━━━━━━┓        │  │
│                                      │    │  │  ┃ Recovery Instance  ┃        │  │
└──────────────────────────────────────┘    │  │  ┃ (DR 시에만 시작)    ┃        │  │
                                            │  │  ┃ - nginx (복제됨)    ┃        │  │
         복제 데이터 흐름 (Port 1500)       │  │  ┃ - SG: recovery      ┃        │  │
                  ══════>                   │  │  ┗━━━━━━━━━━━━━━━━━━━━┛        │  │
                                            │  │                                │  │
                                            │  └────────────────────────────────┘  │
                                            │                                      │
                                            └──────────────────────────────────────┘
```

### 리소스 간 관계
1. **소스 서버** → DRS 에이전트 설치 → **DR 리전 스테이징 서브넷**으로 블록 복제
2. **IAM Role/User** → DRS 에이전트에 권한 부여
3. **DRS Replication Template** → 복제 정책 및 PIT(Point-in-Time) 스냅샷 정책 정의
4. DR 이벤트 발생 시 → **복구 인스턴스** 자동 시작 (public subnet)

## 📝 Terraform 코드 분석

### 1. Provider 설정 (providers.tf)

```hcl
# 기본 프로바이더 - 소스 리전
provider "aws" {
  region = var.source_region  # ap-northeast-2 (Seoul)

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
      Project     = "drs-test"
    }
  }
}

# DR 프로바이더 - DR 리전
provider "aws" {
  alias  = "dr"
  region = var.dr_region  # ap-northeast-1 (Tokyo)

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
      Project     = "drs-test"
    }
  }
}
```

**주요 포인트:**
- **듀얼 프로바이더 패턴**: 멀티 리전 구성을 위한 필수 패턴
- **alias 사용**: DR 리전 리소스 생성 시 `provider = aws.dr` 명시 필요
- **default_tags**: 모든 리소스에 자동으로 태그 적용 (비용 추적 용이)

> [!tip] 팁
> 멀티 리전 DR 구성 시 프로바이더 alias는 필수입니다. 각 리소스에서 `providers = { aws = aws.dr }` 형태로 명시해야 합니다.

---

### 2. 소스 환경 - VPC 및 EC2 (source.tf)

#### VPC 모듈

```hcl
# AZ 필터링 - a, c 존만 사용
data "aws_availability_zones" "source" {
  state = "available"
  filter {
    name   = "zone-name"
    values = ["${var.source_region}a", "${var.source_region}c"]
  }
}

# terraform-aws-modules/vpc/aws v5.x 사용
module "source_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "drs-source-onprem-vpc"
  cidr = var.source_vpc_cidr  # 10.100.0.0/16

  azs            = data.aws_availability_zones.source.names
  public_subnets = [
    cidrsubnet(var.source_vpc_cidr, 8, 1),  # 10.100.1.0/24
    cidrsubnet(var.source_vpc_cidr, 8, 2)   # 10.100.2.0/24
  ]

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags
}
```

**주요 속성 설명:**

| 속성 | 설명 | 값 |
|------|------|-----|
| `azs` | 가용 영역 목록 | a, c 존만 사용 (표준 패턴) |
| `public_subnets` | 퍼블릭 서브넷 CIDR | cidrsubnet 함수로 자동 계산 |
| `enable_dns_hostnames` | DNS 호스트명 활성화 | DRS 에이전트 통신에 필요 |

> [!note] 참고
> `cidrsubnet(var.source_vpc_cidr, 8, 1)` 함수는 16비트 VPC CIDR을 24비트 서브넷으로 분할합니다.

#### Security Group 모듈

```hcl
module "source_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "drs-source-server-sg"
  description = "Security group for source server (on-prem simulation)"
  vpc_id      = module.source_vpc.vpc_id

  # 인바운드 규칙
  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "HTTP for nginx verification"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "SSH access"
    }
  ]

  # 아웃바운드 규칙 (DRS 복제 트래픽 포함)
  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "All outbound"
    }
  ]
}
```

**보안 고려사항:**

> [!warning] 주의
> 프로덕션 환경에서는 SSH (22번 포트)를 `0.0.0.0/0`으로 열지 말고, 특정 관리 IP 또는 VPN CIDR로 제한해야 합니다.

> [!note] 참고
> DRS 에이전트는 HTTPS(443)를 통해 AWS DRS 서비스와 통신하므로 아웃바운드 443 포트가 열려 있어야 합니다.

#### EC2 Instance 모듈

```hcl
# 최신 Amazon Linux 2023 AMI 조회
data "aws_ami" "amazon_linux_source" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

module "source_server" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  name = "drs-source-server"

  ami                    = data.aws_ami.amazon_linux_source.id
  instance_type          = var.source_instance_type  # t3.micro
  subnet_id              = module.source_vpc.public_subnets[0]
  vpc_security_group_ids = [module.source_sg.security_group_id]

  # 퍼블릭 IP 할당 (테스트 접근용)
  associate_public_ip_address = true
  
  # IAM 인스턴스 프로파일 (DRS 에이전트 권한)
  iam_instance_profile        = aws_iam_instance_profile.source_server.name

  # User Data - nginx 설치 및 DRS 에이전트 다운로드
  user_data = base64encode(templatefile("${path.module}/scripts/source_userdata.sh", {
    dr_region = var.dr_region
  }))

  # EBS 볼륨 설정
  root_block_device = [
    {
      volume_type = "gp3"      # 최신 GP3 타입
      volume_size = 20         # 20GB
      encrypted   = true       # 암호화 활성화
    }
  ]

  tags = merge(local.common_tags, {
    Role = "source-server"
  })
}
```

**주요 구성 요소:**

| 구성 요소 | 설명 | 비고 |
|-----------|------|------|
| `user_data` | 인스턴스 부팅 시 실행되는 스크립트 | nginx 설치 + DRS 에이전트 다운로드 |
| `iam_instance_profile` | IAM 역할 연결 | DRS 에이전트가 AWS API 호출 시 필요 |
| `root_block_device` | 루트 볼륨 설정 | 암호화 필수 (보안 규정) |

---

### 3. DR 환경 - VPC 및 DRS 설정 (dr.tf)

#### DR VPC 모듈

```hcl
module "dr_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.dr  # DR 리전 프로바이더 사용
  }

  name = "drs-recovery-vpc"
  cidr = var.dr_vpc_cidr  # 10.200.0.0/16

  azs             = data.aws_availability_zones.dr.names
  public_subnets  = [
    cidrsubnet(var.dr_vpc_cidr, 8, 1),   # 복구 인스턴스용
    cidrsubnet(var.dr_vpc_cidr, 8, 2)
  ]
  private_subnets = [
    cidrsubnet(var.dr_vpc_cidr, 8, 11),  # 스테이징 서버용
    cidrsubnet(var.dr_vpc_cidr, 8, 12)
  ]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = true   # Private 서브넷 아웃바운드용
  single_nat_gateway   = true   # 비용 절감 (단일 NAT)

  tags = merge(local.common_tags, {
    Purpose = "disaster-recovery"
  })
}
```

**VPC 구성 차이점:**

| 구성 | 소스 VPC | DR VPC | 이유 |
|------|----------|--------|------|
| Public Subnet | O | O | 복구 인스턴스 배치 |
| Private Subnet | X | O | DRS 스테이징 서버 배치 (보안) |
| NAT Gateway | X | O | 스테이징 서버 아웃바운드 통신 |

> [!note] 참고
> DRS는 스테이징 서버를 Private 서브넷에 배치하는 것을 권장합니다. NAT Gateway를 통해 AWS DRS API와 통신합니다.

#### DRS 스테이징 Security Group

```hcl
module "dr_staging_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.dr
  }

  name        = "drs-staging-sg"
  description = "Security group for DRS staging area (replication servers)"
  vpc_id      = module.dr_vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 1500
      to_port     = 1500
      protocol    = "tcp"
      cidr_blocks = var.source_vpc_cidr  # 소스 VPC CIDR만 허용
      description = "DRS replication traffic from source"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "HTTPS for DRS API communication"
    }
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "All outbound"
    }
  ]

  tags = merge(local.common_tags, {
    Purpose = "drs-staging"
  })
}
```

**DRS 필수 포트:**

| 포트 | 프로토콜 | 방향 | 용도 |
|------|----------|------|------|
| 1500 | TCP | Inbound | 복제 데이터 전송 (소스 → 스테이징) |
| 443 | TCP | Outbound | DRS 서비스 API 통신 |

> [!warning] 중요
> **Port 1500**은 DRS 에이전트가 스테이징 서버로 블록 데이터를 전송하는 전용 포트입니다. 방화벽에서 이 포트가 막혀있으면 복제가 실패합니다.

#### DRS Replication Configuration Template

```hcl
resource "aws_drs_replication_configuration_template" "this" {
  provider = aws.dr

  # 보안 설정
  associate_default_security_group = false  # 기본 SG 사용 안 함
  
  # 복제 설정
  bandwidth_throttling             = 0      # 대역폭 제한 없음 (테스트)
  create_public_ip                 = true   # 스테이징 서버에 Public IP 할당
  data_plane_routing               = "PUBLIC_IP"  # 인터넷 경유
  
  # 스토리지 설정
  default_large_staging_disk_type  = "GP3"  # 스테이징 디스크 타입
  ebs_encryption                   = "DEFAULT"  # 기본 KMS 키로 암호화
  
  # 인스턴스 설정
  replication_server_instance_type = var.replication_server_instance_type  # t3.small
  staging_area_subnet_id           = module.dr_vpc.private_subnets[0]
  use_dedicated_replication_server = false  # 공유 복제 서버 사용 (비용 절감)

  # Security Group 연결
  replication_servers_security_groups_ids = [
    module.dr_staging_sg.security_group_id
  ]

  # PIT (Point-in-Time) 정책 1: 분 단위 스냅샷
  pit_policy {
    enabled            = true
    interval           = 10   # 10분마다
    retention_duration = 60   # 60분간 보관
    units              = "MINUTE"
    rule_id            = 1
  }

  # PIT 정책 2: 시간 단위 스냅샷
  pit_policy {
    enabled            = true
    interval           = 1    # 1시간마다
    retention_duration = 24   # 24시간 보관
    units              = "HOUR"
    rule_id            = 2
  }

  # PIT 정책 3: 일 단위 스냅샷
  pit_policy {
    enabled            = true
    interval           = 1    # 1일마다
    retention_duration = 7    # 7일 보관
    units              = "DAY"
    rule_id            = 3
  }

  staging_area_tags = merge(local.common_tags, {
    Purpose = "drs-staging-area"
  })

  tags = merge(local.common_tags, {
    Name = "drs-replication-template"
  })
}
```

**주요 설정 해설:**

| 설정 | 값 | 설명 |
|------|-----|------|
| `data_plane_routing` | `PUBLIC_IP` | 소스 → DR 간 인터넷 경유 복제 (VPN 불필요) |
| `use_dedicated_replication_server` | `false` | 여러 소스 서버가 하나의 복제 서버 공유 (비용 효율적) |
| `bandwidth_throttling` | `0` | 대역폭 제한 없음 (프로덕션에서는 조절 권장) |

**PIT (Point-in-Time) 정책 이해:**

```
Timeline:
├─ 10분 간격 스냅샷 (60분 보관)   ──────────┐
├─ 1시간 간격 스냅샷 (24시간 보관) ─────┐    │
└─ 1일 간격 스냅샷 (7일 보관)        │    │
                                    │    │
   세밀한 복구 ←──────────────────── 거친 복구
```

> [!tip] PIT 정책 활용
> - **10분 간격**: 최근 1시간 내 세밀한 복구 포인트 선택 가능
> - **1시간 간격**: 어제~오늘 사이 복구 포인트
> - **1일 간격**: 일주일 전까지 복구 가능
> 
> 이 계층 구조를 통해 스토리지 비용을 최적화하면서 다양한 복구 시나리오를 커버합니다.

---

### 4. IAM 권한 설정 (iam.tf)

#### 소스 서버 IAM Role

```hcl
# EC2가 Role을 assume 할 수 있도록 Trust Policy 정의
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "source_server" {
  name               = "drs-source-server-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = local.common_tags
}
```

#### DRS 에이전트 Policy

```hcl
data "aws_iam_policy_document" "drs_agent" {
  # DRS 에이전트 핵심 권한
  statement {
    sid = "DRSAgentPermissions"
    actions = [
      "drs:SendAgentMetricsForDrs",           # 메트릭 전송
      "drs:SendAgentLogsForDrs",              # 로그 전송
      "drs:GetAgentInstallationAssetsForDrs", # 설치 자산 조회
      "drs:GetAgentCommandForDrs",            # 명령 수신
      "drs:SendClientLogsForDrs",             # 클라이언트 로그
      "drs:GetAgentConfirmedResumeInfoForDrs", # 재개 정보
      "drs:GetAgentRuntimeConfigurationForDrs", # 런타임 설정
      "drs:UpdateAgentSourcePropertiesForDrs",  # 소스 속성 업데이트
      "drs:UpdateAgentReplicationInfoForDrs",   # 복제 정보 업데이트
      "drs:UpdateAgentConversionInfoForDrs",    # 변환 정보
      "drs:GetAgentReplicationInfoForDrs",      # 복제 정보 조회
      "drs:DescribeReplicationConfigurationTemplates", # 템플릿 조회
      "drs:DescribeSourceServers",            # 소스 서버 조회
      "drs:SendClientMetricsForDrs",          # 클라이언트 메트릭
      "drs:TagResource"                       # 태그 관리
    ]
    resources = ["*"]
  }

  # S3 접근 권한 (DRS가 사용하는 내부 버킷)
  statement {
    sid = "S3ReplicationAccess"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:GetBucketLocation"
    ]
    resources = [
      "arn:aws:s3:::aws-elastic-disaster-recovery-*",
      "arn:aws:s3:::aws-elastic-disaster-recovery-*/*"
    ]
  }

  # EC2 메타데이터 조회 권한
  statement {
    sid = "EC2DescribeAccess"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "drs_agent" {
  name   = "drs-agent-policy"
  policy = data.aws_iam_policy_document.drs_agent.json

  tags = local.common_tags
}

# Role에 Policy 연결
resource "aws_iam_role_policy_attachment" "drs_agent" {
  role       = aws_iam_role.source_server.name
  policy_arn = aws_iam_policy.drs_agent.arn
}
```

**권한 그룹별 설명:**

| 권한 그룹 | 용도 | 리소스 범위 |
|----------|------|-------------|
| `drs:*` | DRS 에이전트 ↔ DRS 서비스 통신 | `*` (특정 서버 지정 불가) |
| `s3:*` | 복제 데이터 임시 저장 | `aws-elastic-disaster-recovery-*` 버킷 |
| `ec2:Describe*` | 서버 메타데이터 수집 | `*` (읽기 전용) |

> [!warning] 보안 고려사항
> DRS 에이전트 권한은 `*` 리소스를 사용하지만, 모두 읽기 전용이거나 DRS 전용 API이므로 보안상 큰 위험은 없습니다. 다만 IAM User의 Access Key는 안전하게 관리해야 합니다.

#### SSM 및 Instance Profile

```hcl
# Systems Manager를 통한 원격 접속 지원
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.source_server.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance Profile 생성 (EC2에 Role 연결)
resource "aws_iam_instance_profile" "source_server" {
  name = "drs-source-server-profile"
  role = aws_iam_role.source_server.name

  tags = local.common_tags
}
```

#### DRS 에이전트 설치용 IAM User

```hcl
# 에이전트 설치 시 사용할 IAM User (Access Key 발급용)
resource "aws_iam_user" "drs_agent" {
  name = "drs-agent-user"
  tags = local.common_tags
}

resource "aws_iam_user_policy_attachment" "drs_agent" {
  user       = aws_iam_user.drs_agent.name
  policy_arn = aws_iam_policy.drs_agent.arn
}

# Access Key 생성
resource "aws_iam_access_key" "drs_agent" {
  user = aws_iam_user.drs_agent.name
}
```

> [!note] IAM User vs IAM Role
> - **IAM Role**: EC2 인스턴스에 연결 (Instance Profile 사용)
> - **IAM User + Access Key**: DRS 에이전트 설치 시 인증에 사용
> 
> 에이전트 설치 과정에서 Access Key를 입력하면, 이후 에이전트는 Instance Profile의 Role을 사용합니다.

---

### 5. User Data 스크립트 (scripts/source_userdata.sh)

```bash
#!/bin/bash
set -euxo pipefail

# nginx 설치 및 시작
dnf install -y nginx
systemctl enable nginx
systemctl start nginx

# 커스텀 HTML 페이지 생성 (DR 복구 확인용)
cat > /usr/share/nginx/html/index.html <<'HTML'
<!DOCTYPE html>
<html>
<head><title>DRS Source Server</title></head>
<body>
<h1>AWS DRS Test - Source Server</h1>
<p>Region: ap-northeast-2 (Seoul)</p>
<p>Role: On-premises simulation</p>
<p>Hostname: HOSTNAME_PLACEHOLDER</p>
<p>Timestamp: TIMESTAMP_PLACEHOLDER</p>
</body>
</html>
HTML

# Placeholder 치환
HOSTNAME=$(hostname)
TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
sed -i "s/HOSTNAME_PLACEHOLDER/$HOSTNAME/" /usr/share/nginx/html/index.html
sed -i "s/TIMESTAMP_PLACEHOLDER/$TIMESTAMP/" /usr/share/nginx/html/index.html

# DRS 에이전트 사전 요구사항 설치
dnf install -y python3 python3-pip wget

# DRS 에이전트 설치 파일 다운로드 (수동 실행 대기)
wget -O /tmp/aws-replication-installer-init \
  "https://aws-elastic-disaster-recovery-${dr_region}.s3.${dr_region}.amazonaws.com/latest/linux/aws-replication-installer-init"
chmod +x /tmp/aws-replication-installer-init

echo "=== Source server setup complete. DRS agent installer downloaded to /tmp/ ==="
```

**스크립트 동작 흐름:**

1. nginx 설치 및 자동 시작 설정
2. 호스트명 + 타임스탬프가 포함된 HTML 페이지 생성
3. Python3 설치 (DRS 에이전트 의존성)
4. DRS 에이전트 설치 파일 다운로드 (실행은 terraform apply 이후 수동)

> [!tip] 왜 에이전트를 자동 설치하지 않나요?
> DRS 에이전트 설치 시 **Access Key 입력**이 필요하므로 User Data에서 자동화하기 어렵습니다. Terraform 출력값에서 Access Key를 확인한 후 수동으로 설치하는 것이 안전합니다.

---

### 6. Outputs (outputs.tf)

```hcl
# 소스 서버 정보
output "source_server_public_ip" {
  description = "Public IP of source server (on-prem simulation)"
  value       = module.source_server.public_ip
}

output "source_server_instance_id" {
  description = "Instance ID of source server"
  value       = module.source_server.id
}

# DR 환경 정보
output "dr_staging_subnet_id" {
  description = "DR staging subnet ID"
  value       = module.dr_vpc.private_subnets[0]
}

output "dr_recovery_subnet_id" {
  description = "DR recovery subnet ID (public)"
  value       = module.dr_vpc.public_subnets[0]
}

# DRS 에이전트 자격 증명
output "drs_agent_access_key_id" {
  description = "Access Key ID for DRS agent"
  value       = aws_iam_access_key.drs_agent.id
}

output "drs_agent_secret_access_key" {
  description = "Secret Access Key for DRS agent (sensitive)"
  value       = aws_iam_access_key.drs_agent.secret
  sensitive   = true  # terraform output 시 기본적으로 숨김
}

# 검증 URL
output "source_nginx_url" {
  description = "URL to verify nginx on source server"
  value       = "http://${module.source_server.public_ip}"
}

# 에이전트 설치 명령어 가이드
output "agent_install_command" {
  description = "Command to install DRS agent on source server"
  value       = <<-EOT
    # SSH into source server, then run:
    sudo su -
    wget -O ./aws-replication-installer-init https://aws-elastic-disaster-recovery-${var.dr_region}.s3.${var.dr_region}.amazonaws.com/latest/linux/aws-replication-installer-init
    chmod +x aws-replication-installer-init
    ./aws-replication-installer-init --region ${var.dr_region} --no-prompt
  EOT
}
```

**유용한 Output 활용 예시:**

```bash
# 소스 서버 Public IP 확인
terraform output source_server_public_ip

# nginx 접속 테스트
curl $(terraform output -raw source_nginx_url)

# Secret Access Key 확인 (에이전트 설치 시 필요)
terraform output -raw drs_agent_secret_access_key

# SSM으로 소스 서버 접속
aws ssm start-session --target $(terraform output -raw source_server_instance_id) --region ap-northeast-2
```

---

## 🔑 핵심 포인트

### DRS 작동 원리

1. **에이전트 설치 단계**
   - 소스 서버에 DRS 에이전트 설치
   - 에이전트가 디스크 블록 읽기 시작
   - DR 리전 스테이징 서브넷으로 초기 전체 복제

2. **지속적 복제 (Continuous Replication)**
   - 블록 변경사항만 실시간 전송 (Port 1500)
   - 스테이징 서버가 EBS 스냅샷으로 저장
   - PIT 정책에 따라 주기적으로 스냅샷 생성

3. **DR 이벤트 발생 시**
   - DR Drill 또는 실제 Failover 명령 실행
   - 스테이징 데이터에서 복구 인스턴스 생성
   - 복구 인스턴스가 Public 서브넷에서 시작됨
   - 원본 소스 서버와 동일한 상태로 복구 완료

### RPO/RTO 이해

| 메트릭 | 값 | 설명 |
|--------|-----|------|
| **RPO** | 초 단위 | 데이터 손실 허용 범위 - DRS는 거의 실시간 복제 |
| **RTO** | 분 단위 | 복구 시간 목표 - 인스턴스 부팅 시간 정도 |

> [!note] 참고
> 전통적인 백업/복원 방식은 RPO가 시간~일 단위, RTO가 시간~일 단위인 반면, DRS는 훨씬 짧은 시간을 제공합니다.

### 비용 최적화 전략

**평상시 (복제 중)**
- 스테이징 서버: t3.small (1대) - 약 $15/월
- EBS 스냅샷 스토리지 - 데이터 크기에 비례
- 데이터 전송: 리전 간 전송 비용 발생

**DR 이벤트 시**
- 복구 인스턴스: 원본과 동일한 인스턴스 타입으로 시작
- 프로덕션급 비용 발생 (일시적)

> [!tip] 비용 절감 팁
> - `use_dedicated_replication_server = false`: 여러 소스 서버가 하나의 복제 서버 공유
> - `single_nat_gateway = true`: NAT Gateway를 1개만 사용
> - DR 드릴 테스트 후 즉시 복구 인스턴스 종료

---

## 💡 실습 절차

### 1단계: 인프라 배포

```bash
cd /home/ec2-user/claude-code/626635430480-fnf/AWS_Disaster_Recovery

# Terraform 초기화
terraform init

# 배포 계획 확인
terraform plan

# 인프라 생성
terraform apply -auto-approve

# 출력값 확인
terraform output
```

**예상 소요 시간:** 약 5-7분

---

### 2단계: DRS 서비스 초기화 및 에이전트 설치

```bash
# DRS 서비스 초기화 (DR 리전에서 최초 1회)
./scripts/01_init_drs.sh
```

**스크립트 동작:**
1. DRS 서비스 초기화 (`aws drs initialize-service`)
2. DRS 에이전트 Access Key 출력
3. SSM 접속 명령어 출력

**수동 작업 - 소스 서버에 에이전트 설치:**

```bash
# 1. SSM으로 소스 서버 접속
SOURCE_INSTANCE_ID=$(terraform output -raw source_server_instance_id)
aws ssm start-session --target $SOURCE_INSTANCE_ID --region ap-northeast-2

# 2. 소스 서버 내부에서 실행
sudo su -
cd /tmp
./aws-replication-installer-init --region ap-northeast-1 --no-prompt

# 3. 프롬프트가 나오면 Access Key 입력
# Access Key ID: (terraform output에서 확인)
# Secret Access Key: (terraform output -raw drs_agent_secret_access_key)
```

> [!note] 에이전트 설치 과정
> 에이전트 설치는 약 2-3분 소요되며, 설치 후 자동으로 초기 복제를 시작합니다.

---

### 3단계: 복제 상태 확인

```bash
# 소스 서버 목록 및 복제 상태 확인
aws drs describe-source-servers --region ap-northeast-1

# 출력 예시:
# {
#   "items": [
#     {
#       "sourceServerID": "s-1234567890abcdef0",
#       "dataReplicationInfo": {
#         "dataReplicationState": "INITIATING" or "CONTINUOUS_REPLICATION",
#         "lagDuration": "PT0S"  # 복제 지연 시간
#       }
#     }
#   ]
# }
```

**복제 상태 단계:**

| 상태 | 설명 | 예상 시간 |
|------|------|-----------|
| `INITIATING` | 초기 복제 시작 중 | 즉시 |
| `INITIAL_SYNC` | 전체 디스크 복제 중 | 10-30분 (디스크 크기에 따라) |
| `CONTINUOUS_REPLICATION` | 지속적 복제 상태 | - |

> [!warning] 중요
> DR 드릴 또는 Failover를 실행하려면 반드시 `CONTINUOUS_REPLICATION` 상태가 되어야 합니다.

---

### 4단계: DR 드릴 실행 (테스트 복구)

```bash
# DR 드릴 실행 (비파괴 테스트)
./scripts/02_dr_drill.sh
```

**스크립트 동작:**
1. 소스 서버 ID 자동 조회
2. 복제 상태 확인
3. `aws drs start-recovery --is-drill` 명령 실행
4. Job ID 출력

**DR 드릴 vs 실제 Failover:**

| 항목 | DR Drill | Failover |
|------|----------|----------|
| 소스 서버 영향 | 없음 (복제 계속) | 있음 (복제 중단 가능) |
| 용도 | 정기 테스트 | 실제 재해 복구 |
| 명령어 | `--is-drill` 옵션 | 옵션 없음 |

**복구 진행 상황 모니터링:**

```bash
# Job 상태 확인
JOB_ID=<출력된 Job ID>
aws drs describe-jobs --region ap-northeast-1 --filters jobIDs=$JOB_ID

# 복구 인스턴스 확인
aws drs describe-recovery-instances --region ap-northeast-1
```

**예상 소요 시간:** 약 5-10분

---

### 5단계: 복구 인스턴스 검증

```bash
# 복구 인스턴스 Public IP 확인
aws ec2 describe-instances \
  --region ap-northeast-1 \
  --filters "Name=tag:Name,Values=*recovery*" \
  --query "Reservations[].Instances[].[InstanceId,PublicIpAddress,State.Name]" \
  --output table

# nginx 동작 확인
RECOVERY_IP=<복구 인스턴스 Public IP>
curl http://$RECOVERY_IP

# 기대 결과:
# <h1>AWS DRS Test - Source Server</h1>
# <p>Region: ap-northeast-2 (Seoul)</p>
# <p>Hostname: ip-10-100-1-xxx</p>
```

**검증 체크리스트:**

- [ ] 복구 인스턴스가 DR 리전(Tokyo)에서 정상 시작됨
- [ ] nginx 서비스가 자동으로 실행 중
- [ ] HTML 콘텐츠가 소스 서버와 동일함
- [ ] 호스트명/타임스탬프가 원본 소스 서버의 것과 일치함

> [!note] 호스트명 차이
> 복구 인스턴스의 IP는 DR VPC(10.200.x.x)로 변경되지만, 디스크 내용(nginx HTML 파일)은 소스 서버의 타임스탬프를 그대로 유지합니다.

---

### 6단계: DR 드릴 정리

```bash
# 복구 인스턴스 종료
RECOVERY_INSTANCE_ID=<복구 인스턴스 ID>
aws drs terminate-recovery-instances \
  --region ap-northeast-1 \
  --recovery-instance-ids $RECOVERY_INSTANCE_ID

# 또는 EC2 콘솔에서 인스턴스 종료
```

> [!tip] 비용 절감
> DR 드릴 검증이 끝나면 즉시 복구 인스턴스를 종료하세요. 소스 서버의 복제는 계속 유지되므로 언제든지 다시 드릴을 실행할 수 있습니다.

---

### 7단계: (선택) 실제 Failover 테스트

```bash
# 실제 Failover 실행 (주의: 프로덕션 시뮬레이션)
./scripts/03_failover.sh
```

> [!warning] 주의
> 실제 Failover는 소스 서버의 복제를 중단시킬 수 있습니다. 테스트 환경에서만 실행하세요.

**Failover 후 작업:**
1. DNS/Route53를 복구 인스턴스 IP로 변경
2. 애플리케이션 연결 테스트
3. 소스 환경 복구 후 Failback 준비

---

### 8단계: (선택) Failback

```bash
# Failback 가이드 출력
./scripts/04_failback.sh
```

**Failback 절차:**
1. 소스 환경이 복구되었는지 확인
2. DR → 소스 방향으로 역방향 복제 시작
3. 복제 완료 후 소스 환경으로 Cutover
4. DRS 소스 서버 연결 해제

---

### 9단계: 전체 정리

```bash
# Terraform으로 모든 리소스 삭제
terraform destroy -auto-approve

# 주의: DRS 소스 서버는 수동 삭제 필요
aws drs delete-source-server \
  --region ap-northeast-1 \
  --source-server-id <SOURCE_SERVER_ID>
```

**삭제 순서:**
1. 복구 인스턴스 종료 (있는 경우)
2. DRS 소스 서버 연결 해제
3. `terraform destroy` 실행
4. DRS 서비스는 유지됨 (다음 테스트에 재사용 가능)

---

## 📚 주요 개념 정리

### DRS 용어 사전

| 용어 | 영문 | 설명 |
|------|------|------|
| 소스 서버 | Source Server | 복제 대상 서버 (온프레미스 또는 다른 클라우드) |
| 스테이징 서버 | Staging Server | DR 리전에서 복제 데이터를 받는 경량 서버 |
| 복구 인스턴스 | Recovery Instance | DR 이벤트 시 생성되는 프로덕션급 인스턴스 |
| 복제 템플릿 | Replication Template | 복제 설정 및 PIT 정책을 정의한 템플릿 |
| PIT | Point-in-Time | 특정 시점 스냅샷 - 과거 시점으로 복구 가능 |
| DR 드릴 | Drill | 비파괴적 복구 테스트 (소스에 영향 없음) |
| Failover | Failover | 실제 재해 복구 (소스 → DR 전환) |
| Failback | Failback | DR → 소스로 역전환 |

### AWS 서비스 용어

| 용어 | 설명 |
|------|------|
| VPC Peering | 두 VPC 간 직접 통신 (이 실습에서는 미사용) |
| NAT Gateway | Private 서브넷에서 인터넷 아웃바운드 통신 제공 |
| Instance Profile | EC2 인스턴스에 IAM Role을 연결하는 매개체 |
| User Data | EC2 인스턴스 최초 부팅 시 실행되는 스크립트 |
| EBS Snapshot | EBS 볼륨의 특정 시점 백업 |

---

## 🔗 관련 링크 및 리소스

### 공식 문서
- [AWS DRS 공식 문서](https://docs.aws.amazon.com/drs/latest/userguide/what-is-drs.html)
- [DRS 에이전트 설치 가이드](https://docs.aws.amazon.com/drs/latest/userguide/agent-installation.html)
- [terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest)
- [terraform-aws-modules/ec2-instance](https://registry.terraform.io/modules/terraform-aws-modules/ec2-instance/aws/latest)

### 연관 주제
- [[AWS Backup 서비스]] - RTO/RPO 요구사항이 낮을 때 대안
- [[Route53 Failover 라우팅]] - DR 환경과 함께 사용하는 DNS 기반 Failover
- [[VPC Peering vs Transit Gateway]] - 프로덕션 DR 환경에서 Private 연결 구성
- [[AWS Site-to-Site VPN]] - 온프레미스와 AWS 간 Private 복제

### 베스트 프랙티스 가이드
- [AWS 재해 복구 백서](https://docs.aws.amazon.com/whitepapers/latest/disaster-recovery-workloads-on-aws/disaster-recovery-workloads-on-aws.html)
- [멀티 리전 아키텍처 설계](https://aws.amazon.com/blogs/architecture/)

---

## 🎯 학습 점검 체크리스트

완료한 항목을 체크하세요:

### 개념 이해
- [ ] DRS의 RPO/RTO 개념을 이해했다
- [ ] 에이전트 기반 복제와 블록 레벨 복제의 차이를 안다
- [ ] 스테이징 서버와 복구 인스턴스의 역할 차이를 안다
- [ ] PIT 정책의 3단계 계층 구조를 이해했다
- [ ] DR 드릴과 실제 Failover의 차이를 안다

### 실습 수행
- [ ] 듀얼 프로바이더로 멀티 리전 구성을 했다
- [ ] DRS 에이전트를 소스 서버에 설치했다
- [ ] 복제 상태가 CONTINUOUS_REPLICATION에 도달했다
- [ ] DR 드릴을 성공적으로 실행했다
- [ ] 복구 인스턴스에서 nginx가 정상 동작함을 확인했다
- [ ] 리소스를 정리(terraform destroy)했다

### Terraform 기술
- [ ] terraform-aws-modules 사용 방법을 익혔다
- [ ] `cidrsubnet` 함수로 서브넷 CIDR을 자동 계산했다
- [ ] `providers` 블록으로 멀티 리전 리소스를 관리했다
- [ ] `sensitive = true`로 민감한 출력값을 보호했다
- [ ] User Data에 `templatefile` 함수를 사용했다

### 보안 고려사항
- [ ] IAM 최소 권한 원칙을 적용했다 (DRS 전용 Policy)
- [ ] EBS 볼륨 암호화를 활성화했다
- [ ] Security Group에서 필수 포트(1500, 443)만 개방했다
- [ ] Access Key는 Terraform State에 저장되므로 State 파일 보호가 중요함을 안다

---

## 📌 트러블슈팅

### 문제 1: 복제 상태가 INITIATING에서 멈춤

**증상:**
```bash
aws drs describe-source-servers --region ap-northeast-1
# dataReplicationState: "INITIATING" (계속 유지됨)
```

**원인:**
- Port 1500이 Security Group에서 막혀있음
- 소스 서버에서 DR 리전으로 아웃바운드 443 차단

**해결:**
```bash
# DR Staging SG 확인
aws ec2 describe-security-groups \
  --region ap-northeast-1 \
  --filters "Name=group-name,Values=drs-staging-sg" \
  --query 'SecurityGroups[].IpPermissions'

# Inbound 1500 포트가 소스 VPC CIDR(10.100.0.0/16)에서 허용되는지 확인
```

---

### 문제 2: DR 드릴 시 복구 인스턴스가 시작되지 않음

**증상:**
```bash
aws drs describe-jobs --region ap-northeast-1
# Status: "FAILED"
# Error: "Insufficient capacity" 또는 "Invalid subnet"
```

**원인:**
- DR VPC의 Public 서브넷이 설정되지 않음
- 복구 서브넷에 가용한 IP가 없음
- 선택한 인스턴스 타입이 해당 AZ에서 지원되지 않음

**해결:**
```bash
# DR VPC Public 서브넷 확인
terraform output dr_recovery_subnet_id

# 서브넷 가용 IP 확인
aws ec2 describe-subnets \
  --region ap-northeast-1 \
  --subnet-ids <SUBNET_ID> \
  --query 'Subnets[].AvailableIpAddressCount'
```

---

### 문제 3: Access Key 입력 후 에이전트 설치 실패

**증상:**
```bash
./aws-replication-installer-init --region ap-northeast-1 --no-prompt
# Error: "InvalidAccessKeyId" or "SignatureDoesNotMatch"
```

**원인:**
- Access Key가 잘못 복사됨 (공백 포함)
- IAM User에 Policy가 연결되지 않음
- 리전이 잘못 지정됨

**해결:**
```bash
# Access Key 다시 확인 (공백 없이)
terraform output -raw drs_agent_access_key_id
terraform output -raw drs_agent_secret_access_key

# IAM User Policy 확인
aws iam list-attached-user-policies --user-name drs-agent-user

# 올바른 리전 지정 확인
# --region ap-northeast-1 (DR 리전)
```

---

### 문제 4: Terraform Destroy 시 VPC 삭제 실패

**증상:**
```bash
terraform destroy
# Error: DependencyViolation - resource has a dependent object
```

**원인:**
- DRS가 생성한 ENI(네트워크 인터페이스)가 남아있음
- 복구 인스턴스가 종료되지 않음

**해결:**
```bash
# 1. DRS 소스 서버 연결 해제
SOURCE_SERVER_ID=$(aws drs describe-source-servers --region ap-northeast-1 --query 'items[0].sourceServerID' --output text)
aws drs disconnect-source-server --region ap-northeast-1 --source-server-id $SOURCE_SERVER_ID

# 2. 복구 인스턴스 종료
aws drs describe-recovery-instances --region ap-northeast-1
aws drs terminate-recovery-instances --region ap-northeast-1 --recovery-instance-ids <ID>

# 3. ENI 수동 삭제 (필요시)
aws ec2 describe-network-interfaces --region ap-northeast-1 --filters "Name=vpc-id,Values=<VPC_ID>"
aws ec2 delete-network-interface --region ap-northeast-1 --network-interface-id <ENI_ID>

# 4. 다시 시도
terraform destroy
```

---

## 🚀 다음 단계

이 실습을 완료했다면 다음 주제로 넘어가세요:

1. **[[VPC Peering을 활용한 Private DR 복제]]**
   - 인터넷을 경유하지 않는 Private 복제 구성
   - 보안 강화 및 데이터 전송 비용 절감

2. **[[Route53 Health Check + Failover 라우팅]]**
   - DNS 기반 자동 Failover
   - DRS와 결합한 완전 자동화 DR 시스템

3. **[[AWS Backup과 DRS 비교]]**
   - RTO/RPO 요구사항에 따른 적절한 서비스 선택
   - 비용 대비 효과 분석

4. **[[멀티 리전 Application Load Balancer]]**
   - Global Accelerator를 활용한 애플리케이션 레벨 DR
   - DRS와 함께 사용하는 패턴

---

## 💬 학습 노트

> 이 섹션은 개인 학습 메모용입니다. 실습 중 배운 점이나 주의할 점을 자유롭게 기록하세요.

```
예시:
- DRS 에이전트 설치 시 Python3 의존성 필수
- Port 1500은 복제 전용, 443은 제어 플레인
- PIT 정책은 3단계로 나누면 스토리지 비용 최적화
- DR 드릴은 프로덕션 영향 없이 언제든 테스트 가능
- terraform-aws-modules는 best practice가 내장되어 있어 편리함
```

---

**문서 최종 업데이트:** 2026-05-07  
**실습 난이도:** ⭐⭐⭐ (중급)  
**예상 소요 시간:** 2-3시간 (복제 대기 시간 포함)

---

> 생성: Claude Code (Terraform + AWS 전문 어시스턴트)
