variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  description = "Subnets to create EFS mount targets in — one per subnet."
  type        = list(string)
}

variable "project_name" {
  type = string
}
