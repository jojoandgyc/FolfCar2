#!/usr/bin/env bash
set -euo pipefail

# Stage3C UART boot-log fanout image.
# It edits boot.cmd/orangepiEnv.txt so UART2 stays present while UART0/UART3/
# UART9 also receive kernel console output at 115200, then regenerates boot.scr.
# SRC is copied first; only DST is modified and overwritten.
IMGDIR="/home/jojo/opi5puls/orangepi-build/output/images/Orangepi5plus_1.2.2_ubuntu_jammy_desktop_xfce_linux6.1.99"
SRC="$IMGDIR/opi5p-rj45-stage3c-dts-uart039-login115200.img"
DST="$IMGDIR/opi5p-rj45-stage3c-dts-uart039-bootlog115200.img"
OFFSET=$((61440 * 512))

if [ "$(id -u)" -ne 0 ]; then
	echo "Run as root: printf '123456\\n' | sudo -S bash $0" >&2
	exit 1
fi

if [ ! -f "$SRC" ]; then
	echo "Source image not found: $SRC" >&2
	exit 1
fi

echo "Creating UART0/3/9 bootlog image..."
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

ENV="$MNT/boot/orangepiEnv.txt"
BOOTCMD="$MNT/boot/boot.cmd"
BOOTSCR="$MNT/boot/boot.scr"

python3 - "$ENV" "$BOOTCMD" <<'PY'
from pathlib import Path
import re
import sys

env = Path(sys.argv[1])
bootcmd = Path(sys.argv[2])

lines = env.read_text().splitlines()
out = []
seen = False
for line in lines:
    if line.startswith("console="):
        out.append("console=both")
        seen = True
    else:
        out.append(line)
if not seen:
    out.append("console=both")
env.write_text("\n".join(out) + "\n")

text = bootcmd.read_text()
new_line = (
    'if test "${console}" = "serial" || test "${console}" = "both"; '
    'then setenv consoleargs "${consoleargs} console=ttyS2,1500000 '
    'console=ttyS0,115200 console=ttyS3,115200 console=ttyS9,115200"; fi'
)
pattern = (
    r'if test "\$\{console\}" = "serial" \|\| test "\$\{console\}" = "both"; '
    r'then setenv consoleargs "[^"]*console=ttyS2,1500000[^"]*"; fi'
)
text, count = re.subn(pattern, new_line, text, count=1)
if count != 1:
    raise SystemExit("failed to replace serial consoleargs line")
bootcmd.write_text(text)
PY

mkimage -C none -A arm -T script -d "$BOOTCMD" "$BOOTSCR" >/dev/null

echo "== Verification =="
echo "Image: $DST"
grep -nE '^(console|verbosity|bootlogo|extraargs)=' "$ENV"
grep -nE 'consoleargs|bootargs' "$BOOTCMD"
strings "$BOOTSCR" | grep -E 'console=ttyS2|console=ttyS0|console=ttyS3|console=ttyS9|bootargs' || true
sha256sum "$DST" "$BOOTSCR"

sync
umount "$MNT"
rmdir "$MNT"
trap - EXIT

echo "Created: $DST"
