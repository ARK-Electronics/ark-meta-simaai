#!/bin/bash
# Tag a carrier overlay release. CI packs the tarball and opens a hidden draft.
#
# Usage: ./publish_release.sh <JAJ | PAB | PAB_V3> <version>
#   e.g. ./publish_release.sh JAJ 1.0.0   → tag jaj-1.0.0
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: ./publish_release.sh <JAJ | PAB | PAB_V3> <version>"
    echo "  e.g. ./publish_release.sh JAJ 1.0.0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/targets.sh
source "$ROOT_DIR/scripts/targets.sh"

TARGET="$(ark_target "$1")" || { echo "ERROR: unknown target '$1'" >&2; exit 1; }
VERSION="$2"
case "$TARGET" in
    JAJ|PAB|PAB_V3) ;;
    *)
        echo "ERROR: releases are JAJ, PAB, or PAB_V3 (not $TARGET)." >&2
        exit 1 ;;
esac
if ! echo "$VERSION" | grep -qE '^[0-9]+(\.[0-9]+)*$'; then
    echo "ERROR: version must be digits and dots (e.g. 1.0.0), got: $VERSION" >&2
    exit 1
fi

SLUG="$(ark_product_slug "$TARGET")"
TAG="${SLUG}-${VERSION}"

if ! git -C "$ROOT_DIR" diff-index --quiet HEAD --; then
    echo "ERROR: working tree has uncommitted changes." >&2
    exit 1
fi
if git -C "$ROOT_DIR" rev-parse "$TAG" >/dev/null 2>&1; then
    echo "ERROR: tag '$TAG' already exists." >&2
    exit 1
fi

echo "Target: $TARGET"
echo "Tag:    $TAG"
read -r -p "Create and push tag '$TAG'? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

git -C "$ROOT_DIR" tag -a "$TAG" -m "$TAG"
git -C "$ROOT_DIR" push origin "$TAG"
echo "Tag '$TAG' pushed. CI will attach dist/$(ark_package_name "$TARGET") as a hidden draft."
echo "Validate, then publish the GitHub release by hand."
echo "Monitor: https://github.com/ARK-Electronics/meta-ark-simaai/actions"
