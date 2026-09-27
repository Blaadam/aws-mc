output "topic_arn" {
  value = local.topic_enabled ? aws_sns_topic.this[0].arn : ""
}

output "discord_function_name" {
  value = local.discord_enabled ? aws_lambda_function.discord[0].function_name : ""
}
