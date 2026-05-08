# =============================================================================
# Source Region (ap-northeast-2) - Simulated On-Premises Environment
# =============================================================================

data "aws_availability_zones" "source" {
  state = "available"
  filter {
    name   = "zone-name"
    values = ["${var.source_region}a", "${var.source_region}c"]
  }
}

data "aws_ami" "amazon_linux_source" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Terraform Registry: terraform-aws-modules/vpc/aws v5.x (latest 6.6.1)
module "source_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "drs-source-onprem-vpc"
  cidr = var.source_vpc_cidr

  azs            = data.aws_availability_zones.source.names
  public_subnets = [cidrsubnet(var.source_vpc_cidr, 8, 1), cidrsubnet(var.source_vpc_cidr, 8, 2)]

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags
}

# Terraform Registry: terraform-aws-modules/security-group/aws v5.x (latest 5.3.1)
module "source_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "drs-source-server-sg"
  description = "Security group for source server (on-prem simulation)"
  vpc_id      = module.source_vpc.vpc_id

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

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = "0.0.0.0/0"
      description = "All outbound"
    }
  ]

  tags = local.common_tags
}

# Terraform Registry: terraform-aws-modules/ec2-instance/aws v5.x (latest 6.4.0)
module "source_server" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  name = "drs-source-server"

  ami                    = data.aws_ami.amazon_linux_source.id
  instance_type          = var.source_instance_type
  subnet_id              = module.source_vpc.public_subnets[0]
  vpc_security_group_ids = [module.source_sg.security_group_id]

  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.source_server.name

  user_data = base64encode(templatefile("${path.module}/scripts/source_userdata.sh", {
    dr_region = var.dr_region
  }))

  root_block_device = [
    {
      volume_type = "gp3"
      volume_size = 30
      encrypted   = true
    }
  ]

  tags = merge(local.common_tags, {
    Role = "source-server"
  })
}
