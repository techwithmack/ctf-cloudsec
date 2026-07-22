# Challenge 2 per-team stack. Applied once per team via
# `terraform apply -var="team_id=<team>" -var="zone_name=<zone>" -var="ctf_domain=<domain>"`, AFTER
# challenge-2-iac/bootstrap/ has been applied once (shared ALB, ACM cert, Route53
# zone, ECR repo - all referenced here read-only via data sources, never created,
# for the same reason Challenge 1 looks up its ECR repo as a data source: a
# per-team-applied stack cannot safely *create* a resource every other team's
# separate apply would also try to create).

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

locals {
  forgejo_hostname      = "${var.team_id}.${var.ctf_domain}"
  forgejo_url           = "https://${local.forgejo_hostname}"
  oidc_issuer           = "${local.forgejo_url}/api/actions"
  oidc_issuer_no_scheme = "${local.forgejo_hostname}/api/actions"
  org_name              = "team-${var.team_id}"
  repo_name             = "infra"
  ssm_param_name        = "/ctf/challenge2/${var.team_id}/runner-token"
  ssm_param_arn         = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_param_name}"

  # Computed deterministically (not via aws_iam_role.deploy.arn) to avoid a
  # circular dependency: the Forgejo task needs this ARN as an env var, but the
  # deploy role's own trust policy depends on the OIDC provider, which in turn
  # depends on Forgejo already being healthy - a cycle if the task definition
  # also depended directly on the role resource.
  deploy_role_name = "shadow-pipeline-deploy-${var.team_id}"
  deploy_role_arn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${local.deploy_role_name}"
}

# Terraform-managed (not just written by bootstrap.sh via raw AWS CLI) so that
# `terraform destroy` actually deletes it. Found by live testing: without this,
# a team_id's parameter path survives destroy, and a later re-apply of the same
# team_id starts with a stale token still sitting there - the EC2 runner's
# polling loop would grab that stale, no-longer-valid value before the fresh
# Forgejo container (with a brand-new database) has a chance to overwrite it,
# and registration fails with "runner registration token not found".
resource "aws_ssm_parameter" "runner_token" {
  name  = local.ssm_param_name
  type  = "SecureString"
  value = "PENDING"

  lifecycle {
    ignore_changes = [value] # bootstrap.sh overwrites this at runtime; Terraform shouldn't fight it
  }
}

# ---------------------------------------------------------------------------
# Shared bootstrap resources, looked up read-only
# ---------------------------------------------------------------------------

data "aws_vpc" "default" { default = true }
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_lb" "shared" {
  name = "shadow-pipeline-alb"
}

data "aws_lb_listener" "shared_https" {
  load_balancer_arn = data.aws_lb.shared.arn
  port              = 443
}

data "aws_security_group" "alb_sg" {
  filter {
    name   = "group-name"
    values = ["shadow-pipeline-alb-sg-*"]
  }
}

data "aws_route53_zone" "ctf" {
  name = var.zone_name
}

data "aws_ecr_repository" "forgejo" {
  name = "shadow-pipeline-forgejo"
}

# ---------------------------------------------------------------------------
# The flag
# ---------------------------------------------------------------------------

resource "random_id" "flag_hex" {
  byte_length = 16
}

locals {
  generated_flag = "FLAG-${random_id.flag_hex.hex}"
}

resource "aws_secretsmanager_secret" "flag" {
  name                    = "shadow-pipeline-flag-${var.team_id}"
  recovery_window_in_days = 0 # allow immediate delete on team reset/teardown

  tags = {
    Challenge = "The Shadow Pipeline Overlord"
    TeamID    = var.team_id
  }
}

resource "aws_secretsmanager_secret_version" "flag" {
  secret_id     = aws_secretsmanager_secret.flag.id
  secret_string = local.generated_flag
}

output "qa_verification_flag" {
  value       = local.generated_flag
  description = "The generated flag for QA verification purposes."
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Forgejo credentials (admin is internal-automation-only; player creds are what
# the team receives)
# ---------------------------------------------------------------------------

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "random_password" "player" {
  length  = 16
  special = false
}

# ---------------------------------------------------------------------------
# Persistent storage for Forgejo's data dir (SQLite DB, repos, Actions state).
# Without this, a Fargate task replacement wipes everything - including any
# branch/commit the player has already pushed mid-solve.
# ---------------------------------------------------------------------------

resource "aws_security_group" "efs_sg" {
  name        = "shadow-pipeline-efs-sg-${var.team_id}"
  vpc_id      = data.aws_vpc.default.id
  description = "Allow NFS from this Forgejo task only"

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.forgejo_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_efs_file_system" "forgejo_data" {
  encrypted = true

  tags = {
    Challenge = "The Shadow Pipeline Overlord"
    TeamID    = var.team_id
  }
}

resource "aws_efs_mount_target" "forgejo_data" {
  for_each        = toset(data.aws_subnets.default.ids)
  file_system_id  = aws_efs_file_system.forgejo_data.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs_sg.id]
}

# Terraform considers a mount target "created" as soon as the API call
# succeeds, but its DNS hostname isn't reliably resolvable for a few more
# seconds - without this wait, the Fargate task can fail to start with
# "ResourceInitializationError: failed to invoke EFS utils commands... Failed
# to resolve <fs-id>.efs.<region>.amazonaws.com", found by live testing.
resource "null_resource" "wait_for_efs_mount_targets" {
  depends_on = [aws_efs_mount_target.forgejo_data]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      for id in ${join(" ", [for mt in aws_efs_mount_target.forgejo_data : mt.id])}; do
        for i in $(seq 1 30); do
          STATE=$(aws efs describe-mount-targets --mount-target-id "$id" --region "${var.aws_region}" --query 'MountTargets[0].LifeCycleState' --output text)
          if [ "$STATE" = "available" ]; then
            break
          fi
          sleep 5
        done
      done
    EOT
  }
}

# ---------------------------------------------------------------------------
# Forgejo (ECS Fargate)
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "ctf_cluster" {
  name = "shadow-pipeline-cluster-${var.team_id}"
}

resource "aws_iam_role" "ecs_execution_role" {
  name = "shadow-pipeline-ecs-execution-${var.team_id}"

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

# Separate from the execution role: this is the container's own runtime identity,
# scoped to exactly one action - writing the runner registration token it mints
# to this team's one SSM parameter. Deliberately has no other AWS permissions.
resource "aws_iam_role" "forgejo_task" {
  name = "shadow-pipeline-forgejo-task-${var.team_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "forgejo_task_ssm_write" {
  name = "write-runner-token"
  role = aws_iam_role.forgejo_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:PutParameter"]
      Resource = local.ssm_param_arn
    }]
  })
}

resource "aws_security_group" "forgejo_sg" {
  name        = "shadow-pipeline-forgejo-sg-${var.team_id}"
  vpc_id      = data.aws_vpc.default.id
  description = "Allow HTTP from the shared ALB only"

  ingress {
    from_port       = 3000
    to_port         = 3000
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

resource "aws_cloudwatch_log_group" "forgejo" {
  name              = "/ecs/shadow-pipeline-forgejo-${var.team_id}"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "forgejo" {
  family                   = "shadow-pipeline-forgejo-${var.team_id}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.forgejo_task.arn

  volume {
    name = "forgejo-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.forgejo_data.id
      root_directory     = "/"
      transit_encryption = "ENABLED"
    }
  }

  container_definitions = jsonencode([{
    name      = "forgejo"
    image     = "${data.aws_ecr_repository.forgejo.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 3000
      hostPort      = 3000
    }]

    mountPoints = [{
      sourceVolume  = "forgejo-data"
      containerPath = "/data"
      readOnly      = false
    }]

    environment = [
      { name = "FORGEJO__actions__ENABLED", value = "true" },
      { name = "FORGEJO__security__INSTALL_LOCK", value = "true" },
      { name = "FORGEJO__database__DB_TYPE", value = "sqlite3" },
      { name = "FORGEJO__server__ROOT_URL", value = "${local.forgejo_url}/" },
      { name = "ADMIN_USERNAME", value = "ctfadmin" },
      { name = "ADMIN_PASSWORD", value = random_password.admin.result },
      { name = "ORG_NAME", value = local.org_name },
      { name = "REPO_NAME", value = local.repo_name },
      { name = "PLAYER_USERNAME", value = "player" },
      { name = "PLAYER_PASSWORD", value = random_password.player.result },
      { name = "AWS_DEPLOY_ROLE_ARN", value = local.deploy_role_arn },
      { name = "FLAG_SECRET_ID", value = aws_secretsmanager_secret.flag.arn },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "SSM_PARAM_NAME", value = local.ssm_param_name },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.forgejo.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "forgejo"
      }
    }
  }])
}

resource "aws_lb_target_group" "forgejo" {
  name        = "shadow-tg-${var.team_id}"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    path                = "/api/v1/version"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
  }
}

# priority intentionally omitted: AWS assigns the next free priority on this
# shared listener at apply time, so independent per-team applies never collide.
resource "aws_lb_listener_rule" "forgejo" {
  listener_arn = data.aws_lb_listener.shared_https.arn

  condition {
    host_header {
      values = [local.forgejo_hostname]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.forgejo.arn
  }
}

resource "aws_ecs_service" "forgejo" {
  name             = "forgejo-service-${var.team_id}"
  cluster          = aws_ecs_cluster.ctf_cluster.id
  task_definition  = aws_ecs_task_definition.forgejo.arn
  desired_count    = 1
  launch_type      = "FARGATE"
  platform_version = "1.4.0" # required for EFS volume support

  network_configuration {
    subnets          = data.aws_subnets.default.ids
    security_groups  = [aws_security_group.forgejo_sg.id]
    assign_public_ip = true # needed for egress (ECR pull, SSM) via IGW in the default public subnets - inbound is still SG-gated to the ALB only
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.forgejo.arn
    container_name   = "forgejo"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener_rule.forgejo, null_resource.wait_for_efs_mount_targets]
}

resource "aws_route53_record" "forgejo" {
  zone_id = data.aws_route53_zone.ctf.zone_id
  name    = local.forgejo_hostname
  type    = "A"

  alias {
    name                   = data.aws_lb.shared.dns_name
    zone_id                = data.aws_lb.shared.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# IAM OIDC federation - the trust boundary. Deliberately NOT the vulnerability:
# the condition below correctly restricts assumption to the exact ref pattern
# used by the deploy workflow. The escalation only works because Forgejo's
# branch protection (set in forgejo/bootstrap.sh) fails to gate who can push a
# ref matching that pattern.
# ---------------------------------------------------------------------------

# AWS validates an OIDC provider by connecting to its issuer's discovery endpoint
# at creation time - nothing enforces that Forgejo is actually up and healthy
# behind the ALB before this resource is created otherwise, so it fails outright
# ("OpenIdIdpCommunicationError") if it races ahead of the ECS service.
resource "null_resource" "wait_for_forgejo_healthy" {
  depends_on = [aws_ecs_service.forgejo]

  triggers = {
    service = aws_ecs_service.forgejo.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      for i in $(seq 1 60); do
        STATE=$(aws elbv2 describe-target-health \
          --target-group-arn "${aws_lb_target_group.forgejo.arn}" \
          --region "${var.aws_region}" \
          --query 'TargetHealthDescriptions[0].TargetHealth.State' \
          --output text 2>/dev/null || echo "")
        if [ "$STATE" = "healthy" ]; then
          exit 0
        fi
        sleep 10
      done
      echo "Timed out waiting for the Forgejo target to become healthy" >&2
      exit 1
    EOT
  }
}

resource "aws_iam_openid_connect_provider" "forgejo" {
  url            = local.oidc_issuer
  client_id_list = ["sts.amazonaws.com"]
  # thumbprint_list intentionally omitted: the ALB serves a publicly-trusted ACM
  # certificate, so AWS trusts it directly without thumbprint pinning.

  depends_on = [null_resource.wait_for_forgejo_healthy]
}

resource "aws_iam_role" "deploy" {
  name = local.deploy_role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.forgejo.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_no_scheme}:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "${local.oidc_issuer_no_scheme}:sub" = "repo:${local.org_name}/${local.repo_name}:ref:refs/heads/deploy/*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "deploy_secrets_read" {
  name = "read-flag-secret"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.flag.arn
    }]
  })
}

# ---------------------------------------------------------------------------
# CI runner (EC2 - Fargate cannot run the Docker-in-Docker workload act_runner
# needs). Deliberately carries no AWS permissions beyond reading its own
# registration token: cloud privilege in this challenge comes from the OIDC
# token exchange during a job run, never from the runner host itself.
# ---------------------------------------------------------------------------

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_iam_role" "runner" {
  name = "shadow-pipeline-runner-${var.team_id}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "runner_ssm_read" {
  name = "read-runner-token"
  role = aws_iam_role.runner.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = local.ssm_param_arn
    }]
  })
}

resource "aws_iam_role_policy_attachment" "runner_ssm_core" {
  role       = aws_iam_role.runner.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "runner" {
  name = "shadow-pipeline-runner-${var.team_id}"
  role = aws_iam_role.runner.name
}

resource "aws_security_group" "runner_sg" {
  name        = "shadow-pipeline-runner-sg-${var.team_id}"
  vpc_id      = data.aws_vpc.default.id
  description = "CI runner - untrusted job execution surface, no inbound needed"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "runner" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.runner_instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.runner_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  associate_public_ip_address = true
  user_data_replace_on_change = true # user-data only runs on first boot, so a change must force a fresh instance

  user_data = templatefile("${path.module}/runner/user_data.sh.tftpl", {
    forgejo_url    = local.forgejo_url
    ssm_param_name = local.ssm_param_name
    aws_region     = var.aws_region
    team_id        = var.team_id
  })

  tags = {
    Name      = "shadow-pipeline-runner-${var.team_id}"
    Challenge = "The Shadow Pipeline Overlord"
    TeamID    = var.team_id
  }

  depends_on = [aws_ecs_service.forgejo]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "entrypoint_url" {
  value       = local.forgejo_url
  description = "The Forgejo URL this team's players should navigate to."
}

output "player_username" {
  value = "player"
}

output "player_password" {
  value     = random_password.player.result
  sensitive = true
}
