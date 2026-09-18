locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  })
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

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
