output "topic_arn" {
  value = var.sns_email_address != "" || local.discord_enabled ? aws_sns_topic.this[0].arn : ""
}

output "discord_function_name" {
  value = local.discord_enabled ? aws_lambda_function.discord[0].function_name : ""
}
