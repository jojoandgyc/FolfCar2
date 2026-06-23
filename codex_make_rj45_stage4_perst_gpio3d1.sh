#!/usr/bin/env bash
set -euo pipefail

# Stage4 PCIe PERST GPIO experiment.
# It starts from the stage3C PCIe diagnostic image, keeps verified RJ45 power,
# assigns RTL8125 PERST to GPIO3_D1, removes hotplug GPIOs, and enables the
# tested PCIe path. SRC is copied first; only DST is modified.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage3c-pcie-hotplug-nullguard-uart-login115200.img"
DST="$IMGDIR/opi5p-rj45-stage4-pcie-perst-gpio3d1-nohotplug-uart-login115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

echo "Creating stage4 image with RTL8125 PERST on GPIO3_D1..."
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

echo "Keep RJ45 power enable verified as GPIO3_B4 active-high."
fdtput -d "$DTB" /vcc3v3-pcie-eth enable-active-low 2>/dev/null || true
fdtput "$DTB" /vcc3v3-pcie-eth enable-active-high
fdtput -t u "$DTB" /vcc3v3-pcie-eth gpios "$GPIO3_PHANDLE" 12 0
fdtput -t s "$DTB" /vcc3v3-pcie-eth status "okay"
fdtput -t s "$DTB" /pcie20-avdd0v85 status "okay"
fdtput -t s "$DTB" /pcie20-avdd1v8 status "okay"

echo "Use schematic PERST: PCIE20_1_2_PERSTN_L -> GPIO3_D1, active-high descriptor."
fdtput -t u "$DTB" /pcie@fe190000 reset-gpios "$GPIO3_PHANDLE" 25 0
fdtput -d "$DTB" /pcie@fe190000 hotplug-gpios 2>/dev/null || true
fdtput -d "$DTB" /pcie@fe190000 hotplug-gpio 2>/dev/null || true
fdtput -t u "$DTB" /pcie@fe190000 vpcie3v3-supply "$VCC_ETH_PHANDLE"
fdtput -t u "$DTB" /pcie@fe190000 rockchip,wait-for-link-ms 3000
fdtput -t u "$DTB" /pcie@fe190000 rockchip,perst-inactive-ms 300
fdtput -t s "$DTB" /phy@fee20000 status "okay"
fdtput -t s "$DTB" /pcie@fe190000 status "okay"
fdtput -t s "$DTB" /phy@fee00000 status "disabled" 2>/dev/null || true

echo "== Verification =="
echo "Image: $DST"
for node in /pcie20-avdd0v85 /pcie20-avdd1v8 /vcc3v3-pcie-eth /phy@fee00000 /phy@fee20000 /pcie@fe190000; do
	printf '%-22s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
printf '/vcc3v3-pcie-eth gpios='
fdtget "$DTB" /vcc3v3-pcie-eth gpios
printf '/pcie@fe190000 reset-gpios='
fdtget "$DTB" /pcie@fe190000 reset-gpios
for prop in hotplug-gpios hotplug-gpio rockchip,wait-for-link-ms rockchip,perst-inactive-ms vpcie3v3-supply phys max-link-speed num-lanes; do
	printf '/pcie@fe190000 %s=' "$prop"
	fdtget "$DTB" /pcie@fe190000 "$prop" 2>/dev/null || echo NA
done
for tty in ttyS0 ttyS3 ttyS9; do
	echo "-- $tty getty override --"
	cat "$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf"
done
sha256sum "$DST" "$MNT/boot/Image" "$DTB"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
