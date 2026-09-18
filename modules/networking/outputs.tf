output "vpc_id" {
  value = local.create_vpc ? aws_vpc.this[0].id : data.aws_vpc.existing[0].id
}

output "subnet_ids" {
  description = "Public subnet IDs for the Fargate service and EFS mount targets."
  value       = local.create_vpc ? aws_subnet.public[*].id : data.aws_subnets.existing[0].ids
}
