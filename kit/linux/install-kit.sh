#!/bin/sh
# DayZero for Linux - run by the Ubuntu installer (autoinstall late-command) just before the
# first restart. $1 is where the new system is mounted (/target). Copies the kit to
# /opt/dayzero, turns on the first-boot service and the progress window, and never touches a
# disk. A problem here is logged, never fatal: the installed system must still start.
T="${1:-/target}"
SRC="$(cd "$(dirname "$0")" && pwd)"
LOG="$T/var/log/dayzero/install.log"
mkdir -p "$T/var/log/dayzero"
exec >>"$LOG" 2>&1
echo "DayZero install-kit: from $SRC to $T at $(date)"

if [ ! -d "$T/etc" ]; then echo "No installed system at $T; nothing done."; exit 0; fi

rm -rf "$T/opt/dayzero"
mkdir -p "$T/opt/dayzero"
cp -r "$SRC/." "$T/opt/dayzero/" || echo "Copying the kit failed."
rm -f "$T/opt/dayzero/autoinstall.yaml"
chmod 755 "$T/opt/dayzero" "$T/opt/dayzero/dayzero.py" 2>/dev/null
find "$T/opt/dayzero" -type f -name '*.sh' -exec chmod 755 {} \;
# settings.json holds no password; the kit is readable so the progress window can read it.
chmod -R go-w "$T/opt/dayzero"

install -m 644 "$SRC/dayzero-setup.service" "$T/etc/systemd/system/dayzero-setup.service"
mkdir -p "$T/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/dayzero-setup.service "$T/etc/systemd/system/multi-user.target.wants/dayzero-setup.service"
mkdir -p "$T/etc/xdg/autostart"
install -m 644 "$SRC/dayzero-progress.desktop" "$T/etc/xdg/autostart/dayzero-progress.desktop"

# Temporary password: Linux asks for a new one at the first sign-in.
USERNAME="$(sed -n 's/^ *"userName": *"\([a-z][a-z0-9_-]*\)".*/\1/p' "$SRC/settings.json" | head -n 1)"
if grep -q '"temporaryPassword": *true' "$SRC/settings.json" && [ -n "$USERNAME" ]; then
    chage -R "$T" -d 0 "$USERNAME" && echo "Password of $USERNAME must be changed at the first sign-in."
fi
echo "DayZero install-kit: done."
exit 0
