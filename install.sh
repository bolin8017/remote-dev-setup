#!/usr/bin/env bash
# install.sh — Lightweight entry point for curl|bash one-liner install.
# Downloads the remote-dev-setup repo and runs setup.sh.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bolin8017/remote-dev-setup/main/install.sh | bash
#   curl -fsSL ... | bash -s -- --github-user myuser --yes
#
# Or (safer, preserves stdin for interactive prompts):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/bolin8017/remote-dev-setup/main/install.sh)"

set -euo pipefail

REPO_URL="https://github.com/bolin8017/remote-dev-setup.git"
TARBALL_URL="https://github.com/bolin8017/remote-dev-setup/archive/refs/heads/main.tar.gz"
INSTALL_DIR="${HOME}/.remote-dev-setup"

# ── Colors ───────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' NC=''
fi

info() { printf "  ${GREEN}✓${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}⚠${NC} %s\n" "$*"; }
fail() { printf "  ${RED}✗${NC} %s\n" "$*" >&2; exit 1; }

# ── Pre-flight checks ───────────────────────────────────────
main() {
    echo ""
    printf "${BOLD}  Remote Dev Setup — Installer${NC}\n"
    echo ""

    # Must be running on WSL2
    if [[ -z "${WSL_DISTRO_NAME:-}" ]]; then
        if ! grep -qi "microsoft\|wsl" /proc/version 2>/dev/null; then
            fail "This installer is designed for WSL2 (Ubuntu/Debian)."
        fi
    fi

    # Must be Debian/Ubuntu
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" ]]; then
            if [[ "${ID_LIKE:-}" != *"debian"* ]]; then
                fail "Unsupported distro: ${ID:-unknown}. Only Ubuntu/Debian are supported."
            fi
        fi
    else
        fail "Cannot detect OS. /etc/os-release not found."
    fi

    # ── Download repo ────────────────────────────────────────
    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        info "Updating existing installation..."
        git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null || {
            warn "Git pull failed. Re-downloading..."
            rm -rf "$INSTALL_DIR"
        }
    fi

    if [[ ! -d "$INSTALL_DIR" ]]; then
        if command -v git >/dev/null 2>&1; then
            info "Downloading via git..."
            git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>/dev/null
        elif command -v curl >/dev/null 2>&1; then
            info "Downloading via tarball..."
            mkdir -p "$INSTALL_DIR"
            curl -fsSL "$TARBALL_URL" | tar xz --strip-components=1 -C "$INSTALL_DIR"
        elif command -v wget >/dev/null 2>&1; then
            info "Downloading via wget..."
            mkdir -p "$INSTALL_DIR"
            wget -qO- "$TARBALL_URL" | tar xz --strip-components=1 -C "$INSTALL_DIR"
        else
            fail "Neither git, curl, nor wget found. Install one and retry."
        fi
    fi

    info "Downloaded to ${INSTALL_DIR}"
    echo ""

    # ── Run setup ────────────────────────────────────────────
    chmod +x "${INSTALL_DIR}/setup.sh"
    exec bash "${INSTALL_DIR}/setup.sh" "$@"
}

# Wrap in main() to prevent partial-download execution via curl|bash.
main "$@"
