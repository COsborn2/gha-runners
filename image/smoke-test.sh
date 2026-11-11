#!/bin/bash
# Final Packer step: proves the image has what CI jobs expect. Any failure
# aborts the build before an AMI is created. Runs as root.
set -euo pipefail

: "${RUNNER_USER:?}" "${RUNNER_VERSION:?}" "${BUN_VERSION:?}" "${NODE_MAJOR:?}" "${PREPULL_IMAGES:?}"

fail() {
  echo "smoke test failed: $*" >&2
  exit 1
}

as_runner() {
  sudo -u "$RUNNER_USER" -H bash -lc "$1"
}

echo "== docker"
systemctl is-active --quiet docker || fail "docker service is not running"
id -nG "$RUNNER_USER" | tr ' ' '\n' | grep -qx docker || fail "$RUNNER_USER is not in the docker group"
docker buildx version
docker compose version
for image in $PREPULL_IMAGES; do
  docker image inspect "$image" >/dev/null || fail "image $image was not pre-pulled"
done

echo "== bun"
# shellcheck disable=SC2088 # the tilde expands in the runner user's shell
bun_actual="$(as_runner '~/.bun/bin/bun --version')"
[ "$bun_actual" = "$BUN_VERSION" ] || fail "bun is $bun_actual, expected $BUN_VERSION"

echo "== node"
node_bin="$(find /opt/hostedtoolcache/node -maxdepth 4 -path "*/${NODE_MAJOR}.*/x64/bin/node" | head -n 1)"
[ -n "$node_bin" ] || fail "no Node ${NODE_MAJOR}.x in /opt/hostedtoolcache"
[ -f "$(dirname "$(dirname "$node_bin")").complete" ] || fail "Node tool cache entry is missing its .complete marker"
"$node_bin" --version

echo "== system"
if [ ! -f /swapfile ] || ! grep -q '^/swapfile ' /etc/fstab; then
  fail "/swapfile is missing or not in /etc/fstab"
fi
if systemctl is-enabled --quiet apt-daily.timer; then
  fail "apt-daily.timer is still enabled"
fi

echo "== cli tools"
for tool in git jq curl wget unzip zip xz gcc make gh aws; do
  command -v "$tool" >/dev/null || fail "$tool is not installed"
done
gh --version | head -n 1
aws --version

echo "== actions runner"
[ -x /opt/actions-runner/config.sh ] || fail "actions runner is not installed"
[ -x /var/lib/cloud/scripts/per-boot/start-runner.sh ] || fail "start-runner.sh is not installed"
runner_actual="$(as_runner '/opt/actions-runner/bin/Runner.Listener --version')"
[ "$runner_actual" = "$RUNNER_VERSION" ] || fail "runner is $runner_actual, expected $RUNNER_VERSION"
[ "$(stat -c %U /opt/actions-runner)" = "$RUNNER_USER" ] || fail "/opt/actions-runner is not owned by $RUNNER_USER"

echo "all smoke tests passed"
