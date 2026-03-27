#!/usr/bin/env bash
# /etc/remote-dev-boot.sh — WSL2 boot script for non-systemd environments.
# Started via [boot] command in /etc/wsl.conf.
# Managed by remote-dev-setup.

LOG="/var/log/remote-dev-boot.log"
exec >> "$LOG" 2>&1
echo "--- Boot at $(date -Iseconds) ---"

# Start SSH server
if command -v service >/dev/null 2>&1; then
    service ssh start && echo "sshd: started" || echo "sshd: FAILED"
fi

# Start Tailscale daemon
if command -v tailscaled >/dev/null 2>&1; then
    if ! pgrep -x tailscaled >/dev/null 2>&1; then
        mkdir -p /run/tailscale
        tailscaled --state=/var/lib/tailscale/tailscaled.state \
                   --socket=/run/tailscale/tailscaled.sock \
                   --port=41641 &
        echo "tailscaled: started (pid $!)"
    else
        echo "tailscaled: already running"
    fi
fi
