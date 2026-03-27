#!/usr/bin/env bash
# setup.sh — Automated remote dev environment setup for WSL2.
# Installs Tailscale + OpenSSH Server, hardens SSH, configures boot services.
# https://github.com/bolin8017/remote-dev-setup
#
# Usage:
#   bash setup.sh [OPTIONS]
#
# Options:
#   --generate-key                   Generate ed25519 key pair (recommended)
#   --pubkey "ssh-ed25519 AAAA..."   Add a public key to authorized_keys
#   --github-user <username>         Fetch public keys from GitHub
#   --ssh-port <port>                SSH port (default: 22)
#   --skip-tailscale                 Skip Tailscale installation
#   --yes                            Non-interactive mode, accept all defaults
#   --uninstall                      Remove all changes made by this script

set -euo pipefail

# ============================================================
# Constants
# ============================================================
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
DROPIN_CONF="/etc/ssh/sshd_config.d/99-remote-dev.conf"
DROPIN_AUTH="/etc/ssh/sshd_config.d/99-remote-dev-auth.conf"
BOOT_SCRIPT="/etc/remote-dev-boot.sh"
MARKER_FILE="/etc/remote-dev-setup.mark"
LOG_FILE=$(mktemp /tmp/remote-dev-setup-XXXXXXXX.log)
chmod 600 "$LOG_FILE"

# ============================================================
# Options (defaults)
# ============================================================
OPT_PUBKEY=""
OPT_GITHUB_USER=""
OPT_SSH_PORT="22"
OPT_SKIP_TAILSCALE=false
OPT_GENERATE_KEY=false
OPT_YES=false
OPT_UNINSTALL=false
KEEP_PASSWORD_AUTH=false
TAILSCALE_IP=""
GENERATED_KEY_FILE=""

# ============================================================
# Terminal / color support
# ============================================================
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' DIM='' NC=''
fi

# ============================================================
# Logging helpers
# ============================================================
_log() { printf "%s %s\n" "$(date +%H:%M:%S)" "$*" >> "$LOG_FILE"; }

step()    { local n="$1"; shift; printf "${BLUE}${BOLD}[%s]${NC} %s\n" "$n" "$*"; _log "[STEP $n] $*"; }
info()    { printf "  ${GREEN}✓${NC} %s\n" "$*"; _log "[OK] $*"; }
skip()    { printf "  ${DIM}→ %s (skipped)${NC}\n" "$*"; _log "[SKIP] $*"; }
warn()    { printf "  ${YELLOW}⚠${NC} %s\n" "$*"; _log "[WARN] $*"; }
fail()    { printf "  ${RED}✗${NC} %s\n" "$*" >&2; _log "[FAIL] $*"; }
die()     { fail "$*"; echo ""; fail "Setup aborted. Log saved to: ${LOG_FILE}"; exit 1; }

banner() {
    echo ""
    printf "${BOLD}"
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │   Remote Dev Setup for WSL2    v${VERSION}    │"
    echo "  │   SSH + Tailscale + VSCode Ready         │"
    echo "  └──────────────────────────────────────────┘"
    printf "${NC}"
    echo ""
}

# ============================================================
# Helpers
# ============================================================

# Read a line from user, handling curl|bash pipe mode via /dev/tty.
# Result is stored in the variable named by $1.
# shellcheck disable=SC2229  # Indirect variable name is intentional
read_tty() {
    local _var="$1"
    if [[ -t 0 ]]; then
        IFS= read -r "$_var"
    elif [[ -e /dev/tty ]]; then
        IFS= read -r "$_var" < /dev/tty
    else
        printf -v "$_var" ''
    fi
}

setup_sudo() {
    SUDO=""
    if [[ "$(id -u)" -eq 0 ]]; then
        : # already root
    elif command -v sudo >/dev/null 2>&1; then
        SUDO="sudo"
    elif command -v doas >/dev/null 2>&1; then
        SUDO="doas"
    else
        die "This script requires sudo or doas to install packages."
    fi
}

# Prompt user. In non-interactive or --yes mode, return default.
# Usage: confirm "message" [default: y/n]
confirm() {
    local msg="$1" default="${2:-y}"
    if [[ "$OPT_YES" == true ]]; then
        return 0
    fi
    local prompt
    if [[ "$default" == "y" ]]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
    printf "  ${YELLOW}?${NC} %s %s " "$msg" "$prompt"
    local answer
    read_tty answer
    answer="${answer:-$default}"
    [[ "${answer,,}" == "y" || "${answer,,}" == "yes" ]]
}

# Detect if running inside WSL2.
check_wsl2() {
    if [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
        if ! grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
            die "This script is designed for WSL2. Detected non-WSL environment."
        fi
    fi
}

# Detect Debian/Ubuntu based distro.
check_distro() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS. /etc/os-release not found."
    fi
    # shellcheck source=/dev/null
    source /etc/os-release
    if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
        if [[ "${ID_LIKE:-}" != *"debian"* ]]; then
            die "Unsupported distro: ${ID:-unknown}. Only Ubuntu/Debian are supported."
        fi
    fi
    DISTRO_NAME="${PRETTY_NAME:-${ID} ${VERSION_ID:-}}"
}

# Detect if systemd is the init system (cached).
_SYSTEMD=""
has_systemd() {
    if [[ -z "$_SYSTEMD" ]]; then
        if [[ "$(cat /proc/1/comm 2>/dev/null)" == "systemd" ]]; then
            _SYSTEMD=1
        else
            _SYSTEMD=0
        fi
    fi
    [[ "$_SYSTEMD" -eq 1 ]]
}

# Get the current (non-root) user.
detect_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        TARGET_USER="$SUDO_USER"
    elif [[ "$(id -u)" -ne 0 ]]; then
        TARGET_USER="$(whoami)"
    else
        TARGET_USER="${USER:-root}"
    fi
    TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
    if [[ -z "$TARGET_HOME" ]]; then
        TARGET_HOME="/home/${TARGET_USER}"
    fi
}

# ============================================================
# Parse arguments
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pubkey)
                [[ $# -ge 2 ]] || die "--pubkey requires a value"
                OPT_PUBKEY="$2"; shift 2 ;;
            --github-user)
                [[ $# -ge 2 ]] || die "--github-user requires a value"
                OPT_GITHUB_USER="$2"; shift 2 ;;
            --ssh-port)
                [[ $# -ge 2 ]] || die "--ssh-port requires a value"
                OPT_SSH_PORT="$2"; shift 2 ;;
            --skip-tailscale)
                OPT_SKIP_TAILSCALE=true; shift ;;
            --generate-key)
                OPT_GENERATE_KEY=true; shift ;;
            --yes|-y)
                OPT_YES=true; shift ;;
            --uninstall)
                OPT_UNINSTALL=true; shift ;;
            --help|-h)
                usage; exit 0 ;;
            *)
                die "Unknown option: $1. Use --help for usage." ;;
        esac
    done
}

usage() {
    cat <<'USAGE'
Usage: bash setup.sh [OPTIONS]

Options:
  --pubkey "ssh-ed25519 AAAA..."   Add a public key to authorized_keys
  --github-user <username>         Fetch public keys from GitHub
  --generate-key                   Generate an ed25519 key pair on this machine
  --ssh-port <port>                SSH port (default: 22)
  --skip-tailscale                 Skip Tailscale installation
  --yes, -y                        Non-interactive mode, accept all defaults
  --uninstall                      Remove all changes made by this script
  --help, -h                       Show this help

Examples:
  # Interactive install
  bash setup.sh

  # Generate a key pair (private key shown at the end for you to copy)
  bash setup.sh --generate-key

  # Non-interactive with GitHub key
  bash setup.sh --github-user myuser --yes

  # Provide public key directly
  bash setup.sh --pubkey "ssh-ed25519 AAAA... user@host"
USAGE
}

# ============================================================
# Cleanup trap
# ============================================================
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        fail "Setup did not complete successfully (exit code: ${exit_code})."
        fail "Check the log for details: ${LOG_FILE}"
    fi
}
trap cleanup EXIT

# ============================================================
# Uninstall
# ============================================================
do_uninstall() {
    step "1/3" "Removing SSH hardening config..."
    local removed=false
    for f in "$DROPIN_CONF" "$DROPIN_AUTH"; do
        if [[ -f "$f" ]]; then
            $SUDO rm -f "$f"
            info "Removed ${f}"
            removed=true
        fi
    done
    if [[ "$removed" == true ]]; then
        $SUDO sshd -t 2>/dev/null && $SUDO service ssh restart 2>/dev/null || true
    else
        skip "No drop-in config found"
    fi

    step "2/3" "Removing boot script..."
    if [[ -f "$BOOT_SCRIPT" ]]; then
        $SUDO rm -f "$BOOT_SCRIPT"
        info "Removed ${BOOT_SCRIPT}"
    else
        skip "No boot script found"
    fi
    # Restore wsl.conf if we modified it
    if grep -q "remote-dev-boot" /etc/wsl.conf 2>/dev/null; then
        $SUDO sed -i '/remote-dev-boot/d' /etc/wsl.conf
        # Remove empty [boot] section if that was the only command
        $SUDO sed -i '/^\[boot\]$/{ N; /^\[boot\]\ncommand\s*=\s*$/d }' /etc/wsl.conf 2>/dev/null || true
        info "Cleaned wsl.conf"
    fi

    step "3/3" "Removing marker file..."
    $SUDO rm -f "$MARKER_FILE"
    info "Uninstall complete. Tailscale and OpenSSH were NOT removed."
    echo ""
    warn "To fully remove Tailscale:  sudo apt remove tailscale"
    warn "To fully remove SSH:        sudo apt remove openssh-server"
    exit 0
}

# ============================================================
# Step 1: Install OpenSSH Server
# ============================================================
install_openssh() {
    step "1/7" "OpenSSH Server"
    if dpkg -s openssh-server >/dev/null 2>&1; then
        info "OpenSSH Server is already installed"
    else
        info "Installing OpenSSH Server..."
        $SUDO apt-get update -qq 2>> "$LOG_FILE"
        $SUDO apt-get install -y -qq openssh-server 2>> "$LOG_FILE"
        info "OpenSSH Server installed"
    fi

    # Ensure host keys exist
    if [[ ! -f /etc/ssh/ssh_host_ed25519_key ]]; then
        $SUDO ssh-keygen -A >> "$LOG_FILE" 2>&1
        info "SSH host keys generated"
    fi
}

# ============================================================
# Step 2: Install Tailscale
# ============================================================
install_tailscale() {
    step "2/7" "Tailscale"
    if [[ "$OPT_SKIP_TAILSCALE" == true ]]; then
        skip "Tailscale (--skip-tailscale)"
        return
    fi

    if command -v tailscale >/dev/null 2>&1; then
        info "Tailscale is already installed"
    else
        info "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | $SUDO sh >> "$LOG_FILE" 2>&1
        info "Tailscale installed"
    fi
}

# ============================================================
# Step 3: SSH hardening (drop-in config)
# ============================================================
harden_ssh() {
    step "3/7" "SSH hardening"

    # Ensure drop-in directory and Include directive exist (OpenSSH 8.2+)
    $SUDO mkdir -p /etc/ssh/sshd_config.d
    if ! grep -q "^Include /etc/ssh/sshd_config.d/" /etc/ssh/sshd_config 2>/dev/null; then
        $SUDO sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
    fi

    # Custom port handling
    local conf_content
    conf_content=$(cat "${CONFIG_DIR}/sshd_hardening.conf")
    if [[ "$OPT_SSH_PORT" != "22" ]]; then
        conf_content=$(echo "$conf_content" | sed "1i Port ${OPT_SSH_PORT}")
    fi

    # Check if existing config is identical
    if [[ -f "$DROPIN_CONF" ]]; then
        local existing
        existing=$($SUDO cat "$DROPIN_CONF")
        if [[ "$existing" == "$conf_content" ]]; then
            skip "SSH hardening config unchanged"
            return
        fi
        info "Updating SSH hardening config..."
    fi

    echo "$conf_content" | $SUDO tee "$DROPIN_CONF" > /dev/null
    $SUDO chmod 644 "$DROPIN_CONF"

    # Validate before applying
    if $SUDO sshd -t 2>> "$LOG_FILE"; then
        info "SSH config validated"
    else
        $SUDO rm -f "$DROPIN_CONF"
        die "SSH config validation failed. Drop-in removed. Check ${LOG_FILE}"
    fi
}

# ============================================================
# Helper: Generate SSH key pair
# ============================================================
generate_keypair() {
    local ssh_dir="$1" auth_keys="$2"
    local key_name="id_ed25519_wsl_dev"
    local key_path="${ssh_dir}/${key_name}"

    if [[ -f "$key_path" ]]; then
        # Key already generated by a previous run
        if grep -qF "$(cat "${key_path}.pub" 2>/dev/null)" "$auth_keys" 2>/dev/null; then
            skip "Key pair already exists at ${key_path}"
            GENERATED_KEY_FILE="$key_path"
            return
        fi
    fi

    info "Generating ed25519 key pair..."
    ssh-keygen -t ed25519 -f "$key_path" -N "" -C "wsl-dev@$(hostname)" >> "$LOG_FILE" 2>&1
    chmod 600 "$key_path"
    chmod 644 "${key_path}.pub"
    chown "${TARGET_USER}:${TARGET_USER}" "$key_path" "${key_path}.pub" 2>/dev/null || true

    # Add public key to authorized_keys
    cat "${key_path}.pub" >> "$auth_keys"

    GENERATED_KEY_FILE="$key_path"
    info "Key pair generated: ${key_path}"
}

# ============================================================
# Step 4: Set up SSH authorized_keys
# ============================================================
setup_ssh_keys() {
    step "4/7" "SSH authorized keys"

    local ssh_dir="${TARGET_HOME}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    # Ensure .ssh directory
    if [[ ! -d "$ssh_dir" ]]; then
        mkdir -p "$ssh_dir"
    fi
    chmod 700 "$ssh_dir"
    if [[ ! -f "$auth_keys" ]]; then
        touch "$auth_keys"
    fi
    chmod 600 "$auth_keys"

    local keys_added=0

    # Option A: --generate-key — create a new ed25519 key pair on this machine
    if [[ "$OPT_GENERATE_KEY" == true ]]; then
        generate_keypair "$ssh_dir" "$auth_keys"
        keys_added=$((keys_added + 1))
    fi

    # Option B: --pubkey provided directly
    if [[ -n "$OPT_PUBKEY" ]]; then
        if ! grep -qF "$OPT_PUBKEY" "$auth_keys" 2>/dev/null; then
            echo "$OPT_PUBKEY" >> "$auth_keys"
            keys_added=$((keys_added + 1))
            info "Public key added from --pubkey"
        else
            skip "Public key already in authorized_keys"
        fi
    fi

    # Option C: --github-user — fetch from GitHub
    if [[ -n "$OPT_GITHUB_USER" ]]; then
        info "Fetching keys from github.com/${OPT_GITHUB_USER}..."
        local gh_keys
        gh_keys=$(curl -fsSL "https://github.com/${OPT_GITHUB_USER}.keys" 2>/dev/null) || true
        if [[ -z "$gh_keys" ]]; then
            warn "No keys found on GitHub for user '${OPT_GITHUB_USER}'"
        else
            local count=0
            while IFS= read -r key; do
                if [[ -n "$key" ]] && ! grep -qF "$key" "$auth_keys" 2>/dev/null; then
                    echo "$key" >> "$auth_keys"
                    count=$((count + 1))
                fi
            done <<< "$gh_keys"
            if [[ $count -gt 0 ]]; then
                keys_added=$((keys_added + count))
                info "${count} key(s) added from GitHub (${OPT_GITHUB_USER})"
            else
                skip "GitHub keys already in authorized_keys"
            fi
        fi
    fi

    # Option D: Interactive — ask if none provided and file is empty
    if [[ $keys_added -eq 0 && ! -s "$auth_keys" ]]; then
        echo ""
        warn "No SSH public key configured!"
        warn "Password login will be DISABLED. You need at least one public key."
        echo ""
        echo "  How would you like to set up SSH key authentication?"
        echo ""
        echo "    1) Generate a new key pair on this machine (recommended)"
        echo "    2) Paste an existing public key"
        echo "    3) Skip for now (keep password login as fallback)"
        echo ""
        local choice=""
        printf "  ${YELLOW}?${NC} Choose [1/2/3]: "
        read_tty choice
        choice="${choice:-1}"

        case "$choice" in
            1)
                generate_keypair "$ssh_dir" "$auth_keys"
                keys_added=1
                ;;
            2)
                printf "\n  ${YELLOW}?${NC} Paste your public key (ssh-ed25519 AAAA... or ssh-rsa AAAA...):\n  "
                local pasted_key=""
                read_tty pasted_key
                if [[ "$pasted_key" == ssh-* ]]; then
                    echo "$pasted_key" >> "$auth_keys"
                    info "Public key added"
                    keys_added=1
                elif [[ -n "$pasted_key" ]]; then
                    warn "That doesn't look like a valid SSH public key. Skipping."
                fi
                ;;
            3|*)
                ;;
        esac

        if [[ $keys_added -eq 0 ]]; then
            echo ""
            KEEP_PASSWORD_AUTH=true
            warn "Password login will remain ENABLED until you add a key."
            warn "Add your key later with: ssh-copy-id ${TARGET_USER}@<tailscale-ip>"
            warn "Then disable password auth: sudo rm ${DROPIN_AUTH} && sudo service ssh restart"
        fi
    else
        local key_count
        key_count=$(grep -c '.' "$auth_keys" 2>/dev/null || echo 0)
        info "authorized_keys has ${key_count} key(s)"
    fi

    chown -R "${TARGET_USER}:${TARGET_USER}" "$ssh_dir" 2>/dev/null || true
}

# ============================================================
# Step 5: Configure WSL boot (auto-start services)
# ============================================================
configure_boot() {
    step "5/7" "WSL boot configuration"

    if has_systemd; then
        info "systemd detected — using systemctl"
        $SUDO systemctl enable ssh 2>> "$LOG_FILE" || true
        if [[ "$OPT_SKIP_TAILSCALE" != true ]] && command -v tailscale >/dev/null 2>&1; then
            $SUDO systemctl enable tailscaled 2>> "$LOG_FILE" || true
        fi
        info "Services enabled via systemd"
    else
        info "No systemd — configuring wsl.conf boot command"

        # Install boot script
        $SUDO cp "${CONFIG_DIR}/wsl-boot.sh" "$BOOT_SCRIPT"
        $SUDO chmod 755 "$BOOT_SCRIPT"

        # Update wsl.conf
        if [[ ! -f /etc/wsl.conf ]]; then
            printf "[boot]\ncommand = %s\n" "$BOOT_SCRIPT" | $SUDO tee /etc/wsl.conf > /dev/null
        elif ! grep -q "remote-dev-boot" /etc/wsl.conf 2>/dev/null; then
            if grep -q "^\[boot\]" /etc/wsl.conf 2>/dev/null; then
                # [boot] section exists, add/replace command
                if grep -q "^command" /etc/wsl.conf 2>/dev/null; then
                    # Chain with existing command
                    $SUDO sed -i "s|^command\s*=\s*\(.*\)|command = \1 \&\& ${BOOT_SCRIPT}|" /etc/wsl.conf
                else
                    $SUDO sed -i "/^\[boot\]/a command = ${BOOT_SCRIPT}" /etc/wsl.conf
                fi
            else
                printf "\n[boot]\ncommand = %s\n" "$BOOT_SCRIPT" | $SUDO tee -a /etc/wsl.conf > /dev/null
            fi
        else
            skip "Boot command already configured"
        fi
        info "Boot script installed at ${BOOT_SCRIPT}"
    fi
}

# ============================================================
# Step 6: Start services
# ============================================================
start_services() {
    step "6/7" "Starting services"

    # Set password auth based on whether keys are configured
    if [[ "$KEEP_PASSWORD_AUTH" == true ]]; then
        printf "# Temporary: password auth enabled until SSH keys are configured.\n# Remove this file after adding keys: sudo rm %s\nPasswordAuthentication yes\nAuthenticationMethods publickey,password publickey\n" "$DROPIN_AUTH" \
            | $SUDO tee "$DROPIN_AUTH" > /dev/null
        warn "Password auth ENABLED (temporary fallback)"
        warn "After adding your key, run: sudo rm ${DROPIN_AUTH} && sudo service ssh restart"
    else
        printf "PasswordAuthentication no\nAuthenticationMethods publickey\n" \
            | $SUDO tee "$DROPIN_AUTH" > /dev/null
        info "Password auth disabled (key-only)"
    fi

    # Restart SSH
    if has_systemd; then
        $SUDO systemctl restart ssh 2>> "$LOG_FILE"
    else
        $SUDO service ssh restart 2>> "$LOG_FILE"
    fi
    info "SSH server running on port ${OPT_SSH_PORT}"

    # Start/check Tailscale
    if [[ "$OPT_SKIP_TAILSCALE" == true ]]; then
        skip "Tailscale (--skip-tailscale)"
        return
    fi

    if has_systemd; then
        $SUDO systemctl start tailscaled 2>> "$LOG_FILE" || true
    elif ! pgrep -x tailscaled >/dev/null 2>&1; then
        $SUDO tailscaled --state=/var/lib/tailscale/tailscaled.state \
                         --socket=/run/tailscale/tailscaled.sock \
                         --port=41641 >> "$LOG_FILE" 2>&1 &
        sleep 2
    fi

    # Check Tailscale status and authenticate if needed
    local ts_state
    ts_state=$(tailscale status --json 2>/dev/null \
        | grep -oP '"BackendState"\s*:\s*"\K[^"]+' || echo "unknown")

    if [[ "$ts_state" == "Running" ]]; then
        TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
        info "Tailscale connected (${TAILSCALE_IP:-unknown IP})"
    else
        # Needs login — run tailscale up and wait for auth
        info "Authenticating Tailscale..."
        echo ""
        warn "A login URL will appear below. Open it in your browser to authenticate."
        echo ""

        # Run tailscale up — it prints the auth URL and blocks until authenticated
        $SUDO tailscale up

        # Verify authentication succeeded
        ts_state=$(tailscale status --json 2>/dev/null \
            | grep -oP '"BackendState"\s*:\s*"\K[^"]+' || echo "unknown")

        if [[ "$ts_state" == "Running" ]]; then
            TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
            echo ""
            info "Tailscale authenticated (${TAILSCALE_IP})"
        else
            warn "Tailscale authentication incomplete."
            warn "Run 'sudo tailscale up' later to finish setup."
            TAILSCALE_IP="<run 'tailscale ip -4' after login>"
        fi
    fi
}

# ============================================================
# Step 7: Write marker & show summary
# ============================================================
show_summary() {
    step "7/7" "Setup complete"

    # Write marker
    $SUDO tee "$MARKER_FILE" > /dev/null <<EOF
version=${VERSION}
installed_at=$(date -Iseconds)
user=${TARGET_USER}
ssh_port=${OPT_SSH_PORT}
EOF

    local ts_ip="${TAILSCALE_IP:-<tailscale-ip>}"
    local port_flag=""
    if [[ "$OPT_SSH_PORT" != "22" ]]; then
        port_flag=" -p ${OPT_SSH_PORT}"
    fi

    echo ""
    printf "${GREEN}${BOLD}"
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │           Setup Complete!                 │"
    echo "  └──────────────────────────────────────────┘"
    printf "${NC}"
    echo ""
    echo "  ${BOLD}Connection Info${NC}"
    echo "  ─────────────────────────────────────────"
    echo "  User:          ${TARGET_USER}"
    echo "  Tailscale IP:  ${ts_ip}"
    echo "  SSH Port:      ${OPT_SSH_PORT}"
    echo "  SSH Command:   ssh${port_flag} ${TARGET_USER}@${ts_ip}"
    echo ""

    echo "  ${BOLD}Client SSH Config${NC}  (add to ~/.ssh/config)"
    echo "  ─────────────────────────────────────────"
    echo "  Host wsl-dev"
    echo "      HostName ${ts_ip}"
    echo "      User ${TARGET_USER}"
    if [[ "$OPT_SSH_PORT" != "22" ]]; then
        echo "      Port ${OPT_SSH_PORT}"
    fi
    if [[ -n "$GENERATED_KEY_FILE" ]]; then
        echo "      IdentityFile ~/.ssh/id_ed25519_wsl_dev"
    else
        echo "      IdentityFile ~/.ssh/id_ed25519"
    fi
    echo "      ForwardAgent yes"
    echo "      ServerAliveInterval 60"
    echo "      ServerAliveCountMax 3"
    echo ""

    # Show generated private key for user to copy
    if [[ -n "$GENERATED_KEY_FILE" && -f "$GENERATED_KEY_FILE" ]]; then
        echo "  ${BOLD}${YELLOW}⚠ Private Key — Copy to Client${NC}"
        echo "  ─────────────────────────────────────────"
        echo "  Save the following to ${BOLD}~/.ssh/id_ed25519_wsl_dev${NC} on your client machine,"
        echo "  then run: ${DIM}chmod 600 ~/.ssh/id_ed25519_wsl_dev${NC}"
        echo ""
        printf "${DIM}"
        cat "$GENERATED_KEY_FILE"
        printf "${NC}"
        echo ""
        warn "This key will NOT be shown again."
        warn "It is stored at: ${GENERATED_KEY_FILE}"
        echo ""
    fi

    echo "  ${BOLD}Next Steps${NC}"
    echo "  ─────────────────────────────────────────"

    local step_num=1
    if [[ -n "$GENERATED_KEY_FILE" ]]; then
        echo "  ${step_num}. Copy the private key above to your client machine:"
        echo "     ${DIM}Save to ~/.ssh/id_ed25519_wsl_dev and run: chmod 600 ~/.ssh/id_ed25519_wsl_dev${NC}"
        step_num=$((step_num + 1))
    elif [[ "$KEEP_PASSWORD_AUTH" == true ]]; then
        echo "  ${step_num}. Add your SSH public key, then disable password auth:"
        echo "     ${DIM}ssh-copy-id${port_flag} ${TARGET_USER}@${ts_ip}${NC}"
        echo "     ${DIM}Then on WSL: sudo rm ${DROPIN_AUTH} && sudo service ssh restart${NC}"
        step_num=$((step_num + 1))
    fi

    if [[ "$ts_ip" == *"<"* ]]; then
        echo "  ${step_num}. Authenticate Tailscale:"
        echo "     ${DIM}sudo tailscale up${NC}"
        step_num=$((step_num + 1))
    fi

    echo "  ${step_num}. Install Tailscale on your client device:"
    echo "     ${DIM}https://tailscale.com/download${NC}"
    step_num=$((step_num + 1))

    echo "  ${step_num}. Add the SSH config above to your client ~/.ssh/config"
    step_num=$((step_num + 1))

    echo "  ${step_num}. Connect with VSCode Remote SSH:"
    echo "     ${DIM}Ctrl+Shift+P → Remote-SSH: Connect to Host → wsl-dev${NC}"
    step_num=$((step_num + 1))

    if ! has_systemd; then
        echo "  ${step_num}. Restart WSL to activate boot services:"
        echo "     ${DIM}(In Windows PowerShell) wsl --shutdown${NC}"
    fi

    echo ""
    printf "  ${DIM}Log: ${LOG_FILE}${NC}\n"
    echo ""
}

# ============================================================
# Main
# ============================================================
main() {
    parse_args "$@"

    banner

    # Pre-flight checks
    check_wsl2
    check_distro
    setup_sudo
    detect_user

    info "Detected: ${DISTRO_NAME}"
    info "User: ${TARGET_USER}"
    echo ""

    if [[ "$OPT_UNINSTALL" == true ]]; then
        do_uninstall
    fi

    # Sudo keepalive — cache credentials upfront
    if [[ -n "$SUDO" ]]; then
        echo "  This setup requires sudo for installing packages and configuring services."
        $SUDO -v 2>/dev/null || die "Failed to obtain sudo privileges."
        # Keep sudo alive in background
        while true; do $SUDO -n true; sleep 50; done 2>/dev/null &
        SUDO_KEEPALIVE_PID=$!
        trap 'kill $SUDO_KEEPALIVE_PID 2>/dev/null; cleanup' EXIT
    fi

    install_openssh
    install_tailscale
    harden_ssh
    setup_ssh_keys
    configure_boot
    start_services
    show_summary
}

# Wrap in main() to prevent partial-download execution via curl|bash.
main "$@"
