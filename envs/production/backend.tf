# Partial configuration: bucket/key/region come from backend.hcl (gitignored,
# not this file) so the bucket name and region aren't hardcoded here.
#
# One-time setup:
#   1. Apply ../../bootstrap once to create the state bucket.
#   2. cp backend.hcl.example backend.hcl and fill in the bucket/region.
#   3. terraform init -backend-config=backend.hcl
#
# use_lockfile turns on Terraform's native S3 state locking (>=1.10), so no
# DynamoDB lock table is needed.
terraform {
  backend "s3" {
    use_lockfile = true
  }
}
