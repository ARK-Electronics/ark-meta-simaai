#!/bin/bash
# Compile the carrier overlay on the host and pack it with install.sh + userspace
# helpers. No Yocto. Output: dist/ark-modalix-<product>.tar.gz
#
# Usage: ./generate_package.sh <JAJ | PAB | PAB_V3 | CAN_PAB> [version]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../scripts/targets.sh
source "$ROOT_DIR/scripts/targets.sh"

if [ $# -lt 1 ]; then
    echo "Usage: ./generate_package.sh <JAJ | PAB | PAB_V3 | CAN_PAB> [version]" >&2
    exit 1
fi

TARGET="$(ark_target "$1")" || { echo "ERROR: unknown target '$1'" >&2; exit 1; }
CONF="$ROOT_DIR/products/$TARGET/overlay.conf"
if [ ! -f "$CONF" ]; then
    echo "ERROR: missing $CONF" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

if ! command -v dtc >/dev/null; then
    echo "ERROR: device-tree-compiler (dtc) is not installed." >&2
    echo "       sudo apt-get install -y device-tree-compiler" >&2
    exit 1
fi

DTSO="$ROOT_DIR/$DTSO"
if [ ! -f "$DTSO" ]; then
    echo "ERROR: missing $DTSO" >&2
    exit 1
fi

SLUG="$(ark_product_slug "$TARGET")"
VERSION="${2:-}"
if [ -z "$VERSION" ]; then
    VERSION="$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
fi
COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo "==> $TARGET  overlay=$OVERLAY_NAME  version=$VERSION"
dtc -@ -I dts -O dtb -o "$STAGING/${OVERLAY_NAME}.dtbo" "$DTSO"

cat > "$STAGING/overlay.conf" << EOF
OVERLAY_NAME=$OVERLAY_NAME
EXPECTED_MODEL='$EXPECTED_MODEL'
USB_HOST_POLICY=$USB_HOST_POLICY
SYS_POWER=$SYS_POWER
PRODUCT=$SLUG
VERSION=$VERSION
COMMIT=$COMMIT
EOF

install -m 0755 "$SCRIPT_DIR/install.sh" "$STAGING/install.sh"

copy_if() {
    local src="$1"
    [ -f "$src" ] && cp "$src" "$STAGING/"
}

copy_if "$ROOT_DIR/scripts/ark-jaj-usb-init.sh"
copy_if "$ROOT_DIR/scripts/ark-jaj-usb.service"
copy_if "$ROOT_DIR/scripts/install-ark-hdmi.sh"
copy_if "$ROOT_DIR/scripts/ark-hdmi-unblank.sh"
copy_if "$ROOT_DIR/scripts/10-ark-no-blank.conf"
copy_if "$ROOT_DIR/scripts/10-ark-hdmi-lightdm.conf"
copy_if "$ROOT_DIR/scripts/99-ark-hdmi.rules"
if [ "$SYS_POWER" = "1" ]; then
    copy_if "$ROOT_DIR/scripts/ark-jaj-sys-power.py"
    copy_if "$ROOT_DIR/scripts/ark-jaj-sys-power.service"
fi

OUT_DIR="$ROOT_DIR/dist"
mkdir -p "$OUT_DIR"
PACKAGE="$OUT_DIR/$(ark_package_name "$TARGET")"
tar -C "$STAGING" -czf "$PACKAGE" .
echo "Wrote $PACKAGE"
ls -lh "$PACKAGE"
