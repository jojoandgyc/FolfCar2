#!/usr/bin/env bash
set -euo pipefail

BUILD="/home/jojo/opi5puls/orangepi-build"
KDIR="$BUILD/kernel/orange-pi-6.1-rk35xx"
TOOLCHAIN="$BUILD/toolchains/gcc-arm-11.2-2022.02-x86_64-aarch64-none-linux-gnu/bin"
IMGDIR="$BUILD/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC_IMG="$IMGDIR/opi5p-rj45-stage5d-phy0-fee00000-fix-forcedlogin115200.img"
DST_IMG="$IMGDIR/opi5p-rj45-stage5e-after-hwio-diag-forcedlogin115200.img"
PATCH="$BUILD/codex_pcie_stage5e_after_hwio_diag.patch"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC_IMG" ]; then
	echo "Source image not found: $SRC_IMG" >&2
	exit 1
fi

if [ ! -f "$PATCH" ]; then
	echo "Patch not found: $PATCH" >&2
	exit 1
fi

cd "$KDIR"
export PATH="$TOOLCHAIN:$PATH"
export ARCH=arm64
export CROSS_COMPILE=aarch64-none-linux-gnu-

if ! grep -q "codex pcie diag5e: host_config enter" drivers/pci/controller/dwc/pcie-dw-rockchip.c; then
	echo "Checking PCIe stage5e after-HWIO diagnostic patch..."
	git apply --check "$PATCH"
	echo "Applying PCIe stage5e after-HWIO diagnostic patch..."
	git apply "$PATCH"
else
	echo "PCIe stage5e after-HWIO diagnostic patch already present."
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

echo "Replacing /boot/Image in diagnostic image..."
cp -f "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image"

DTB="$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"

# Keep the stage5d electrical setup; only shorten link wait a little for this
# diagnostic pass so a failed link attempt returns faster.
fdtput -t u "$DTB" /pcie@fe190000 rockchip,wait-for-link-ms 3000
fdtput -t u "$DTB" /pcie@fe190000 rockchip,perst-inactive-ms 1000

echo "== Verification =="
echo "Image: $DST_IMG"
ls -lh "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image" "$DST_IMG"
sha256sum "$KDIR/arch/arm64/boot/Image" "$MNT/boot/Image" "$DST_IMG"
for node in /phy@fee00000 /phy@fee20000 /vcc3v3-pcie-eth /pcie@fe190000; do
	printf '%-22s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
for prop in phys reset-gpios vpcie3v3-supply rockchip,wait-for-link-ms rockchip,perst-inactive-ms max-link-speed num-lanes hotplug-gpios prsnt-gpios; do
	printf '/pcie@fe190000 %s=' "$prop"
	fdtget "$DTB" /pcie@fe190000 "$prop" 2>/dev/null || echo NA
done
grep -n "codex pcie diag5e" drivers/pci/controller/dwc/pcie-dw-rockchip.c | head -80

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST_IMG"
