# =============================================================================
# DR Region (ap-northeast-1) - DRS Target Environment
# =============================================================================

data "aws_availability_zones" "dr" {
  provider = aws.dr
  state    = "available"
  filter {
    name   = "zone-name"
    values = ["${var.dr_region}a", "${var.dr_region}c"]
  }
}

# Terraform Registry: terraform-aws-modules/vpc/aws v5.x (latest 6.6.1)
module "dr_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.dr
  }

  name = "drs-recovery-vpc"
  cidr = var.dr_vpc_cidr

  azs             = data.aws_availability_zones.dr.names
  public_subnets  = [cidrsubnet(var.dr_vpc_cidr, 8, 1), cidrsubnet(var.dr_vpc_cidr, 8, 2)]
  private_subnets = [cidrsubnet(var.dr_vpc_cidr, 8, 11), cidrsubnet(var.dr_vpc_cidr, 8, 12)]

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_nat_gateway   = true
  single_nat_gateway   = true

  tags = merge(local.common_tags, {
    Purpose = "disaster-recovery"
  })
}

# Staging subnet security group - replication traffic
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
      cidr_blocks = var.source_vpc_cidr
      description = "DRS replication traffic from source (via peering)"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.dr_vpc_cidr
      description = "HTTPS for VPC Endpoints (DRS/EC2 API)"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = var.source_vpc_cidr
      description = "HTTPS from source (via peering)"
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

# Recovery instance security group
module "dr_recovery_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  providers = {
    aws = aws.dr
  }

  name        = "drs-recovery-sg"
  description = "Security group for recovered instances"
  vpc_id      = module.dr_vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "HTTP for recovery verification"
    },
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = "0.0.0.0/0"
      description = "SSH access"
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
    Purpose = "drs-recovery"
  })
}

# AWS DRS: Replication Configuration Template
# AWS Knowledge: DRS requires staging subnet, security groups, EBS encryption, PIT policy
resource "aws_drs_replication_configuration_template" "this" {
  provider = aws.dr

  associate_default_security_group = false
  bandwidth_throttling             = 0 # No throttling for test
  create_public_ip                 = false
  data_plane_routing               = "PRIVATE_IP"
  default_large_staging_disk_type  = "GP3"
  ebs_encryption                   = "DEFAULT"
  replication_server_instance_type = var.replication_server_instance_type
  staging_area_subnet_id           = module.dr_vpc.private_subnets[0]
  use_dedicated_replication_server = false

  replication_servers_security_groups_ids = [
    module.dr_staging_sg.security_group_id
  ]

  pit_policy {
    enabled            = true
    interval           = 10
    retention_duration = 60
    units              = "MINUTE"
    rule_id            = 1
  }

  pit_policy {
    enabled            = true
    interval           = 1
    retention_duration = 24
    units              = "HOUR"
    rule_id            = 2
  }

  pit_policy {
    enabled            = true
    interval           = 1
    retention_duration = 7
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
