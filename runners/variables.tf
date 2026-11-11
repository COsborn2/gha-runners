variable "region" {
  description = "Region the runners run in. Keep it the same as the bootstrap stack's; it must be a region the account's SCPs allow."
  type        = string
  default     = "us-east-2"
}

variable "prefix" {
  description = "Prefix for the names of everything the runner module creates."
  type        = string
  default     = "gha"
}

variable "github_app_id" {
  description = "App ID of the GitHub App the runners register through (the app's settings → General → App ID)."
  type        = string
}

variable "github_app_private_key_path" {
  description = "Path to the GitHub App's private key (.pem). Read at plan time and stored in SSM Parameter Store as a SecureString."
  type        = string
}

variable "create_spot_service_linked_role" {
  description = "Create the account-wide AWSServiceRoleForEC2Spot role that spot launches need. Set false if the account already has it; the apply fails with \"has been taken\" otherwise."
  type        = bool
  default     = true
}
