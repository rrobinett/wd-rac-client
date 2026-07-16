# wd-rac-client

Minimal WsprDaemon Remote Access Client (RAC) node setup for small Raspberry Pi
machines (target: Pi Zero 2 W, 512 MB RAM, ~3 GB disk, Raspberry Pi OS Lite /
Debian 13 arm64).

The finished node runs exactly three things beyond the base OS:

1. `sshd` — remote login
2. `screen` / `tmux` — persistent terminal sessions (plus `btop` and
   `vim-tiny` as the standard small-tool set)
3. `wd-remote-access` — an frpc reverse tunnel back to the WsprDaemon frps
   server, so the node is reachable even behind NAT

Supported uplinks: onboard wifi (e.g. Zero 2 W, 3B+) or wired ethernet
(e.g. 3B). The debloat script keeps `firmware-brcm80211` either way so
onboard wifi always remains available.

Everything else on a stock Raspberry Pi OS Lite image is a candidate for
removal. The debloat script below reclaims roughly 600–700 MB.

## Layout

```
install.sh                   standalone interactive installer (git clone + run)
scripts/10-debloat.sh        strip a fresh Raspberry Pi OS Lite install
scripts/20-install-wd-rac.sh install frpc + the wd-remote-access service
systemd/wd-remote-access.service
config/frpc.toml.template
deploy.sh                    copy scripts to a node over ssh and run them
docs/survey-ti4jwc-2026-07-16.md   baseline survey of the first target node
```

## Install on any Linux machine (standalone)

The service is not Raspberry Pi specific — it runs on any systemd-based
Linux (x86_64 / arm64 / armv7 / armv6 / riscv64):

```sh
git clone https://github.com/rrobinett/wd-rac-client.git
cd wd-rac-client
sudo ./install.sh
```

`install.sh` prompts for the frps server, port, auth token, this node's
unique remote ssh port, and a proxy name, then installs frpc and enables
the `wd-remote-access` service. Any value already set in the environment
(e.g. `WD_FRPS_SERVER=...`) is used without prompting, so the same script
works unattended for image building.

## Provision a minimal Pi node from your workstation

The target node needs no git — everything is pushed over ssh:

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
