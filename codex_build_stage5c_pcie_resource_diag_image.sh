#!/usr/bin/env bash
set -euo pipefail

BUILD="/home/jojo/opi5puls/orangepi-build"
KDIR="$BUILD/kernel/orange-pi-6.1-rk35xx"
TOOLCHAIN="$BUILD/toolchains/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu/bin"
IMGDIR="$BUILD/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC_IMG="$IMGDIR/opi5p-rj45-stage5b-pcie-diaglog-forcedlogin115200.img"
DST_IMG="$IMGDIR/opi5p-rj45-stage5c-pcie-resource-diag-forcedlogin115200.img"
PATCH="$BUILD/codex_pcie_resource_detail.patch"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC_IMG" ]; then
	echo "Source image not found: $SRC_IMG" >&2
	exit 1
fi

cd "$KDIR"
export PATH="$TOOLCHAIN:$PATH"
export ARCH=arm64
export CROSS_COMPILE=aarch64-none-linux-gnu-

if ! grep -q "codex pcie diag: pcie-phy get failed" drivers/pci/controller/dwc/pcie-dw-rockchip.c; then
	echo "Applying PCIe resource-detail diagnostic patch..."
	git apply --recount "$PATCH"
else
	echo "PCIe resource-detail diagnostic patch already present."
fi

echo "Building kernel Image..."
make -j"$(nproc)" Image

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
cp -f "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image"

DTB="$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"

echo "== Verification =="
echo "Image: $DST_IMG"
ls -lh "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image" "$DST_IMG"
sha256sum "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image" "$DST_IMG"
for prop in reset-gpios vpcie3v3-supply phys rockchip,wait-for-link-ms rockchip,perst-inactive-ms; do
	printf '/pcie@fe190000 %s=' "$prop"
	fdtget "$DTB" /pcie@fe190000 "$prop" 2>/dev/null || echo NA
done
grep -n "codex pcie diag: .*get" drivers/pci/controller/dwc/pcie-dw-rockchip.c | head -40

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST_IMG"
