terraform {
  # 1.10+ for S3 native state locking (use_lockfile); the module itself needs 1.5.6+.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.33" # the runner module needs >= 6.33
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  # State lives in the bucket the bootstrap stack creates. The settings come
  # from backend.hcl, which is gitignored because the bucket name carries the
  # AWS account ID: `terraform init -backend-config=backend.hcl` (see README).
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
