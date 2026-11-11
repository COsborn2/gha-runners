# gha-runners

Self-hosted GitHub Actions runners on AWS for my private repositories, built on
[terraform-aws-github-runner](https://github.com/github-aws-runners/terraform-aws-github-runner)
(v8.1.0). A job asks for one with `runs-on: aws-linux-x64`, gets a fresh EC2
instance, runs on it, and the instance terminates.

| Directory | What it is | Status |
| --- | --- | --- |
| `bootstrap/` | The Terraform state bucket; for the image, a GitHub OIDC provider and build role | applied by hand, once |
| `runners/` | The runner fleet: webhook, lambdas, VPC, runner types | applied by hand |
| `image/` | A prebuilt runner AMI so runners start faster | paused, [see below](#prebuilt-image-paused) |

## How it works

```
job queued ─► GitHub App webhook ─► API Gateway ─► webhook lambda ─► EventBridge
                                                                         │
     dispatcher lambda: do the job's labels match a runner type? ◄───────┘
         │ yes: queue it for that type
         ▼
     scale-up lambda launches an instance ─► user data installs tools,
     the runner registers to the job's repo ─► runs one job ─► instance terminates
```

- **Who can use it**: the repositories the GitHub App is installed on. Runners
  register at repository level, to the repository whose job launched them.
- **Ephemeral**: one job per instance. No files, caches or credentials carry
  over between jobs.
- **Near-zero idle cost**: between jobs only small lambdas run, every 5
  minutes. The VPC has public subnets only, so there's no NAT gateway
  (~$33/month saved), and the runner security group allows no inbound traffic.
- **Boot time is the trade-off**: a job waits roughly 2–4 minutes for its
  instance to boot and for user data to install Docker and the other tools. The
  [prebuilt image](#prebuilt-image-paused) is the fix.

## Runner types

Defined in [`runners/runner-types.tf`](runners/runner-types.tf); the name is the
label jobs use.

| Label | Instance | Disk | Max concurrent, per repository |
| --- | --- | --- | --- |
| `aws-linux-x64` | 2 vCPU / 8 GiB, on-demand: `m7a.large` first, then m7i, m6a, m6i, m5a, m5 `.large` if it has no capacity | 50 GB gp3 | 10 |

The instances are on-demand because the account's SCPs deny spot launches.
Where spot is allowed, switching a type to spot (see the comment in
`runner-types.tf`) costs roughly a third as much.

Every type runs Ubuntu 24.04, using Canonical's latest image at each launch.
[`runners/templates/user-data.sh`](runners/templates/user-data.sh) adds the
tools these repos' jobs use:

- Docker CE with Buildx and Compose. It runs as root, with the runner user in
  the `docker` group, as on hosted runners.
- `gh`, `git`, `jq`, `curl`, `wget`, `unzip`/`zip`, `xz`, `build-essential`
  and the AWS CLI.
- A 4 GiB swap file.
- The runner user, `ubuntu`, has passwordless `sudo`.

The rest of `ubuntu-latest`'s toolset isn't there. `actions/setup-node`,
`oven-sh/setup-bun` and similar actions download what they need.

To add a type (a bigger size, arm64, ...), add an entry to `runner_types` and
apply. A type costs nothing until a job asks for it.

## Setup

### 1. AWS credentials

Use credentials with admin rights, e.g. an IAM Identity Center profile:

```bash
aws sso login --profile <profile>
export AWS_PROFILE=<profile>
```

### 2. Bootstrap (`bootstrap/`, once)

This stack creates an S3 bucket for both stacks' Terraform state. Both stacks
default to `us-east-2`; set `region` in each if your account allows a
different region.

With `-var create_image_build_role=true` it also creates what the [prebuilt
image](#prebuilt-image-paused) needs:

- the GitHub OIDC provider;
- the image build role, which only this repo's `main` branch can assume, with
  EC2 rights limited to the build region and SSM rights limited to the two AMI
  parameters.

The stack keeps its own state in that bucket, so the first apply in a new
account starts with local state. Comment out `backend "s3" {}` in
`versions.tf`, then:

```bash
cd bootstrap
terraform init
terraform apply
```

Then restore the `backend` block and move the state into the bucket the apply
just created:

```bash
cat > backend.hcl <<EOF
bucket       = "$(terraform output -raw state_bucket)"
key          = "bootstrap/terraform.tfstate"
region       = "$(terraform output -raw region)"
use_lockfile = true
EOF
terraform init -migrate-state -backend-config=backend.hcl
```

From then on, a fresh checkout only needs that `backend.hcl` and
`terraform init -backend-config=backend.hcl`.

`backend.hcl` is gitignored because the bucket name contains the account ID.

### 3. Create the GitHub App

Open [New GitHub App](https://github.com/settings/apps/new) and fill in:

| Setting | Value |
| --- | --- |
| GitHub App name | anything unique, e.g. `<you>-gha-runners` |
| Homepage URL | this repository's URL |
| Webhook → Active | **unchecked** for now (step 5 turns it on) |
| Repository permissions | Actions: **Read-only** · Administration: **Read and write** (to register runners) · Checks: **Read-only** · Metadata: Read-only |
| Where can this GitHub App be installed? | Only on this account |

Create the app and note its **App ID**. Then click **Generate a private key**
and keep the `.pem` file outside this repository. Don't install the app yet.

### 4. Runners (`runners/`)

```bash
cd runners
cp terraform.tfvars.example terraform.tfvars    # App ID + path to the .pem
cat > backend.hcl <<EOF
bucket       = "$(terraform -chdir=../bootstrap output -raw state_bucket)"
key          = "runners/terraform.tfstate"
region       = "us-east-2"
use_lockfile = true
EOF
./download-lambdas.sh                           # the module's prebuilt lambdas
terraform init -backend-config=backend.hcl
terraform apply
```

On Windows, run these in Git Bash. In PowerShell, `bash` can resolve to WSL's
launcher instead of Git's.

If the apply fails to create `AWSServiceRoleForEC2Spot` because the name "has
been taken", the account already has that role. Set
`create_spot_service_linked_role = false` in `terraform.tfvars` and apply again.

### 5. Connect the app

In the app's settings:

1. **General → Webhook**: check **Active**, set the URL to
   `terraform output -raw webhook_endpoint` and the secret to
   `terraform output -raw webhook_secret`, and save.
2. **Permissions & events → Subscribe to events**: check **Workflow job**, and save.
3. **Install App** → your account → **Only select repositories** → pick the
   repositories it should serve.

## Adding a repository

Only add private repositories: on a public one, a pull request from a fork
could run its code on these instances.

1. Add the repository to the app's installation:
   [installations](https://github.com/settings/installations) → the app →
   Configure → Repository access.
2. Set a variable that points its jobs at the fleet:
   ```bash
   gh variable set CI_RUNS_ON --body aws-linux-x64 --repo <owner>/<repo>
   ```
3. In its workflows, change `runs-on` for each job that should run here:
   ```yaml
   runs-on: ${{ vars.CI_RUNS_ON || 'ubuntu-latest' }}
   ```

To move those jobs back to GitHub-hosted runners without a commit, delete the
variable: `gh variable delete CI_RUNS_ON --repo <owner>/<repo>`. Forks and copies
of the repository, which don't have the variable, use GitHub-hosted runners too.

## Operating

**Upgrading the module.** Bump `version` in `runners/main.tf` and read the
release notes. Then run `./download-lambdas.sh && terraform apply`; the script
fetches the lambdas for the new version.

**A job stays queued.** Check each step in order:

1. Did GitHub deliver the event? The app's settings → Advanced → Recent
   Deliveries; each delivery should have a 2xx response.
2. Did the job's labels match a runner type? CloudWatch Logs
   `/aws/lambda/gha-dispatch-to-runner`. A job matches a type only when every
   label in its `runs-on` is in that type's matcher.
3. Did an instance launch? `/aws/lambda/gha-aws-linux-x64-scale-up`.
   Capacity, quota and permission errors show up here. EC2 Fleet reports an
   error code for each instance type it tried, and an SCP denial names the
   policy.
4. Did the runner register? `/github-self-hosted-runners/gha-aws-linux-x64/user_data`
   and `.../runner-startup`, one log stream per instance.

To get a shell on a running instance: `aws ssm start-session --target <instance-id>`.

**Cost.** Between jobs, only lambda invocations, CloudWatch Logs (kept 30
days) and a small S3 bucket holding the runner binary: pennies a month. Each
job pays for its instance's time, including the 2–4 minute boot: about
$0.12/hour for `m7a.large` on-demand, so a cent or two per job.

## Prebuilt image (paused)

`image/` builds an AWS AMI with the runner and the tools jobs use already
installed, so a runner doesn't download them when it starts. That removes most
of the boot time. The image rebuilds itself on free GitHub-hosted minutes and is
promoted through an SSM parameter, which runners can read at every launch. It
isn't wired into `runners/` yet.

> `build-image.yml` runs on a daily schedule and fails until step 2 below is
> done. To stop it while the image work is paused, run
> `gh workflow disable "Build Runner Image"`.

### What's in the image

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

### How it stays current

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

### Turning it on

1. Apply `bootstrap/` with `-var create_image_build_role=true`, which creates
   the OIDC provider and build role. The account's SCPs must allow creating
   an OIDC provider. If you disabled the workflow, re-enable it:
   `gh workflow enable "Build Runner Image"`.
2. Add these under Settings → Secrets and variables → Actions, using the
   bootstrap stack's outputs. The repo is public and so are its Actions logs, so
   the role ARN, which contains the AWS account ID, is stored as a secret and
   masked in logs:

   | Name | Kind | Value |
   | --- | --- | --- |
   | `AWS_ROLE_ARN` | secret | `terraform output -raw build_role_arn` |
   | `AWS_REGION` | variable | `terraform output -raw region` |
   | `AMI_SSM_PARAMETER` | variable | `terraform output -raw ami_parameter_name` |

   Also set Settings → Actions → General → "Require approval for all outside
   collaborators", so a stranger's pull request can't run workflows until you
   approve it. (Pull request runs never get secrets or AWS access anyway.)
3. Actions → Build Runner Image → Run workflow. The first successful run creates
   the AMI parameter.
4. Switch the runners to the image in `runners/runner-types.tf`: set
   `ami.id_ssm_parameter_arn` to the bootstrap stack's `ami_parameter_arn`
   output, and set `enable_userdata = false`, because the image already contains
   the runner and its start script. Then apply.

### Rollback

```bash
aws ssm put-parameter --name /gha-runner-image/ami-id --type String --data-type aws:ec2:image --overwrite \
  --value "$(aws ssm get-parameter --name /gha-runner-image/ami-id-previous --query Parameter.Value --output text)"
```

### Building by hand

```bash
cd image
packer init .
packer build -var region=us-east-2 -var runner_version=<x.y.z> -var bun_version=<x.y.z> .
```
