# wd-rac-client

Minimal WsprDaemon Remote Access Client (RAC) node setup for small Raspberry Pi
machines (target: Pi Zero 2 W, 512 MB RAM, ~3 GB disk, Raspberry Pi OS Lite /
Debian 13 arm64).

The finished node runs exactly three things beyond the base OS:

1. `sshd` — remote login
2. `screen` / `tmux` — persistent terminal sessions (plus `btop` and
   `vim-tiny` as the standard small-tool set)
3. `wd-remote-access@gw2` and `wd-remote-access@gw1` — one frpc reverse
   tunnel per WsprDaemon gateway, both up all the time, so the node is
   reachable behind NAT and stays reachable when either gateway is down

Supported uplinks: onboard wifi (e.g. Zero 2 W, 3B+) or wired ethernet
(e.g. 3B). The debloat script keeps `firmware-brcm80211` either way so
onboard wifi always remains available.

Everything else on a stock Raspberry Pi OS Lite image is a candidate for
removal. The debloat script below reclaims roughly 600–700 MB.

## Layout

```
install.sh                   standalone interactive installer (git clone + run)
scripts/10-debloat.sh        strip a fresh Raspberry Pi OS Lite install
scripts/20-install-wd-rac.sh install frpc + one wd-remote-access@<gateway> instance per gateway
systemd/wd-remote-access@.service   template unit
config/frpc.toml.template    per-gateway config header; proxy blocks are appended by the installer
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

No git on the machine? Use the tarball instead (~60 MB smaller footprint):

```sh
curl -L https://github.com/rrobinett/wd-rac-client/archive/main.tar.gz | tar xz
cd wd-rac-client-main
sudo ./install.sh
```

`install.sh` prompts for just two things:

- **site name** (defaults to the hostname)
- **RAC number** — assigned by your administrator, or left empty to let the
  gateway auto-assign one

It then generates a node identity keypair, registers with the RAC registrar
on `gw2.wsprdaemon.org` (which validates the RAC number against every
registered and currently-connected client and rejects collisions), receives
the **gateway list**, fleet token, and this node's deterministic ports
(`35800 + RAC` for ssh, `45800 + RAC` for a web UI, …), installs the
matching frpc release for the local CPU, and enables one
`wd-remote-access@<gateway>` instance per gateway — normally `@gw2`
(primary) and `@gw1` (standby). The node presents the same identity and
ports to both, so it is reachable at whichever gateway is alive; there is
no switching to get wrong. The install fails loudly if a gateway rejects a
port, and confirms `start proxy success` on the primary before declaring
victory.

Set `WD_RAC_SITE` and `WD_RAC_NUMBER` in the environment to skip the
prompts for unattended installs (image building). `WD_RAC_PROXIES`
chooses what is tunnelled (default `vm_ssh=22`; e.g.
`"vm_ssh=22 vm_web=8081"` to also publish ka9q-web on `45800 + RAC`).

### Upgrading, and migrating a WsprDaemon host off its built-in RAC

Re-running the installer on a node with the 1.x single-tunnel
`wd-remote-access` service upgrades it in place: the new instances are
started and proven **before** the old service is retired, under a
10-minute dead-man rollback timer, so the node is never without a working
tunnel — the tunnel being replaced is usually the only way in.

On a WsprDaemon 3.x host that still runs WsprDaemon's own legacy RAC
daemon (`bin/frpc_wd.ini`, frps-open tier), the installer detects it,
keeps the same RAC number and the same tunnels, and replaces it the same
way. Pass `WD_RAC_RETIRE_LEGACY=yes` to also comment `RAC=`/`REMOTE_ACCESS_*`
out of `wsprdaemon.conf` (backup kept) — otherwise WsprDaemon re-enables its
daemon and contends for the ports:

```sh
sudo WD_RAC_SITE=KJ6MKI WD_RAC_RETIRE_LEGACY=yes ./install.sh
```

Run it detached (`systemd-run`) or from the console if your own session
arrives through the tunnel being replaced.

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
