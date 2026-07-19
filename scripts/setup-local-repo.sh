#!/bin/bash
# setup-local-repo.sh — Create pacman local repo DB from kernel packages in local-repo/
#
# This must be run AFTER building the kernel packages with build-kernel.sh
# or manually placing .pkg.tar.zst files in local-repo/
#
# Usage:
#   ./scripts/setup-local-repo.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCAL_REPO="$PROJECT_DIR/local-repo"

echo "=== Setting up local package repo ==="

# Check for packages
pkg_count=$(find "$LOCAL_REPO" -name 'linux-macpro61-*.pkg.tar.zst' 2>/dev/null | wc -l)
if [[ $pkg_count -eq 0 ]]; then
    echo "ERROR: No linux-macpro61 packages found in $LOCAL_REPO/"
    echo ""
    echo "Run scripts/build-kernel.sh first, or manually download packages from"
    echo "the linux-mac releases page and place them in local-repo/"
    exit 1
fi

echo "Found $pkg_count package(s):"
ls -1 "$LOCAL_REPO"/linux-macpro61-*.pkg.tar.zst

# Remove old DB if it exists
rm -f "$LOCAL_REPO"/macpro.db.tar.gz "$LOCAL_REPO"/macpro.db

# Create the repo database
echo ">>> Creating repo database..."
cd "$LOCAL_REPO"
repo-add macpro.db.tar.gz linux-macpro61-*.pkg.tar.zst

# Verify
if [[ -f "$LOCAL_REPO/macpro.db" ]]; then
    echo ""
    echo "=== Local repo ready ==="
    echo "DB: $LOCAL_REPO/macpro.db"
    echo ""
    echo "The pacman.conf in archiso/ points to this directory."
    echo "Make sure the path is absolute before building the ISO."
    echo ""
    echo "Next step: Run scripts/build-iso.sh to build the ISO"
else
    echo "ERROR: Failed to create repo database"
    exit 1
fi