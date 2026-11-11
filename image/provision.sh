#!/bin/bash
# Installs everything the CI jobs that use this image need, so ephemeral
# runners booted from this AMI skip per-job tool downloads. Runs as root during
# the Packer build, before the actions runner itself is installed.
set -euo pipefail

: "${RUNNER_USER:?}" "${BUN_VERSION:?}" "${NODE_MAJOR:?}" "${PREPULL_IMAGES:?}"
export DEBIAN_FRONTEND=noninteractive

cloud-init status --wait >/dev/null

apt-get -y update
apt-get -y install ca-certificates curl gnupg lsb-release jq git unzip zip

# Docker CE with the Buildx and Compose plugins (docker/setup-buildx-action,
# docker/build-push-action, and the integration test containers).
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

# GitHub CLI (Dependabot auto-merge and deploy scripts call `gh`).
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list

apt-get -y update
apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin gh
systemctl enable --now containerd.service docker.service
usermod -a -G docker "$RUNNER_USER"

# CloudWatch agent (the module ships runner logs with it) and the AWS CLI.
curl -fsSL https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb -o /tmp/cwagent.deb
dpkg -i /tmp/cwagent.deb
curl -fsSL https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# Node into the runner tool cache, where actions/setup-node finds it without a
# download (`node-version: '26'` matches any cached 26.x).
node_version="$(curl -fsSL https://nodejs.org/dist/index.json | jq -r --arg m "v${NODE_MAJOR}." '[.[] | select(.version | startswith($m))][0].version')"
if [ -z "$node_version" ] || [ "$node_version" = "null" ]; then
  echo "no Node ${NODE_MAJOR}.x release found" >&2
  exit 1
fi
node_dir="/opt/hostedtoolcache/node/${node_version#v}/x64"
mkdir -p "$node_dir"
curl -fsSL "https://nodejs.org/dist/${node_version}/node-${node_version}-linux-x64.tar.xz" | tar -xJ -C "$node_dir" --strip-components=1
touch "${node_dir}.complete"

# Bun at ~/.bun/bin, the path oven-sh/setup-bun checks first: when the binary
# there already matches the requested version it skips the download.
sudo -u "$RUNNER_USER" -H bash -c "curl -fsSL https://bun.sh/install | bash -s 'bun-v${BUN_VERSION}'"
sudo -u "$RUNNER_USER" -H "/home/${RUNNER_USER}/.bun/bin/bun" --version

# Images the jobs pull every run: integration-test Postgres/Redis, a
# Caddyfile check, and the BuildKit image setup-buildx-action starts.
for image in $PREPULL_IMAGES; do
  docker pull "$image"
done

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/cwagent.deb /tmp/awscliv2.zip /tmp/aws
