#!/usr/bin/env bash
set -euo pipefail

IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage6s-fe180000-phy2-rj45fix-uart3bootlog115200-uart3login115200.img"
DST="$IMGDIR/opi5p-rj45-stage6t-fe180000-phy2-rj45fix-uart3bootlog115200-singlegetty.img"
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

# Keep one login provider per UART. The old forced login service was racing
# serial-getty and printing a second login prompt on ttyS3.
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/codex-serial-login@ttyS0.service"
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/codex-serial-login@ttyS3.service"
rm -f "$MNT/etc/systemd/system/multi-user.target.wants/codex-serial-login@ttyS9.service"

mkdir -p "$MNT/etc/systemd/system/getty.target.wants"
mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"

for tty in ttyS0 ttyS9; do
	ln -sfn /lib/systemd/system/serial-getty@.service \
		"$MNT/etc/systemd/system/getty.target.wants/serial-getty@$tty.service"
	ln -sfn /lib/systemd/system/serial-getty@.service \
		"$MNT/etc/systemd/system/multi-user.target.wants/serial-getty@$tty.service"
	mkdir -p "$MNT/etc/systemd/system/serial-getty@$tty.service.d"
	cat >"$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L --noissue -o '-p -- \\u' 1500000 %I $TERM
EOF
	grep -qx "$tty" "$MNT/etc/securetty" 2>/dev/null || echo "$tty" >>"$MNT/etc/securetty"
done

tty=ttyS3
ln -sfn /lib/systemd/system/serial-getty@.service \
	"$MNT/etc/systemd/system/getty.target.wants/serial-getty@$tty.service"
ln -sfn /lib/systemd/system/serial-getty@.service \
	"$MNT/etc/systemd/system/multi-user.target.wants/serial-getty@$tty.service"
mkdir -p "$MNT/etc/systemd/system/serial-getty@$tty.service.d"
cat >"$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L --noissue -o '-p -- \\u' 115200 %I $TERM
EOF
grep -qx "$tty" "$MNT/etc/securetty" 2>/dev/null || echo "$tty" >>"$MNT/etc/securetty"

DTB="$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb"

echo "== stage6t verify =="
echo "Image: $DST"
echo "WANTS"
find "$MNT/etc/systemd/system" -path '*target.wants*' -maxdepth 4 -printf "%P -> %l\n" \
	| grep -E 'ttyS|codex|serial-getty' | sort
echo "OVERRIDES"
for tty in ttyS0 ttyS3 ttyS9; do
	echo "--$tty"
	sed -n "1,20p" "$MNT/etc/systemd/system/serial-getty@$tty.service.d/override.conf"
done
echo "BOOT_ENV"
cat "$MNT/boot/orangepiEnv.txt"
echo "UART3_DTB"
for prop in status pinctrl-names pinctrl-0 dmas dma-names; do
	printf '/serial@feb60000 %s=' "$prop"
	fdtget "$DTB" /serial@feb60000 "$prop" 2>/dev/null || echo NA
done
echo "RJ45_DTB"
for node in /pcie@fe180000 /phy@fee20000 /vcc3v3-pcie-eth; do
	printf '%-18s status=' "$node"
	fdtget "$DTB" "$node" status 2>/dev/null || echo NA
done
sha256sum "$DST" "$DTB" "$MNT/boot/orangepiEnv.txt"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
