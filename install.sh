#!/bin/bash
# Standalone installer for the wd-remote-access (WD RAC) service.
#
#   git clone https://github.com/rrobinett/wd-rac-client.git
#   cd wd-rac-client
#   sudo ./install.sh
#
# Registers this node with the WsprDaemon RAC registrar on the gateway
# (which validates the RAC number against every registered/live client and
# rejects collisions), then installs frpc and one wd-remote-access@<gateway>
# systemd instance per gateway -- the node holds a tunnel to every gateway
# at once, so losing one gateway never loses the node. Works on any
# systemd-based Linux (x86_64 / arm64 / armv7 / armv6 / riscv64). Needs python3.
#
# Prompts for the site name and RAC number; every value can also be supplied
# via the environment for unattended installs (image building):
#   WD_RAC_SITE     site/station name              (prompt default: hostname)
#   WD_RAC_NUMBER   admin-assigned RAC number; leave empty to let the
#                   gateway auto-assign the lowest free number >= 500
#   WD_RAC_PROXIES  services to expose, as "band=localport ..." using the
#                   registrar's band names vm_ssh vm_web host_ssh host_ui
#                   vm_grape vm_web2 vm_web3 (default "vm_ssh=22"; e.g. "vm_ssh=22 vm_web=8081"
#                   to also publish ka9q-web, "vm_grape=8088" for WsprDaemon's
#                   GRAPE carrier strip charts on 40800+RAC). On a WsprDaemon host still running
#                   the legacy built-in RAC (bin/frpc_wd.ini) the default is
#                   derived from that file, so nothing that was reachable
#                   before stops being reachable.
#   WD_RAC_RETIRE_LEGACY=yes  on such a host, also comment REMOTE_ACCESS_*
#                   out of wsprdaemon.conf once the new tunnels are up, so
#                   WsprDaemon stops re-enabling its legacy daemon
#   WD_REGISTRAR_URL  override the registrar (default below)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WD_REGISTRAR_URL="${WD_REGISTRAR_URL:-http://gw2.wsprdaemon.org:35737}"
KEYFILE=/etc/wd-remote-access/id_ed25519

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi
command -v python3 >/dev/null || { echo "ERROR: python3 is required" >&2; exit 1; }

echo "== WD Remote Access Client installer =="
echo "Gateway registrar: $WD_REGISTRAR_URL"
echo

if [[ -z "${WD_RAC_SITE:-}" ]]; then
    read -r -p "Site name [$(hostname)]: " WD_RAC_SITE </dev/tty
    WD_RAC_SITE="${WD_RAC_SITE:-$(hostname)}"
fi
# --- legacy WsprDaemon RAC on this host? ----------------------------------
# WsprDaemon 3.x's built-in remote access (remote-access-service.sh) writes
# bin/frpc_wd.ini with one [section] per tunnel, remote_port = band + RAC.
# Use it to default the RAC number and the proxy set, so the migration keeps
# every port the station already publishes.
LEGACY_INI=/home/wsprdaemon/wsprdaemon/bin/frpc_wd.ini
if [[ -f "$LEGACY_INI" ]]; then
    legacy="$(awk -F'[ =]+' '
        $1 == "local_port"  { lp = $2 }
        $1 == "remote_port" { rp = $2; band = int(rp / 100) * 100; rac = rp - band
                              b = (band == 35800) ? "vm_ssh" : (band == 45800) ? "vm_web" : \
                                  (band == 50800) ? "host_ssh" : (band == 55800) ? "host_ui" : \
                                  (band == 40800) ? "vm_grape" : ""
                              if (b != "") { printf "%s=%s ", b, lp; RAC = rac } }
        END { printf "\n%s\n", RAC }' "$LEGACY_INI")"
    legacy_proxies="$(sed -n 1p <<<"$legacy" | sed 's/ *$//')"
    legacy_rac="$(sed -n 2p <<<"$legacy")"
    echo "Found WsprDaemon's legacy RAC config ($LEGACY_INI):"
    echo "    RAC ${legacy_rac:-?}, tunnels: ${legacy_proxies:-none recognised}"
    if [[ -z "${WD_RAC_NUMBER+x}" && -n "$legacy_rac" ]]; then
        WD_RAC_NUMBER="$legacy_rac"
        echo "    -> keeping RAC $WD_RAC_NUMBER (set WD_RAC_NUMBER to override)"
    fi
    if [[ -z "${WD_RAC_PROXIES:-}" && -n "$legacy_proxies" ]]; then
        WD_RAC_PROXIES="$legacy_proxies"
        echo "    -> keeping the same tunnels (set WD_RAC_PROXIES to override)"
    fi
fi
WD_RAC_PROXIES="${WD_RAC_PROXIES:-vm_ssh=22}"

if [[ -z "${WD_RAC_NUMBER+x}" ]]; then
    read -r -p "RAC number (from your administrator; empty = auto-assign): " \
        WD_RAC_NUMBER </dev/tty
fi

# --- node identity keypair ------------------------------------------------
# The pubkey is this node's identity: the gateway's auth plugin only accepts
# frpc logins whose 'user' field matches a registered key.
if [[ ! -f "$KEYFILE" ]]; then
    mkdir -p "$(dirname "$KEYFILE")"
    ssh-keygen -q -t ed25519 -N "" -C "wd-rac-$WD_RAC_SITE" -f "$KEYFILE"
    echo "Generated node identity key $KEYFILE"
fi

# --- register with the gateway --------------------------------------------
# The registrar validates the RAC claim (409 if the number or site is taken)
# and returns the frps address, fleet token, per-key user id, and this RAC's
# deterministic ports.
echo "Registering site '$WD_RAC_SITE' (RAC: ${WD_RAC_NUMBER:-auto})..."
reg="$(
SITE="$WD_RAC_SITE" RAC="$WD_RAC_NUMBER" PUBKEY="$(cat "$KEYFILE.pub")" \
URL="$WD_REGISTRAR_URL" python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error
payload = {"site": os.environ["SITE"], "pubkey": os.environ["PUBKEY"]}
if os.environ.get("RAC", "").strip():
    payload["rac"] = int(os.environ["RAC"])
req = urllib.request.Request(
    os.environ["URL"].rstrip("/") + "/register",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        resp = json.load(r)
except urllib.error.HTTPError as e:
    sys.stderr.write("Registration rejected (HTTP %d): %s\n"
                     % (e.code, e.read().decode(errors="replace").strip()))
    sys.exit(1)
except Exception as e:
    sys.stderr.write("Cannot reach registrar: %s\n" % e)
    sys.exit(1)
if not resp.get("ok"):
    sys.stderr.write("Registration failed: %s\n" % json.dumps(resp))
    sys.exit(1)
for k, v in (("WD_FRPS_SERVER", resp["server_addr"]),
             ("WD_FRPS_PORT",   resp["server_port"]),
             ("WD_FRPS_TOKEN",  resp["token"]),
             ("WD_RAC_USER",    resp["user"]),
             ("WD_RAC_NUMBER",  resp["rac"]),
             ("WD_RAC_REMOTE_PORT", resp["ports"]["vm_ssh"])):
    print("%s=%s" % (k, v))
# Every gateway to hold a tunnel to (registrar >= 1.3.0), primary first.
# Older registrars only name one server; treat that as a one-entry list.
gws = resp.get("gateways") or [
    {"name": resp["server_addr"].split(".")[0], "addr": resp["server_addr"],
     "port": resp["server_port"]}]
print("WD_GATEWAYS='%s'" % " ".join(
    "%s=%s:%s" % (g["name"], g["addr"], g["port"]) for g in gws))
# This RAC's port in every band, for the proxy blocks
print("WD_RAC_PORTS='%s'" % " ".join(
    "%s=%s" % (k, v) for k, v in sorted(resp["ports"].items())))
PY
)"
eval "$reg"
export WD_FRPS_SERVER WD_FRPS_PORT WD_FRPS_TOKEN WD_RAC_USER WD_RAC_REMOTE_PORT
export WD_GATEWAYS WD_RAC_PORTS WD_RAC_PROXIES WD_RAC_RETIRE_LEGACY
export WD_RAC_NAME="$WD_RAC_SITE"
echo "Registered: RAC $WD_RAC_NUMBER, ssh remote port $WD_RAC_REMOTE_PORT"
echo "Gateways: $WD_GATEWAYS"
echo "Tunnels:  $WD_RAC_PROXIES"
echo

bash "$HERE/scripts/20-install-wd-rac.sh"
