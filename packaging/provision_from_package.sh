#!/bin/bash
# Download a released overlay package and install it on a live eLxr SoM.
#
# Self-contained on purpose: this is the one file a user curls from main, so it must
# not source or exec anything else in the repo.
#
# Usage:
#   ./provision_from_package.sh jaj                  # latest published JAJ
#   ./provision_from_package.sh jaj-1.0.0            # specific tag
#   ./provision_from_package.sh pab-v3 --draft       # latest draft (needs gh)
#   BOARD=sima@192.168.0.50 ./provision_from_package.sh jaj
set -euo pipefail

REPO="ARK-Electronics/ark-meta-simaai"
API_URL="https://api.github.com/repos/$REPO/releases"
CACHE_BASE="${ARK_MODALIX_CACHE:-$HOME/.ark-modalix-cache}"

usage() {
    echo "Usage: $(basename "$0") <tag|product> [user@host]"
    echo "  $(basename "$0") jaj              latest published JAJ overlay"
    echo "  $(basename "$0") pab-v3           latest published PAB V3 overlay"
    echo "  $(basename "$0") jaj-1.0.0        a specific release (published or draft)"
    echo "  $(basename "$0") jaj --draft      latest JAJ draft (needs gh)"
    exit 1
}

is_product() {
    case "$1" in
        jaj|pab|pab-v3) return 0 ;;
        *) return 1 ;;
    esac
}

WANT_DRAFT=0
REBOOT=1
args=()
for arg in "$@"; do
    case "$arg" in
        --draft) WANT_DRAFT=1 ;;
        --no-reboot) REBOOT=0 ;;
        -h|--help) usage ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]}"

if [ $# -lt 1 ]; then
    usage
fi

SELECTOR="$1"
BOARD="${2:-${BOARD:-sima@192.168.7.50}}"
PASSWORD="${PASSWORD:-edgeai}"

if is_product "$SELECTOR"; then
    PRODUCT="$SELECTOR"
    TAG=""
else
    case "$SELECTOR" in
        pab-v3-*) PRODUCT="pab-v3"; TAG="$SELECTOR" ;;
        jaj-*)    PRODUCT="jaj";    TAG="$SELECTOR" ;;
        pab-*)    PRODUCT="pab";    TAG="$SELECTOR" ;;
        *)
            echo "ERROR: not a product or tag: $SELECTOR" >&2
            usage ;;
    esac
fi

PACKAGE_NAME="ark-modalix-${PRODUCT}.tar.gz"

resolve_latest_tag() {
    local product="$1" draft="$2"
    if [ "$draft" = "1" ]; then
        gh release list -R "$REPO" --limit 100 --json tagName,isDraft,isPrerelease \
            | python3 -c "
import json, sys
product = sys.argv[1]
prefix = product + '-'
for r in json.load(sys.stdin):
    tag = r.get('tagName') or ''
    if (r.get('isDraft') or r.get('isPrerelease')) and tag.startswith(prefix):
        print(tag); sys.exit(0)
sys.exit(1)
" "$product" 2>/dev/null || { echo "ERROR: no draft $product release" >&2; exit 1; }
        return
    fi
    curl -sfL "$API_URL?per_page=100" | python3 -c "
import json, sys
product = sys.argv[1]
prefix = product + '-'
name = 'ark-modalix-' + product + '.tar.gz'
for r in json.load(sys.stdin):
    if r.get('prerelease') or r.get('draft'):
        continue
    tag = r.get('tag_name') or ''
    if not tag.startswith(prefix):
        continue
    for a in r.get('assets') or []:
        if a.get('name') == name:
            print(tag); sys.exit(0)
sys.exit(1)
" "$product" 2>/dev/null || { echo "ERROR: no published $product overlay package" >&2; exit 1; }
}

if [ -z "$TAG" ]; then
    TAG="$(resolve_latest_tag "$PRODUCT" "$WANT_DRAFT")"
fi

CACHE_DIR="$CACHE_BASE/$TAG"
mkdir -p "$CACHE_DIR"
PACKAGE="$CACHE_DIR/$PACKAGE_NAME"
if [ ! -f "$PACKAGE" ]; then
    echo "==> downloading $PACKAGE_NAME from $TAG"
    if [ "$WANT_DRAFT" = "1" ]; then
        gh release download "$TAG" --repo "$REPO" --pattern "$PACKAGE_NAME" --dir "$CACHE_DIR"
    else
        URL=$(curl -sfL "$API_URL/tags/$TAG" | python3 -c "
import json, sys
name = sys.argv[1]
for a in json.load(sys.stdin).get('assets') or []:
    if a.get('name') == name:
        print(a['browser_download_url']); sys.exit(0)
sys.exit(1)
" "$PACKAGE_NAME" 2>/dev/null) || {
            echo "==> tag $TAG is not on the public API; trying gh (draft?)"
            gh release download "$TAG" --repo "$REPO" --pattern "$PACKAGE_NAME" --dir "$CACHE_DIR"
            URL=""
        }
        if [ -n "${URL:-}" ]; then
            curl -sfL -o "$PACKAGE" "$URL"
        fi
    fi
fi
if [ ! -f "$PACKAGE" ]; then
    echo "ERROR: failed to download $PACKAGE_NAME from $TAG" >&2
    exit 1
fi

echo "==> $TAG  $PACKAGE"

ASKPASS=$(mktemp)
trap 'rm -f "$ASKPASS"' EXIT
cat > "$ASKPASS" <<EOF
#!/bin/sh
echo '$PASSWORD'
EOF
chmod 700 "$ASKPASS"
export DISPLAY= SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force

SSH_OPTS=(-o PreferredAuthentications=password -o PubkeyAuthentication=no -o StrictHostKeyChecking=accept-new)
ssh_() { ssh "${SSH_OPTS[@]}" "$BOARD" "$@"; }

REMOTE_DIR=/tmp/ark-overlay
echo "==> Target: $BOARD"
ssh_ "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR"
scp "${SSH_OPTS[@]}" "$PACKAGE" "$BOARD:$REMOTE_DIR/package.tar.gz"
ssh_ "tar -C $REMOTE_DIR -xzf $REMOTE_DIR/package.tar.gz"

echo "==> Installing overlay on $BOARD"
ssh_ "echo '$PASSWORD' | sudo -S bash $REMOTE_DIR/install.sh"

if [ "$REBOOT" = "1" ]; then
    echo "==> Rebooting"
    ssh_ "echo '$PASSWORD' | sudo -S reboot" || true
    echo "Wait for the board, then: ssh $BOARD 'cat /proc/device-tree/model; cat /etc/ark_modalix'"
else
    echo "Installed. Reboot to load the overlay."
fi
