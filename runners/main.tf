data "aws_caller_identity" "current" {}

# Which image runners launch from. Both are SSM parameters that launch
# templates resolve at every launch, so promoting a new image (or Canonical
# publishing one) takes effect without an apply.
# - The prebuilt image from image/: tools and the runner baked in, and it
#   starts the runner itself, so no user data.
# - Canonical's latest Ubuntu 24.04, with user data installing everything.
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  ami_parameter_arn = (
    var.use_prebuilt_image
    ? "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.prebuilt_ami_parameter_name}"
    : data.aws_ssm_parameter.ubuntu_ami.arn
  )
}

# The module grants scale-up ssm:GetParameter on the AMI parameter by building
# its ARN with this account's ID (arn:aws:ssm:<region>:<account>:parameter/...).
# Canonical's parameter is public, and public parameter ARNs have no account
# (arn:aws:ssm:<region>::parameter/...), so that grant never matches and every
# launch fails with AccessDenied. This grants it on the real ARN (redundant,
# but harmless, for the prebuilt image's parameter in this account).
resource "aws_iam_role_policy" "scale_up_read_public_ami_parameter" {
  for_each = local.runner_types

  name = "read-public-ami-parameter"
  role = module.runners.runners_map[each.key].role_scale_up.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = local.ami_parameter_arn
    }]
  })
}

# Shared with the GitHub App (its webhook secret), which signs every delivery with it.
resource "random_password" "webhook_secret" {
  length  = 40
  special = false
}

# Spot requests need this account-wide role. It's created here rather than by
# each runner type, which would collide as soon as there are two types. It only
# has to exist before the first job launches an instance, so nothing waits on it.
resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_service_linked_role ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}

module "runners" {
  source = "github-aws-runners/github-runner/aws//modules/multi-runner"
  # download-lambdas.sh reads this line to fetch the matching lambda zips.
  version = "8.1.0"

  prefix     = var.prefix
  aws_region = var.region

  vpc_id     = aws_vpc.runners.id
  subnet_ids = [for subnet in aws_subnet.public : subnet.id]
  # Public subnets without a NAT gateway (see network.tf).
  associate_public_ipv4_address = true

  # Repo-level runners: each runner registers to the repository whose job it
  # was launched for. The app's installations decide which repositories can
  # use the fleet.
  github_app = {
    id             = var.github_app_id
    key_base64     = filebase64(pathexpand(var.github_app_private_key_path))
    webhook_secret = random_password.webhook_secret.result
  }

  # Prebuilt lambdas from the module's GitHub release; fetched by
  # download-lambdas.sh (gitignored).
  webhook_lambda_zip                = "${path.module}/lambdas/webhook.zip"
  runners_lambda_zip                = "${path.module}/lambdas/runners.zip"
  runner_binaries_syncer_lambda_zip = "${path.module}/lambdas/runner-binaries-syncer.zip"

  eventbridge = {
    enable        = true
    accept_events = ["workflow_job"]
  }

  multi_runner_config = local.multi_runner_config

  # A scale-up run handles a whole batch of queued jobs (see runner-types.tf),
  # about a second per job; 60 s leaves room for a full batch of 10. A run that
  # times out is retried after the queue's visibility timeout, which the module
  # sets to this same value.
  runners_scale_up_lambda_timeout = 60

  logging_retention_in_days = 30
}
