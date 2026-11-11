output "build_role_arn" {
  description = "Set as the AWS_ROLE_ARN repository secret."
  value       = aws_iam_role.build.arn
}

output "ami_parameter_name" {
  description = "Set as the AMI_SSM_PARAMETER repository variable."
  value       = var.ami_parameter_name
}

output "ami_parameter_arn" {
  description = "Pass to the runner module as ami.id_ssm_parameter_arn."
  value       = local.ami_parameter_arns[0]
}

output "region" {
  description = "Set as the AWS_REGION repository variable."
  value       = var.region
}

output "state_bucket" {
  description = "Put in backend.hcl (and the runner stack's backend config)."
  value       = aws_s3_bucket.state.bucket
}
