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

locals {
  entrypoint_hostname = "${var.team_id}.${var.ctf_domain}"
  entrypoint_url      = "https://${local.entrypoint_hostname}"
}

# ---------------------------------------------------------------------------
# Shared bootstrap resources, looked up read-only (see bootstrap/main.tf -
# applied once for the whole event, before any team's stack).
# ---------------------------------------------------------------------------

data "aws_lb" "shared" {
  name = "flawed-blueprint-alb"
}

data "aws_lb_listener" "shared_https" {
  load_balancer_arn = data.aws_lb.shared.arn
  port              = 443
}

data "aws_security_group" "alb_sg" {
  filter {
    name   = "group-name"
    values = ["flawed-blueprint-alb-sg-*"]
  }
}

data "aws_route53_zone" "ctf" {
  name = var.zone_name
}

# 1. Create the S3 Bucket with a uniquely isolated name per team
resource "aws_s3_bucket" "leaky_bucket" {
  bucket        = "aikido-ctf-blueprint-backup-${var.team_id}"
  force_destroy = true # Allows clean teardown post-event

  tags = {
    Challenge   = "The Flawed Blueprint"
    Environment = "CTF-Production"
    TeamID      = var.team_id
  }
}

# 2. Disable Public Access Blocks to explicitly allow public policies
resource "aws_s3_bucket_public_access_block" "allow_public" {
  bucket = aws_s3_bucket.leaky_bucket.id

  block_public_acls       = false
  block_public_policy     = false  # Singular
  ignore_public_acls      = false
  restrict_public_buckets = false  # Plural
}

# 3. Apply the flawed, overly permissive public read policy (The Core Vulnerability)
resource "aws_s3_bucket_policy" "public_read_policy" {
  # Depends on the public access block being modified first
  depends_on = [aws_s3_bucket_public_access_block.allow_public]
  bucket     = aws_s3_bucket.leaky_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.leaky_bucket.arn}/*"
      },
      {
        # s3:ListBucket is a separate permission on the bucket resource itself (not
        # bucket/*) - without it, `aws s3 ls` returns AccessDenied even though
        # `aws s3 cp` of a known key succeeds. Both are needed for the intended
        # enumerate-then-download solve path in docs/walkthrough.md.
        Sid       = "PublicListBucket"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:ListBucket"
        Resource  = aws_s3_bucket.leaky_bucket.arn
      }
    ]
  })
}

# 4a. Dynamically generate a unique 32-character hex string for the flag
resource "random_id" "flag_hex" {
  byte_length = 16 # 16 bytes = 32 hex characters
}

# 4b. Local variable containing the fully formatted CTF flag
locals {
  generated_flag = "FLAG-${random_id.flag_hex.hex}"
}

# 4c. Upload the "forgotten developer backup configuration file" containing the dynamic flag
resource "aws_s3_object" "backup_file" {
  bucket       = aws_s3_bucket.leaky_bucket.id
  key          = "prod_backup_config.toml"
  content_type = "text/plain"

  # The mock configuration file containing environment details and the dynamic flag
  content = <<EOF
[database]
host = "db-prod.internal.aikido.ctf"
port = 5432
username = "deploy_user"
password = "SuperSecretPassword123!"

[environment]
debug = false
app_version = "1.0.4"

[system_canary]
# TODO: Remove this debug token before pushing to production configuration
flag_token = "${local.generated_flag}"
EOF

  tags = {
    Type = "Backup"
  }
}

# 4d. Output the flag (Hidden from players, but visible to you for QA verification)
output "qa_verification_flag" {
  value       = local.generated_flag
  description = "The generated flag for QA verification purposes."
  sensitive   = true 
}

# 5. Create an ECS Cluster for hosting the entry point container
resource "aws_ecs_cluster" "ctf_cluster" {
  name = "aikido-ctf-cluster-${var.team_id}"
}

# 5a. Look up the shared ECR repository for the entry point image (one image, reused
# by every team's task since the app is parameterized purely via TEAM_ID /
# TARGET_BUCKET_URL). This is a data source, not a resource: every team's `terraform
# apply` uses this same team-scoped stack, so the repo itself must be created exactly
# once, out-of-band, before the first team deploys. See app/README.md for the
# one-time bootstrap command (`aws ecr create-repository` + `docker push`).
data "aws_ecr_repository" "app" {
  name = "aikido-ctf-flawed-blueprint"
}

# 6. IAM Role for ECS Task Execution (allows pulling images and logging)
resource "aws_iam_role" "ecs_execution_role" {
  name = "aikido-ctf-ecs-execution-${var.team_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# 7. ECS Task Definition defining the Entry Point container
resource "aws_ecs_task_definition" "entrypoint_task" {
  family                   = "flawed-blueprint-entrypoint-${var.team_id}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn

  container_definitions = jsonencode([{
    name      = "entrypoint-app"
    image     = "${data.aws_ecr_repository.app.repository_url}:latest"
    essential = true
    portMappings = [{
      containerPort = 80
      hostPort      = 80
    }]
    # Dynamically inject the leaky bucket's URL into the container environment variables
    environment = [
      { name = "TEAM_ID", value = var.team_id },
      { name = "TARGET_BUCKET_URL", value = "https://${aws_s3_bucket.leaky_bucket.bucket_regional_domain_name}" }
    ]
  }])
}

# 8. Network infrastructure configuration (assuming a default or pre-existing VPC for simplicity)
data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Security group allowing traffic to the entry point container only from the
# shared ALB (see bootstrap/main.tf) - the ALB is the only public-facing surface.
resource "aws_security_group" "container_sg" {
  name        = "aikido-ctf-container-sg-${var.team_id}"
  vpc_id      = data.aws_vpc.default.id
  description = "Allow HTTP from the shared ALB only"

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [data.aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# 9. Per-team target group + host-header listener rule on the shared ALB.
resource "aws_lb_target_group" "app" {
  name        = "blueprint-tg-${var.team_id}"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

# priority intentionally omitted: AWS assigns the next free priority on this
# shared listener at apply time, so independent per-team applies never collide.
resource "aws_lb_listener_rule" "app" {
  listener_arn = data.aws_lb_listener.shared_https.arn

  condition {
    host_header {
      values = [local.entrypoint_hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# 10. ECS Service to keep the container running and registered with the ALB.
resource "aws_ecs_service" "entrypoint_service" {
  name            = "entrypoint-service-${var.team_id}"
  cluster         = aws_ecs_cluster.ctf_cluster.id
  task_definition = aws_ecs_task_definition.entrypoint_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.container_sg.id]
    assign_public_ip = true # needed for egress (ECR pull) via IGW in the default public subnets - inbound is still SG-gated to the ALB only
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "entrypoint-app"
    container_port   = 80
  }

  depends_on = [aws_lb_listener_rule.app]
}

# 11. DNS record and output for the public endpoint the player will navigate to.
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.ctf.zone_id
  name    = local.entrypoint_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.shared.dns_name
    zone_id                = data.aws_lb.shared.zone_id
    evaluate_target_health = true
  }
}

output "entrypoint_url" {
  value       = local.entrypoint_url
  description = "The target endpoint URL where players begin their initial enumeration."
}