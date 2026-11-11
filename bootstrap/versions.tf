terraform {
  # 1.10+ for S3 native state locking (use_lockfile).
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State lives in the bucket this stack creates; the settings come from
  # backend.hcl, gitignored because the bucket name carries the account ID:
  # `terraform init -backend-config=backend.hcl`. In a new account the bucket
  # doesn't exist yet: comment this out for the first apply, then restore it
  # and run `terraform init -migrate-state -backend-config=backend.hcl`.
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "gha-runners"
      ManagedBy = "terraform"
    }
  }
}
