#!/usr/bin/env bash
set -euo pipefail

# Stage3C UART0/UART3/UART9 DTB/login image.
# It forces UART0 M2, UART3 M2, and UART9 M1 pinmux in the final DTB, disables
# wireless nodes that could claim related pins, and enables 115200 serial-getty
# on ttyS0/ttyS3/ttyS9. SRC is copied first; only DST is modified.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage3c-pcie-hotplug-nullguard-uart-login115200.img"
DST="$IMGDIR/opi5p-rj45-stage3c-dts-uart039-login115200.img"
OFFSET=$((61440 * 512))
BAUD=115200

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

echo "Creating image with UART0 M2, UART3 M2 and UART9 M1 enabled in the final DTB..."
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

get_phandle() {
	local sym_path
	sym_path="$(fdtget "$DTB" /__symbols__ "$1")"
	fdtget "$DTB" "$sym_path" phandle
}

UART0M2="$(get_phandle uart0m2_xfer)"
UART3M2="$(get_phandle uart3m2_xfer)"
UART9M1="$(get_phandle uart9m1_xfer)"

enable_uart() {
	local node="$1"
	local pin="$2"

	fdtput -t s "$DTB" "$node" pinctrl-names "default"
	fdtput -t u "$DTB" "$node" pinctrl-0 "$pin"
	fdtput -d "$DTB" "$node" dmas 2>/dev/null || true
	fdtput -d "$DTB" "$node" dma-names 2>/dev/null || true
	fdtput -t s "$DTB" "$node" status "okay"
}

enable_uart /serial@fd890000 "$UART0M2"
enable_uart /serial@feb60000 "$UART3M2"
enable_uart /serial@febc0000 "$UART9M1"

# Keep wireless nodes disabled so their pinctrl groups cannot claim UART-related pins.
fdtput -t s "$DTB" /wireless-bluetooth status "disabled" 2>/dev/null || true
fdtput -t s "$DTB" /wireless-wlan status "disabled" 2>/dev/null || true
fdtput -t s "$DTB" /wifi-diable-gpio-regulator status "disabled" 2>/dev/null || true

mkdir -p "$MNT/etc/systemd/system/getty.target.wants"
for tty in ttyS0 ttyS3 ttyS9; do
	mkdir -p "$MNT/etc/systemd/system/serial-getty@$tty.service.d"
	ln -sfn /lib/systemd/system/serial-getty@.service \
		"$MNT/etc/systemd/system/getty.target.wants/serial-getty@$tty.service"
	rm -f "$MNT/etc/systemd/system/serial-getty.target.wants/serial-getty@$tty.service"
	cat >"$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L --noissue -o '-p -- \\\\u' --keep-baud ${BAUD},1500000,57600,38400,9600 %I \$TERM
EOF
done

echo "== Verification =="
echo "Image: $DST"
for node in /serial@fd890000 /serial@feb50000 /serial@feb60000 /serial@febc0000 /wireless-bluetooth /wireless-wlan; do
	echo "-- $node --"
	printf 'status='
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
	printf 'pinctrl-0='
	fdtget "$DTB" "$node" pinctrl-0 2>/dev/null || echo NA
	printf 'dmas='
	fdtget "$DTB" "$node" dmas 2>/dev/null || echo NA
done
for tty in ttyS0 ttyS3 ttyS9; do
	echo "-- $tty getty --"
	ls -l "$MNT/etc/systemd/system/getty.target.wants/serial-getty@$tty.service"
	cat "$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf"
done
sha256sum "$DST" "$DTB"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
