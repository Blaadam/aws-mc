output "topic_arn" {
  value = var.sns_email_address != "" || local.discord_enabled ? aws_sns_topic.this[0].arn : ""
}
