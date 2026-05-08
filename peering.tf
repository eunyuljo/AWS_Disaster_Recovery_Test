# =============================================================================
# VPC Peering (Source ↔ DR) - VPN/DX Alternative for Test Environment
# =============================================================================

resource "aws_vpc_peering_connection" "source_to_dr" {
  vpc_id      = module.source_vpc.vpc_id
  peer_vpc_id = module.dr_vpc.vpc_id
  peer_region = var.dr_region
  auto_accept = false

  tags = merge(local.common_tags, {
    Name = "drs-vpn-alternative-peering"
  })
}

resource "aws_vpc_peering_connection_accepter" "dr_accept" {
  provider                  = aws.dr
  vpc_peering_connection_id = aws_vpc_peering_connection.source_to_dr.id
  auto_accept               = true

  tags = merge(local.common_tags, {
    Name = "drs-vpn-alternative-peering"
  })
}

# Source VPC → DR VPC route
resource "aws_route" "source_to_dr" {
  count                     = length(module.source_vpc.public_route_table_ids)
  route_table_id            = module.source_vpc.public_route_table_ids[count.index]
  destination_cidr_block    = var.dr_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.source_to_dr.id
}

# DR VPC → Source VPC route (private subnets)
resource "aws_route" "dr_private_to_source" {
  provider                  = aws.dr
  count                     = length(module.dr_vpc.private_route_table_ids)
  route_table_id            = module.dr_vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.source_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.source_to_dr.id
}

# DR VPC → Source VPC route (public subnets)
resource "aws_route" "dr_public_to_source" {
  provider                  = aws.dr
  count                     = length(module.dr_vpc.public_route_table_ids)
  route_table_id            = module.dr_vpc.public_route_table_ids[count.index]
  destination_cidr_block    = var.source_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.source_to_dr.id
}
