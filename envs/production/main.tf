module "networking" {
  source = "../../modules/networking"

  vpc_id       = var.vpc_id
  project_name = var.project_name
}

module "storage" {
  source = "../../modules/storage"

  vpc_id       = module.networking.vpc_id
  subnet_ids   = module.networking.subnet_ids
  project_name = var.project_name
}

module "notifications" {
  source = "../../modules/notifications"

  project_name        = var.project_name
  sns_email_address   = var.sns_email_address
  discord_webhook_url = var.discord_webhook_url
  discord_message     = var.discord_message
  # null when enable_start_api is false — start_api_url's type is string,
  # not string?, so that has to become "" rather than pass through as null.
  start_api_url = coalesce(module.dns_trigger.start_api_url, "")
  # Reuses the same ICON already set for the server's own list entry — one
  # source of truth instead of a second URL to keep in sync.
  icon_url = lookup(var.minecraft_image_env_vars, "ICON", "")
}

# Runs entirely in us-east-1: Route 53 query logging requires the
# CloudWatch Logs destination there, so the whole module (hosted zone
# included) is pinned to it for simplicity, mirroring the CDK original's
# DomainStack region.
module "dns_trigger" {
  source = "../../modules/dns-trigger"

  providers = {
    aws = aws.use1
  }

  domain_name      = var.domain_name
  subdomain_part   = var.subdomain_part
  aws_region       = var.aws_region
  cluster_name     = var.project_name
  service_name     = "${var.project_name}-server"
  enable_start_api = var.enable_start_api
}

module "ecs" {
  source = "../../modules/ecs"

  vpc_id       = module.networking.vpc_id
  subnet_ids   = module.networking.subnet_ids
  cluster_name = var.project_name
  service_name = "${var.project_name}-server"

  minecraft_edition        = var.minecraft_edition
  minecraft_image_env_vars = var.minecraft_image_env_vars
  task_cpu                 = var.task_cpu
  task_memory              = var.task_memory
  use_fargate_spot         = var.use_fargate_spot
  startup_minutes          = var.startup_minutes
  shutdown_minutes         = var.shutdown_minutes
  debug                    = var.debug
  container_insights       = var.container_insights
  rcon_allowed_cidrs       = var.rcon_allowed_cidrs

  efs_file_system_id   = module.storage.file_system_id
  efs_file_system_arn  = module.storage.file_system_arn
  efs_access_point_id  = module.storage.access_point_id
  efs_access_point_arn = module.storage.access_point_arn

  hosted_zone_id     = module.dns_trigger.hosted_zone_id
  subdomain          = module.dns_trigger.subdomain
  launcher_role_name = module.dns_trigger.launcher_role_name

  sns_topic_arn = module.notifications.topic_arn
  # Not var.sns_topic_arn != "" — on the topic's first apply its ARN is
  # unknown at plan time, and count can't depend on an unknown value.
  # sns_email_address/discord_webhook_url are plain input variables, always
  # known — mirrors modules/notifications' own topic-creation condition.
  sns_topic_configured = var.sns_email_address != "" || local.discord_enabled
}

# Task 2.5 (docs/PROJECT_PLAN.md) — opt-in: some deployments won't want the
# (small, but non-zero) extra CloudWatch cost. count on the module itself
# rather than threading an "enabled" flag through every resource inside it.
module "observability" {
  count  = var.enable_observability ? 1 : 0
  source = "../../modules/observability"

  project_name = var.project_name
  aws_region   = var.aws_region
  cluster_name = var.project_name
  service_name = "${var.project_name}-server"

  launcher_function_name = module.dns_trigger.launcher_function_name
  discord_function_name  = module.notifications.discord_function_name
  sns_topic_arn          = module.notifications.topic_arn

  long_running_alarm_hours = var.long_running_alarm_hours
}

# Opt-in, same reasoning as observability above: not everyone wants the
# extra storage cost or needs the durability (this protects against a
# corrupted world or a mistake — EFS's own IA lifecycle policy in
# modules/storage is about storage class, not backup history).
module "backup" {
  count  = var.enable_backup ? 1 : 0
  source = "../../modules/backup"

  project_name        = var.project_name
  efs_file_system_arn = module.storage.file_system_arn

  backup_days_of_week   = var.backup_days_of_week
  backup_hour           = var.backup_hour
  backup_retention_days = var.backup_retention_days
}

# Breaks the storage <-> ecs module cycle: neither module knows about the
# other, this rule connects their security groups from the root.
resource "aws_vpc_security_group_ingress_rule" "efs_from_ecs" {
  security_group_id            = module.storage.security_group_id
  description                  = "NFS from the Minecraft ECS service"
  referenced_security_group_id = module.ecs.security_group_id
  from_port                    = 2049
  to_port                      = 2049
  ip_protocol                  = "tcp"
}

# Delegates the child zone from Cloudflare (authoritative for domain_name)
# to the Route 53 zone dns_trigger created — this is the fix for the
# Cloudflare-parent DNS assumption in the CDK original. Optional: only
# created when manage_cloudflare_dns is true — domain_name can be hosted
# anywhere, this is just the one provider Terraform can automate delegation
# for. When false, delegate hosted_zone_name_servers manually instead (see
# README).
#
# count instead of for_each: the name servers are unknown until the zone is
# actually created (a brand-new zone's NS values can't be known at plan
# time), and for_each requires its keys to be known up front. A Route 53
# public hosted zone always returns exactly 4 name servers — a fixed AWS
# platform invariant — so count = 4 (when enabled) is safe here.
resource "cloudflare_record" "ns_delegation" {
  count = var.manage_cloudflare_dns ? 4 : 0

  zone_id = var.cloudflare_zone_id
  name    = module.dns_trigger.subdomain
  type    = "NS"
  content = module.dns_trigger.hosted_zone_name_servers[count.index]
  ttl     = 3600
  proxied = false
}

# Groups every resource tagged for this project in one place in the AWS
# console (Resource Groups & Tag Editor), across both regions — everything
# already gets Project/Environment tags via default_tags on both providers.
# Free. Also gives task 2.5 (observability) a natural anchor to build a
# CloudWatch dashboard from later.
resource "aws_resourcegroups_group" "this" {
  name        = var.project_name
  description = "All resources for the ${var.project_name} on-demand Minecraft server"

  resource_query {
    query = jsonencode({
      ResourceTypeFilters = ["AWS::AllSupported"]
      TagFilters = [
        {
          Key    = "Project"
          Values = [var.project_name]
        },
        {
          Key    = "Environment"
          Values = [var.environment]
        },
      ]
    })
  }
}

# Billing-side counterpart to the resource group above: activates the same
# two tags as AWS Cost Allocation Tags so Cost Explorer can break down
# spend by Project/Environment too, not just inventory. Account-wide
# setting, not scoped to this stack — this only activates a tag key AWS has
# already seen on a billed resource, it doesn't create the tag itself.
resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "environment" {
  tag_key = "Environment"
  status  = "Active"
}
