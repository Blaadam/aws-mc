locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  })

  # The Cloudflare provider validates api_token's shape (40+ chars,
  # a-zA-Z0-9_-) during Configure, even with zero cloudflare_record
  # instances to actually use it — an empty string fails that check and
  # breaks `plan`/`apply` outright when manage_cloudflare_dns is false and
  # cloudflare_api_token was never set. Substitute an obviously-fake
  # placeholder in that case; it's never used for a real request.
  cloudflare_api_token = var.cloudflare_api_token != "" ? var.cloudflare_api_token : "unused-manage_cloudflare_dns-is-false-000"
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

# Route 53 query logging (the DNS-trigger launcher, Phase 1) only accepts a
# CloudWatch Logs destination in us-east-1, regardless of which region the
# rest of the stack runs in — this is an AWS constraint, not a preference.
# See constants.ts::DOMAIN_STACK_REGION in the CDK original.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"

  default_tags {
    tags = local.common_tags
  }
}

# Configured even when manage_cloudflare_dns is false — Terraform requires
# every provider a resource block references to be configured, regardless
# of whether that resource's count evaluates to zero.
provider "cloudflare" {
  api_token = local.cloudflare_api_token
}
