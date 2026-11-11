variable "region" {
  description = "Region the image is built in and the runners run in."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "owner/name of this repository; only its main branch may assume the build role."
  type        = string
  default     = "COsborn2/gha-runner-image"
}

variable "ami_parameter_name" {
  description = "SSM parameter holding the promoted AMI ID (the workflow's AMI_SSM_PARAMETER). The workflow also writes <name>-previous."
  type        = string
  default     = "/gha-runner-image/ami-id"
}

variable "create_github_oidc_provider" {
  description = "An account can hold only one GitHub OIDC provider. Set false if one already exists; it is then looked up instead."
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "S3 bucket for Terraform state. Defaults to gha-terraform-state-<account id>."
  type        = string
  default     = null
}
