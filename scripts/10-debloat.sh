#!/bin/bash
# Strip a fresh Raspberry Pi OS Lite (Debian 13) install down to a minimal
# ssh + screen + wd-remote-access node. Run ON the target as root.
#
# Reclaims roughly 600-700 MB. See docs/survey-ti4jwc-2026-07-16.md for the
# reasoning behind each group.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root (sudo $0)" >&2
    exit 1
fi

# --- Sanity guards: only run on the intended class of machine ------------
if ! grep -qi 'raspberry' /proc/device-tree/model 2>/dev/null; then
    echo "ERROR: this does not look like a Raspberry Pi — refusing to run." >&2
    exit 1
fi

# The default route must be on onboard wifi (wlan*) or wired ethernet
# (eth*/en*); anything else (USB dongle, PPP, ...) may depend on packages
# purged below, so refuse and let a human look.
uplink=$(ip route show default | awk '/^default/ {for (i=1;i<NF;i++) if ($i=="dev") print $(i+1); exit}')
case "$uplink" in
    wlan*|eth*|en*) echo "Uplink: $uplink" ;;
    *)
        echo "ERROR: default route is via '${uplink:-none}', not wifi/ethernet — review before debloating." >&2
        ip route show default >&2
        exit 1
        ;;
esac

# --- Protect the packages that keep the only link to the box alive -------
apt-mark hold network-manager wpasupplicant firmware-brcm80211 \
    openssh-server raspi-firmware rpi-swap 2>/dev/null || true

PURGE=(
    # build toolchain (~250 MB) — nothing is compiled on-node
    build-essential gcc g++ make gdb dpkg-dev libc6-dev
    'linux-headers-*' manpages-dev
    # firmware for wifi chips this board does not have (~173 MB)
    firmware-atheros firmware-mediatek firmware-realtek firmware-libertas
    # oddball non-default packages found on the image
    mkvtoolnix sq 7zip
    # cloud-init: first-boot provisioning, done its job on a static node
    cloud-init rpi-cloud-init-mods
    # camera / ML stack — no camera on this node
    'libcamera*' 'rpicam-apps*' 'libtensorflow-lite*'
    # remote-desktop / disk-automount / mDNS extras
    rpi-connect-lite udisks2 avahi-daemon
    # bluetooth
    bluez bluez-firmware
    # audio
    alsa-utils
    # docs and update tooling not needed on a 3 GB card
    man-db manpages apt-listchanges
    # Pi Zero 2 W has no bootloader EEPROM; rpi-update is hazardous anyway
    rpi-eeprom rpi-update
)

echo "== Packages to purge =="
printf '  %s\n' "${PURGE[@]}"
echo
df -h /
read -r -p "Proceed with purge? [y/N] " ans
[[ ${ans,,} == y ]] || { echo "Aborted."; exit 0; }

apt-get purge -y "${PURGE[@]}"
apt-get autoremove --purge -y
apt-get clean

# cloud-init leaves state behind
rm -rf /etc/cloud /var/lib/cloud

# Nightly apt download/upgrade churn is unwelcome on 512 MB RAM / 3 GB disk;
# update manually over ssh instead.
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# The Pi 5 kernel ships in the image but is dead weight on a Zero 2 W
if [[ "$(uname -r)" == *-rpi-v8 ]]; then
    apt-get purge -y 'linux-image-*-rpi-2712' 2>/dev/null || true
    apt-get autoremove --purge -y
fi

# --- Install the standard tool set for a minimal node --------------------
apt-get update
apt-get install -y screen tmux btop vim-tiny git
apt-get clean

echo
echo "== Done =="
df -h /
