# =============================================================================
# VPC Endpoints (DR Region) - Private access to AWS services
# =============================================================================

# S3 Gateway Endpoint - for DRS agent binary download and replication data
resource "aws_vpc_endpoint" "dr_s3" {
  provider     = aws.dr
  vpc_id       = module.dr_vpc.vpc_id
  service_name = "com.amazonaws.${var.dr_region}.s3"

  route_table_ids = concat(
    module.dr_vpc.private_route_table_ids,
    module.dr_vpc.public_route_table_ids
  )

  tags = merge(local.common_tags, {
    Name = "drs-dr-s3-endpoint"
  })
}

# DRS Interface Endpoint - for DRS API communication
resource "aws_vpc_endpoint" "dr_drs" {
  provider            = aws.dr
  vpc_id              = module.dr_vpc.vpc_id
  service_name        = "com.amazonaws.${var.dr_region}.drs"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = module.dr_vpc.private_subnets
  security_group_ids = [module.dr_staging_sg.security_group_id]

  tags = merge(local.common_tags, {
    Name = "drs-dr-drs-endpoint"
  })
}

# EC2 Interface Endpoint - DRS replication server needs EC2 API access
resource "aws_vpc_endpoint" "dr_ec2" {
  provider            = aws.dr
  vpc_id              = module.dr_vpc.vpc_id
  service_name        = "com.amazonaws.${var.dr_region}.ec2"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = module.dr_vpc.private_subnets
  security_group_ids = [module.dr_staging_sg.security_group_id]

  tags = merge(local.common_tags, {
    Name = "drs-dr-ec2-endpoint"
  })
}
