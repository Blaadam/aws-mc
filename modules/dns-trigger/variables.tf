variable "domain_name" {
  type = string
}

variable "subdomain_part" {
  type = string
}

variable "aws_region" {
  description = "Region the ECS cluster/service actually run in — passed to the launcher Lambda so it calls the ECS API in the right place. This module's own resources (hosted zone, query log, Lambda) run wherever the caller's default provider points, which must be us-east-1 (Route 53 query logging requires the CloudWatch Logs destination to be there)."
  type        = string
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "log_retention_days" {
  type    = number
  default = 3
}
