#!/usr/bin/env bash
set -euo pipefail

IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage6t-fe180000-phy2-rj45fix-uart3bootlog115200-singlegetty.img"
DST="$IMGDIR/opi5p-rj45-stage6u-fe180000-phy2-ethpower-activelow-uart3bootlog115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

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

# Q13 high-side switch looks active-low: pull ETHERNET_POWER_EN low to enable LAN 3.3V.
fdtput -d "$DTB" /vcc3v3-pcie-eth enable-active-high 2>/dev/null || true
fdtput -d "$DTB" /vcc3v3-pcie-eth enable-active-low 2>/dev/null || true
fdtput -t u "$DTB" /vcc3v3-pcie-eth gpios "$GPIO3_PHANDLE" 12 1
fdtput -t s "$DTB" /vcc3v3-pcie-eth status okay

echo "== stage6u verify =="
echo "Image: $DST"
echo "POWER_DTB"
for prop in status gpios enable-active-high enable-active-low regulator-boot-on regulator-always-on; do
	printf '/vcc3v3-pcie-eth %s=' "$prop"
	fdtget "$DTB" /vcc3v3-pcie-eth "$prop" 2>/dev/null || echo NA
done
echo "RJ45_DTB"
for node in /pcie@fe180000 /phy@fee20000 /pcie@fe190000 /phy@fee00000 /sata@fe230000 /usbhost3_0 /usbdrd3_1; do
	printf '%-20s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
printf '/pcie@fe180000 reset-gpios='
fdtget "$DTB" /pcie@fe180000 reset-gpios
printf '/pcie@fe180000 pinctrl-0='
fdtget "$DTB" /pcie@fe180000 pinctrl-0
echo "BOOT_ENV"
cat "$MNT/boot/orangepiEnv.txt"
sha256sum "$DST" "$DTB" "$MNT/boot/orangepiEnv.txt"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
