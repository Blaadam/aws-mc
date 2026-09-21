variable "project_name" {
  type = string
}

variable "efs_file_system_arn" {
  description = "The world-data EFS file system to back up."
  type        = string
}

variable "backup_days_of_week" {
  description = "Days of the week to run the backup, as AWS Backup cron day-of-week codes (e.g. [\"SUN\"] for once a week, [\"MON\", \"THU\"] for twice). At least one required."
  type        = list(string)
  default     = ["SUN"]

  validation {
    condition     = length(var.backup_days_of_week) > 0
    error_message = "backup_days_of_week must list at least one day."
  }

  validation {
    condition     = alltrue([for d in var.backup_days_of_week : contains(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], d)])
    error_message = "backup_days_of_week entries must be one of MON, TUE, WED, THU, FRI, SAT, SUN."
  }
}

variable "backup_hour" {
  description = "UTC hour (0-23) the backup job starts. EFS backups run live against the filesystem — no need to avoid server playtime, but a low-traffic hour keeps the (small) extra EFS read load off a session in progress."
  type        = number
  default     = 9

  validation {
    condition     = var.backup_hour >= 0 && var.backup_hour <= 23
    error_message = "backup_hour must be between 0 and 23."
  }
}

variable "backup_retention_days" {
  description = "How long recovery points are kept before AWS Backup deletes them. EFS backup storage is billed per GB-month retained (~$0.05/GB-month, incremental after the first backup) — this is the main cost lever."
  type        = number
  default     = 30

  validation {
    condition     = var.backup_retention_days >= 1
    error_message = "backup_retention_days must be at least 1."
  }
}
