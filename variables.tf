variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "The target AWS region. Selected to avoid the restricted us-east-1 region."
}

variable "team_id" {
  type        = string
  description = "Unique identifier for the team/player to enforce strict multi-tenant isolation."
}