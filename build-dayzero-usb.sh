#!/bin/sh
# DayZero USB Builder for Linux. Makes a Windows or Linux install stick from a Linux PC.
# Needs PowerShell 7 and a few standard tools; erasing a stick needs root (sudo).
#   sudo ./build-dayzero-usb.sh                 (asks everything)
#   ./build-dayzero-usb.sh -ListDisks           (shows the USB sticks, changes nothing)
#   sudo ./build-dayzero-usb.sh -System ubuntu-26.04 -Disk /dev/sdb -UserName ivan
cd "$(dirname "$0")" || exit 1

if ! command -v pwsh >/dev/null 2>&1; then
    echo "PowerShell 7 (pwsh) is needed. Install it, then start again:"
    echo "  Ubuntu/Debian/Mint:  sudo snap install powershell --classic"
    echo "  Fedora:              sudo dnf install https://github.com/PowerShell/PowerShell/releases (powershell-*.rpm)"
    echo "  Arch:                yay -S powershell-bin"
    echo "  More:                https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux"
    exit 1
fi

missing=""
for t in lsblk wipefs parted mkfs.vfat; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
if [ -n "$missing" ]; then
    echo "Missing tools:$missing"
    echo "  Ubuntu/Debian/Mint:  sudo apt install util-linux parted dosfstools"
    echo "  Fedora:              sudo dnf install util-linux parted dosfstools"
    exit 1
fi
# Only needed for some sticks; the builder says so when it needs them.
for t in wimlib-imagex cabextract xorriso mcopy; do
    command -v "$t" >/dev/null 2>&1 || echo "Note: $t is not installed (packages: wimtools for Windows sticks, cabextract for Windows downloads, xorriso or mtools as fallbacks)."
done

exec pwsh -NoProfile -NoLogo -File builder/BuilderCli.ps1 "$@"
