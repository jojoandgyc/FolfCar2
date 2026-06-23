#!/usr/bin/env bash
set -euo pipefail

# Stage3C forced UART login image.
# It installs a custom systemd template that waits for ttyS0/ttyS3/ttyS9,
# configures each port, and starts agetty directly so login prompts appear
# reliably even when normal serial-getty ordering is fragile.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage3c-dts-uart039-login115200.img"
DST="$IMGDIR/opi5p-rj45-stage3c-dts-uart039-forcedlogin115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

echo "Creating forced UART0/3/9 login image..."
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

cat >"$MNT/usr/local/sbin/codex-serial-login.sh" <<'EOF'
#!/bin/sh
set -eu

tty_name="$1"
tty_path="/dev/$tty_name"

while [ ! -e "$tty_path" ]; do
	sleep 0.2
done

stty -F "$tty_path" 115200 cs8 -cstopb -parenb -ixon -ixoff -crtscts sane || true
printf '\r\nCodex serial login ready on %s at 115200\r\n\r\n' "$tty_name" > "$tty_path" || true
exec /sbin/agetty -L --noissue --noclear -o '-p -- \\u' 115200 "$tty_name" vt102
EOF
chmod 0755 "$MNT/usr/local/sbin/codex-serial-login.sh"

cat >"$MNT/etc/systemd/system/codex-serial-login@.service" <<'EOF'
[Unit]
Description=Codex forced serial login on %I
After=dev-%i.device systemd-user-sessions.service multi-user.target
Wants=dev-%i.device

[Service]
Type=simple
ExecStart=/usr/local/sbin/codex-serial-login.sh %I
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF

mkdir -p "$MNT/etc/systemd/system/multi-user.target.wants"
for tty in ttyS0 ttyS3 ttyS9; do
	ln -sfn /etc/systemd/system/codex-serial-login@.service \
		"$MNT/etc/systemd/system/multi-user.target.wants/codex-serial-login@$tty.service"
	# Avoid two agetty instances fighting for the same port if getty.target is pulled in.
	rm -f "$MNT/etc/systemd/system/getty.target.wants/serial-getty@$tty.service"
done

echo "== Verification =="
echo "Image: $DST"
cat "$MNT/usr/local/sbin/codex-serial-login.sh"
cat "$MNT/etc/systemd/system/codex-serial-login@.service"
ls -l "$MNT/etc/systemd/system/multi-user.target.wants"/codex-serial-login@ttyS*.service
for tty in ttyS0 ttyS3 ttyS9; do
	if [ -e "$MNT/etc/systemd/system/getty.target.wants/serial-getty@$tty.service" ]; then
		echo "unexpected old serial-getty link for $tty" >&2
		exit 1
	fi
done
sha256sum "$DST"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
