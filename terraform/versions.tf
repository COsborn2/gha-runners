terraform {
  # 1.10+ for S3 native state locking (use_lockfile).
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # State starts local. After the first apply creates the bucket, uncomment this
  # and run `terraform init -migrate-state -backend-config=backend.hcl` (see
  # README). backend.hcl is gitignored: the bucket name carries the account ID.
  # backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "gha-runner-image"
      ManagedBy = "terraform"
    }
  }
}
