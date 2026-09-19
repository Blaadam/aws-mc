output "server_address" {
  description = "Address to connect to in the Minecraft client."
  value       = module.dns_trigger.subdomain
}

output "hosted_zone_name_servers" {
  description = "Route 53 name servers for the child zone — should match what was delegated in Cloudflare."
  value       = module.dns_trigger.hosted_zone_name_servers
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "ecs_service_name" {
  value = module.ecs.service_name
}

output "sns_topic_arn" {
  value = module.notifications.topic_arn
}

output "launcher_function_name" {
  value = module.dns_trigger.launcher_function_name
}

# null unless var.debug is true — see modules/ecs/outputs.tf.
output "minecraft_log_group_name" {
  value = module.ecs.minecraft_log_group_name
}

output "watchdog_log_group_name" {
  value = module.ecs.watchdog_log_group_name
}

# null unless var.enable_start_api is true — see modules/dns-trigger/outputs.tf.
output "start_api_url" {
  value     = module.dns_trigger.start_api_url
  sensitive = true
}
