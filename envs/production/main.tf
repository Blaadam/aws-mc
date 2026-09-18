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

  project_name      = var.project_name
  sns_email_address = var.sns_email_address
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

  domain_name    = var.domain_name
  subdomain_part = var.subdomain_part
  aws_region     = var.aws_region
  cluster_name   = var.project_name
  service_name   = "${var.project_name}-server"
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
  # sns_email_address is a plain input variable, always known.
  sns_topic_configured = var.sns_email_address != ""
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
# Cloudflare-parent DNS assumption in the CDK original.
#
# count instead of for_each: the name servers are unknown until the zone is
# actually created (a brand-new zone's NS values can't be known at plan
# time), and for_each requires its keys to be known up front. A Route 53
# public hosted zone always returns exactly 4 name servers — a fixed AWS
# platform invariant — so count = 4 is safe here.
resource "cloudflare_record" "ns_delegation" {
  count = 4

  zone_id = var.cloudflare_zone_id
  name    = module.dns_trigger.subdomain
  type    = "NS"
  content = module.dns_trigger.hosted_zone_name_servers[count.index]
  ttl     = 3600
  proxied = false
}
