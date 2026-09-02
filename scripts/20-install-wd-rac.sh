#!/bin/bash
# Install frpc and one wd-remote-access@<gateway> systemd instance per
# gateway. Run ON the target as root, with the frps details in the
# environment:
#
#   WD_GATEWAYS      gateways to tunnel to, primary first, as
#                    "name=host:port name=host:port ..."
#                    (default: one entry built from WD_FRPS_SERVER/PORT)
#   WD_FRPS_SERVER   frps server hostname or IP        (required unless WD_GATEWAYS)
#   WD_FRPS_PORT     frps control port                 (default 7000)
#   WD_FRPS_TOKEN    frps auth token                   (required)
#   WD_RAC_PORTS     this RAC's port per band, "vm_ssh=358xx vm_web=458xx ..."
#                    (default: vm_ssh=WD_RAC_REMOTE_PORT)
#   WD_RAC_REMOTE_PORT  port on the frps servers mapped to this node's sshd
#                                                      (required unless WD_RAC_PORTS)
#   WD_RAC_PROXIES   services to expose, "band=localport ..." (default "vm_ssh=22")
#   WD_RAC_NAME      site name used in the proxy names (default: hostname)
#   WD_RAC_USER      frpc user id (pubkey hash) for the gateway's auth
#                    plugin (default: empty, for plain token-only servers)
#   WD_RAC_RETIRE_LEGACY=yes  if WsprDaemon's built-in RAC daemon is what is
#                    being replaced, also comment REMOTE_ACCESS_* out of
#                    wsprdaemon.conf so WsprDaemon does not re-enable it;
#                    =managed when WsprDaemon itself runs this installer and
#                    owns the RAC= setting (no conf edit, no warning)
#   FRP_VERSION      frp release to install            (default below)
#
# The node presents one identity (user, token, proxy names, remote ports) to
# every gateway; only serverAddr differs between the per-gateway configs.
#
# Replacing a running single-tunnel service (this client's 1.x
# wd-remote-access.service, or WsprDaemon's legacy daemon of the same unit
# name) is done add-before-remove under a dead-man rollback timer: the
# tunnel being replaced is the only way into the node, so no step may leave
# it without a working tunnel even if this script dies halfway.
#
# Expects frpc.toml.template and wd-remote-access@.service either alongside
# this script (deploy.sh staging) or in ../config and ../systemd (git clone).
# Works on any systemd-based Linux; arch is auto-detected.
set -euo pipefail

CLIENT_VERSION="2.0.0"

# 0.64.0 matches the frps version running on gw2
FRP_VERSION="${FRP_VERSION:-0.64.0}"
WD_FRPS_PORT="${WD_FRPS_PORT:-7000}"
WD_RAC_NAME="${WD_RAC_NAME:-$(hostname)}"
WD_RAC_USER="${WD_RAC_USER:-}"
WD_RAC_PROXIES="${WD_RAC_PROXIES:-vm_ssh=22}"
WD_RAC_RETIRE_LEGACY="${WD_RAC_RETIRE_LEGACY:-no}"
if [[ -z "${WD_GATEWAYS:-}" && -n "${WD_FRPS_SERVER:-}" ]]; then
    WD_GATEWAYS="${WD_FRPS_SERVER%%.*}=${WD_FRPS_SERVER}:${WD_FRPS_PORT}"
fi
if [[ -z "${WD_RAC_PORTS:-}" && -n "${WD_RAC_REMOTE_PORT:-}" ]]; then
    WD_RAC_PORTS="vm_ssh=${WD_RAC_REMOTE_PORT}"
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root (sudo -E $0)" >&2
    exit 1
fi
for var in WD_GATEWAYS WD_FRPS_TOKEN WD_RAC_PORTS; do
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
UNIT="$(find_file "$HERE/wd-remote-access@.service" "$HERE/../systemd/wd-remote-access@.service")"

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

CONF_DIR=/etc/wd-remote-access
mkdir -p "$CONF_DIR/gateways"

# --- proxy set -------------------------------------------------------------
# One [[proxies]] block per exposed service. Names carry the rac-dashboard
# suffixes (-vm-ssh, -vm-web, -host-ssh, -host-ui) so the node shows up
# there automatically; remote ports come from the registrar's band table.
band_port() {  # band_port <band> -> remote port from WD_RAC_PORTS
    local e
    for e in $WD_RAC_PORTS; do [[ "${e%%=*}" == "$1" ]] && { echo "${e#*=}"; return 0; }; done
    return 1
}
PROXY_BLOCKS=""
PROXY_COUNT=0
for entry in $WD_RAC_PROXIES; do
    band="${entry%%=*}"; lport="${entry#*=}"
    rport="$(band_port "$band")" || { echo "ERROR: registrar gave no port for band '$band' (WD_RAC_PROXIES=$WD_RAC_PROXIES)" >&2; exit 1; }
    [[ "$lport" =~ ^[0-9]+$ ]] || { echo "ERROR: bad local port in '$entry'" >&2; exit 1; }
    PROXY_BLOCKS+="
[[proxies]]
name = \"${WD_RAC_NAME}-${band//_/-}\"
type = \"tcp\"
localIP = \"127.0.0.1\"
localPort = ${lport}
remotePort = ${rport}
"
    PROXY_COUNT=$((PROXY_COUNT + 1))
done
WD_RAC_REMOTE_PORT="$(band_port vm_ssh || echo "${WD_RAC_REMOTE_PORT:-?}")"

# One config per gateway: identical except for serverAddr/serverPort, so the
# node presents the same identity everywhere and the dashboards agree on
# who it is. Configs are (re)written before anything is started.
GW_NAMES=()
for entry in $WD_GATEWAYS; do
    name="${entry%%=*}"; hostport="${entry#*=}"
    host="${hostport%:*}"; port="${hostport##*:}"
    if [[ -z "$name" || -z "$host" || ! "$port" =~ ^[0-9]+$ ]]; then
        echo "ERROR: bad WD_GATEWAYS entry '$entry' (want name=host:port)" >&2
        exit 1
    fi
    {
        sed -e "s|@WD_FRPS_SERVER@|$host|" \
            -e "s|@WD_FRPS_PORT@|$port|" \
            -e "s|@WD_FRPS_TOKEN@|$WD_FRPS_TOKEN|" \
            -e "s|@WD_RAC_USER@|$WD_RAC_USER|" \
            "$TEMPLATE"
        printf '%s' "$PROXY_BLOCKS"
    } > "$CONF_DIR/gateways/$name.toml"
    chown root:wd-rac "$CONF_DIR/gateways/$name.toml"
    chmod 640 "$CONF_DIR/gateways/$name.toml"
    GW_NAMES+=("$name")
done
PRIMARY="${GW_NAMES[0]}"
echo "$CLIENT_VERSION" > "$CONF_DIR/VERSION"

# --- systemd template unit ------------------------------------------------
install -m 644 "$UNIT" /etc/systemd/system/wd-remote-access@.service
systemctl daemon-reload

# --- helpers --------------------------------------------------------------
OLD_UNIT=wd-remote-access.service
ROLLBACK_UNIT=wd-rac-rollback
# WsprDaemon's own legacy RAC daemon uses the same unit name; it must be
# retired differently (WsprDaemon re-enables it while REMOTE_ACCESS_CHANNEL
# is set in wsprdaemon.conf).
LEGACY_WD=0
if systemctl cat "$OLD_UNIT" 2>/dev/null | grep -q 'wd-remote-access-daemon.sh'; then
    LEGACY_WD=1
fi

# proxies_up <unit>: number of 'start proxy success' lines in this boot's journal
proxies_up() {
    journalctl -u "$1" -b --no-pager 2>/dev/null | tail -n 60 | grep -c 'start proxy success' || true
}
# wait_proxy <unit> <seconds>: 0 = every proxy up, 2 = a port was rejected, 1 = not yet
wait_proxy() {
    local unit="$1" secs="$2" log
    for _ in $(seq 1 $(( secs / 2 ))); do
        sleep 2
        [[ "$(proxies_up "$unit")" -ge "$PROXY_COUNT" ]] && return 0
        log="$(journalctl -u "$unit" -b --no-pager 2>/dev/null | tail -n 60 || true)"
        grep -qE 'port already used|port not allowed|proxy .* already exists' <<<"$log" && return 2
        echo -n "."
    done
    return 1
}

instances() { local n; for n in "${GW_NAMES[@]}"; do echo "wd-remote-access@$n.service"; done; }

retire_legacy_conf() {
    # Only when asked: WsprDaemon would otherwise bring its daemon back.
    local conf=/home/wsprdaemon/wsprdaemon/wsprdaemon.conf
    [[ $LEGACY_WD -eq 1 && "$WD_RAC_RETIRE_LEGACY" == "yes" && -f "$conf" ]] || return 0
    if grep -qE '^\s*(REMOTE_ACCESS_CHANNEL|REMOTE_ACCESS_ID|RAC)=' "$conf"; then
        cp -a "$conf" "$conf.before-wd-rac-client-$(date +%Y%m%d-%H%M%S)"
        sed -i -E 's|^(\s*)((REMOTE_ACCESS_CHANNEL\|REMOTE_ACCESS_ID\|RAC)=.*)$|\1#\2   # retired by wd-rac-client 2.0 (dual-gateway tunnels)|' "$conf"
        echo "Commented REMOTE_ACCESS_* out of $conf (backup kept) so WsprDaemon stops re-enabling its legacy daemon"
    fi
}

report_and_exit() {
    echo
    echo "Tunnels ($PROXY_COUNT proxies each):"
    local n up
    for n in "${GW_NAMES[@]}"; do
        up="$(proxies_up "wd-remote-access@$n.service")"
        if [[ "$up" -ge "$PROXY_COUNT" ]]; then
            printf '    %-6s up\n' "$n"
        else
            printf '    %-6s %s/%s proxies up (frpc keeps retrying in the background)\n' "$n" "$up" "$PROXY_COUNT"
        fi
    done
    echo
    echo "Reach this node via the gateways' WireGuard tiers, e.g.:"
    echo "    ssh -p $WD_RAC_REMOTE_PORT <user>@10.111.220.1     (wd-rac, via gw2)"
    # (WD_RAC_RETIRE_LEGACY=managed: WsprDaemon itself invoked us and owns
    #  the RAC= setting, so neither edit the conf nor warn about it)
    if [[ $LEGACY_WD -eq 1 && "$WD_RAC_RETIRE_LEGACY" != "yes" && "$WD_RAC_RETIRE_LEGACY" != "managed" ]]; then
        echo
        echo "NOTE: WsprDaemon's legacy RAC daemon was stopped, but REMOTE_ACCESS_CHANNEL"
        echo "      is still set in wsprdaemon.conf, so WsprDaemon will re-enable it and"
        echo "      fight the new tunnels for port $WD_RAC_REMOTE_PORT. Either comment the"
        echo "      REMOTE_ACCESS_* lines out yourself, or re-run with WD_RAC_RETIRE_LEGACY=yes."
    fi
    exit 0
}

# --- start the tunnels ----------------------------------------------------
if systemctl is-active --quiet "$OLD_UNIT"; then
    if [[ $LEGACY_WD -eq 1 ]]; then
        echo "Replacing WsprDaemon's legacy RAC daemon with one instance per gateway"
    else
        echo "Upgrading the single-tunnel service to one instance per gateway"
    fi

    # Dead-man rollback: if this script dies before the last line, the old
    # tunnel comes back on its own in 10 minutes. Survives the installer,
    # not a reboot -- but the old unit stays enabled until we retire it, so
    # a reboot mid-upgrade also boots into the old tunnel.
    systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
    # (AccuracySec: systemd timers default to a 1-minute coalescing window)
    systemd-run --quiet --on-active=600 --timer-property=AccuracySec=15s --unit="$ROLLBACK_UNIT" \
        /bin/bash -c "systemctl disable --now $(instances | tr '\n' ' '); systemctl start $OLD_UNIT"
    echo "Rollback timer armed (${ROLLBACK_UNIT}.timer, 10 min)"

    systemctl enable --now $(instances)
    # The primary cannot bind its ports while the old service holds them, so
    # 'port already used' from the primary is expected here; every proxy up
    # on ANY instance proves the identity, token and configs are right.
    echo -n "Waiting for a new instance to come up"
    proven=0
    for _ in $(seq 1 15); do
        sleep 2
        for n in "${GW_NAMES[@]}"; do
            if [[ "$(proxies_up "wd-remote-access@$n.service")" -ge "$PROXY_COUNT" ]]; then
                proven=1; echo; echo "  $n: up"; break 2
            fi
        done
        echo -n "."
    done
    if [[ $proven -eq 0 ]]; then
        echo; echo "ERROR: no new instance came up in 30s; keeping the old service." >&2
        for n in "${GW_NAMES[@]}"; do journalctl -u "wd-remote-access@$n.service" -b -n 8 --no-pager >&2 || true; done
        systemctl disable --now $(instances)
        systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
        exit 1
    fi

    # Retire the old service and hand its ports to the primary instance.
    # (1.x config file frpc.toml is kept for a manual rollback.)
    systemctl disable --now "$OLD_UNIT"
    systemctl restart "wd-remote-access@$PRIMARY.service"
    echo -n "Waiting for $PRIMARY to take over the ports"
    if wait_proxy "wd-remote-access@$PRIMARY.service" 40; then
        echo; echo "  $PRIMARY: up"
    else
        echo; echo "ERROR: $PRIMARY did not come up after retiring the old service -- rolling back." >&2
        journalctl -u "wd-remote-access@$PRIMARY.service" -b -n 10 --no-pager >&2 || true
        systemctl disable --now $(instances)
        systemctl enable --now "$OLD_UNIT"
        systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
        exit 1
    fi
    systemctl stop "$ROLLBACK_UNIT.timer" 2>/dev/null || true
    echo "Upgrade complete; rollback timer disarmed."
    retire_legacy_conf
    echo "SUCCESS: primary tunnel is up."
    report_and_exit
fi

# Fresh install (or re-run on an already-upgraded node)
systemctl enable --now $(instances)

# 'port already used' here means another client grabbed the remote port
# between registration and now — frps is the final arbiter.
echo -n "Waiting for the $PRIMARY tunnel"
wait_proxy "wd-remote-access@$PRIMARY.service" 30; rc=$?
echo
case $rc in
    0)  echo "SUCCESS: primary tunnel is up."
        # give the standby instance(s) a moment so the report is honest
        for n in "${GW_NAMES[@]:1}"; do
            wait_proxy "wd-remote-access@$n.service" 10 >/dev/null || true
        done
        report_and_exit ;;
    2)  echo "ERROR: the gateway rejected one of this RAC's ports:" >&2
        journalctl -u "wd-remote-access@$PRIMARY.service" -b --no-pager | grep -E 'port already used|port not allowed|already exists' | tail -3 >&2
        echo "Another client is using this RAC's port — pick a different RAC number." >&2
        systemctl disable --now $(instances)
        exit 1 ;;
    *)  echo "WARNING: primary tunnel not confirmed up after 30s; recent log:" >&2
        journalctl -u "wd-remote-access@$PRIMARY.service" -b -n 20 --no-pager >&2 || true
        exit 1 ;;
esac
