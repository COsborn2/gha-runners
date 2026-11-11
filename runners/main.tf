# Latest Ubuntu 24.04 LTS image, as published by Canonical. Launch templates
# resolve this parameter at every launch, so runners pick up Canonical's new
# images without an apply. To switch to the prebuilt image from image/, point
# the runner types at the bootstrap stack's `ami_parameter_arn` output instead
# (and drop the user-data installs the image makes redundant).
data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# The module grants scale-up ssm:GetParameter on the AMI parameter by building
# its ARN with this account's ID (arn:aws:ssm:<region>:<account>:parameter/...).
# Canonical's parameter is public, and public parameter ARNs have no account
# (arn:aws:ssm:<region>::parameter/...), so that grant never matches and every
# launch fails with AccessDenied. This grants it on the real ARN.
resource "aws_iam_role_policy" "scale_up_read_public_ami_parameter" {
  for_each = local.runner_types

  name = "read-public-ami-parameter"
  role = module.runners.runners_map[each.key].role_scale_up.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = data.aws_ssm_parameter.ubuntu_ami.arn
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

  logging_retention_in_days = 30
}
