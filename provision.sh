#!/bin/bash
# Install the ARK carrier overlay on a live SiMa eLxr SoM (SSH).
# Compiles a package from this tree unless --package or --release is given.
#
# Usage:
#   ./provision.sh JAJ sima@192.168.0.50
#   ./provision.sh PAB_V3 sima@192.168.0.50 --package dist/ark-modalix-pab-v3.tar.gz
#   ./provision.sh JAJ sima@192.168.0.50 --release
#   ./provision.sh PAB_V3 --serial              # KSZ poke, then SSH to BOARD
#   PASSWORD=edgeai ./provision.sh JAJ sima@192.168.0.50 --no-reboot
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/targets.sh
source "$SCRIPT_DIR/scripts/targets.sh"

usage() {
    sed -n '2,12p' "$0"
}

TARGET=""
BOARD="${BOARD:-}"
PACKAGE=""
RELEASE=0
SERIAL=0
REBOOT=1
PASSWORD="${PASSWORD:-edgeai}"
SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new)

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --package) PACKAGE="$2"; shift 2 ;;
        --release) RELEASE=1; shift ;;
        --serial) SERIAL=1; shift ;;
        --reboot) REBOOT=1; shift ;;
        --no-reboot) REBOOT=0; shift ;;
        --board) BOARD="$2"; shift 2 ;;
        *)
            if [ -z "$TARGET" ] && ark_target "$1" >/dev/null 2>&1; then
                TARGET="$(ark_target "$1")"
                shift
            elif [ -z "$BOARD" ] && [[ "$1" == *@* ]]; then
                BOARD="$1"
                shift
            else
                echo "Unknown option: $1" >&2
                usage
                exit 1
            fi ;;
    esac
done

if [ -z "$TARGET" ]; then
    echo "ERROR: target required (JAJ | PAB | PAB_V3)" >&2
    usage
    exit 1
fi

if [ "$SERIAL" = "1" ]; then
    if [ "$TARGET" != "PAB_V3" ]; then
        echo "ERROR: --serial is PAB_V3 only (KSZ held in reset on stock eLxr)" >&2
        exit 1
    fi
    # firstboot reads BOARD_IP and PASSWORD from its own environment, so export ours —
    # otherwise an override here silently disagrees with the serial poke.
    export BOARD_IP="${BOARD_IP:-192.168.1.20}" PASSWORD
    "$SCRIPT_DIR/scripts/pab-v3-firstboot.sh"
    BOARD="${BOARD:-sima@$BOARD_IP}"
fi

if [ -z "$BOARD" ]; then
    BOARD="sima@192.168.7.50"
fi

if [ -z "$PACKAGE" ]; then
    if [ "$RELEASE" = "1" ]; then
        exec "$SCRIPT_DIR/packaging/provision_from_package.sh" "$(ark_product_slug "$TARGET")" "$BOARD"
    fi
    "$SCRIPT_DIR/packaging/generate_package.sh" "$TARGET"
    PACKAGE="$SCRIPT_DIR/dist/$(ark_package_name "$TARGET")"
fi

if [ ! -f "$PACKAGE" ]; then
    echo "ERROR: package not found: $PACKAGE" >&2
    exit 1
fi

ASKPASS=$(mktemp)
trap 'rm -f "$ASKPASS"' EXIT
cat > "$ASKPASS" <<EOF
#!/bin/sh
echo '$PASSWORD'
EOF
chmod 700 "$ASKPASS"
export DISPLAY= SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force

ssh_() { ssh "${SSH_OPTS[@]}" "$BOARD" "$@"; }
scp_() { scp "${SSH_OPTS[@]}" "$@"; }

REMOTE_DIR=/tmp/ark-overlay
REMOTE_TAR="$REMOTE_DIR/package.tar.gz"
echo "==> Target: $BOARD"
echo "==> Package: $PACKAGE"
ssh_ "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
scp_ "$PACKAGE" "$BOARD:$REMOTE_TAR"
ssh_ "tar -C $REMOTE_DIR -xzf $REMOTE_TAR"

echo "==> Installing overlay on $BOARD"
ssh_ "echo '$PASSWORD' | sudo -S bash $REMOTE_DIR/install.sh"

if [ "$REBOOT" = "1" ]; then
    echo "==> Rebooting"
    ssh_ "echo '$PASSWORD' | sudo -S reboot" || true
    echo "Wait for the board, then: ssh $BOARD 'cat /proc/device-tree/model; cat /etc/ark_modalix'"
else
    echo "Installed. Reboot to load the overlay (or re-run without --no-reboot)."
fi
