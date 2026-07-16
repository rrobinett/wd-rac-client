#!/bin/bash
# Install frpc and the wd-remote-access systemd service. Run ON the target
# as root, with the frps server details in the environment:
#
#   WD_FRPS_SERVER   frps server hostname or IP        (required)
#   WD_FRPS_TOKEN    frps auth token                   (required)
#   WD_FRPS_PORT     frps control port                 (default 7000)
#   WD_RAC_REMOTE_PORT  port on the frps server mapped to this node's sshd
#                                                      (required, unique per node)
#   WD_RAC_NAME      proxy name                        (default: hostname)
#   FRP_VERSION      frp release to install            (default below)
#
# Expects frpc.toml.template and wd-remote-access.service alongside this
# script (deploy.sh arranges that).
set -euo pipefail

FRP_VERSION="${FRP_VERSION:-0.63.0}"
WD_FRPS_PORT="${WD_FRPS_PORT:-7000}"
WD_RAC_NAME="${WD_RAC_NAME:-$(hostname)}"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root (sudo -E $0)" >&2
    exit 1
fi
for var in WD_FRPS_SERVER WD_FRPS_TOKEN WD_RAC_REMOTE_PORT; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not set" >&2
        exit 1
    fi
done

HERE="$(cd "$(dirname "$0")" && pwd)"

# --- frpc binary ----------------------------------------------------------
if [[ ! -x /usr/local/bin/frpc ]]; then
    tarball="frp_${FRP_VERSION}_linux_arm64.tar.gz"
    url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${tarball}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "Downloading $url"
    wget -qO "$tmp/$tarball" "$url"
    tar -xzf "$tmp/$tarball" -C "$tmp"
    install -m 755 "$tmp/frp_${FRP_VERSION}_linux_arm64/frpc" /usr/local/bin/frpc
fi
/usr/local/bin/frpc --version

# --- service user and config ---------------------------------------------
id wd-rac &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin wd-rac

mkdir -p /etc/wd-remote-access
sed -e "s|@WD_FRPS_SERVER@|$WD_FRPS_SERVER|" \
    -e "s|@WD_FRPS_PORT@|$WD_FRPS_PORT|" \
    -e "s|@WD_FRPS_TOKEN@|$WD_FRPS_TOKEN|" \
    -e "s|@WD_RAC_NAME@|$WD_RAC_NAME|" \
    -e "s|@WD_RAC_REMOTE_PORT@|$WD_RAC_REMOTE_PORT|" \
    "$HERE/frpc.toml.template" > /etc/wd-remote-access/frpc.toml
chown root:wd-rac /etc/wd-remote-access/frpc.toml
chmod 640 /etc/wd-remote-access/frpc.toml

# --- systemd unit ---------------------------------------------------------
install -m 644 "$HERE/wd-remote-access.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now wd-remote-access.service
sleep 3
systemctl --no-pager status wd-remote-access.service

echo
echo "Tunnel up if the status above shows 'login to server success'."
echo "Reach this node via:  ssh -p $WD_RAC_REMOTE_PORT <user>@$WD_FRPS_SERVER"
