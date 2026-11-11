data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id         = data.aws_caller_identity.current.account_id
  partition          = data.aws_partition.current.partition
  oidc_provider_arn  = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
  state_bucket_name  = coalesce(var.state_bucket_name, "gha-terraform-state-${local.account_id}")
  ami_parameter_arns = [for name in [var.ami_parameter_name, "${var.ami_parameter_name}-previous"] : "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${name}"]
}

# --- GitHub Actions OIDC: lets workflows get short-lived AWS credentials -----

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

# --- Build role: assumed by build-image.yml on this repo's main branch -------

data "aws_iam_policy_document" "build_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pushes, schedules and manual runs on main only: pull requests, other
    # branches and forks get a different subject and are refused.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "build" {
  name                 = "gha-runner-image-build"
  description          = "Builds and promotes the runner AMI from ${var.github_repository}"
  assume_role_policy   = data.aws_iam_policy_document.build_trust.json
  max_session_duration = 7200 # a build plus promotion fits comfortably
}

data "aws_iam_policy_document" "build" {
  # Packer's amazon-ebs builder (developer.hashicorp.com/packer/integrations/hashicorp/amazon#iam-task-or-instance-role)
  # plus the workflow's image cleanup. EC2 doesn't support resource-level
  # scoping for most of these, so they are fenced to the build region instead.
  statement {
    sid = "PackerBuildAndCleanup"
    actions = [
      "ec2:AttachVolume",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CopyImage",
      "ec2:CreateImage",
      "ec2:CreateKeyPair",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:DeleteKeyPair",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSnapshot",
      "ec2:DeleteVolume",
      "ec2:DeregisterImage",
      "ec2:DescribeImageAttribute",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeRegions",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSnapshots",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcs",
      "ec2:DetachVolume",
      "ec2:GetPasswordData",
      "ec2:ModifyImageAttribute",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifySnapshotAttribute",
      "ec2:RegisterImage",
      "ec2:RunInstances",
      "ec2:StopInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  statement {
    sid       = "PromoteAmi"
    actions   = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = local.ami_parameter_arns
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "build-and-promote"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}

# --- Terraform state bucket (this stack's and the runner stack's) -----------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Old state versions are kept 90 days, enough to recover from a bad apply.
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }
}
