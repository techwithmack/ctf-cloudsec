# CI bootstrap - apply this ONCE, before wiring up the GitHub Actions workflows
# in .github/workflows/. Unlike challenge-1-iac/bootstrap and challenge-2-iac/bootstrap
# (per-challenge, per-event shared resources), this stack is org-level: it exists once
# for the whole repo, independent of which challenges exist.
#
# Provisions:
#   1. An S3 bucket + DynamoDB table so both challenges can move from local Terraform
#      state (unusable from ephemeral GitHub-hosted runners) to shared remote state.
#   2. A GitHub Actions OIDC provider + IAM role that organizers' workflows assume to
#      run `terraform apply`/`destroy` against real team stacks - no long-lived AWS
#      keys stored in GitHub secrets.
#
# This role is deliberately NOT the same as either challenge's per-team OIDC deploy
# role (challenge-2-iac/main.tf's aws_iam_role.deploy) - that one is the intentionally
# vulnerable in-challenge target players escalate into. This one is real CI/CD
# infrastructure trusted only by this exact GitHub repo, used only by organizers.

terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# 1. Remote state backend
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "tf_state" {
  bucket = var.state_bucket_name

  # No force_destroy: this bucket holds the only copy of both challenges' live
  # infrastructure state. An accidental `terraform destroy` here should fail loudly,
  # not silently wipe every team's state.
}

resource "aws_s3_bucket_versioning" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tf_state" {
  bucket = aws_s3_bucket.tf_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tf_lock" {
  name         = var.state_lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

# ---------------------------------------------------------------------------
# 2. GitHub Actions OIDC federation for the organizer provisioning workflows
# ---------------------------------------------------------------------------

# AWS trusts GitHub's OIDC issuer via its TLS cert chain rather than a hardcoded
# thumbprint - fetched dynamically here so it can't silently go stale if GitHub
# rotates its intermediate CA.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# Trust policy restricts to this exact repo. Not restricted further to a branch/ref
# because both the apply and destroy workflows run from whatever the default branch
# is - the guardrail against accidental destroys is the GitHub Environment approval
# gate on the destroy workflow (configured in repo settings, see README), not this
# trust policy.
data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The `repository` claim is the real security boundary here: a stable,
    # ID-free `owner/repo` string, and all this needs anyway - no branch/ref
    # restriction was ever intended (both apply and destroy workflows run from
    # whatever the default branch is; the guardrail is the `destroy-approval`
    # environment gate on destroy, not this trust policy).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:repository"
      values   = [var.github_repo]
    }

    # AWS requires a `sub` (or `job_workflow_ref`) condition that isn't
    # wildcarded down to "match everything" - rejects the update otherwise
    # ("MalformedPolicyDocument ... not scoped to all"). This is NOT the real
    # access boundary (that's `repository` above) - it exists only to satisfy
    # that requirement. GitHub's actual sub claim is
    # `repo:{owner}@{owner_id}/{repo}@{repo_id}:ref:refs/heads/{branch}`
    # (confirmed by decoding a real token live - NOT the plain
    # `repo:{owner}/{repo}:ref:...` older docs/examples assume, which is why
    # the original `repo:${var.github_repo}:*` pattern here silently matched
    # nothing and every assume-role attempt failed with AccessDenied,
    # regardless of branch). The owner/repo IDs are wildcarded since they're
    # incidental to this account, not the actual thing being restricted.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${split("/", var.github_repo)[0]}@*/${split("/", var.github_repo)[1]}@*:*"]
    }
  }
}

resource "aws_iam_role" "github_actions_provisioner" {
  name               = "ctf-github-actions-provisioner"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

# Least-privilege-ish policy scoped to the resource naming conventions both
# challenges' per-team stacks use (aikido-ctf-*, flawed-blueprint-*,
# shadow-pipeline-*). A handful of action types don't support resource-level
# restriction in AWS's IAM model at all (e.g. ecs:RegisterTaskDefinition,
# ec2:RunInstances-adjacent Describe calls) - those are scoped to "*" with a
# comment rather than pretending a fake ARN restricts them.
data "aws_iam_policy_document" "provisioner_permissions" {
  # Remote state backend
  statement {
    sid       = "TerraformStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [aws_s3_bucket.tf_state.arn]
  }

  statement {
    sid       = "TerraformStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tf_state.arn}/*"]
  }

  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"]
    resources = [aws_dynamodb_table.tf_lock.arn]
  }

  # Challenge S3 buckets (Challenge 1's leaky bucket, per team). The
  # aws_s3_bucket resource in this AWS provider version reads every one of a
  # bucket's sub-configurations on every refresh (CORS, lifecycle, logging,
  # versioning, encryption, website, object lock, replication, request
  # payment, acceleration, location) regardless of whether any of them are
  # actually set - found by live testing one AccessDenied at a time, so
  # granted up front here rather than one more round trip per attribute.
  statement {
    sid    = "ChallengeBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket", "s3:GetBucketPolicy", "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy", "s3:GetBucketPublicAccessBlock", "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketTagging", "s3:PutBucketTagging", "s3:ListBucket", "s3:GetBucketAcl",
      "s3:GetBucketCORS", "s3:GetLifecycleConfiguration", "s3:GetBucketLogging",
      "s3:GetBucketObjectLockConfiguration", "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration", "s3:GetBucketVersioning", "s3:GetBucketWebsite",
      "s3:GetAccelerateConfiguration", "s3:GetBucketRequestPayment", "s3:GetBucketLocation",
    ]
    resources = ["arn:aws:s3:::aikido-ctf-blueprint-backup-*"]
  }

  statement {
    sid       = "ChallengeBucketObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:GetObjectTagging", "s3:PutObjectTagging", "s3:DeleteObjectTagging"]
    resources = ["arn:aws:s3:::aikido-ctf-blueprint-backup-*/*"]
  }

  # ECS/EC2/networking Describe calls: AWS does not support resource-level
  # restriction on these read-only Describe/List actions.
  #
  # DescribeLoadBalancerAttributes / ListHostedZones / ecr:ListTagsForResource /
  # DescribeVpcAttribute were all found missing by live testing - the
  # `aws_lb`, `aws_route53_zone`, `aws_ecr_repository`, and `aws_vpc` data
  # sources in this AWS provider version each call one more read-only API
  # than the original permission set assumed, and this role (unlike the
  # `ctf-user` IAM user used to author/test the Terraform locally) has no
  # broader permissions to silently fall back on.
  statement {
    sid    = "ReadOnlyDescribe"
    effect = "Allow"
    actions = [
      "ecs:DescribeClusters", "ecs:DescribeServices", "ecs:DescribeTaskDefinition", "ecs:ListTagsForResource",
      "ec2:DescribeVpcs", "ec2:DescribeVpcAttribute", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeImages",
      "ec2:DescribeInstances", "ec2:DescribeNetworkInterfaces", "ec2:DescribeAvailabilityZones",
      "ec2:DescribeAccountAttributes", "ec2:DescribeTags",
      "elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeLoadBalancerAttributes", "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeRules", "elasticloadbalancing:DescribeTargetGroups", "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth", "elasticloadbalancing:DescribeTags",
      "route53:GetHostedZone", "route53:ListHostedZones", "route53:ListHostedZonesByName", "route53:ListResourceRecordSets", "route53:GetChange", "route53:ListTagsForResource",
      "ecr:GetAuthorizationToken", "ecr:DescribeRepositories", "ecr:DescribeImages", "ecr:ListTagsForResource",
      "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
      "sts:GetCallerIdentity", "ssm:DescribeParameters", "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }

  # ECS write actions that don't support resource-level restriction either
  # (RegisterTaskDefinition, CreateCluster) - scoped as tightly as ECS allows.
  statement {
    sid       = "EcsClusterAndTaskDef"
    effect    = "Allow"
    actions   = ["ecs:CreateCluster", "ecs:DeleteCluster", "ecs:RegisterTaskDefinition", "ecs:DeregisterTaskDefinition", "ecs:TagResource"]
    resources = ["*"]
  }

  statement {
    sid    = "EcsServices"
    effect = "Allow"
    actions = [
      "ecs:CreateService", "ecs:UpdateService", "ecs:DeleteService",
    ]
    resources = [
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/aikido-ctf-cluster-*",
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/shadow-pipeline-cluster-*",
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/aikido-ctf-cluster-*/*",
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/shadow-pipeline-cluster-*/*",
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/flawed-blueprint-entrypoint-*:*",
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task-definition/shadow-pipeline-forgejo-*:*",
    ]
  }

  # EC2 security groups + the Challenge 2 CI runner instance. RunInstances requires
  # broad resource coverage across instance/image/subnet/sg/volume/network-interface
  # ARNs to work at all, so it's scoped to "*" rather than an incomplete fake
  # restriction.
  statement {
    sid    = "Ec2Write"
    effect = "Allow"
    actions = [
      "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
      "ec2:CreateTags", "ec2:DeleteTags",
      "ec2:RunInstances", "ec2:TerminateInstances", "ec2:StopInstances",
      "ec2:ModifyInstanceAttribute",
    ]
    resources = ["*"]
  }

  # Shared ALB listener rules + per-team target groups
  statement {
    sid    = "Elbv2Write"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateTargetGroup", "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup", "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:CreateRule", "elasticloadbalancing:DeleteRule", "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags",
    ]
    resources = ["*"] # target-group/listener-rule ARNs are only known after creation
  }

  # Route53 record changes, scoped to change-batches within any hosted zone -
  # ChangeResourceRecordSets itself can't be scoped tighter than zone ARN, and the
  # zone is shared bootstrap infra rather than a per-team resource.
  statement {
    sid       = "Route53Write"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/*"]
  }

  # IAM roles/instance-profiles/OIDC provider created per team. Scoped to the two
  # challenges' naming prefixes so this role can never touch unrelated IAM
  # principals in the account (including its own).
  statement {
    sid    = "IamRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:GetRolePolicy",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListRolePolicies",
      "iam:PassRole",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aikido-ctf-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/shadow-pipeline-*",
    ]
  }

  statement {
    sid    = "IamInstanceProfiles"
    effect = "Allow"
    actions = [
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
    ]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/shadow-pipeline-*"]
  }

  statement {
    sid       = "IamOidcProviderPerTeam"
    effect    = "Allow"
    actions   = ["iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint"]
    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/*"]
  }

  # Challenge 2's Secrets Manager flag (now one shared secret created by
  # bootstrap/, not per-team - GetSecretValue is what the per-team stack's data
  # source needs to read it) + SSM runner-token, per team.
  statement {
    sid    = "SecretsManagerFlag"
    effect = "Allow"
    actions = [
      "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
      "secretsmanager:PutSecretValue", "secretsmanager:GetSecretValue", "secretsmanager:TagResource",
      "secretsmanager:GetResourcePolicy",
    ]
    resources = ["arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:shadow-pipeline-flag-*"]
  }

  statement {
    sid    = "SsmRunnerToken"
    effect = "Allow"
    actions = [
      "ssm:PutParameter", "ssm:GetParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource",
      "ssm:ListTagsForResource",
    ]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ctf/challenge2/*"]
  }

  # Challenge 1's shared flag parameter (one per event, created by bootstrap/ -
  # per-team applies only ever read it).
  statement {
    sid       = "SsmChallenge1Flag"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/ctf/challenge1/flag"]
  }

  # ssm:GetParameter alone only returns ciphertext - WithDecryption=true (what
  # the Challenge 1 flag data source uses) makes a separate KMS Decrypt call
  # that IAM must authorize independently, even against the default aws/ssm
  # managed key. That key's ARN isn't known ahead of a bootstrap apply (and its
  # own resource policy can't be customized anyway - it's AWS-managed), so this
  # is scoped as "*" like this account's other un-scopable actions above.
  statement {
    sid       = "KmsDecryptDefaultSsmKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
  }

  # Challenge 2's Forgejo EFS volume, per team
  statement {
    sid    = "Efs"
    effect = "Allow"
    actions = [
      "elasticfilesystem:CreateFileSystem", "elasticfilesystem:DeleteFileSystem", "elasticfilesystem:DescribeFileSystems",
      "elasticfilesystem:CreateMountTarget", "elasticfilesystem:DeleteMountTarget", "elasticfilesystem:DescribeMountTargets",
      "elasticfilesystem:TagResource", "elasticfilesystem:DescribeTags", "elasticfilesystem:DescribeLifecycleConfiguration",
    ]
    resources = ["*"] # EFS file-system IDs are only known after creation
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    # logs:DescribeLogGroups is deliberately NOT here - it's a bulk-list
    # action that doesn't support resource-level restriction (found live:
    # AWS evaluated it against a malformed pseudo-ARN, not this log group's
    # real one, and denied regardless) - granted "*"-scoped in
    # ReadOnlyDescribe above instead.
    actions   = ["logs:CreateLogGroup", "logs:DeleteLogGroup", "logs:PutRetentionPolicy", "logs:TagResource", "logs:ListTagsForResource"]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/shadow-pipeline-forgejo-*"]
  }
}

resource "aws_iam_role_policy" "provisioner" {
  name   = "ctf-team-provisioning"
  role   = aws_iam_role.github_actions_provisioner.id
  policy = data.aws_iam_policy_document.provisioner_permissions.json
}

output "provisioner_role_arn" {
  value       = aws_iam_role.github_actions_provisioner.arn
  description = "Set this as the AWS_GITHUB_OIDC_ROLE_ARN secret in the GitHub repo (see README)."
}

output "state_bucket_name" {
  value = aws_s3_bucket.tf_state.bucket
}

output "state_lock_table_name" {
  value = aws_dynamodb_table.tf_lock.name
}
