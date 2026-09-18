variable "project_name" {
  type = string
}

variable "sns_email_address" {
  description = "Email address for server-ready notifications. Leave empty to skip creating the SNS topic/subscription entirely."
  type        = string
  default     = ""
}
