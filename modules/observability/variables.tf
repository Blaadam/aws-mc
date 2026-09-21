variable "project_name" {
  type = string
}

variable "aws_region" {
  type = string
}

variable "cluster_name" {
  type = string
}

variable "service_name" {
  type = string
}

variable "launcher_function_name" {
  description = "DNS-trigger launcher Lambda (also handles the start API) — gets an Errors alarm."
  type        = string
}

variable "discord_function_name" {
  description = "Discord-notify Lambda's function name. Empty when discord_webhook_url isn't set, in which case its Errors alarm and dashboard widget are both skipped."
  type        = string
  default     = ""
}

variable "sns_topic_arn" {
  description = "Existing notifications topic (modules/notifications) to publish alarm state changes to — reuses the same email/Discord fan-out rather than adding a separate alert channel. Empty skips alarm_actions entirely; the alarms still exist and show in the console, they just don't notify anywhere."
  type        = string
  default     = ""
}

variable "long_running_alarm_hours" {
  description = "Consecutive hours of continuous ECS CPUUtilization data — i.e. the task hasn't scaled back to zero — before the long-running safety-net alarm fires. A cost guard against a stuck watchdog (Spot interruption mid-shutdown, a crash, etc), not a gameplay limit. Raise it if long sessions are normal for you."
  type        = number
  default     = 6
}
