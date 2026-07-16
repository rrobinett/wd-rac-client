#!/bin/bash
# Install frpc and the wd-remote-access systemd service. Run ON the target
# as root, with the frps server details in the environment:
#
#   WD_FRPS_SERVER   frps server hostname or IP        (required)
#   WD_FRPS_TOKEN    frps auth token                   (required)
#   WD_FRPS_PORT     frps control port                 (default 7000)
#   WD_RAC_REMOTE_PORT  port on the frps server mapped to this node's sshd
#                                                      (required, unique per node)
#   WD_RAC_NAME      site name used in the proxy name  (default: hostname)
#   WD_RAC_USER      frpc user id (pubkey hash) for the gateway's auth
#                    plugin (default: empty, for plain token-only servers)
#   FRP_VERSION      frp release to install            (default below)
#
# Expects frpc.toml.template and wd-remote-access.service either alongside
# this script (deploy.sh staging) or in ../config and ../systemd (git clone).
# Works on any systemd-based Linux; arch is auto-detected.
set -euo pipefail

# 0.64.0 matches the frps version running on gw2
FRP_VERSION="${FRP_VERSION:-0.64.0}"
WD_FRPS_PORT="${WD_FRPS_PORT:-7000}"
WD_RAC_NAME="${WD_RAC_NAME:-$(hostname)}"
WD_RAC_USER="${WD_RAC_USER:-}"

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

find_file() {  # first existing path among the arguments
    local f
    for f in "$@"; do
        [[ -f $f ]] && { echo "$f"; return 0; }
    done
    echo "ERROR: none of these support files found: $*" >&2
    return 1
}
TEMPLATE="$(find_file "$HERE/frpc.toml.template" "$HERE/../config/frpc.toml.template")"
UNIT="$(find_file "$HERE/wd-remote-access.service" "$HERE/../systemd/wd-remote-access.service")"

case "$(uname -m)" in
    aarch64)        FRP_ARCH=arm64 ;;
    x86_64)         FRP_ARCH=amd64 ;;
    armv7l|armv6l)  FRP_ARCH=arm ;;
    riscv64)        FRP_ARCH=riscv64 ;;
    *) echo "ERROR: unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

fetch() {  # fetch <url> <outfile>
    if command -v wget >/dev/null; then
        wget -qO "$2" "$1"
    elif command -v curl >/dev/null; then
        curl -fsSLo "$2" "$1"
    else
        echo "ERROR: need wget or curl to download frpc" >&2
        exit 1
    fi
}

# --- frpc binary ----------------------------------------------------------
if [[ ! -x /usr/local/bin/frpc ]]; then
    dir="frp_${FRP_VERSION}_linux_${FRP_ARCH}"
    url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${dir}.tar.gz"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "Downloading $url"
    fetch "$url" "$tmp/frp.tar.gz"
    tar -xzf "$tmp/frp.tar.gz" -C "$tmp"
    install -m 755 "$tmp/$dir/frpc" /usr/local/bin/frpc
fi
/usr/local/bin/frpc --version

# --- service user and config ---------------------------------------------
id wd-rac &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin wd-rac

mkdir -p /etc/wd-remote-access
sed -e "s|@WD_FRPS_SERVER@|$WD_FRPS_SERVER|" \
    -e "s|@WD_FRPS_PORT@|$WD_FRPS_PORT|" \
    -e "s|@WD_FRPS_TOKEN@|$WD_FRPS_TOKEN|" \
    -e "s|@WD_RAC_USER@|$WD_RAC_USER|" \
    -e "s|@WD_RAC_NAME@|$WD_RAC_NAME|" \
    -e "s|@WD_RAC_REMOTE_PORT@|$WD_RAC_REMOTE_PORT|" \
    "$TEMPLATE" > /etc/wd-remote-access/frpc.toml
chown root:wd-rac /etc/wd-remote-access/frpc.toml
chmod 640 /etc/wd-remote-access/frpc.toml

# --- systemd unit ---------------------------------------------------------
install -m 644 "$UNIT" /etc/systemd/system/wd-remote-access.service
systemctl daemon-reload
systemctl enable --now wd-remote-access.service

# --- verify the tunnel actually came up -----------------------------------
# 'port already used' here means another client grabbed the remote port
# between registration and now — frps is the final arbiter.
echo -n "Waiting for tunnel"
for _ in $(seq 1 15); do
    sleep 2
    log="$(journalctl -u wd-remote-access.service -n 30 --no-pager 2>/dev/null || true)"
    if grep -q 'start proxy success' <<<"$log"; then
        echo; echo "SUCCESS: tunnel is up."
        echo "Reach this node via:  ssh -p $WD_RAC_REMOTE_PORT <user>@$WD_FRPS_SERVER"
        exit 0
    fi
    if grep -qE 'port already used|port not allowed|proxy .* already exists' <<<"$log"; then
        echo; echo "ERROR: the gateway rejected remote port $WD_RAC_REMOTE_PORT:" >&2
        grep -E 'port already used|port not allowed|already exists' <<<"$log" | tail -3 >&2
        echo "Another client is using this RAC's port — pick a different RAC number." >&2
        systemctl disable --now wd-remote-access.service
        exit 1
    fi
    echo -n "."
done
echo
echo "WARNING: tunnel not confirmed up after 30s; recent log:" >&2
journalctl -u wd-remote-access.service -n 20 --no-pager >&2 || true
exit 1
