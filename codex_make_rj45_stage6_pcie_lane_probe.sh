#!/usr/bin/env bash
set -euo pipefail

IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage5e-after-hwio-diag-forcedlogin115200.img"
DST0="$IMGDIR/opi5p-rj45-stage6a-pcie2x1l0-fe170000-phy1-probe.img"
DST1="$IMGDIR/opi5p-rj45-stage6b-pcie2x1l1-fe180000-phy2-probe.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

patch_common() {
	local dtb="$1"
	local selected_pcie="$2"
	local selected_phy="$3"

	local gpio3_path gpio3_phandle vcc_eth_phandle phy_phandle
	gpio3_path="$(fdtget "$dtb" /aliases gpio3)"
	gpio3_phandle="$(fdtget "$dtb" "$gpio3_path" phandle)"
	vcc_eth_phandle="$(fdtget "$dtb" /vcc3v3-pcie-eth phandle)"
	phy_phandle="$(fdtget "$dtb" "$selected_phy" phandle)"

	# RJ45 3.3V enable: ETHERNET_POWER_EN, RK3588 AC29, GPIO3_B4, active-high.
	fdtput -d "$dtb" /vcc3v3-pcie-eth enable-active-low 2>/dev/null || true
	fdtput "$dtb" /vcc3v3-pcie-eth enable-active-high
	fdtput -t u "$dtb" /vcc3v3-pcie-eth gpios "$gpio3_phandle" 12 0
	fdtput -t s "$dtb" /vcc3v3-pcie-eth status "okay"

	fdtput -t s "$dtb" /pcie20-avdd0v85 status "okay"
	fdtput -t s "$dtb" /pcie20-avdd1v8 status "okay"

	for phy in /phy@fee00000 /phy@fee10000 /phy@fee20000; do
		fdtput -t s "$dtb" "$phy" status "disabled" 2>/dev/null || true
	done
	fdtput -t s "$dtb" "$selected_phy" status "okay"

	for pcie in /pcie@fe170000 /pcie@fe180000 /pcie@fe190000; do
		fdtput -t s "$dtb" "$pcie" status "disabled" 2>/dev/null || true
		fdtput -d "$dtb" "$pcie" hotplug-gpios 2>/dev/null || true
		fdtput -d "$dtb" "$pcie" hotplug-gpio 2>/dev/null || true
		fdtput -d "$dtb" "$pcie" prsnt-gpios 2>/dev/null || true
		fdtput -d "$dtb" "$pcie" prsnt-gpio 2>/dev/null || true
	done

	# PERST: PCIE20_1_2_PERSTN_L, GPIO3_D1, active-low.
	fdtput -t u "$dtb" "$selected_pcie" reset-gpios "$gpio3_phandle" 25 1
	fdtput -t u "$dtb" "$selected_pcie" vpcie3v3-supply "$vcc_eth_phandle"
	fdtput -t u "$dtb" "$selected_pcie" phys "$phy_phandle" 2
	fdtput -t u "$dtb" "$selected_pcie" rockchip,wait-for-link-ms 3000
	fdtput -t u "$dtb" "$selected_pcie" rockchip,perst-inactive-ms 1000
	fdtput -t u "$dtb" "$selected_pcie" max-link-speed 1
	fdtput -t u "$dtb" "$selected_pcie" num-lanes 1
	fdtput -t s "$dtb" "$selected_pcie" status "okay"
}

make_one() {
	local dst="$1"
	local selected_pcie="$2"
	local selected_phy="$3"

	rm -f "$dst"
	cp --reflink=auto --sparse=always "$SRC" "$dst"
	chown jojo:sudo "$dst" 2>/dev/null || true
	chmod 664 "$dst"

	local mnt
	mnt="$(mktemp -d)"
	mount -o loop,rw,offset="$OFFSET" "$dst" "$mnt"
	local dtb="$mnt/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"
	patch_common "$dtb" "$selected_pcie" "$selected_phy"

	echo "== Verification for $(basename "$dst") =="
	echo "Image: $dst"
	for node in /phy@fee00000 /phy@fee10000 /phy@fee20000 /pcie@fe170000 /pcie@fe180000 /pcie@fe190000 /vcc3v3-pcie-eth; do
		printf '%-22s status=' "$node"
		fdtget "$dtb" "$node" status 2>/dev/null || echo NA
	done
	for pcie in /pcie@fe170000 /pcie@fe180000 /pcie@fe190000; do
		echo "-- $pcie --"
		for prop in phys reset-gpios vpcie3v3-supply rockchip,wait-for-link-ms rockchip,perst-inactive-ms max-link-speed num-lanes; do
			printf '%s=' "$prop"
			fdtget "$dtb" "$pcie" "$prop" 2>/dev/null || echo NA
		done
	done
	sha256sum "$dst" "$dtb" "$mnt/boot/Image"
	sync
	umount "$mnt"
	rmdir "$mnt"
}

make_one "$DST0" /pcie@fe170000 /phy@fee10000
make_one "$DST1" /pcie@fe180000 /phy@fee20000

echo "Created:"
echo "$DST0"
echo "$DST1"
