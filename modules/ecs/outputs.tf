output "cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "service_name" {
  value = aws_ecs_service.this.name
}

output "service_arn" {
  value = aws_ecs_service.this.id
}

output "task_role_arn" {
  value = aws_iam_role.task.arn
}

output "security_group_id" {
  value = aws_security_group.service.id
}

# null when var.debug is false — the log groups only exist then. Indexing
# [0] unconditionally would be a hard error against a zero-count resource,
# same reason local.mc_log_config/watchdog_log_config guard it in main.tf.
output "minecraft_log_group_name" {
  value = var.debug ? aws_cloudwatch_log_group.minecraft[0].name : null
}

output "watchdog_log_group_name" {
  value = var.debug ? aws_cloudwatch_log_group.watchdog[0].name : null
}
