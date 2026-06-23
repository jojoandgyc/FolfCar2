#!/usr/bin/env bash
set -euo pipefail

# Kernel + image diagnostic builder.
# It expects the PCIe nullguard patch to already be present in the kernel tree,
# rebuilds the arm64 kernel Image, copies SRC_IMG to DST_IMG, and replaces
# /boot/Image inside the copied diagnostic image. This modifies the build tree
# and overwrites DST_IMG, but leaves SRC_IMG unchanged.
BUILD="/home/jojo/opi5puls/orangepi-build"
KDIR="$BUILD/kernel/orange-pi-6.1-rk35xx"
TOOLCHAIN="$BUILD/toolchains/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu/bin"
IMGDIR="$BUILD/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC_IMG="$IMGDIR/opi5p-rj45-stage3b-pcie-hotplug-activehigh-uart-loginL-login115200.img"
DST_IMG="$IMGDIR/opi5p-rj45-stage3c-pcie-hotplug-nullguard-uart-login115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

cd "$KDIR"
export PATH="$TOOLCHAIN:$PATH"
export ARCH=arm64
export CROSS_COMPILE=aarch64-none-linux-gnu-

echo "Checking PCIe nullguard patch..."
grep -nA5 -B2 '!rk_pcie->pci ||' drivers/pci/controller/dwc/pcie-dw-rockchip.c

echo "Running olddefconfig..."
make olddefconfig

echo "Building kernel Image..."
make -j"$(nproc)" Image

if [ ! -f "$SRC_IMG" ]; then
	echo "Source image not found: $SRC_IMG" >&2
	exit 1
fi

echo "Creating diagnostic image: $DST_IMG"
rm -f "$DST_IMG"
cp --reflink=auto --sparse=always "$SRC_IMG" "$DST_IMG"
chown jojo:sudo "$DST_IMG" 2>/dev/null || true
chmod 664 "$DST_IMG"

MNT="$(mktemp -d)"
cleanup() {
	sync || true
	if mountpoint -q "$MNT"; then
		umount "$MNT"
	fi
	rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

mount -o loop,rw,offset="$OFFSET" "$DST_IMG" "$MNT"

echo "Replacing /boot/Image in diagnostic image..."
cp -f "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image"

echo "== Verification =="
ls -lh "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image" "$DST_IMG"
sha256sum "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image" "$DST_IMG"

DTB="$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"
for node in /phy@fee20000 /pcie@fe190000 /vcc3v3-pcie-eth; do
	printf '%-22s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
for prop in hotplug-gpios rockchip,wait-for-link-ms rockchip,perst-inactive-ms reset-gpios vpcie3v3-supply; do
	printf '/pcie@fe190000 %s=' "$prop"
	fdtget "$DTB" /pcie@fe190000 "$prop" 2>/dev/null || echo NA
done
for tty in ttyS0 ttyS3 ttyS9; do
	echo "-- $tty getty override --"
	cat "$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf"
done

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST_IMG"
