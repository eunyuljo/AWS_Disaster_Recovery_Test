locals {
  common_tags = merge(var.common_tags, {
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
    Project     = "drs-test"
  })
}
