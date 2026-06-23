#!/usr/bin/env bash
set -euo pipefail

# Stage3 UART baud-rate converter.
# It copies the stage3a/stage3b images and rewrites UART0/UART3/UART9 getty
# overrides to prefer 115200 while still accepting the earlier 1500000 baud.
# Each generated destination image is overwritten.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
OFFSET=$((61440 * 512))
BAUD=115200

SOURCES=(
	"opi5p-rj45-stage3a-phyonly-activehigh-uart-loginL-1500000.img"
	"opi5p-rj45-stage3b-pcie-hotplug-activehigh-uart-loginL-1500000.img"
)

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root, for example: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

for name in "${SOURCES[@]}"; do
	src="$IMGDIR/$name"
	dst="$IMGDIR/${name/1500000/login115200}"

	if [ ! -f "$src" ]; then
		echo "Source image not found: $src" >&2
		exit 1
	fi

	echo "Creating $dst"
	rm -f "$dst"
	cp --reflink=auto --sparse=always "$src" "$dst"
	chown jojo:sudo "$dst" 2>/dev/null || true
	chmod 664 "$dst"

	mnt="$(mktemp -d)"
	cleanup() {
		sync || true
		if mountpoint -q "$mnt"; then
			umount "$mnt"
		fi
		rmdir "$mnt" 2>/dev/null || true
	}
	trap cleanup EXIT

	mount -o loop,rw,offset="$OFFSET" "$dst" "$mnt"
	mkdir -p "$mnt/etc/systemd/system/getty.target.wants"

	for tty in ttyS0 ttyS3 ttyS9; do
		mkdir -p "$mnt/etc/systemd/system/serial-getty@$tty.service.d"
		ln -sfn /lib/systemd/system/serial-getty@.service \
			"$mnt/etc/systemd/system/getty.target.wants/serial-getty@$tty.service"
		rm -f "$mnt/etc/systemd/system/serial-getty.target.wants/serial-getty@$tty.service"
		cat >"$mnt/etc/systemd/system/serial-getty@$tty.service.d/override.conf" <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty -L --noissue -o '-p -- \\\\u' --keep-baud ${BAUD},1500000,57600,38400,9600 %I \$TERM
EOF
	done

	echo "== Verification: $dst =="
	for tty in ttyS0 ttyS2 ttyS3 ttyS9; do
		echo "-- $tty --"
		ls -l "$mnt/etc/systemd/system/getty.target.wants/serial-getty@$tty.service" 2>/dev/null || true
		ovr="$mnt/etc/systemd/system/serial-getty@$tty.service.d/override.conf"
		if [ -f "$ovr" ]; then
			cat "$ovr"
		else
			echo "NO_OVERRIDE"
		fi
	done
	grep -nE 'consoleargs|bootargs' "$mnt/boot/boot.cmd" | head -20
	sha256sum "$dst"

	sync
	umount "$mnt"
	rmdir "$mnt"
	trap - EXIT
done
