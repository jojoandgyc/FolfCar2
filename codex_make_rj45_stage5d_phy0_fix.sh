#!/usr/bin/env bash
set -euo pipefail

IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage5c-pcie-resource-diag-forcedlogin115200.img"
DST="$IMGDIR/opi5p-rj45-stage5d-phy0-fee00000-fix-forcedlogin115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

echo "Creating stage5d image: enable the PHY actually referenced by pcie@fe190000..."
rm -f "$DST"
cp --reflink=auto --sparse=always "$SRC" "$DST"
chown jojo:sudo "$DST" 2>/dev/null || true
chmod 664 "$DST"

MNT="$(mktemp -d)"
cleanup() {
	sync || true
	if mountpoint -q "$MNT"; then
		umount "$MNT"
	fi
	rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

mount -o loop,rw,offset="$OFFSET" "$DST" "$MNT"

DTB="$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"
GPIO3_PATH="$(fdtget "$DTB" /aliases gpio3)"
GPIO3_PHANDLE="$(fdtget "$DTB" "$GPIO3_PATH" phandle)"
VCC_ETH_PHANDLE="$(fdtget "$DTB" /vcc3v3-pcie-eth phandle)"

# pcie@fe190000 currently points to /phy@fee00000 via its phys phandle.
# Keep that reference and enable the matching PHY instead of fee20000.
fdtput -t s "$DTB" /phy@fee00000 status "okay"
fdtput -t s "$DTB" /phy@fee20000 status "disabled"
fdtput -t u "$DTB" /pcie@fe190000 phys "$(fdtget "$DTB" /phy@fee00000 phandle)" 2

fdtput -d "$DTB" /vcc3v3-pcie-eth enable-active-low 2>/dev/null || true
fdtput "$DTB" /vcc3v3-pcie-eth enable-active-high
fdtput -t u "$DTB" /vcc3v3-pcie-eth gpios "$GPIO3_PHANDLE" 12 0
fdtput -t s "$DTB" /vcc3v3-pcie-eth status "okay"
fdtput -t s "$DTB" /pcie20-avdd0v85 status "okay"
fdtput -t s "$DTB" /pcie20-avdd1v8 status "okay"

fdtput -t u "$DTB" /pcie@fe190000 reset-gpios "$GPIO3_PHANDLE" 25 1
fdtput -d "$DTB" /pcie@fe190000 hotplug-gpios 2>/dev/null || true
fdtput -d "$DTB" /pcie@fe190000 hotplug-gpio 2>/dev/null || true
fdtput -d "$DTB" /pcie@fe190000 prsnt-gpios 2>/dev/null || true
fdtput -d "$DTB" /pcie@fe190000 prsnt-gpio 2>/dev/null || true
fdtput -t u "$DTB" /pcie@fe190000 vpcie3v3-supply "$VCC_ETH_PHANDLE"
fdtput -t u "$DTB" /pcie@fe190000 rockchip,wait-for-link-ms 10000
fdtput -t u "$DTB" /pcie@fe190000 rockchip,perst-inactive-ms 1000
fdtput -t u "$DTB" /pcie@fe190000 max-link-speed 1
fdtput -t u "$DTB" /pcie@fe190000 num-lanes 1
fdtput -t s "$DTB" /pcie@fe190000 status "okay"

echo "== Verification =="
echo "Image: $DST"
for node in /phy@fee00000 /phy@fee10000 /phy@fee20000 /vcc3v3-pcie-eth /pcie@fe190000; do
	printf '%-22s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
	printf '%-22s phandle=' "$node"
	fdtget "$DTB" "$node" phandle 2>/dev/null || echo NA
done
for prop in phys reset-gpios vpcie3v3-supply rockchip,wait-for-link-ms rockchip,perst-inactive-ms max-link-speed num-lanes hotplug-gpios prsnt-gpios; do
	printf '/pcie@fe190000 %s=' "$prop"
	fdtget "$DTB" /pcie@fe190000 "$prop" 2>/dev/null || echo NA
done
printf '/vcc3v3-pcie-eth gpios='
fdtget "$DTB" /vcc3v3-pcie-eth gpios
sha256sum "$DST" "$DTB" "$MNT/boot/Image"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
