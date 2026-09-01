# ark-meta-simaai

ARK carrier support for a [SiMa.ai Modalix](https://sima.ai) SoM. The SoM keeps SiMa eLxr on eMMC; this repo adds the carrier device-tree overlay, USB/HDMI helpers, and (via Yocto) optional recovery images.

Workflow matches [`ark_jetson_kernel`](https://github.com/ARK-Electronics/ark_jetson_kernel): `setup.sh` → `build.sh` → `flash.sh`, plus `provision.sh` for a live eLxr board.

## Products

| Target | Carrier | Overlay |
|--------|---------|---------|
| `JAJ` | ARK Just a Jetson | live |
| `PAB` | ARK Jetson PAB | live |
| `PAB_V3` | ARK Jetson PAB V3 | live (KSZ 100M) |
| `CAN_PAB` | ARK Jetson CAN PAB | placeholder |

## Provision a stock SoM

eLxr is already on the module. On a Debian/Ubuntu host, with SSH to the board (`sima` / `edgeai`):

```
curl -LO https://raw.githubusercontent.com/ARK-Electronics/ark-meta-simaai/main/packaging/provision_from_package.sh
chmod +x provision_from_package.sh
BOARD=sima@192.168.0.50 ./provision_from_package.sh jaj        # or pab / pab-v3
```

From a checkout of this repo:

```
./provision.sh JAJ sima@192.168.0.50
```

PAB V3 has no Ethernet until the overlay releases `SWITCH_RSTn`. USB-C console first (DTR/RTS off):

```
./provision.sh PAB_V3 --serial
```

That pokes the KSZ, then installs over SSH at `sima@192.168.1.20` (host NIC `192.168.1.10/24`).

After reboot:

```
cat /proc/device-tree/model
cat /etc/ark_modalix
```

ARK-OS is a separate Debian package (`ark-os-modalix-bookworm` from [ARK-OS](https://github.com/ARK-Electronics/ARK-OS)).

## Build an overlay package

Needs `device-tree-compiler` only — no Yocto.

```
./packaging/generate_package.sh JAJ
./packaging/publish_release.sh JAJ 1.0.0
```

See [packaging/README.md](packaging/README.md).

## Recovery image (optional)

Yocto image for eMMC rewrite. ~80 GB disk.

```
SETUP_INSTALL_DEPS=1 ./setup.sh
./build.sh JAJ
./flash.sh JAJ --netboot              # sima-cli TFTP → eMMC
./flash.sh JAJ --device /dev/sdX      # WIC to a host-attached disk (not the host root disk)
```

Bring-up notes: [docs/bringup-jaj.md](docs/bringup-jaj.md), [docs/bringup-pab-v3.md](docs/bringup-pab-v3.md).
