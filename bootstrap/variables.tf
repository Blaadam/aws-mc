variable "aws_region" {
  description = "AWS region the state bucket lives in. Should match the region used in envs/*/backend.hcl."
  type        = string
  default     = "eu-west-2"
}

variable "bucket_name" {
  description = "Globally-unique S3 bucket name for Terraform state, e.g. \"mc-tfstate-<your-account-id>\"."
  type        = string
}
