# gha-runner-image

An AWS AMI for [terraform-aws-github-runner](https://github.com/github-aws-runners/terraform-aws-github-runner)
(v8.1.0) with the tools CI jobs use already installed, so each ephemeral runner
starts work without downloading them. The image rebuilds itself here on free
GitHub-hosted minutes and is promoted through an SSM parameter the runners read
at every launch.

## What's in the image

| Baked in | Why |
| --- | --- |
| Ubuntu 24.04 (latest Canonical AMI at build time) | matches `ubuntu-latest` |
| Docker CE + Buildx + Compose plugins | image builds, integration-test containers |
| Bun (latest release) at `~ubuntu/.bun/bin` | `oven-sh/setup-bun` skips its download when this binary matches the repo's `.bun-version`; repos pinned to another version download theirs (a few seconds) |
| Node 26.x in `/opt/hostedtoolcache` | `actions/setup-node` with `node-version: '26'` finds it without a download |
| `postgres:17-alpine`, `redis:7-alpine`, `caddy:2-alpine`, `moby/buildkit:buildx-stable-1` | pulled by jobs every run |
| git, jq, curl, unzip, gh, AWS CLI, CloudWatch agent | workflow scripts, the module's log shipping |
| actions/runner (latest release at build time) + the module's start script | registers the runner on boot |

`image/smoke-test.sh` runs as the last Packer step and checks all of this; any
failure stops the build before an AMI exists.

## How it stays current

`.github/workflows/build-image.yml`:

- **Daily** it compares the promoted AMI's `Runner_Version` / `Bun_Version` tags with
  the latest [actions/runner](https://github.com/actions/runner/releases) and
  [Bun](https://github.com/oven-sh/bun/releases) releases, and builds only if either
  moved. A release must be at least 3 days old (`MIN_RELEASE_AGE_DAYS`) before it's
  baked in, so a bad one has time to be pulled. GitHub stops
  sending jobs to a runner 30 days after a newer runner release, so this stays far
  inside that window.
- **Weekly** (Monday) it rebuilds regardless, for OS security patches and fresh
  container images.
- On a **push to `main`** touching `image/`, and from the **Run workflow** button.
- **Pull requests** only lint and `packer validate`; they never get AWS credentials.

After a build it writes the new AMI ID to the SSM parameter (the old one moves to
`<parameter>-previous`) and deletes all but the newest 3 images, never touching
the current or previous one.

## Setup

Repository settings (Settings → Secrets and variables → Actions). The repo is
public and so are its Actions logs, so the role ARN (it contains the AWS account
ID) is a secret, masked in logs:

| Name | Kind | Value |
| --- | --- | --- |
| `AWS_ROLE_ARN` | secret | IAM role this workflow assumes via GitHub OIDC (contains the account ID) |
| `AWS_REGION` | variable | region the runners run in, e.g. `us-west-2` |
| `AMI_SSM_PARAMETER` | variable | e.g. `/gha-runner-image/ami-id` |

Also set Settings → Actions → General → "Require approval for all outside
collaborators", so a stranger's pull request can't run workflows without you
approving it. (Pull request runs get no secrets and no AWS access regardless.)

The IAM role must trust only `repo:<owner>/gha-runner-image:ref:refs/heads/main`
and allow Packer's EC2 actions plus `ssm:GetParameter`/`ssm:PutParameter` on the
two parameters.

## Using it from the runner module

```hcl
module "runners" {
  source  = "github-aws-runners/github-runner/aws"
  version = "8.1.0"

  enable_organization_runners = false # personal repos: register per repository
  enable_ephemeral_runners    = true
  enable_userdata             = false # the image already has the runner
  runner_run_as               = "ubuntu"

  # Resolved at every launch, so a promoted image is used without terraform apply.
  ami = {
    id_ssm_parameter_arn = "arn:aws:ssm:<region>:<account>:parameter/gha-runner-image/ami-id"
  }

  runner_extra_labels = ["ci"]
  # github_app, aws_region, vpc_id, subnet_ids, prefix, lambda zips ...
}
```

Workflows select these runners with `runs-on: [self-hosted, linux, x64, ci]`.

## Rollback

```bash
aws ssm put-parameter --name /gha-runner-image/ami-id --type String --data-type aws:ec2:image --overwrite \
  --value "$(aws ssm get-parameter --name /gha-runner-image/ami-id-previous --query Parameter.Value --output text)"
```

## Building by hand

```bash
cd image
packer init .
packer build -var region=us-east-1 -var runner_version=<x.y.z> -var bun_version=<x.y.z> .
```
