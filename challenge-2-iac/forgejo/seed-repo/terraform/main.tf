# checkout-service's own application infrastructure - unrelated to the CI/CD platform this repo
# runs on itself (see docs/ARCHITECTURE.md).

terraform {
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

resource "aws_ecs_task_definition" "checkout" {
  family                   = "checkout-service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"

  container_definitions = jsonencode([{
    name  = "checkout-service"
    image = "${var.ecr_repository_url}:${var.image_tag}"

    portMappings = [{ containerPort = 8080 }]

    environment = [
      { name = "DB_HOST", value = var.db_host },
      { name = "DB_NAME", value = "checkout" },
    ]

    secrets = [
      { name = "DB_PASSWORD", valueFrom = var.db_password_secret_arn },
    ]
  }])
}

resource "aws_ecs_service" "checkout" {
  name            = "checkout-service"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.checkout.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "checkout-service"
    container_port   = 8080
  }
}
