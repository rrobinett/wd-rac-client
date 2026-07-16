#!/bin/bash
# Standalone installer for the wd-remote-access (WD RAC) service.
#
#   git clone https://github.com/rrobinett/wd-rac-client.git
#   cd wd-rac-client
#   sudo ./install.sh
#
# Registers this node with the WsprDaemon RAC registrar on the gateway
# (which validates the RAC number against every registered/live client and
# rejects collisions), then installs frpc and the wd-remote-access systemd
# service. Works on any systemd-based Linux (x86_64 / arm64 / armv7 / armv6 /
# riscv64). Needs python3.
#
# Prompts for the site name and RAC number; every value can also be supplied
# via the environment for unattended installs (image building):
#   WD_RAC_SITE     site/station name              (prompt default: hostname)
#   WD_RAC_NUMBER   admin-assigned RAC number; leave empty to let the
#                   gateway auto-assign the lowest free number >= 500
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
PY
)"
eval "$reg"
export WD_FRPS_SERVER WD_FRPS_PORT WD_FRPS_TOKEN WD_RAC_USER WD_RAC_REMOTE_PORT
export WD_RAC_NAME="$WD_RAC_SITE"
echo "Registered: RAC $WD_RAC_NUMBER, ssh remote port $WD_RAC_REMOTE_PORT"
echo

bash "$HERE/scripts/20-install-wd-rac.sh"
