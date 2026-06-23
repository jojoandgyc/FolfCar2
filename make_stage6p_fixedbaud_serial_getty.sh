#!/usr/bin/env bash
set -euo pipefail

IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage6m-fe180000-phy2-ac28-gpio3b3-perst-aj24clkreq-ag25wake-uart2log1500000.img"
DST="$IMGDIR/opi5p-rj45-stage6p-fe180000-phy2-rj45fix-uart039-login-fixed1500000.img"
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

mkdir -p "$MNT/etc/systemd/system/getty.target.wants"
for tty in ttyS0 ttyS3 ttyS9; do
	ln -sfn /lib/systemd/system/serial-getty@.service \
		"$MNT/etc/systemd/system/getty.target.wants/serial-getty@$tty.service"
	mkdir -p "$MNT/etc/systemd/system/serial-getty@$tty.service.d"
	cat >"$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L --noissue -o '-p -- \\u' 1500000 %I $TERM
EOF
	grep -qx "$tty" "$MNT/etc/securetty" 2>/dev/null || echo "$tty" >>"$MNT/etc/securetty"
done

DTB="$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"

echo "== stage6p verify =="
echo "Image: $DST"
echo "GETTY_WANTS"
find "$MNT/etc/systemd/system/getty.target.wants" -maxdepth 1 -printf "%f -> %l\n" | sort
for tty in ttyS0 ttyS3 ttyS9; do
	echo "--$tty override"
	sed -n "1,20p" "$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf"
done
echo "UART_DTB"
for node in /serial@fd890000 /serial@feb50000 /serial@feb60000 /serial@febc0000; do
	printf '%-18s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
echo "RJ45_DTB"
for node in /pcie@fe180000 /phy@fee20000 /vcc3v3-pcie-eth; do
	printf '%-18s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
printf '/pcie@fe180000 reset-gpios='
fdtget "$DTB" /pcie@fe180000 reset-gpios
printf '/pcie@fe180000 pinctrl-0='
fdtget "$DTB" /pcie@fe180000 pinctrl-0
echo "SECURETTY"
grep -n 'ttyS[0239]' "$MNT/etc/securetty" || true
sha256sum "$DST" "$DTB"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
