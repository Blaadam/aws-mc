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
