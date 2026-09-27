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

variable "start_api_url" {
  description = "Ready-to-use start URL (dns-trigger's start_api_url output, empty when enable_start_api is false). When set, the Discord shutdown notification gets a link-style \"Restart server\" button pointing at it. No effect when discord_webhook_url is empty."
  type        = string
  default     = ""
  sensitive   = true
}

variable "icon_url" {
  description = "Server icon URL (minecraft_image_env_vars[\"ICON\"], if set) — shown as a thumbnail on the Discord notification card. No effect when discord_webhook_url is empty."
  type        = string
  default     = ""
}

variable "ecs_cluster_arn" {
  description = "Cluster the Minecraft service runs in — scopes the crash-notification EventBridge rule to this stack's tasks."
  type        = string
}

variable "ecs_service_name" {
  description = "Minecraft ECS service name — the crash rule matches its tasks' \"service:<name>\" group."
  type        = string
}

variable "minecraft_container_name" {
  description = "Name of the Minecraft container in the task definition (not the watchdog) — the one whose unexpected stop triggers a crash notification."
  type        = string
  default     = "minecraft-server"
}

variable "log_retention_days" {
  type    = number
  default = 3
}
