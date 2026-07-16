#!/bin/bash
# Standalone interactive installer for the wd-remote-access (WD RAC) service.
#
#   git clone https://github.com/rrobinett/wd-rac-client.git
#   cd wd-rac-client
#   sudo ./install.sh
#
# Prompts for any value not already set in the environment, then installs
# frpc and the wd-remote-access systemd service. Works on any systemd-based
# Linux (x86_64 / arm64 / armv7 / armv6 / riscv64); nothing Raspberry Pi
# specific. The Pi-image debloat step lives separately in scripts/10-debloat.sh.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

ask() {  # ask VAR "prompt" [default] [secret]
    local var="$1" prompt="$2" default="${3:-}" secret="${4:-}" val
    if [[ -n "${!var:-}" ]]; then
        return 0
    fi
    while :; do
        if [[ -n $secret ]]; then
            read -r -s -p "$prompt: " val </dev/tty; echo
        elif [[ -n $default ]]; then
            read -r -p "$prompt [$default]: " val </dev/tty
            val="${val:-$default}"
        else
            read -r -p "$prompt: " val </dev/tty
        fi
        [[ -n $val ]] && break
        echo "  A value is required."
    done
    printf -v "$var" '%s' "$val"
    export "${var?}"
}

echo "== WD Remote Access Client installer =="
echo "Values already set in the environment are used without prompting."
echo

ask WD_FRPS_SERVER     "frps server hostname or IP"
ask WD_FRPS_PORT       "frps control port" "7000"
ask WD_FRPS_TOKEN      "frps auth token" "" secret
ask WD_RAC_REMOTE_PORT "Remote port on the frps server for this node's sshd (unique per node)"
ask WD_RAC_NAME        "Proxy name for this node" "$(hostname)"

exec bash "$HERE/scripts/20-install-wd-rac.sh"
