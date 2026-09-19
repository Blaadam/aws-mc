output "hosted_zone_id" {
  value = aws_route53_zone.this.zone_id
}

output "hosted_zone_name_servers" {
  value = aws_route53_zone.this.name_servers
}

output "subdomain" {
  value = local.subdomain
}

output "launcher_role_name" {
  value = aws_iam_role.launcher.name
}

output "launcher_role_arn" {
  value = aws_iam_role.launcher.arn
}

output "launcher_function_name" {
  value = aws_lambda_function.launcher.function_name
}

# null unless var.enable_start_api is true. Ready to bookmark as-is —
# already includes the ?token= query param.
output "start_api_url" {
  value     = var.enable_start_api ? "${aws_lambda_function_url.start[0].function_url}?token=${random_password.start_token[0].result}" : null
  sensitive = true
}
