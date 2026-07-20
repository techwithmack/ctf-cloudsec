variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "The target AWS region. Selected to avoid the restricted us-east-1 region."
}

variable "ctf_domain" {
  type        = string
  description = "Dedicated domain for Challenge 3 (e.g. \"ctf-shadow-pipeline.example.com\"). Per-team Forgejo instances are published at <team_id>.<ctf_domain>. A wildcard ACM cert and shared ALB are provisioned for *.<ctf_domain>."
}

variable "create_route53_zone" {
  type        = bool
  default     = true
  description = "Whether to create a new Route53 public hosted zone for ctf_domain. Set to false if the zone already exists and should be looked up instead (e.g. ctf_domain is a subdomain delegated from an existing zone you manage elsewhere)."
}
