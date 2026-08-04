variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "cluster_arn" {
  type        = string
  description = "ECS cluster checkout-service runs on"
}

variable "target_group_arn" {
  type        = string
  description = "ALB target group for checkout-service"
}

variable "ecr_repository_url" {
  type = string
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "db_host" {
  type = string
}

variable "db_password_secret_arn" {
  type        = string
  description = "Secrets Manager ARN for the checkout-db password"
}
