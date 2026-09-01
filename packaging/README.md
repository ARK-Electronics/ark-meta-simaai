# Overlay packages

Each GitHub release is one carrier's overlay tarball, installed onto stock SiMa eLxr.

| Target | Tag | Asset |
|--------|-----|-------|
| JAJ | `jaj-1.0.0` | `ark-modalix-jaj.tar.gz` |
| PAB | `pab-1.0.0` | `ark-modalix-pab.tar.gz` |
| PAB_V3 | `pab-v3-1.0.0` | `ark-modalix-pab-v3.tar.gz` |

```
./packaging/generate_package.sh JAJ
./packaging/publish_release.sh JAJ 1.0.0    # tag; CI attaches the tarball as a hidden draft
```

Promote the draft in the GitHub UI after a board check. The tarball is precompiled `.dtbo` plus `install.sh` — no Yocto, no on-target `dtc`.
