#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT}/Config/Octelium.xcconfig"
SEMVER_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

requested="${1:-}"
if [ -z "${requested}" ]; then
  echo "Usage: make release VERSION=x.y.z" >&2
  exit 1
fi

cd "${ROOT}"

if [ -n "$(git status --porcelain)" ]; then
  echo "The worktree must be clean before creating a release" >&2
  exit 1
fi

current="$(sed -n 's/^MARKETING_VERSION = \(.*\)$/\1/p' "${CONFIG}")"
if ! [[ "${current}" =~ ${SEMVER_PATTERN} ]]; then
  echo "Current version is not a stable SemVer: ${current}" >&2
  exit 1
fi

IFS=. read -r major minor patch <<< "${current}"

case "${requested}" in
  major)
    version="$((major + 1)).0.0"
    ;;
  minor)
    version="${major}.$((minor + 1)).0"
    ;;
  patch)
    version="${major}.${minor}.$((patch + 1))"
    ;;
  *)
    version="${requested}"
    ;;
esac

if ! [[ "${version}" =~ ${SEMVER_PATTERN} ]]; then
  echo "Invalid stable SemVer: ${version}" >&2
  exit 1
fi

if [ "${version}" = "${current}" ]; then
  echo "Version is already ${version}" >&2
  exit 1
fi

if [ "$(printf '%s\n%s\n' "${current}" "${version}" | sort -V | tail -n 1)" != "${version}" ]; then
  echo "Version ${version} must be greater than ${current}" >&2
  exit 1
fi

IFS=. read -r major_next minor_next patch_next <<< "${version}"
if [ "${minor_next}" -gt 999 ] || [ "${patch_next}" -gt 999 ]; then
  echo "The minor and patch versions must not exceed 999" >&2
  exit 1
fi

build="$((major_next * 1000000 + minor_next * 1000 + patch_next))"

tag="v${version}"
if git rev-parse --verify --quiet "refs/tags/${tag}" > /dev/null; then
  echo "Tag already exists: ${tag}" >&2
  exit 1
fi

sed -i.bak \
  -e "s/^MARKETING_VERSION = .*/MARKETING_VERSION = ${version}/" \
  -e "s/^CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${build}/" \
  "${CONFIG}"
rm -f "${CONFIG}.bak"

git add -- "${CONFIG}"
git diff --cached --check
git commit -m "chore: release ${tag}"
git tag -a "${tag}" -m "${tag}"

echo "Created release commit and tag ${tag}"
