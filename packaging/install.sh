#!/bin/bash
# Runs on the Modalix as root. Installs the carrier overlay into both eLxr boot
# slots and points U-Boot at it. USB/HDMI helpers apply userspace bits that the
# overlay does not cover.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC1091
source "$HERE/overlay.conf"

DTBO="$HERE/${OVERLAY_NAME}.dtbo"
if [ ! -f "$DTBO" ]; then
    echo "ERROR: missing $DTBO" >&2
    exit 1
fi

install -m 0644 "$DTBO" "/boot/boot-0/${OVERLAY_NAME}.dtbo"
install -m 0644 "$DTBO" "/boot/boot-1/${OVERLAY_NAME}.dtbo"
mkdir -p /boot/boot-0/overlays /boot/boot-1/overlays
cp -f "/boot/boot-0/${OVERLAY_NAME}.dtbo" /boot/boot-0/overlays/
cp -f "/boot/boot-1/${OVERLAY_NAME}.dtbo" /boot/boot-1/overlays/

install -d /usr/local/sbin
if [ -f "$HERE/ark-jaj-usb-init.sh" ]; then
    install -m 0755 "$HERE/ark-jaj-usb-init.sh" /usr/local/sbin/ark-jaj-usb-init.sh
fi
if [ -f "$HERE/ark-jaj-usb.service" ]; then
    install -m 0644 "$HERE/ark-jaj-usb.service" /etc/systemd/system/ark-jaj-usb.service
    if [ "${USB_HOST_POLICY:-0}" = "1" ]; then
        mkdir -p /etc/systemd/system/ark-jaj-usb.service.d
        printf '%s\n' '[Service]' 'Environment=ROLE_POLICY=prefer-host' > /etc/systemd/system/ark-jaj-usb.service.d/pab-v3.conf
    fi
fi
if [ "${SYS_POWER:-0}" = "1" ] && [ -f "$HERE/ark-jaj-sys-power.py" ]; then
    install -m 0755 "$HERE/ark-jaj-sys-power.py" /usr/local/sbin/ark-jaj-sys-power.py
    install -m 0644 "$HERE/ark-jaj-sys-power.service" /etc/systemd/system/ark-jaj-sys-power.service
fi

command -v i2cget >/dev/null || apt-get install -y i2c-tools >/dev/null 2>&1 || true
systemctl daemon-reload
systemctl enable ark-jaj-usb.service 2>/dev/null || true
# Overlay is not live until reboot; FUSB programming can fail on stock DT.
/usr/local/sbin/ark-jaj-usb-init.sh || true
if [ "${SYS_POWER:-0}" = "1" ]; then
    systemctl enable ark-jaj-sys-power.service
    systemctl restart ark-jaj-sys-power.service || true
fi
if [ -f "$HERE/install-ark-hdmi.sh" ]; then
    bash "$HERE/install-ark-hdmi.sh" "$HERE" || true
fi

# eLxr's fw_env.config points at the wrong size and a /tmp path with no mount.
mkdir -p /tmp/boot
cp -a /boot/uboot.env /boot/uboot-redund.env /tmp/boot/
cat > /tmp/fw_env.config << EOF
/tmp/boot/uboot.env 0x0000 0x80000
/tmp/boot/uboot-redund.env 0x0000 0x80000
EOF
if [ -f /boot/boot-0/modalix-som_16g.dtb ]; then
    fw_setenv -c /tmp/fw_env.config fdt_name modalix-som_16g.dtb
elif [ -f /boot/boot-0/modalix-som.dtb ]; then
    fw_setenv -c /tmp/fw_env.config fdt_name modalix-som.dtb
fi
fw_setenv -c /tmp/fw_env.config dtbos "${OVERLAY_NAME}.dtbo"
cp -a /tmp/boot/uboot.env /tmp/boot/uboot-redund.env /boot/

cat > /etc/ark_modalix << EOF
product=${PRODUCT}
overlay=${OVERLAY_NAME}
version=${VERSION}
commit=${COMMIT}
EOF

sync
fw_printenv -c /tmp/fw_env.config fdt_name dtbos
ls -la "/boot/boot-0/${OVERLAY_NAME}.dtbo"
echo INSTALL_OK
