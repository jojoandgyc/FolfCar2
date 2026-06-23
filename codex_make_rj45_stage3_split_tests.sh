#!/usr/bin/env bash
set -euo pipefail

# RJ45 stage3 split-test generator.
# It creates two images from the same stage2 source: one with only the PCIe PHY
# enabled, and one with the PCIe host enabled using nonfatal/hotplug-style link
# timing. This separates PHY bring-up from host enumeration failures.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage2-activehigh-uart0-uart3-uart9-loginL-1500000.img"
PHY_ONLY="$IMGDIR/opi5p-rj45-stage3a-phyonly-activehigh-uart-loginL-1500000.img"
HOTPLUG="$IMGDIR/opi5p-rj45-stage3b-pcie-hotplug-activehigh-uart-loginL-1500000.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root, for example: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

make_copy() {
	local dst="$1"
	rm -f "$dst"
	cp --reflink=auto --sparse=always "$SRC" "$dst"
	chown jojo:sudo "$dst" 2>/dev/null || true
	chmod 664 "$dst"
}

with_mount() {
	local img="$1"
	local fn="$2"
	local mnt
	mnt="$(mktemp -d)"
	mount -o loop,rw,offset="$OFFSET" "$img" "$mnt"
	"$fn" "$mnt"
	sync
	umount "$mnt"
	rmdir "$mnt"
}

keep_verified_power() {
	local dtb="$1"
	local gpio3_path gpio3_phandle
	gpio3_path="$(fdtget "$dtb" /aliases gpio3)"
	gpio3_phandle="$(fdtget "$dtb" "$gpio3_path" phandle)"

	fdtput -d "$dtb" /vcc3v3-pcie-eth enable-active-low 2>/dev/null || true
	fdtput "$dtb" /vcc3v3-pcie-eth enable-active-high
	fdtput -t u "$dtb" /vcc3v3-pcie-eth gpios "$gpio3_phandle" 12 0
	fdtput -t s "$dtb" /vcc3v3-pcie-eth status "okay"
	fdtput -t s "$dtb" /pcie20-avdd0v85 status "okay"
	fdtput -t s "$dtb" /pcie20-avdd1v8 status "okay"
}

verify_image() {
	local img="$1"
	local mnt="$2"
	local dtb="$mnt/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"
	echo "== Verification: $img =="
	for node in /pcie20-avdd0v85 /pcie20-avdd1v8 /vcc3v3-pcie-eth /phy@fee00000 /phy@fee20000 /pcie@fe190000; do
		printf '%-22s status=' "$node"
		fdtget "$dtb" "$node" status 2>/dev/null || echo NA
	done
	for prop in gpios enable-active-low enable-active-high; do
		printf '/vcc3v3-pcie-eth %s=' "$prop"
		fdtget "$dtb" /vcc3v3-pcie-eth "$prop" 2>/dev/null || echo NA
	done
	for prop in reset-gpios prsnt-gpios hotplug-gpios rockchip,wait-for-link-ms rockchip,perst-inactive-ms vpcie3v3-supply phys; do
		printf '/pcie@fe190000 %s=' "$prop"
		fdtget "$dtb" /pcie@fe190000 "$prop" 2>/dev/null || echo NA
	done
	grep -nE 'consoleargs|bootargs' "$mnt/boot/boot.cmd" | head -20
	sha256sum "$img" "$dtb"
}

make_phy_only() {
	local mnt="$1"
	local dtb="$mnt/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"
	keep_verified_power "$dtb"

	# Isolate ComboPHY probing from the PCIe host controller.
	fdtput -t s "$dtb" /phy@fee20000 status "okay"
	fdtput -t s "$dtb" /pcie@fe190000 status "disabled"
	fdtput -t s "$dtb" /phy@fee00000 status "disabled" 2>/dev/null || true
	fdtput -d "$dtb" /pcie@fe190000 vpcie3v3-supply 2>/dev/null || true
	verify_image "$PHY_ONLY" "$mnt"
}

make_hotplug() {
	local mnt="$1"
	local dtb="$mnt/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"
	local vcc_eth_phandle
	vcc_eth_phandle="$(fdtget "$dtb" /vcc3v3-pcie-eth phandle)"
	keep_verified_power "$dtb"

	# Enable host but make link failure non-fatal in the Rockchip driver.
	fdtput -t s "$dtb" /phy@fee20000 status "okay"
	fdtput -t u "$dtb" /pcie@fe190000 vpcie3v3-supply "$vcc_eth_phandle"
	fdtput "$dtb" /pcie@fe190000 hotplug-gpios
	fdtput -t u "$dtb" /pcie@fe190000 rockchip,wait-for-link-ms 1000
	fdtput -t u "$dtb" /pcie@fe190000 rockchip,perst-inactive-ms 200
	fdtput -t s "$dtb" /pcie@fe190000 status "okay"
	fdtput -t s "$dtb" /phy@fee00000 status "disabled" 2>/dev/null || true
	verify_image "$HOTPLUG" "$mnt"
}

echo "Creating stage3 split test images..."
make_copy "$PHY_ONLY"
with_mount "$PHY_ONLY" make_phy_only

make_copy "$HOTPLUG"
with_mount "$HOTPLUG" make_hotplug

echo "Created:"
echo "  $PHY_ONLY"
echo "  $HOTPLUG"
