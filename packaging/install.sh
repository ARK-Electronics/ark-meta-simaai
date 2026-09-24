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

# Stock eLxr carries no carrier identity, so a previous stamp is the only thing that can
# tell us the SoM moved carriers. Not fatal: SoMs get swapped between carriers on the bench.
if [ -f /etc/ark_modalix ]; then
    previous=$(sed -n 's/^product=//p' /etc/ark_modalix)
    if [ -n "$previous" ] && [ "$previous" != "$PRODUCT" ]; then
        echo "NOTE: replacing the $previous overlay with $PRODUCT"
    fi
fi

install_tree() {
    local dest="$1"
    mkdir -p "$dest/overlays"
    install -m 0644 "$DTBO" "$dest/${OVERLAY_NAME}.dtbo"
    cp -f "$dest/${OVERLAY_NAME}.dtbo" "$dest/overlays/"
}

# Point U-Boot's boot.scr at this overlay when dtbos is empty. The No-UART1
# eLxr image keeps its environment in the U-Boot binary (CONFIG_ENV_IS_NOWHERE)
# and selects fdt_name from the SoM id, so fw_setenv does not affect the next boot.
patch_bootscript() {
    local img="$1"
    local name="${OVERLAY_NAME}.dtbo"
    [ -f "$img" ] || return 0
    if grep -a -F -q "setenv dtbos ${name}" "$img"; then
        echo "boot script already requests ${name}"
        return 0
    fi
    python3 - "$img" "$name" << 'PY'
import pathlib, struct, sys, time, zlib
img = pathlib.Path(sys.argv[1])
name = sys.argv[2]
data = img.read_bytes()
payload = data[64:]
text = payload[8:] if len(payload) > 8 and payload[8:9] == b"#" else payload
text = text.split(b"\x00", 1)[0].decode()
needle = "setenv all_dtbos\n"
insert = 'if test -z "${dtbos}"; then setenv dtbos %s; fi\n' % name
if needle not in text:
    raise SystemExit("no dtbo hook in %s" % img)
if 'setenv dtbos %s' % name not in text:
    text = text.replace(needle, insert + needle, 1)
# A failed `fdt apply` aborts the sourced script before booti. Keep booting.
apply = "fdt apply ${dtbo_addr}\n"
guarded = "if fdt apply ${dtbo_addr}; then echo applied ${dtbo}; else echo OVERLAY ${dtbo} failed; fi\n"
if apply in text and "OVERLAY ${dtbo} failed" not in text:
    text = text.replace(apply, guarded, 1)
# Four IMX219 nodes need more room than the stock 64 KiB fdt resize.
resize = "fdt resize ${dtb_resize}\n"
if resize in text:
    text = text.replace(resize, "fdt resize 0x40000\n", 1)
script = text.encode()
body = struct.pack(">II", len(script), 0) + script
stamp = int(time.time())
dcrc = zlib.crc32(body) & 0xFFFFFFFF
title = b"boot.scr".ljust(32, b"\x00")

def header(hcrc):
    hdr = struct.pack(">IIIIIII", 0x27051956, hcrc, stamp, len(body), 0, 0, dcrc)
    return hdr + struct.pack(">BBBB", 5, 2, 6, 0) + title

hcrc = zlib.crc32(header(0)) & 0xFFFFFFFF
out = header(hcrc) + body
bak = pathlib.Path(str(img) + ".bak")
if not bak.exists():
    bak.write_bytes(data)
img.write_bytes(out)
print("patched %s" % img)
PY
}

# Flat eLxr (one vfat at /boot, boot.scr.uimg at the root) and the older
# boot-0/boot-1 layout. The No-UART1 image has no boot-0 directory.
if [ -d /boot/boot-0 ]; then
    install_tree /boot/boot-0
    install_tree /boot/boot-1
else
    mount -o remount,rw /boot
    install_tree /boot
    # Install the dtbo on the inactive slot too, but do not rewrite its boot
    # script. Slot B stays a stock boot if the active script is bad.
    if blkid -o value -s TYPE /dev/mmcblk0p2 2>/dev/null | grep -qx vfat; then
        if ! findmnt -n /dev/mmcblk0p2 >/dev/null; then
            mkdir -p /mnt/boot-b
            mount -o rw /dev/mmcblk0p2 /mnt/boot-b
            install_tree /mnt/boot-b
            umount /mnt/boot-b
        fi
    fi
    patch_bootscript /boot/boot.scr.uimg
fi

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

# Older slot layout stores U-Boot env in the FAT file. The No-UART1 image does
# not: boot.scr (patched above) is what applies dtbos, and board id picks fdt_name.
if [ -d /boot/boot-0 ]; then
    mkdir -p /tmp/boot
    cp -a /boot/uboot.env /boot/uboot-redund.env /tmp/boot/
    cat > /tmp/fw_env.config << EOF
/tmp/boot/uboot.env 0x0000 0x80000
/tmp/boot/uboot-redund.env 0x0000 0x80000
EOF
    if [ -f /boot/boot-0/modalix-som_16g_nouart1.dtb ]; then
        fw_setenv -c /tmp/fw_env.config fdt_name modalix-som_16g_nouart1.dtb
    elif [ -f /boot/boot-0/modalix-som_16g.dtb ]; then
        fw_setenv -c /tmp/fw_env.config fdt_name modalix-som_16g.dtb
    elif [ -f /boot/boot-0/modalix-som.dtb ]; then
        fw_setenv -c /tmp/fw_env.config fdt_name modalix-som.dtb
    fi
    fw_setenv -c /tmp/fw_env.config dtbos "${OVERLAY_NAME}.dtbo"
    cp -a /tmp/boot/uboot.env /tmp/boot/uboot-redund.env /boot/
    fw_printenv -c /tmp/fw_env.config fdt_name dtbos
    ls -la "/boot/boot-0/${OVERLAY_NAME}.dtbo"
else
    echo "flat boot: ${OVERLAY_NAME}.dtbo via boot.scr, fdt_name left to the SoM id"
    ls -la "/boot/${OVERLAY_NAME}.dtbo"
fi

cat > /etc/ark_modalix << EOF
product=${PRODUCT}
overlay=${OVERLAY_NAME}
model=${EXPECTED_MODEL}
version=${VERSION}
commit=${COMMIT}
EOF

sync
echo INSTALL_OK
