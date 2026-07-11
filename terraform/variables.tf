variable "aws_region" {
  description = "AWS region to deploy the lab into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "EC2 instance type. SigNoz (ClickHouse + collector + UI) wants at least 2 vCPU / 8 GiB."
  type        = string
  default     = "t3.large"
}

variable "key_name" {
  description = "Name of an existing EC2 key pair used for SSH access."
  type        = string
  default     = "My-key"
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the lab (SSH, SigNoz UI, OTLP). Leave null to auto-detect your current public IP."
  type        = string
  default     = null
}

variable "root_volume_gb" {
  description = "Root EBS volume size in GiB. ClickHouse data lives here."
  type        = number
  default     = 40
}

variable "open_mcp_port" {
  description = "Also open port 8000 (SigNoz MCP server) to allowed_cidr. Off by default; use an SSH tunnel instead."
  type        = bool
  default     = false
}
