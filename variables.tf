variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "The target AWS region. Selected to avoid the restricted us-east-1 region."
}

variable "team_id" {
  type        = string
  description = "Unique identifier for the team/player to enforce strict multi-tenant isolation."
}

variable "zone_name" {
  type        = string
  description = "The same zone_name used when applying bootstrap/ (e.g. \"aikidoctf.com\") - the Route53 zone that actually exists."
}

variable "ctf_domain" {
  type        = string
  description = "The same dedicated subdomain used when applying bootstrap/ (e.g. \"challenge1.aikidoctf.com\"). This team's entry point is published at <team_id>.<ctf_domain>."
}