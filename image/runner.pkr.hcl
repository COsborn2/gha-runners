# GitHub Actions runner AMI for terraform-aws-github-runner.
# Adapted from the module's images/ubuntu-jammy template (v8.1.0); the runner
# install/start scripts in vendor/ are that release's, unchanged.
#
#   packer init .
#   packer build -var region=us-east-2 -var runner_version=<x.y.z> -var bun_version=<x.y.z> .
#
# build-local.sh wraps this: it picks the versions, builds, and promotes the
# result into the SSM parameter the runners read.

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "region" {
  description = "Region to build the AMI in (the runners must launch in the same one)."
  type        = string
}

variable "runner_version" {
  description = "actions/runner version without the v prefix (https://github.com/actions/runner/releases)."
  type        = string
}

variable "bun_version" {
  description = "Bun to bake in, without the bun-v prefix (https://github.com/oven-sh/bun/releases)."
  type        = string
}

variable "node_major" {
  description = "Node major baked into the tool cache (workflows use node-version '26')."
  type        = number
  default     = 26
}

variable "prepull_images" {
  description = "Container images pulled into the AMI so jobs don't download them."
  type        = list(string)
  default = [
    "postgres:17-alpine",
    "redis:7-alpine",
    "caddy:2-alpine",
    "moby/buildkit:buildx-stable-1",
  ]
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "root_volume_size_gb" {
  description = "Docker builds and node_modules need far more than the stock 8 GB."
  type        = number
  default     = 40
}

variable "subnet_id" {
  description = "Subnet for the build instance; null uses the default VPC."
  type        = string
  default     = null
}

variable "associate_public_ip_address" {
  type    = bool
  default = null
}

variable "source_commit" {
  description = "Commit of this repo the image was built from (recorded as a tag)."
  type        = string
  default     = "local"
}

locals {
  runner_user = "ubuntu"
  timestamp   = formatdate("YYYYMMDDhhmm", timestamp())
}

source "amazon-ebs" "runner" {
  ami_name                    = "gha-runner-image-ubuntu-noble-amd64-${local.timestamp}"
  instance_type               = var.instance_type
  region                      = var.region
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ip_address
  ssh_username                = local.runner_user

  # SSH to the build instance only from the machine running Packer, not 0.0.0.0/0.
  temporary_security_group_source_public_ip = true

  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["099720109477"] # Canonical
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  # The rebuild workflow reads these to decide whether a new image is needed
  # and to find old images to delete.
  tags = {
    Name           = "gha-runner-image"
    OS_Version     = "ubuntu-noble"
    Runner_Version = var.runner_version
    Bun_Version    = var.bun_version
    Node_Major     = var.node_major
    Source_Commit  = var.source_commit
    Base_AMI_Name  = "{{ .SourceAMIName }}"
  }
  snapshot_tags = {
    Name = "gha-runner-image"
  }
}

build {
  sources = ["source.amazon-ebs.runner"]

  provisioner "shell" {
    script          = "provision.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Vars }} bash {{ .Path }}"
    environment_vars = [
      "RUNNER_USER=${local.runner_user}",
      "BUN_VERSION=${var.bun_version}",
      "NODE_MAJOR=${var.node_major}",
      "PREPULL_IMAGES=${join(" ", var.prepull_images)}",
    ]
  }

  provisioner "file" {
    content = templatefile("vendor/install-runner.sh", {
      install_runner = templatefile("vendor/templates/install-runner.sh", {
        ARM_PATCH                       = ""
        S3_LOCATION_RUNNER_DISTRIBUTION = ""
        RUNNER_ARCHITECTURE             = "x64"
      })
    })
    destination = "/tmp/install-runner.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "RUNNER_TARBALL_URL=https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-x64-${var.runner_version}.tar.gz",
    ]
    inline = [
      "echo ${local.runner_user} > /tmp/install-user.txt",
      "sudo chmod +x /tmp/install-runner.sh",
      "sudo RUNNER_ARCHITECTURE=x64 RUNNER_TARBALL_URL=$RUNNER_TARBALL_URL /tmp/install-runner.sh",
      "echo ImageOS=ubuntu24 | sudo tee -a /opt/actions-runner/.env",
    ]
  }

  provisioner "file" {
    content = templatefile("vendor/start-runner.sh", {
      start_runner = templatefile("vendor/templates/start-runner.sh", { metadata_tags = "enabled" })
    })
    destination = "/tmp/start-runner.sh"
  }

  provisioner "shell" {
    inline = [
      "sudo mv /tmp/start-runner.sh /var/lib/cloud/scripts/per-boot/start-runner.sh",
      "sudo chmod +x /var/lib/cloud/scripts/per-boot/start-runner.sh",
    ]
  }

  # Last step: if any check fails Packer stops here and no AMI is created, so
  # a broken image can never be promoted.
  provisioner "shell" {
    script          = "smoke-test.sh"
    execute_command = "chmod +x {{ .Path }}; sudo -E {{ .Vars }} bash {{ .Path }}"
    environment_vars = [
      "RUNNER_USER=${local.runner_user}",
      "RUNNER_VERSION=${var.runner_version}",
      "BUN_VERSION=${var.bun_version}",
      "NODE_MAJOR=${var.node_major}",
      "PREPULL_IMAGES=${join(" ", var.prepull_images)}",
    ]
  }

  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
