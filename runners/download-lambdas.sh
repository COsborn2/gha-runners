#!/usr/bin/env bash
# Downloads the runner module's prebuilt lambdas into lambdas/ for the module
# version pinned in main.tf. Terraform hashes these zips at plan time, so run
# this before `terraform plan`/`apply`. It does nothing when lambdas/ already
# matches the pinned version, so it's safe to run every time.
set -euo pipefail

cd "$(dirname "$0")"

# The first `version = "x.y.z"` after the module's source line.
version="$(awk '
  /source *= *"github-aws-runners\/github-runner\/aws/ { in_module = 1 }
  in_module && /^[[:space:]]*version[[:space:]]*=/ {
    gsub(/^[^"]*"|".*$/, "")
    print
    exit
  }' main.tf)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Could not read the runner module version from main.tf (got '$version')." >&2
  exit 1
fi
tag="v$version"

lambdas=(webhook runners runner-binaries-syncer)

mkdir -p lambdas
up_to_date=true
[ "$(cat lambdas/VERSION 2>/dev/null || true)" = "$tag" ] || up_to_date=false
for name in "${lambdas[@]}"; do
  [ -s "lambdas/$name.zip" ] || up_to_date=false
done
if [ "$up_to_date" = true ]; then
  echo "lambdas/ already holds the $tag lambdas."
  exit 0
fi

rm -f lambdas/VERSION
for name in "${lambdas[@]}"; do
  url="https://github.com/github-aws-runners/terraform-aws-github-runner/releases/download/$tag/$name.zip"
  echo "Downloading $url"
  curl -fsSL --retry 3 -o "lambdas/$name.zip.partial" "$url"
  mv "lambdas/$name.zip.partial" "lambdas/$name.zip"
done
echo "$tag" > lambdas/VERSION
echo "lambdas/ now holds the $tag lambdas."
