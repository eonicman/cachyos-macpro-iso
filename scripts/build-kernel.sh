#!/bin/bash
# build-kernel.sh — Build linux-macpro61 from the linux-mac PKGBUILD
#
# Prerequisites:
#   - Arch Linux or CachyOS build environment
#   - Base-devel, clang, llvm, lld installed
#   - linux-mac repo cloned at LINUX_MAC_DIR (default: ../linux-mac)
#
# Usage:
#   ./scripts/build-kernel.sh [/path/to/linux-mac]
#
# Output:
#   Packages placed in local-repo/:
#     linux-macpro61-7.0rc1-1-x86_64.pkg.tar.zst
#     linux-macpro61-headers-7.0rc1-1-x86_64.pkg.tar.zst

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LINUX_MAC_DIR="${1:-$PROJECT_DIR/../linux-mac}"
LOCAL_REPO="$PROJECT_DIR/local-repo"

# Validate linux-mac directory
if [[ ! -f "$LINUX_MAC_DIR/packaging/arch/PKGBUILD" ]]; then
    echo "ERROR: PKGBUILD not found at $LINUX_MAC_DIR/packaging/arch/PKGBUILD"
    echo "Clone the linux-mac repo first:"
    echo "  git clone https://github.com/eonicman/linux-mac.git"
    exit 1
fi

echo "=== Building linux-macpro61 kernel ==="
echo "Source: $LINUX_MAC_DIR"
echo "Output: $LOCAL_REPO"
echo ""

# Create temp build directory
BUILD_DIR="$(mktemp -d)"
echo "Build directory: $BUILD_DIR"

# Copy PKGBUILD and supporting files
cp "$LINUX_MAC_DIR/packaging/arch/PKGBUILD" "$BUILD_DIR/"
cp "$LINUX_MAC_DIR/packaging/arch/config" "$BUILD_DIR/"
cp "$LINUX_MAC_DIR/packaging/arch/99-macpro.conf" "$BUILD_DIR/"
cp "$LINUX_MAC_DIR/packaging/arch/linux-macpro61.install" "$BUILD_DIR/"

# Copy patches
for patch in "$LINUX_MAC_DIR/packaging/arch/"*.patch; do
    [[ -f "$patch" ]] && cp "$patch" "$BUILD_DIR/"
done

# Download kernel source
echo ">>> Downloading Linux 7.0-rc1 source..."
cd "$BUILD_DIR"
source /etc/makepkg.conf 2>/dev/null || true
makepkg --nodeps --nobuild --skipinteg 2>/dev/null || {
    # If makepkg --nobuild fails, try manual download
    echo ">>> Manual source download..."
    if [[ ! -f linux-7.0-rc1.tar.gz ]]; then
        curl -L -o linux-7.0-rc1.tar.gz \
            "https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-7.0-rc1.tar.gz"
    fi
    tar xf linux-7.0-rc1.tar.gz 2>/dev/null || true
}

# Build the packages
echo ">>> Building kernel packages (this takes 30-90 minutes on a Mac Pro)..."
cd "$BUILD_DIR"
makepkg -s --noconfirm --skipinteg 2>/dev/null || {
    echo ""
    echo "NOTE: If the build fails, you can build on the Mac Pro itself:"
    echo "  cd $BUILD_DIR"
    echo "  makepkg -s --noconfirm"
    echo ""
    echo "Or use a faster machine and copy the packages."
    exit 1
}

# Copy packages to local-repo
echo ">>> Copying packages to local-repo..."
mkdir -p "$LOCAL_REPO"
cp "$BUILD_DIR"/linux-macpro61-*.pkg.tar.zst "$LOCAL_REPO/"

echo ""
echo "=== Kernel build complete ==="
echo "Packages in $LOCAL_REPO:"
ls -lh "$LOCAL_REPO"/linux-macpro61-*.pkg.tar.zst 2>/dev/null || echo "(no packages found — build may have failed)"

echo ""
echo "Next step: Run scripts/setup-local-repo.sh to create the repo database"