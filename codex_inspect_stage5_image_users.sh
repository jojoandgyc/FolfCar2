#!/usr/bin/env bash
set -euo pipefail

# Read-only stage5 login inspector.
# It mounts the stage5 image without modifying it and prints password/login
# service details that matter for UART debug access.
IMG="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99/opi5p-rj45-stage5-perst-active-low-longwait-forcedlogin115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root" >&2
	exit 1
fi

MNT="$(mktemp -d)"
cleanup() {
	if mountpoint -q "$MNT"; then
		umount "$MNT"
	fi
	rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

mount -o loop,ro,offset="$OFFSET" "$IMG" "$MNT"

echo "== passwd users =="
awk -F: '{ if ($3 >= 0 && $3 < 2000) print }' "$MNT/etc/passwd"

echo "== shadow relevant =="
grep -E '^(root|orangepi|jojo):' "$MNT/etc/shadow" || true

echo "== codex serial login script =="
sed -n '1,120p' "$MNT/usr/local/sbin/codex-serial-login.sh"

echo "== codex serial login unit =="
sed -n '1,120p' "$MNT/etc/systemd/system/codex-serial-login@.service"

echo "== serial unit links =="
find "$MNT/etc/systemd/system" -maxdepth 3 \( -type f -o -type l \) |
	grep -E 'getty|serial|codex' |
	sort

echo "== securetty serial entries =="
grep -E 'ttyS[039]|ttyFIQ|console' "$MNT/etc/securetty" 2>/dev/null || true

echo "== PAM login head =="
sed -n '1,100p' "$MNT/etc/pam.d/login"
