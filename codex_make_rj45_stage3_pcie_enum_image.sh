#!/usr/bin/env bash
set -euo pipefail

# RJ45 stage3 PCIe enumeration image.
# It keeps the verified active-high Ethernet power rail, enables the tested
# PCIe PHY/host path, wires vpcie3v3-supply, and leaves the other PHY disabled.
# SRC is copied first; only DST is modified and overwritten.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage2-activehigh-uart0-uart3-uart9-loginL-1500000.img"
DST="$IMGDIR/opi5p-rj45-stage3-pcie-enum-activehigh-uart-loginL-1500000.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root, for example: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

echo "Creating RJ45 stage3 PCIe enumeration image..."
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

echo "Keep verified RJ45 power polarity: GPIO3_B4 active-high."
fdtput -d "$DTB" /vcc3v3-pcie-eth enable-active-low 2>/dev/null || true
fdtput "$DTB" /vcc3v3-pcie-eth enable-active-high
fdtput -t u "$DTB" /vcc3v3-pcie-eth gpios "$GPIO3_PHANDLE" 12 0
fdtput -t s "$DTB" /vcc3v3-pcie-eth status "okay"
fdtput -t s "$DTB" /pcie20-avdd0v85 status "okay"
fdtput -t s "$DTB" /pcie20-avdd1v8 status "okay"

echo "Enable only the PCIe controller path used by the RJ45 slot."
fdtput -t s "$DTB" /phy@fee20000 status "okay"
fdtput -t u "$DTB" /pcie@fe190000 vpcie3v3-supply "$VCC_ETH_PHANDLE"
fdtput -t s "$DTB" /pcie@fe190000 status "okay"

echo "Leave the other PCIe combo PHY disabled for this stage."
fdtput -t s "$DTB" /phy@fee00000 status "disabled" 2>/dev/null || true

echo "== Verification =="
echo "Image: $DST"
for node in /pcie20-avdd0v85 /pcie20-avdd1v8 /vcc3v3-pcie-eth /phy@fee00000 /phy@fee20000 /pcie@fe190000; do
	printf '%-22s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
printf '/vcc3v3-pcie-eth gpios='
fdtget "$DTB" /vcc3v3-pcie-eth gpios
printf '/vcc3v3-pcie-eth enable-active-low='
fdtget "$DTB" /vcc3v3-pcie-eth enable-active-low 2>/dev/null || echo NA
printf '/vcc3v3-pcie-eth enable-active-high='
fdtget "$DTB" /vcc3v3-pcie-eth enable-active-high 2>/dev/null || echo present
printf '/pcie@fe190000 phys='
fdtget "$DTB" /pcie@fe190000 phys 2>/dev/null || echo NA
printf '/pcie@fe190000 vpcie3v3-supply='
fdtget "$DTB" /pcie@fe190000 vpcie3v3-supply 2>/dev/null || echo NA
grep -nE 'consoleargs|bootargs' "$MNT/boot/boot.cmd" | head -20
sha256sum "$DST" "$DTB"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
