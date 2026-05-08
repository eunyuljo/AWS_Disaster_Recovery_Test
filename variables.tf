variable "source_region" {
  description = "Source region (simulated on-premises)"
  type        = string
  default     = "ap-northeast-2"
}

variable "dr_region" {
  description = "DR target region"
  type        = string
  default     = "ap-northeast-1"
}

variable "source_vpc_cidr" {
  description = "CIDR for source VPC"
  type        = string
  default     = "10.100.0.0/16"
}

variable "dr_vpc_cidr" {
  description = "CIDR for DR VPC"
  type        = string
  default     = "10.200.0.0/16"
}

variable "source_instance_type" {
  description = "Instance type for source EC2 (on-prem simulation)"
  type        = string
  default     = "t3.micro"
}

variable "replication_server_instance_type" {
  description = "Instance type for DRS replication server"
  type        = string
  default     = "t3.small"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dr-test"
}

variable "owner" {
  description = "Resource owner"
  type        = string
  default     = "fnf-team"
}

variable "common_tags" {
  description = "Common tags for all resources"
  type        = map(string)
  default     = {}
}
