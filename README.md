# wd-rac-client

Minimal WsprDaemon Remote Access Client (RAC) node setup for small Raspberry Pi
machines (target: Pi Zero 2 W, 512 MB RAM, ~3 GB disk, Raspberry Pi OS Lite /
Debian 13 arm64).

The finished node runs exactly three things beyond the base OS:

1. `sshd` — remote login
2. `screen` — persistent terminal sessions
3. `wd-remote-access` — an frpc reverse tunnel back to the WsprDaemon frps
   server, so the node is reachable even behind NAT

Everything else on a stock Raspberry Pi OS Lite image is a candidate for
removal. The debloat script below reclaims roughly 600–700 MB.

## Layout

```
scripts/10-debloat.sh        strip a fresh Raspberry Pi OS Lite install
scripts/20-install-wd-rac.sh install frpc + the wd-remote-access service
systemd/wd-remote-access.service
config/frpc.toml.template
deploy.sh                    copy scripts to a node over ssh and run them
docs/survey-ti4jwc-2026-07-16.md   baseline survey of the first target node
```

## Usage

The target node needs no git — everything is pushed over ssh from your
workstation:

```sh
# 1. Strip the OS (interactive confirmation before anything is purged)
./deploy.sh <ssh-alias> debloat

# 2. Install the tunnel client (fill in your frps server details first)
WD_FRPS_SERVER=frps.example.com \
WD_FRPS_PORT=7000 \
WD_FRPS_TOKEN=secret \
WD_RAC_REMOTE_PORT=35800 \
./deploy.sh <ssh-alias> install
```

`WD_RAC_REMOTE_PORT` is the port on the frps server that maps to the node's
sshd; pick a unique one per node.

## Safety rails

The debloat script refuses to run unless the box looks like the intended
target, and it `apt-mark hold`s the packages that keep the only network link
alive (`network-manager`, `wpasupplicant`, `firmware-brcm80211`,
`openssh-server`, `raspi-firmware`). Never restart `wd-remote-access` and
networking in the same command once the tunnel is the only way in.
