#!/usr/bin/env bash
set -euo pipefail

# Build & push the cmkl-web-ui image to GHCR.
# Build context = repo root (this dir). Run from repo root: ./build.sh [feat|fix|major|x.y.z]
#
# Versioning: reads the latest semver tag already on GHCR and bumps it.
#   feat -> minor bump (1.2.4 -> 1.3.0)
#   fix  -> patch bump (1.2.4 -> 1.2.5)
# Always pushes 2 tags: the new version + latest.
#
# Auth: set CR_PAT (or GITHUB_TOKEN) to a GHCR-scoped token. Falls back to an
# anonymous token (works only if the image is public).

IMAGE="ghcr.io/cmkl-apex/cmkl-web-ui"
DOCKERFILE="./Dockerfile"
PLATFORMS="linux/amd64,linux/arm64"

# ---- resolve version or bump type -------------------------------------------
INPUT="${1:-}"
NEW=""
BUMP=""

if printf '%s' "$INPUT" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  NEW="$INPUT"
elif [ -z "$INPUT" ]; then
  case "$(git log -1 --pretty=%s)" in
    feat*|feature*) BUMP="minor" ;;
    fix*)           BUMP="patch" ;;
    *)              BUMP="patch" ;;
  esac
else
  BUMP="$INPUT"
fi

if [ -z "$NEW" ]; then
  case "$BUMP" in
    feat|feature|minor) BUMP="minor" ;;
    fix|patch)          BUMP="patch" ;;
    major)              BUMP="major" ;;
    *) echo "unknown input: $INPUT (use feat|fix|major|x.y.z)"; exit 1 ;;
  esac
fi

# ---- read latest version from GHCR ------------------------------------------
repo_path="${IMAGE#ghcr.io/}"   # cmkl-apex/cmkl-web-ui

if [ -z "$NEW" ]; then
  if [ -n "${CR_PAT:-${GITHUB_TOKEN:-}}" ]; then
    token=$(printf '%s' "${CR_PAT:-${GITHUB_TOKEN}}" | base64)
  else
    echo "CR_PAT/GITHUB_TOKEN not set — trying anonymous token (public images only)" >&2
    token=$(curl -fsSL "https://ghcr.io/token?scope=repository:${repo_path}:pull" | jq -r '.token')
  fi

  tags=$(curl -fsSL -H "Authorization: Bearer ${token}" \
    "https://ghcr.io/v2/${repo_path}/tags/list" | jq -r '.tags[]?' || true)

  latest=$(printf '%s\n' "$tags" \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1)
  latest="${latest:-0.0.0}"

  # ---- bump -----------------------------------------------------------------
  IFS=. read -r MAJ MIN PAT <<< "$latest"
  case "$BUMP" in
    major) MAJ=$((MAJ + 1)); MIN=0; PAT=0 ;;
    minor) MIN=$((MIN + 1)); PAT=0 ;;
    patch) PAT=$((PAT + 1)) ;;
  esac
  NEW="${MAJ}.${MIN}.${PAT}"
else
  latest="manual"
fi

echo "latest on GHCR : ${latest}"
echo "bump           : ${BUMP:-manual}"
echo "new version    : ${NEW}"
echo "tags to push   : ${IMAGE}:${NEW}, ${IMAGE}:latest"
echo

# ---- build & push -----------------------------------------------------------
docker buildx build \
  --platform "${PLATFORMS}" \
  -t "${IMAGE}:${NEW}" \
  -t "${IMAGE}:latest" \
  -f "${DOCKERFILE}" \
  . --push
