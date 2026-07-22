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
  description = "The same zone_name used when applying challenge-2-iac/bootstrap (e.g. \"aikidoctf.com\") - the Route53 zone that actually exists."
}

variable "ctf_domain" {
  type        = string
  description = "The same dedicated subdomain used when applying challenge-2-iac/bootstrap (e.g. \"challenge2.aikidoctf.com\"). This team's Forgejo instance is published at <team_id>.<ctf_domain>."
}

variable "runner_instance_type" {
  type        = string
  default     = "t3.small"
  description = "EC2 instance type for this team's CI runner. Fargate cannot run it (no Docker-in-Docker support), so this component runs on EC2."
}
