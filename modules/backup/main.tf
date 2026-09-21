locals {
  # 6-field AWS Backup cron: minute hour day-of-month month day-of-week year.
  # day-of-month is "?" since day-of-week is set instead — AWS Backup (like
  # EventBridge) doesn't allow both.
  schedule = "cron(0 ${var.backup_hour} ? * ${join(",", var.backup_days_of_week)} *)"
}

resource "aws_iam_role" "backup" {
  name = "${var.project_name}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "backup.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# Backup only, not restore — restoring the world is a rare, manual, "you're
# already in the console/CLI for this" action, not something this role
# needs standing permission for.
resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

# No kms_key_arn: uses the AWS-managed "aws/backup" key, same "AWS-managed
# over customer-managed" cost call as everywhere else in this project.
resource "aws_backup_vault" "this" {
  name = "${var.project_name}-backup"
}

resource "aws_backup_plan" "this" {
  name = "${var.project_name}-backup"

  rule {
    rule_name         = "world-data"
    target_vault_name = aws_backup_vault.this.name
    schedule          = local.schedule

    lifecycle {
      delete_after = var.backup_retention_days
    }
  }
}

resource "aws_backup_selection" "this" {
  name         = "${var.project_name}-world-data"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = [var.efs_file_system_arn]
}
