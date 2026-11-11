variable "region" {
  description = "Region the image is built in and the runners run in. Keep it the same as the runners stack's; it must be a region the account's SCPs allow."
  type        = string
  default     = "us-east-2"
}

variable "create_image_build_role" {
  description = "Create the GitHub OIDC provider and the role build-image.yml assumes. Only the prebuilt image (image/, paused) needs them, and the account's SCPs may forbid creating OIDC providers."
  type        = bool
  default     = false
}

variable "github_repository" {
  description = "owner/name of this repository; only its main branch may assume the image build role."
  type        = string
  default     = "COsborn2/gha-runners"
}

variable "ami_parameter_name" {
  description = "SSM parameter holding the promoted AMI ID (the workflow's AMI_SSM_PARAMETER). The workflow also writes <name>-previous."
  type        = string
  default     = "/gha-runner-image/ami-id"
}

variable "create_github_oidc_provider" {
  description = "With create_image_build_role: an account can hold only one GitHub OIDC provider. Set false if one already exists; it is then looked up instead."
  type        = bool
  default     = true
}

variable "state_bucket_name" {
  description = "S3 bucket for Terraform state. Defaults to gha-terraform-state-<account id>."
  type        = string
  default     = null
}
