#!/usr/bin/env bash
set -euo pipefail

IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage6r-fe180000-phy2-rj45fix-uart3bootlog-uart039login1500000.img"
DST="$IMGDIR/opi5p-rj45-stage6s-fe180000-phy2-rj45fix-uart3bootlog115200-uart3login115200.img"
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

ENV_FILE="$MNT/boot/orangepiEnv.txt"
sed -i 's/console=ttyS3,1500000/console=ttyS3,115200/g' "$ENV_FILE"
if ! grep -q 'console=ttyS3,115200' "$ENV_FILE"; then
	if grep -q '^extraargs=' "$ENV_FILE"; then
		sed -i 's/^extraargs=/extraargs=console=ttyS3,115200 /' "$ENV_FILE"
	else
		printf '\nextraargs=console=ttyS3,115200\n' >>"$ENV_FILE"
	fi
fi

mkdir -p "$MNT/etc/systemd/system/serial-getty@ttyS3.service.d"
cat >"$MNT/etc/systemd/system/serial-getty@ttyS3.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L --noissue -o '-p -- \\u' 115200 %I $TERM
EOF
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants" "$MNT/etc/systemd/system/getty.target.wants"
ln -sfn /lib/systemd/system/serial-getty@.service \
	"$MNT/etc/systemd/system/multi-user.target.wants/serial-getty@ttyS3.service"
ln -sfn /lib/systemd/system/serial-getty@.service \
	"$MNT/etc/systemd/system/getty.target.wants/serial-getty@ttyS3.service"
grep -qx ttyS3 "$MNT/etc/securetty" 2>/dev/null || echo ttyS3 >>"$MNT/etc/securetty"

DTB="$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"

echo "== stage6s verify =="
echo "Image: $DST"
echo "BOOT_ENV"
cat "$ENV_FILE"
echo "UART3_DTB"
for prop in status pinctrl-names pinctrl-0 dmas dma-names; do
	printf '/serial@feb60000 %s=' "$prop"
	fdtget "$DTB" /serial@feb60000 "$prop" 2>/dev/null || echo NA
done
echo "UART3_GETTY"
readlink "$MNT/etc/systemd/system/multi-user.target.wants/serial-getty@ttyS3.service" || true
sed -n "1,20p" "$MNT/etc/systemd/system/serial-getty@ttyS3.service.d/override.conf"
echo "OTHER_GETTY"
for tty in ttyS0 ttyS9; do
	echo "--$tty"
	sed -n "1,20p" "$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf" 2>/dev/null || true
done
echo "RJ45_DTB"
for node in /pcie@fe180000 /phy@fee20000 /vcc3v3-pcie-eth; do
	printf '%-18s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
sha256sum "$DST" "$DTB" "$ENV_FILE"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
