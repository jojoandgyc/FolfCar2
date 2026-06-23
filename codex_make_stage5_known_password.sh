#!/usr/bin/env bash
set -euo pipefail

# Lab-only stage5 login convenience image.
# It copies the stage5 forced-login image, sets root/orangepi to the known
# password "orangepi", and permits ttyS0/ttyS3/ttyS9 in securetty.
# Do not use the resulting known-password image outside controlled debugging.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage5-perst-active-low-longwait-forcedlogin115200.img"
DST="$IMGDIR/opi5p-rj45-stage5-perst-active-low-longwait-knownpass115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

echo "Creating stage5 image with known serial login password..."
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

# Password is "orangepi". SHA512-crypt keeps this compatible with Ubuntu PAM.
HASH='$6$codexdbg$efL/tgSdUCSBHUIPjtvAKIv8JM0dxOdkVZ3SN9tymV6Ioqy.rkO.v588i7JEkGhOnfktPYksWVXNhR.ncHK/O.'
sed -i -E \
	-e "s#^root:[^:]*:#root:${HASH}:#" \
	-e "s#^orangepi:[^:]*:#orangepi:${HASH}:#" \
	"$MNT/etc/shadow"

for tty in ttyS0 ttyS3 ttyS9; do
	if ! grep -qx "$tty" "$MNT/etc/securetty" 2>/dev/null; then
		echo "$tty" >>"$MNT/etc/securetty"
	fi
done

echo "== Verification =="
echo "Image: $DST"
grep -E '^(root|orangepi):' "$MNT/etc/shadow"
grep -E 'ttyS[039]' "$MNT/etc/securetty"
printf '/pcie@fe190000 reset-gpios='
fdtget "$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb" /pcie@fe190000 reset-gpios
printf '/pcie@fe190000 rockchip,wait-for-link-ms='
fdtget "$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb" /pcie@fe190000 rockchip,wait-for-link-ms
printf '/vcc3v3-pcie-eth gpios='
fdtget "$MNT/boot/dtb/rockchip/rk3588-orangepi-5-plus.dtb" /vcc3v3-pcie-eth gpios
sha256sum "$DST"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
echo "Login after boot: root/orangepi or orangepi/orangepi"
