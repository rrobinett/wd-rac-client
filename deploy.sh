#!/bin/bash
# Push the scripts to a node over ssh and run them there.
#
#   ./deploy.sh <ssh-alias> debloat
#   WD_FRPS_SERVER=... WD_FRPS_TOKEN=... WD_RAC_REMOTE_PORT=... \
#       ./deploy.sh <ssh-alias> install
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NODE="${1:?usage: $0 <ssh-alias> debloat|install}"
ACTION="${2:?usage: $0 <ssh-alias> debloat|install}"

STAGE=/tmp/wd-rac-client

case "$ACTION" in
    debloat)
        scp -q "$HERE/scripts/10-debloat.sh" "$NODE:/tmp/10-debloat.sh"
        ssh -t "$NODE" 'sudo bash /tmp/10-debloat.sh && rm -f /tmp/10-debloat.sh'
        ;;
    install)
        : "${WD_FRPS_SERVER:?set WD_FRPS_SERVER}"
        : "${WD_FRPS_TOKEN:?set WD_FRPS_TOKEN}"
        : "${WD_RAC_REMOTE_PORT:?set WD_RAC_REMOTE_PORT}"
        ssh "$NODE" "mkdir -p $STAGE"
        scp -q "$HERE/scripts/20-install-wd-rac.sh" \
               "$HERE/config/frpc.toml.template" \
               "$HERE/systemd/wd-remote-access.service" \
               "$NODE:$STAGE/"
        ssh -t "$NODE" "sudo -E env \
            WD_FRPS_SERVER='$WD_FRPS_SERVER' \
            WD_FRPS_TOKEN='$WD_FRPS_TOKEN' \
            WD_FRPS_PORT='${WD_FRPS_PORT:-7000}' \
            WD_RAC_REMOTE_PORT='$WD_RAC_REMOTE_PORT' \
            WD_RAC_NAME='${WD_RAC_NAME:-}' \
            FRP_VERSION='${FRP_VERSION:-}' \
            bash $STAGE/20-install-wd-rac.sh && rm -rf $STAGE"
        ;;
    *)
        echo "unknown action: $ACTION (use debloat or install)" >&2
        exit 1
        ;;
esac
