variable "vpc_id" {
  type = string
}

variable "subnet_ids" {
  type = list(string)
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "minecraft_edition" {
  type = string

  validation {
    condition     = contains(["java", "bedrock"], var.minecraft_edition)
    error_message = "minecraft_edition must be \"java\" or \"bedrock\"."
  }
}

variable "minecraft_image_env_vars" {
  type = map(string)
}

variable "task_cpu" {
  type = number
}

variable "task_memory" {
  type = number
}

variable "use_fargate_spot" {
  type = bool
}

variable "startup_minutes" {
  type = number
}

variable "shutdown_minutes" {
  type = number
}

variable "debug" {
  description = "Enables CloudWatch Logs for both the minecraft-server and watchdog containers."
  type        = bool
}

variable "efs_file_system_id" {
  type = string
}

variable "efs_file_system_arn" {
  type = string
}

variable "efs_access_point_id" {
  type = string
}

variable "efs_access_point_arn" {
  type = string
}

variable "hosted_zone_id" {
  description = "Route 53 hosted zone ID the watchdog is allowed to update the A record in."
  type        = string
}

variable "subdomain" {
  description = "FQDN the watchdog reports as SERVERNAME, e.g. minecraft.example.com."
  type        = string
}

variable "sns_topic_arn" {
  description = "SNS topic for server-ready notifications. Leave empty to skip granting publish permission."
  type        = string
  default     = ""
}

variable "sns_topic_configured" {
  description = "Whether an SNS topic was actually requested — drives whether the publish policy gets created. Can't just test sns_topic_arn != \"\" for this: on the topic's first apply, its ARN is unknown at plan time, which makes count unknown too. This must come from a statically-known root variable instead (e.g. sns_email_address != \"\"), not from any resource attribute."
  type        = bool
  default     = false
}

variable "launcher_role_name" {
  description = "IAM role name of the DNS-trigger launcher Lambda — also needs ecs:UpdateService permission on this service to start it from zero."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 3
}

variable "container_insights" {
  type    = bool
  default = false
}
