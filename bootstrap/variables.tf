variable "aws_region" {
  type        = string
  default     = "us-west-2"
  description = "The target AWS region. Selected to avoid the restricted us-east-1 region."
}

variable "zone_name" {
  type        = string
  description = "The Route53 public hosted zone that actually exists (e.g. \"aikidoctf.com\"). ctf_domain is looked up/validated against this zone - it may equal zone_name or be a subdomain of it (e.g. zone_name = \"aikidoctf.com\", ctf_domain = \"challenge1.aikidoctf.com\")."
}

variable "ctf_domain" {
  type        = string
  description = "Dedicated subdomain for Challenge 1 (e.g. \"challenge1.aikidoctf.com\"). Per-team entry points are published at <team_id>.<ctf_domain>. A wildcard ACM cert is provisioned for *.<ctf_domain>."
}

variable "create_route53_zone" {
  type        = bool
  default     = false
  description = "Whether to create a new Route53 public hosted zone for zone_name. Default false: a domain registered directly through Route53 Registrar (e.g. aikidoctf.com) already has its zone auto-created. Set to true only if zone_name genuinely doesn't exist yet in this account."
}
