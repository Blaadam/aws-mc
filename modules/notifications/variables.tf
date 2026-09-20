variable "project_name" {
  type = string
}

variable "sns_email_address" {
  description = "Email address for server-ready notifications. Leave empty to skip creating the SNS topic/subscription entirely."
  type        = string
  default     = ""
}

variable "discord_webhook_url" {
  description = "Discord webhook URL to relay start/stop notifications to. Leave empty to skip creating the forwarder Lambda entirely — independent of sns_email_address, so Discord notifications work with or without an email subscription."
  type        = string
  default     = ""
  sensitive   = true
}

variable "discord_message" {
  description = "Optional text prepended above the watchdog's actual start/stop message in the Discord post (e.g. an @everyone ping). Leave empty to relay the watchdog's message unmodified. No effect when discord_webhook_url is empty."
  type        = string
  default     = ""
}

variable "log_retention_days" {
  type    = number
  default = 3
}
