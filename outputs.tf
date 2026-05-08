# =============================================================================
# Outputs
# =============================================================================

# Source Environment
output "source_server_public_ip" {
  description = "Public IP of source server (on-prem simulation)"
  value       = module.source_server.public_ip
}

output "source_server_instance_id" {
  description = "Instance ID of source server"
  value       = module.source_server.id
}

output "source_vpc_id" {
  description = "Source VPC ID"
  value       = module.source_vpc.vpc_id
}

# DR Environment
output "dr_vpc_id" {
  description = "DR VPC ID"
  value       = module.dr_vpc.vpc_id
}

output "dr_staging_subnet_id" {
  description = "DR staging subnet ID"
  value       = module.dr_vpc.private_subnets[0]
}

output "dr_recovery_subnet_id" {
  description = "DR recovery subnet ID (public)"
  value       = module.dr_vpc.public_subnets[0]
}

output "drs_replication_template_id" {
  description = "DRS Replication Configuration Template ID"
  value       = aws_drs_replication_configuration_template.this.id
}

# DRS Agent Installation Info
output "drs_agent_access_key_id" {
  description = "Access Key ID for DRS agent"
  value       = aws_iam_access_key.drs_agent.id
}

output "drs_agent_secret_access_key" {
  description = "Secret Access Key for DRS agent (sensitive)"
  value       = aws_iam_access_key.drs_agent.secret
  sensitive   = true
}

# Verification URLs
output "source_nginx_url" {
  description = "URL to verify nginx on source server"
  value       = "http://${module.source_server.public_ip}"
}

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
