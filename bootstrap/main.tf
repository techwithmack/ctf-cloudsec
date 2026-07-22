# Challenge 1 shared bootstrap - apply this ONCE, before any team's per-team stack
# (main.tf) is applied. Every resource here is referenced back by the per-team
# stack via data sources (never created there) - the same reasoning as Challenge
# 2's bootstrap/: a per-team-applied stack cannot safely *create* a resource that
# every other team's separate apply would also try to create.
#
# Provisions: the Route53 zone lookup for the CTF domain, a wildcard ACM cert for
# *.<ctf_domain>, and one shared Application Load Balancer (teams are
# distinguished by per-team host-header listener rules, not per-team ALBs).
#
# Deliberately does NOT provision the entry-point ECR repo - that's a one-time,
# out-of-band `aws ecr create-repository` + `docker push` (see app/README.md),
# looked up read-only by main.tf via `data "aws_ecr_repository"`, same as before.

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# 1. Route53 hosted zone. zone_name is the apex domain that actually exists in
# Route53 (e.g. "aikidoctf.com"); ctf_domain (used below for the cert/ALB) may be
# that same apex or a subdomain of it (e.g. "challenge1.aikidoctf.com") - either
# way, records for ctf_domain get created inside this zone.
resource "aws_route53_zone" "ctf" {
  count = var.create_route53_zone ? 1 : 0
  name  = var.zone_name
}

data "aws_route53_zone" "ctf" {
  count = var.create_route53_zone ? 0 : 1
  name  = var.zone_name
}

locals {
  zone_id = var.create_route53_zone ? aws_route53_zone.ctf[0].zone_id : data.aws_route53_zone.ctf[0].zone_id
}

# 2. Wildcard ACM certificate for *.<ctf_domain>, DNS-validated automatically since
# we own the zone above.
resource "aws_acm_certificate" "wildcard" {
  domain_name       = "*.${var.ctf_domain}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.wildcard.domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  }

  zone_id         = local.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "wildcard" {
  certificate_arn         = aws_acm_certificate.wildcard.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# 3. Shared network + ALB
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "alb_sg" {
  # name_prefix (not a fixed name) + create_before_destroy: this SG stays attached
  # to the live shared ALB, so any future change that forces replacement (e.g.
  # editing description) must create the replacement and re-point the ALB at it
  # before the old one is destroyed - otherwise AWS refuses the delete with
  # DependencyViolation (found by live testing on Challenge 2's identical setup).
  name_prefix = "flawed-blueprint-alb-sg-"
  vpc_id      = data.aws_vpc.default.id
  description = "Allow public HTTP/HTTPS to the shared Challenge 1 ALB"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "shared" {
  name               = "flawed-blueprint-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.shared.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Default action here returns a plain 404. Per-team host-header rules (added by
# main.tf) take priority over this default and route each
# team<id>.<ctf_domain> hostname to that team's entry-point target group.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.shared.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.wildcard.certificate_arn

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

output "alb_security_group_id" {
  value = aws_security_group.alb_sg.id
}

output "alb_arn" {
  value = aws_lb.shared.arn
}

output "alb_dns_name" {
  value = aws_lb.shared.dns_name
}

output "alb_zone_id" {
  value = aws_lb.shared.zone_id
}

output "https_listener_arn" {
  value = aws_lb_listener.https.arn
}

output "route53_zone_id" {
  value = local.zone_id
}

output "nameservers" {
  value       = var.create_route53_zone ? aws_route53_zone.ctf[0].name_servers : null
  description = "If a new zone was created, delegate zone_name to these nameservers at your registrar."
}
