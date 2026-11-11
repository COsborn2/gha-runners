output "build_role_arn" {
  description = "Set as the AWS_ROLE_ARN repository secret. Null unless create_image_build_role is set."
  value       = one(aws_iam_role.build[*].arn)
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
  description = "Put in backend.hcl for both stacks (bootstrap/ and runners/)."
  value       = aws_s3_bucket.state.bucket
}
