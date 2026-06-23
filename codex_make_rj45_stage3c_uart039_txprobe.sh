#!/usr/bin/env bash
set -euo pipefail

# Stage3C UART TX probe image.
# It adds a persistent service that writes a numbered test line once per second
# to ttyS0, ttyS3, and ttyS9 at 115200 for adapter/scope/logic-analyzer checks.
# SRC is copied first; only DST is modified and overwritten.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage3c-dts-uart039-login115200.img"
DST="$IMGDIR/opi5p-rj45-stage3c-dts-uart039-txprobe115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

echo "Creating UART0/3/9 TX probe image..."
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

cat >"$MNT/usr/local/sbin/codex-uart039-txprobe.sh" <<'EOF'
#!/bin/sh
set -eu

setup_tty() {
	tty="$1"
	if [ -e "$tty" ]; then
		stty -F "$tty" 115200 cs8 -cstopb -parenb -ixon -ixoff -crtscts raw -echo || true
	fi
}

setup_tty /dev/ttyS0
setup_tty /dev/ttyS3
setup_tty /dev/ttyS9

i=0
while true; do
	i=$((i + 1))
	printf 'UART0_TEST_%06d\r\n' "$i" > /dev/ttyS0 2>/dev/null || true
	printf 'UART3_TEST_%06d\r\n' "$i" > /dev/ttyS3 2>/dev/null || true
	printf 'UART9_TEST_%06d\r\n' "$i" > /dev/ttyS9 2>/dev/null || true
	sleep 1
done
EOF
chmod 0755 "$MNT/usr/local/sbin/codex-uart039-txprobe.sh"

cat >"$MNT/etc/systemd/system/codex-uart039-txprobe.service" <<'EOF'
[Unit]
Description=Codex UART0 UART3 UART9 TX probe
After=dev-ttyS0.device dev-ttyS3.device dev-ttyS9.device multi-user.target
Wants=dev-ttyS0.device dev-ttyS3.device dev-ttyS9.device

[Service]
Type=simple
ExecStart=/usr/local/sbin/codex-uart039-txprobe.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
ln -sfn /etc/systemd/system/codex-uart039-txprobe.service \
	"$MNT/etc/systemd/system/multi-user.target.wants/codex-uart039-txprobe.service"

echo "== Verification =="
echo "Image: $DST"
ls -l "$MNT/usr/local/sbin/codex-uart039-txprobe.sh"
cat "$MNT/etc/systemd/system/codex-uart039-txprobe.service"
ls -l "$MNT/etc/systemd/system/multi-user.target.wants/codex-uart039-txprobe.service"
sha256sum "$DST"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
