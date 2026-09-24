#!/usr/bin/env python3
"""Keep a Jetson PAB boot from stopping on flight-controller UART traffic.

U-Boot's console is UART1. On the PAB that pin is Telem2, so MAVLink arrives
during boot:

* bootdelay>=0 treats any pending byte as "hit any key" and skips autoboot.
  bootdelay=-2 skips that check. The following baudrate entry stays intact.
  If the env lookup misses, this image falls back to bootdelay 3, so the
  compare that implements the check is also turned into an unconditional
  branch on the factory binary.
* run_command_list still calls ctrlc(). A 0x03 in the Telem2 stream aborts
  the boot script even when bootdelay is -2. Stock SiMa images have a fixed
  ctrlc() prologue; that prologue is rewritten to return 0. Images built
  with the ark-pab autoboot patch ignore console input for the whole boot
  command, so a missing prologue is not an error.
"""
import pathlib
import sys

OLD = b"bootdelay=3\x00"
NEW = b"bootdelay=-2\x00"

# ctrlc() in the 2026-09-11 Modalix u-boot.bin (link address used by ADRP).
# adrp; ldr ctrlc_disabled; cbz; mov w0,#0; ret; mov w0,#0; ldp; ret;
# ldr gd->flags; tbz console-ready.
CTRLC_STOCK = bytes.fromhex(
    "2009009000444db9c000003400008052c0035fd6"
    "00008052fd7bc1a8c0035fd6402240f940ffdf36"
)
CTRLC_OFF = bytes.fromhex("00008052c0035fd6") + CTRLC_STOCK[8:]

# autoboot_command: ldr stored_bootdelay; str x23; cmn w19,#2; b.eq; cmn w19,#1
# If env_get("bootdelay") misses, this image falls back to 3 and any UART
# byte still aborts. Replace the compare with an unconditional branch to
# the same boot path.
KEYCHECK = bytes.fromhex("13dc4bb9f71b00f97f0a0031000700547f060031")
KEYCHECK_FOLLOW = bytes.fromhex("7f060031")


def patch_bootdelay(data: bytearray) -> str:
    if data.find(NEW) != -1 and data.find(OLD) == -1:
        return "bootdelay=-2"
    idx = data.find(OLD)
    if idx < 0 or data.find(OLD, idx + 1) != -1:
        raise SystemExit("expected exactly one bootdelay=3")
    end = data.find(b"\x00\x00", idx)
    if data[end:end + 3] != b"\x00\x00\x00":
        raise SystemExit("no spare NUL after the default environment")
    if data[end + 3:end + 7] != b"0123":
        raise SystemExit("environment tail is not the expected marker")
    rest = data[idx + len(OLD):end + 2]
    blob = NEW + rest
    if len(blob) != (end + 3 - idx):
        raise SystemExit("bootdelay size mismatch")
    data[idx:end + 3] = blob
    if b"baudrate=115200\x00" not in data[idx:idx + 40]:
        raise SystemExit("baudrate entry was disturbed")
    return "bootdelay=-2"


def patch_keycheck(data: bytearray) -> str:
    """Skip the hit-any-key check regardless of the bootdelay value."""
    idx = data.find(KEYCHECK)
    again = data.find(KEYCHECK, idx + 1) if idx >= 0 else -1
    if idx < 0 or again != -1:
        done = bytes.fromhex("13dc4bb9f71b00f9")  # ldr; str still precede the branch
        # already patched: unconditional b + nop + cmn w19,#1
        start = 0
        found = 0
        while True:
            i = data.find(done, start)
            if i < 0 or i + 16 > len(data):
                break
            branch = int.from_bytes(data[i + 8:i + 12], "little")
            nop = int.from_bytes(data[i + 12:i + 16], "little")
            if (branch & 0xfc000000) == 0x14000000 and nop == 0xD503201F and data[i + 16:i + 20] == KEYCHECK_FOLLOW:
                found += 1
            start = i + 1
        if found == 1:
            return "key check already skipped"
        return "key-check site not in this image"
    beq = int.from_bytes(data[idx + 12:idx + 16], "little")
    imm19 = (beq >> 5) & 0x7FFFF
    if imm19 & 0x40000:
        imm19 -= 0x80000
    disp = imm19 + 1  # branch is one instruction earlier than b.eq
    if not -0x2000000 <= disp < 0x2000000:
        raise SystemExit("key-check branch is out of range")
    branch = (0x14000000 | (disp & 0x3FFFFFF)).to_bytes(4, "little")
    nop = (0xD503201F).to_bytes(4, "little")
    data[idx + 8:idx + 16] = branch + nop
    return "key check skipped"


def patch_ctrlc(data: bytearray) -> str:
    stock = data.find(CTRLC_STOCK)
    done = data.find(CTRLC_OFF)
    if stock < 0 and done != -1 and data.find(CTRLC_OFF, done + 1) < 0:
        return "ctrlc already returns 0"
    if stock < 0 or data.find(CTRLC_STOCK, stock + 1) != -1:
        return "ctrlc prologue not in this image"
    data[stock:stock + len(CTRLC_STOCK)] = CTRLC_OFF
    return "ctrlc returns 0"


def patch(path: pathlib.Path) -> str:
    data = bytearray(path.read_bytes())
    before = bytes(data)
    delay = patch_bootdelay(data)
    ctrlc = patch_ctrlc(data)
    key = patch_keycheck(data)
    if data != before:
        path.write_bytes(data)
    return f"{path}: {delay}; {ctrlc}; {key}"


def main(argv: list[str]) -> None:
    if len(argv) < 2:
        raise SystemExit(f"usage: {argv[0]} u-boot.bin [...]")
    for arg in argv[1:]:
        print(patch(pathlib.Path(arg)))


if __name__ == "__main__":
    main(sys.argv)
