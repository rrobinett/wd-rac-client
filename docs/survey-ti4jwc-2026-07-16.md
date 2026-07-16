# Baseline survey — ti4jwc (hostname `wsprsondepi`) — 2026-07-16

Fresh-ish Raspberry Pi OS Lite image (machine-id dated 2026-06-17) on a
Pi Zero 2 W. Surveyed read-only before any debloat.

## System

- Debian 13 (trixie), kernel 6.18.34+rpt-rpi-v8, arm64
- Disk: 3.1 G root, 2.3 G used (78 %), 662 M free
- RAM: 415 Mi + 415 Mi zram swap (`rpi-swap` package, `/etc/rpi/swap.conf`;
  dphys-swapfile is NOT installed)
- 632 packages installed; no GUI packages at all
- Sole user `wsprdaemon` (UID 1000), passwordless sudo, autologin on tty1
- No crontabs, `/usr/local` and `/opt` empty

## Key findings

- **No `wd-remote-access` service and no frpc binary exist yet.** ssh
  currently reaches the box directly over wifi (10.2.10.60 on `wlan0`) —
  the tunnel client is what this repo installs.
- **`screen` is not installed** — must be added.
- `git` is not installed (not needed on the node; deploy is via scp/ssh).
- **wlan0 is the only uplink**, managed by NetworkManager + wpa_supplicant.
  `firmware-brcm80211` drives the onboard wifi chip. These must never be
  removed.

## Removal candidates (approximate installed sizes)

| Group | Packages | Size |
|---|---|---|
| Build toolchain | build-essential, gcc/g++/cpp-14, gdb, make, linux-headers, libstdc++/libgcc-dev, sanitizers | ~250 MB |
| Surplus wifi firmware | firmware-atheros (97 M), firmware-mediatek (46 M), firmware-realtek (19 M), firmware-libertas (11 M) | ~173 MB |
| apt package cache | `apt-get clean` | 132 MB |
| Oddballs | mkvtoolnix (28 M), sq/Sequoia-PGP (20 M), 7zip (7 M) | ~55 MB |
| cloud-init stack | cloud-init, rpi-cloud-init-mods, python-babel-localedata + ~60 python3-* deps via autoremove | ~60 MB+ |
| Camera stack | libcamera*, rpicam-apps*, libtensorflow-lite | ~25 MB |
| Remote/desktop extras | rpi-connect-lite (21 M), udisks2, avahi-daemon | ~30 MB |
| Bluetooth | bluez, bluez-firmware | ~10 MB |
| Audio | alsa-utils + libs | ~5 MB |
| Docs | man-db, manpages, manpages-dev, apt-listchanges | ~12 MB |
| EEPROM tools | rpi-eeprom, rpi-update (Zero 2 W has no bootloader EEPROM) | ~8 MB |
| Optional 2nd stage | linux-image-*-rpi-2712 (Pi 5 kernel, unused on a Zero 2 W) | ~50 MB |

## Must keep

sshd, NetworkManager, wpa_supplicant, firmware-brcm80211, raspi-firmware,
rpi-swap (zram), linux-image-*-rpi-v8, nano/vim-tiny.

## Services/timers running at survey time

avahi-daemon, bluetooth, cron, dbus, getty@tty1, NetworkManager, polkit, ssh,
systemd-journald/logind/timesyncd/udevd, udisks2, wpa_supplicant; timers:
apt-daily, apt-daily-upgrade, dpkg-db-backup, e2scrub_all, fstrim, logrotate,
man-db, rpi-zram-writeback, systemd-tmpfiles-clean.
