# --------------------------------------------------------------------------
# Parity checklist (task 0.4): every key from the CDK original's
# cdk/.env.sample has a variable below, grouped the same way the original
# grouped them. Terraform/Cloudflare-only additions are called out separately
# at the bottom — they don't correspond to a CDK env var.
# --------------------------------------------------------------------------

# --- Required ---------------------------------------------------------------

variable "domain_name" {
  description = "Root domain the subdomain will be created under, e.g. \"example.com\". A child Route 53 zone (subdomain_part.domain_name) is always created for it — Route 53 query logging is what the DNS-trigger depends on, regardless of who hosts domain_name's own authoritative DNS. If that's Cloudflare, see manage_cloudflare_dns for automated delegation; otherwise delegate the zone manually (see README) using the hosted_zone_name_servers output. Was DOMAIN_NAME."
  type        = string
}

# --- Optional (mirrors cdk/.env.sample defaults) -----------------------------

variable "subdomain_part" {
  description = "Subdomain used for the delegated hosted zone, e.g. \"minecraft\" -> minecraft.example.com. Must not already be in use. Was SUBDOMAIN_PART."
  type        = string
  default     = "minecraft"
}

variable "minecraft_edition" {
  description = "\"java\" or \"bedrock\". Was MINECRAFT_EDITION."
  type        = string
  default     = "java"

  validation {
    condition     = contains(["java", "bedrock"], var.minecraft_edition)
    error_message = "minecraft_edition must be \"java\" or \"bedrock\"."
  }
}

variable "startup_minutes" {
  description = "Minutes to wait for a connection after startup before the watchdog shuts the server back down. Was STARTUP_MINUTES."
  type        = number
  default     = 10
}

variable "shutdown_minutes" {
  description = "Minutes to wait after the last client disconnects before the watchdog scales back to zero. Was SHUTDOWN_MINUTES. Defaulted lower than the CDK original's 20 for cost — every minute here is billed Fargate time with nobody playing. Raise it if short reconnect gaps (bathroom breaks, crashes) shouldn't cost a full restart."
  type        = number
  default     = 10
}

variable "use_fargate_spot" {
  description = "Run the ECS task on FARGATE_SPOT (~1.5c/hr) instead of on-demand FARGATE (~5c/hr). The watchdog handles the Spot interruption signal. Was USE_FARGATE_SPOT."
  type        = bool
  default     = true
}

variable "task_cpu" {
  description = "Fargate task vCPU units (256/512/1024/2048/4096) — constrains valid task_memory values. Was TASK_CPU. Defaulted to 0.5 vCPU (half the CDK original's 1 vCPU) since Fargate bills per vCPU-second — this is a deliberately tight, cheap default for a small hobby server; bump to 1024+ if you see CPU throttling (redstone/mob-heavy worlds, several concurrent players)."
  type        = number
  default     = 512
}

variable "task_memory" {
  description = "Fargate task memory in MiB — must be a valid pairing for task_cpu. Was TASK_MEMORY. Defaulted to 1GB (half the CDK original's 2GB) for cost — below Mojang's official 2GB+ recommendation, workable for a small vanilla world but tight for modpacks or several players. Bump if the server OOMs or feels sluggish; valid pairings for task_cpu=512 are 1024/2048/3072/4096."
  type        = number
  default     = 1024
}

variable "vpc_id" {
  description = "Existing VPC ID to deploy into. Leave empty to create a new dedicated VPC (public subnets only, no NAT gateways, matching the CDK original). Was VPC_ID."
  type        = string
  default     = ""
}

variable "minecraft_image_env_vars" {
  description = "Extra environment variables passed to the itzg/minecraft-server (or -bedrock-server) container. Was MINECRAFT_IMAGE_ENV_VARS_JSON (a JSON string there; a native map here)."
  type        = map(string)
  default     = { EULA = "TRUE" }
}

variable "sns_email_address" {
  description = "Email address for server-ready notifications. Leave empty to skip creating the SNS topic/subscription. Was SNS_EMAIL_ADDRESS."
  type        = string
  default     = ""
}

# TWILIO_PHONE_FROM / TWILIO_PHONE_TO / TWILIO_ACCOUNT_ID / TWILIO_AUTH_CODE
# are intentionally dropped for now — SNS email is the only notification
# path. See docs/PROJECT_PLAN.md.

variable "debug" {
  description = "When true, enables CloudWatch Logs for both the minecraft-server and watchdog containers. Was DEBUG."
  type        = bool
  default     = false
}

# --- Terraform/Cloudflare port additions (no CDK env var equivalent) --------

variable "aws_region" {
  description = "AWS region for the core stack (VPC/ECS/EFS/etc). Was hardcoded to SERVER_REGION's default of us-east-1 in the CDK original; kept configurable here since it's a personal deployment."
  type        = string
  default     = "eu-west-2"
}

variable "project_name" {
  description = "Short name used for resource naming/tagging. Matches the CDK original's ECS cluster name (\"minecraft\")."
  type        = string
  default     = "minecraft"
}

variable "environment" {
  description = "Deployment environment name, used in tags."
  type        = string
  default     = "production"
}

variable "tags" {
  description = "Extra tags applied to all resources, merged with the project/environment/managed-by tags."
  type        = map(string)
  default     = {}
}

variable "manage_cloudflare_dns" {
  description = "Whether Terraform creates the NS delegation record in Cloudflare automatically. Off by default — this stack works with domain_name hosted anywhere; Cloudflare is just the one provider it can automate delegation for. When false, cloudflare_api_token/cloudflare_zone_id aren't needed — delegate the child zone manually instead (see README), using the hosted_zone_name_servers output."
  type        = bool
  default     = false
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token, scoped to DNS edit on the zone covering domain_name. Required only when manage_cloudflare_dns is true. Set it in terraform.tfvars (gitignored, same as the CDK original's .env) or via TF_VAR_cloudflare_api_token — either way, never in a committed file."
  type        = string
  sensitive   = true
  default     = ""

  validation {
    condition     = !var.manage_cloudflare_dns || var.cloudflare_api_token != ""
    error_message = "cloudflare_api_token is required when manage_cloudflare_dns is true."
  }
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for domain_name, where the NS delegation record for the child Route 53 zone is created. Required only when manage_cloudflare_dns is true."
  type        = string
  default     = ""

  validation {
    condition     = !var.manage_cloudflare_dns || var.cloudflare_zone_id != ""
    error_message = "cloudflare_zone_id is required when manage_cloudflare_dns is true."
  }
}

variable "container_insights" {
  description = "Enable ECS Container Insights on the cluster. Off by default for cost — it bills per custom CloudWatch metric, which adds up against a server that's mostly scaled to zero. Turn on for better visibility if you're debugging performance."
  type        = bool
  default     = false
}

variable "rcon_allowed_cidrs" {
  description = "CIDR blocks allowed to reach RCON (25575/tcp) on the service security group, e.g. [\"203.0.113.4/32\"] for your own IP. Empty by default — nothing in this stack needs RCON reachable from outside the task. Only set this if you want to run remote admin commands yourself (e.g. mcrcon). Never use 0.0.0.0/0: RCON auth is a plaintext password over TCP."
  type        = list(string)
  default     = []
}
