# RAC node management
- Remote nodes are reached via `ssh <alias>` (see ~/.ssh/config).
- ti4jwc: Pi Zero 2 W, 512MB RAM, ~3GB disk (keep usage < 80%), Debian 13 arm64.
- It runs ONLY the wd-remote-access service (frpc tunnel). No WD, no ka9q.
- Never restart wd-remote-access and networking in the same command —
  that tunnel is the only way in.
- Edit remote files via: ssh alias 'cat > file <<EOF ...' or scp, then verify.
