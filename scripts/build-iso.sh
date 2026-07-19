#!/bin/bash
# build-iso.sh — Build the CachyOS Mac Pro 6,1 ISO
#
# Prerequisites:
#   - Arch Linux or CachyOS build environment
#   - Kernel packages built and local-repo/ set up
#   - archiso, mkinitcpio-archiso, squashfs-tools, grub installed
#
# Usage:
#   ./scripts/build-iso.sh [-c] [-v]
#     -c    Clean build directory first
#     -v    Verbose output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CLEAN=false
VERBOSE=false

while getopts "cvh" opt; do
    case $opt in
        c) CLEAN=true ;;
        v) VERBOSE=true ;;
        h) echo "Usage: $0 [-c] [-v]"; exit 0 ;;
        *) echo "Unknown option: -$opt"; exit 1 ;;
    esac
done

# Verify local-repo exists and has packages
if [[ ! -f "$PROJECT_DIR/local-repo/macpro.db" ]]; then
    echo "ERROR: Local repo not set up. Run scripts/setup-local-repo.sh first."
    exit 1
fi

pkg_count=$(find "$PROJECT_DIR/local-repo" -name 'linux-macpro61-*.pkg.tar.zst' 2>/dev/null | wc -l)
if [[ $pkg_count -eq 0 ]]; then
    echo "ERROR: No kernel packages in local-repo/. Run scripts/build-kernel.sh first."
    exit 1
fi

# Fix pacman.conf to use absolute path
PACMAN_CONF="$PROJECT_DIR/archiso/pacman.conf"
REPO_PATH="$(realpath "$PROJECT_DIR/local-repo")"

echo "=== Building CachyOS Mac Pro 6,1 ISO ==="
echo "Local repo: $REPO_PATH"
echo ""

# Update pacman.conf with absolute path to local-repo
if grep -q 'file:///home/michael' "$PACMAN_CONF"; then
    echo ">>> Fixing local repo path in pacman.conf..."
    sed -i "s|Server = file:///home/michael/linux-mac/cachyos-iso/local-repo|Server = file://$REPO_PATH|" "$PACMAN_CONF"
    echo "    Updated to: Server = file://$REPO_PATH"
elif grep -q 'Server = file://.*local-repo' "$PACMAN_CONF"; then
    echo ">>> Updating local repo path in pacman.conf..."
    sed -i "s|Server = file://.*local-repo|Server = file://$REPO_PATH|" "$PACMAN_CONF"
    echo "    Updated to: Server = file://$REPO_PATH"
fi

# Import CachyOS key if not present
if ! pacman-key --list-keys 882DCFE48E2051D48E2562ABF3B607488DB35A47 &>/dev/null; then
    echo ">>> Importing CachyOS signing key..."
    sudo pacman-key --recv-keys 882DCFE48E2051D48E2562ABF3B607488DB35A47
    sudo pacman-key --lsign-key 882DCFE48E2051D48E2562ABF3B607488DB35A47
fi

# Build
cd "$PROJECT_DIR"

BUILD_CMD="sudo ./buildiso.sh -p desktop -w"
if $VERBOSE; then
    BUILD_CMD="$BUILD_CMD -v"
fi
if $CLEAN; then
    BUILD_CMD="$BUILD_CMD -c"
fi

echo ">>> Running: $BUILD_CMD"
echo ""

eval "$BUILD_CMD"

echo ""
echo "=== ISO build complete ==="
echo "Check the out/ directory for the ISO file."
echo ""
echo "To write to USB:"
echo "  sudo dd if=out/desktop/cachyos-macpro-*.iso of=/dev/sdX bs=4M status=progress && sync"
echo ""
echo "⚠️  Remember: Always power off the Mac Pro (never reboot) for GPU init!"