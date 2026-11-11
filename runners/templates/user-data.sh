#!/bin/bash
# User data for the Ubuntu 24.04 runners. Installs what GitHub's ubuntu-latest
# has and the stock Ubuntu image lacks (Docker with Buildx and Compose, gh,
# jq, build tools, AWS CLI), then the module's scripts download, register and
# start an ephemeral runner. This is what makes a runner take a few minutes to
# come up; the prebuilt image in image/ moves all of it to build time.
#
# Rendered by Terraform's templatefile(): $${...} and %%{...} are template
# syntax, so the shell code below uses plain $var and never $-brace forms.
#
# The module's snippets are inserted through replace(..., "\r", ""). Terraform
# fetches the module with git, and Git for Windows' default core.autocrlf=true
# checks its scripts out with CRLF line endings, which bash refuses to run.

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

# Logging every command would print the runner's registration config.
set +x
%{ if enable_debug_logging }
set -x
%{ endif }

# Ubuntu's apt timers start shortly after boot and hold the dpkg lock that the
# installs below (and the runner's installdependencies.sh) need.
systemctl stop unattended-upgrades apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl mask unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
  echo "Waiting for the dpkg lock to be released..."
  sleep 5
done

${replace(pre_install, "\r", "")}

export DEBIAN_FRONTEND=noninteractive
deb_arch=$(dpkg --print-architecture) # amd64 / arm64
cpu_arch=$(uname -m)                  # x86_64 / aarch64
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")

# Package repositories for Docker CE and the GitHub CLI, then one apt update.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod a+r /etc/apt/keyrings/docker.asc /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$deb_arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" > /etc/apt/sources.list.d/docker.list
echo "deb [arch=$deb_arch signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list

apt-get -q update
apt-get -q -y install \
  build-essential \
  ca-certificates \
  curl \
  git \
  jq \
  unzip \
  wget \
  xz-utils \
  zip \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  gh

# Rootful Docker with the runner user in the docker group, as on GitHub's
# hosted runners. Rootless Docker would add no isolation here: the runner
# user has passwordless sudo, and the instance is discarded after one job.
user_name=ubuntu # also read by the module's install script below
usermod -aG docker "$user_name"
systemctl enable --now docker

# ubuntu-latest has a 4 GiB swap file; without one, an 8 GiB runner OOMs on
# builds the hosted runner survives.
if [ ! -f /swapfile ]; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
fi

# AWS CLI v2: the module's scripts use it to fetch the runner binary and its
# registration config.
awscli_dir=$(mktemp -d)
curl -fsSL -o "$awscli_dir/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-$cpu_arch.zip"
unzip -q "$awscli_dir/awscliv2.zip" -d "$awscli_dir"
"$awscli_dir/aws/install" --update
rm -rf "$awscli_dir"

%{ if enable_cloudwatch_agent }
# Ships the runner_log_files from runner-types.tf to CloudWatch Logs.
cw_deb=$(mktemp --suffix=.deb)
curl -fsSL -o "$cw_deb" "https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/$deb_arch/latest/amazon-cloudwatch-agent.deb"
dpkg -i -E "$cw_deb"
rm -f "$cw_deb"
amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c "ssm:${ssm_key_cloudwatch_agent_config}"
%{ endif }

${replace(install_runner, "\r", "")}

${replace(post_install, "\r", "")}

cd /opt/actions-runner

%{ if hook_job_started != "" }
cat > /opt/actions-runner/hook_job_started.sh <<'EOF'
${replace(hook_job_started, "\r", "")}
EOF
echo ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner/hook_job_started.sh | tee -a /opt/actions-runner/.env
%{ endif }

%{ if hook_job_completed != "" }
cat > /opt/actions-runner/hook_job_completed.sh <<'EOF'
${replace(hook_job_completed, "\r", "")}
EOF
echo ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/actions-runner/hook_job_completed.sh | tee -a /opt/actions-runner/.env
%{ endif }

${replace(start_runner, "\r", "")}
