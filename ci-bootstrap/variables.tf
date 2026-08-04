variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "The target AWS region. Selected to avoid the restricted us-east-1 region."
}

variable "github_repo" {
  type        = string
  default     = "techwithmack/ctf-cloudsec"
  description = "GitHub \"org/repo\" allowed to assume the CI provisioning role via OIDC. Only workflows running from this exact repo can assume it."
}

variable "state_bucket_name" {
  type        = string
  default     = "aikidoctf-terraform-state"
  description = "Globally-unique S3 bucket name for both challenges' remote Terraform state. Must not already exist."
}

variable "state_lock_table_name" {
  type        = string
  default     = "aikidoctf-terraform-locks"
  description = "DynamoDB table name used for Terraform state locking."
}

variable "create_github_oidc_provider" {
  type        = bool
  default     = true
  description = "Whether to create the GitHub Actions OIDC provider. Set to false if one already exists in this account (only one provider per URL is allowed per account) - this module will look it up read-only instead."
}
