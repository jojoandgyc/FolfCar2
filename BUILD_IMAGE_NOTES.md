# Repacking A Burnable SD Image

## Current Safe Command

Use the protected wrapper instead of calling `build.sh` directly:

```bash
cd /home/jojo/opi5puls/orangepi-build
printf '123456\n' | sudo -S /home/jojo/codex_repack_base_image_safe.sh
```

The wrapper preserves the current `base.img` and `opi5p-*.img` files before running the official Orange Pi image build.

## Official Non-Interactive Command

The Orange Pi build command itself can be run without the whiptail UI because `userpatches/config-opi5plus.conf` already sets the board, branch, release, desktop, and kernel config choices:

```bash
cd /home/jojo/opi5puls/orangepi-build
sudo ./build.sh opi5plus BUILD_OPT=image
```

That config expands to the same important options shown by the previous build log:

```bash
BOARD=orangepi5plus
BRANCH=current
BUILD_OPT=image
RELEASE=jammy
BUILD_MINIMAL=no
BUILD_DESKTOP=yes
KERNEL_CONFIGURE=no
DESKTOP_ENVIRONMENT=xfce
DESKTOP_ENVIRONMENT_CONFIG_NAME=config_base
DESKTOP_APPGROUPS_SELECTED=internet
COMPRESS_OUTPUTIMAGE=sha,img
```

## Why Use The Wrapper

The official `create_image()` flow writes to:

```text
output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99
```

Before generating the image, it removes that whole output directory. Our hand-built test images also live there, so a direct official rebuild would delete `base.img`, `opi5p-gps.img`, `opi5p-noeth.img`, and the other experiment images.

The wrapper moves those images to:

```text
output/images/_codex-preserved/<timestamp>/
```

then runs the official build, renames the new long image to `base.img`, and restores the `opi5p-*.img` experiment images.

## What The Official Build Does

The packaging path is:

1. `build.sh` loads `userpatches/config-opi5plus.conf`.
2. `scripts/main.sh` sees `BUILD_OPT=image`.
3. If matching `.deb` packages already exist in `output/debs`, kernel and U-Boot compilation are skipped.
4. `debootstrap_ng()` extracts or creates a rootfs cache from `external/cache/rootfs`.
5. `prepare_partitions()` creates a raw image file, partitions it with `sfdisk`, formats rootfs/boot, and mounts it through a loop device.
6. `create_image()` rsyncs `/` and `/boot`, updates initramfs, writes U-Boot, unmounts, and moves the raw file to the final `.img`.
7. `COMPRESS_OUTPUTIMAGE=sha,img` keeps the raw `.img` and generates a sha file.
