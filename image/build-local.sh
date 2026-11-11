#!/usr/bin/env bash
# Builds the runner image from this machine and promotes it, doing what
# .github/workflows/build-image.yml does (that workflow needs the GitHub OIDC
# role, which the bootstrap stack only creates with create_image_build_role).
#
#   AWS_PROFILE=runner-infra ./build-local.sh
#
# Environment (all optional):
#   AWS_REGION      region to build in (default us-east-2, like the stacks)
#   RUNNER_VERSION  actions/runner version (default: newest release >= 3 days old)
#   BUN_VERSION     Bun version (default: newest release >= 3 days old)
#   AMI_PARAMETER   SSM parameter the runners read (default /gha-runner-image/ami-id)
#   KEEP_IMAGES     images to keep when pruning (default 3)
#
# Needs packer, the AWS CLI and gh (logged in, for the release lookups).
set -euo pipefail

cd "$(dirname "$0")"

export AWS_REGION="${AWS_REGION:-us-east-2}"
AMI_PARAMETER="${AMI_PARAMETER:-/gha-runner-image/ami-id}"
KEEP_IMAGES="${KEEP_IMAGES:-3}"
MIN_RELEASE_AGE_DAYS=3
export MSYS_NO_PATHCONV=1 # Git Bash: keep /gha-runner-image/... from becoming a Windows path

# Packer's AWS plugin may not read every credential type the AWS CLI does
# (e.g. `aws login` sessions), so hand it plain temporary credentials.
if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  eval "$(aws configure export-credentials --format env | tr -d '\r')"
fi

# Newest stable release at least MIN_RELEASE_AGE_DAYS old, without the tag prefix.
cutoff="$(date -u -d "-${MIN_RELEASE_AGE_DAYS} days" +%Y-%m-%dT%H:%M:%SZ)"
latest_release() {
  gh api "repos/$1/releases?per_page=30" --jq "[.[] | select((.draft or .prerelease) | not) | select(.published_at <= \"$cutoff\")] | sort_by(.published_at) | last | .tag_name // \"\" | ltrimstr(\"$2\")"
}
RUNNER_VERSION="${RUNNER_VERSION:-$(latest_release actions/runner v)}"
BUN_VERSION="${BUN_VERSION:-$(latest_release oven-sh/bun bun-v)}"
[ -n "$RUNNER_VERSION" ] && [ -n "$BUN_VERSION" ] || { echo "could not resolve the runner/bun versions" >&2; exit 1; }

source_commit="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- . || echo -dirty)"
current_ami="$(aws ssm get-parameter --name "$AMI_PARAMETER" --query Parameter.Value --output text 2>/dev/null | tr -d '\r' || true)"
[ "$current_ami" = "None" ] && current_ami=""

echo "Building in $AWS_REGION: actions/runner $RUNNER_VERSION, bun $BUN_VERSION, commit $source_commit"
echo "Current image: ${current_ami:-none}"

packer init .
packer build -color=false \
  -var "region=$AWS_REGION" \
  -var "runner_version=$RUNNER_VERSION" \
  -var "bun_version=$BUN_VERSION" \
  -var "source_commit=$source_commit" \
  .

new_ami="$(grep -o '"artifact_id": *"[^"]*"' manifest.json | tail -n 1 | sed -E 's/.*:(ami-[0-9a-f]+)"$/\1/')"
[[ "$new_ami" == ami-* ]] || { echo "no AMI in packer's manifest.json" >&2; exit 1; }

# Promote: the runners resolve this parameter at every launch, so new runners
# use the image from now on. The outgoing image stays one command away.
aws ec2 wait image-available --image-ids "$new_ami"
if [ -n "$current_ami" ]; then
  aws ssm put-parameter --name "${AMI_PARAMETER}-previous" --type String --data-type aws:ec2:image \
    --value "$current_ami" --overwrite >/dev/null
fi
aws ssm put-parameter --name "$AMI_PARAMETER" --type String --data-type aws:ec2:image \
  --value "$new_ami" --overwrite >/dev/null
echo "Promoted $new_ami (previous: ${current_ami:-none})"

# Prune: keep the newest KEEP_IMAGES, never the promoted or previous image.
aws ec2 describe-images --owners self \
  --filters Name=tag:Name,Values=gha-runner-image Name=state,Values=available \
  --query "reverse(sort_by(Images, &CreationDate))[${KEEP_IMAGES}:].[ImageId, join(' ', BlockDeviceMappings[].Ebs.SnapshotId)]" \
  --output text | tr -d '\r' | while read -r id snaps; do
  [ -n "$id" ] || continue
  if [ "$id" = "$new_ami" ] || [ "$id" = "$current_ami" ]; then continue; fi
  echo "Deregistering $id"
  aws ec2 deregister-image --image-id "$id"
  for snap in $snaps; do aws ec2 delete-snapshot --snapshot-id "$snap"; done
done
