variable "vpc_id" {
  description = "Existing VPC ID to reuse. Leave empty to create a new dedicated VPC with public subnets only and no NAT gateways (matches the CDK original's `natGateways: 0`, so it costs nothing extra either way)."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "Used to name and tag the created VPC/subnets. Ignored when vpc_id is set."
  type        = string
}

variable "max_azs" {
  description = "Maximum number of availability zones to spread public subnets across when creating a new VPC."
  type        = number
  default     = 3
}
