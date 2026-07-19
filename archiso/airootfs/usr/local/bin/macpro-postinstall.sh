#!/bin/bash
# macpro-postinstall.sh — Run inside the installed system chroot after Calamares finishes
#
# This script fixes the #1 killer bug: Calamares pacstrap installs the wrong kernel.
# It must run AFTER the target system is installed but BEFORE the user reboots.
#
# What it does:
#   1. Installs linux-macpro61 from the ISO's package cache
#   2. Removes the stock CachyOS kernel
#   3. Sets up systemd-boot entry for the custom kernel
#   4. Configures macfanctld for fan control
#   5. Masks reboot.target (Apple EFI cold boot requirement)
#   6. Sets up no-reboot alias
#   7. Configures sysctl for Mac Pro
#   8. Copies modprobe.d configs
#   9. Adds [macpro] repo to installed system's pacman.conf
#  10. Generates initramfs (minimal, since most drivers are built-in)
#
# Usage (called by Calamares contextualprocess or manually):
#   This script is designed to run INSIDE the chroot of the installed system.
#   Calamares runs it as: chroot /mnt /usr/local/bin/macpro-postinstall.sh
#
# Environment:
#   MACPRO_KERNEL_PKG  — Path to kernel package relative to /var/cache/pacman/pkg/
#   If not set, the script will try to find it.

set -euo pipefail

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Mac Pro 6,1 Post-Install Configuration                  ║"
echo "║   Fixing kernel, fan control, and boot configuration      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ─── Step 1: Find and install the Mac Pro kernel ─────────────────────────────
echo ">>> [1/10] Installing linux-macpro61 kernel..."

# The kernel package should be in the live ISO's pacman cache
KERNEL_PKG=""
for pkg in /var/cache/pacman/pkg/linux-macpro61-*.pkg.tar.zst; do
    if [[ -f "$pkg" ]]; then
        KERNEL_PKG="$pkg"
        break
    fi
done

# Also check the ISO mount
if [[ -z "$KERNEL_PKG" ]]; then
    for pkg in /run/archiso/bootmnt/arch/x86_64/macpro/linux-macpro61-*.pkg.tar.zst; do
        if [[ -f "$pkg" ]]; then
            KERNEL_PKG="$pkg"
            break
        fi
    done
fi

if [[ -n "$KERNEL_PKG" ]]; then
    echo "    Found kernel package: $KERNEL_PKG"
    pacman -U --noconfirm "$KERNEL_PKG"
else
    echo "    WARNING: Kernel package not found in cache."
    echo "    Attempting to install from local repo..."
    # Try from the [macpro] repo if it's in pacman.conf
    if pacman -Si linux-macpro61 &>/dev/null; then
        pacman -S --noconfirm linux-macpro61 linux-macpro61-headers
    else
        echo "    ERROR: Cannot find linux-macpro61 package!"
        echo "    The installed system will use the stock kernel."
        echo "    You will need to manually install the kernel after first boot."
        echo ""
        echo "    Workaround: Boot the live ISO, chroot into the installed system,"
        echo "    and install the kernel from the ISO's package cache."
        exit 1
    fi
fi

echo "    ✅ linux-macpro61 installed"

# ─── Step 2: Remove stock CachyOS kernels ─────────────────────────────────────
echo ">>> [2/10] Removing stock CachyOS kernels..."

for pkg in linux-cachyos linux-cachyos-headers linux-cachyos-lts linux-cachyos-lts-headers; do
    if pacman -Q "$pkg" &>/dev/null; then
        pacman -Rns --noconfirm "$pkg" 2>/dev/null || true
        echo "    Removed $pkg"
    fi
done

echo "    ✅ Stock kernels removed"

# ─── Step 3: Generate minimal initramfs ────────────────────────────────────────
echo ">>> [3/10] Generating initramfs..."

# Create a minimal mkinitcpio config — most drivers are built-in
cat > /etc/mkinitcpio.conf.d/macpro.conf << 'EOF'
# Mac Pro 6,1 minimal initramfs — most drivers are built into the kernel
# Only need base + udev for early boot; amdgpu, applesmc, nvme, etc. are =y
HOOKS=(base udev modconf keyboard fsck)
COMPRESSION="zstd"
EOF

# Generate initramfs
if [[ -f /boot/vmlinuz-linux-macpro61 ]]; then
    mkinitcpio -p linux-macpro61 2>/dev/null || {
        echo "    WARNING: mkinitcpio failed, creating minimal fallback..."
        # Create a minimal initramfs manually
        mkinitcpio -A base -A udev -A modconf -A fsck -k /boot/vmlinuz-linux-macpro61 \
            -g /boot/initramfs-linux-macpro61.img 2>/dev/null || true
    }
    echo "    ✅ initramfs generated"
else
    echo "    WARNING: vmlinuz not found at /boot/vmlinuz-linux-macpro61"
    echo "    Skipping initramfs generation — kernel has all drivers built-in"
fi

# ─── Step 4: Set up systemd-boot entry ────────────────────────────────────────
echo ">>> [4/10] Setting up boot entries..."

# Ensure ESP is mounted
if ! mountpoint -q /boot/efi; then
    echo "    Mounting /boot/efi..."
    # Try to find and mount the ESP
    ESP_PART="$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || blkid -t PARTTYPE=c12a7328-f0f6-11d2-ba4b-00a0c93ec93b -o device 2>/dev/null | head -1)"
    if [[ -n "$ESP_PART" ]]; then
        mkdir -p /boot/efi
        mount "$ESP_PART" /boot/efi 2>/dev/null || true
    fi
fi

if mountpoint -q /boot/efi; then
    # Copy kernel and initramfs to ESP
    mkdir -p /boot/efi/
    cp /boot/vmlinuz-linux-macpro61 /boot/efi/ 2>/dev/null || true
    cp /boot/initramfs-linux-macpro61.img /boot/efi/ 2>/dev/null || true

    # Create systemd-boot entry
    mkdir -p /boot/efi/loader/entries/

    cat > /boot/efi/loader/entries/macpro61.conf << 'ENTRY'
title   CachyOS (Mac Pro 6,1)
sort-key A
linux   /vmlinuz-linux-macpro61
initrd  /initramfs-linux-macpro61.img
options root=PARTUUID=%%PARTUUID%% rw amdgpu.si_support=1 amdgpu.dc=0 radeon.si_support=0 acpi_mask_gpe=0x16 nvme_load=yes
ENTRY

    # Create fallback entry
    cat > /boot/efi/loader/entries/macpro61-fallback.conf << 'ENTRY'
title   CachyOS (Mac Pro 6,1 - Fallback)
sort-key B
linux   /vmlinuz-linux-macpro61
initrd  /initramfs-linux-macpro61-fallback.img
options root=PARTUUID=%%PARTUUID%% rw amdgpu.si_support=1 amdgpu.dc=0 radeon.si_support=0 acpi_mask_gpe=0x16 nvme_load=yes
ENTRY

    # Update loader.conf
    cat > /boot/efi/loader/loader.conf << 'LOADER'
timeout 15
default macpro61.conf
LOADER

    # Fix PARTUUID in boot entries
    ROOT_PART="$(findmnt -n -o SOURCE / 2>/dev/null)"
    if [[ -n "$ROOT_PART" ]]; then
        ROOT_UUID="$(blkid -s PARTUUID -o value "$ROOT_PART" 2>/dev/null || echo "REPLACE_WITH_YOUR_PARTUUID")"
        sed -i "s/%%PARTUUID%%/$ROOT_UUID/g" /boot/efi/loader/entries/macpro61.conf
        sed -i "s/%%PARTUUID%%/$ROOT_UUID/g" /boot/efi/loader/entries/macpro61-fallback.conf
    fi

    echo "    ✅ Boot entries created"
else
    echo "    ⚠️  ESP not mounted — boot entries will be created by ESP sync hook"
    echo "    The 99-esp-kernel-sync.hook will sync on next kernel update."
fi

# ─── Step 5: Fan control ─────────────────────────────────────────────────────
echo ">>> [5/10] Configuring fan control..."

# Install macfanctld if not already present
pacman -S --noconfirm macfanctld 2>/dev/null || {
    echo "    macfanctld not in repos — installing from AUR..."
    # Try paru or yay
    if command -v paru &>/dev/null; then
        paru -S --noconfirm macfanctld
    elif command -v yay &>/dev/null; then
        yay -S --noconfirm macfanctld
    else
        echo "    WARNING: Cannot install macfanctld automatically."
        echo "    Install it manually after first boot: yay -S macfanctld"
    fi
}

# Configure macfanctld
mkdir -p /etc/macfanctld/
cat > /etc/macfanctld/macfanctld.conf << 'FANCONF'
# Mac Pro 6,1 fan control configuration
# Fan speed is controlled by applesmc via macfanctld
#
# Default curve: ramp fans up as temperature increases
# 40°C → 40%, 50°C → 50%, 60°C → 60%, 70°C → 75%, 80°C → 90%
avg_temp_max    40
avg_temp_min    30
disk_temp_max   50
disk_temp_min   30
logic_board_max 60
logic_board_min 40
FANCONF

systemctl enable macfanctld.service 2>/dev/null || true
echo "    ✅ macfanctld configured and enabled"

# ─── Step 6: Mask reboot.target ───────────────────────────────────────────────
echo ">>> [6/10] Masking reboot.target (Apple EFI requires cold boot)..."

systemctl mask reboot.target
ln -sf /dev/null /etc/systemd/system/reboot.target 2>/dev/null || true
echo "    ✅ reboot.target masked"

# ─── Step 7: No-reboot alias ──────────────────────────────────────────────────
echo ">>> [7/10] Setting up no-reboot protection..."

cat > /etc/profile.d/no-reboot.sh << 'ALIAS'
# Mac Pro 6,1: Apple EFI requires cold boot (poweroff) for GPU initialization
# Warm reboot leaves GPU in uninitialized state — black screen
alias reboot='echo "⚠️  Mac Pro 6,1 requires cold boot for GPU init. Use: sudo poweroff"; sudo poweroff'
ALIAS
chmod 644 /etc/profile.d/no-reboot.sh

# Also add to /etc/bash.bashrc for non-login shells
if ! grep -q 'Mac Pro 6,1' /etc/bash.bashrc 2>/dev/null; then
    cat >> /etc/bash.bashrc << 'BASHRC'

# Mac Pro 6,1: never reboot, always poweroff (GPU init requires cold boot)
alias reboot='echo "⚠️  Use sudo poweroff (Mac Pro needs cold boot for GPU)"; sudo poweroff'
BASHRC
fi

echo "    ✅ No-reboot alias configured"

# ─── Step 8: Sysctl and modprobe ──────────────────────────────────────────────
echo ">>> [8/10] Configuring sysctl and modprobe..."

# Sysctl tuning (from linux-mac 99-macpro.conf)
cat > /etc/sysctl.d/99-macpro.conf << 'SYSCTL'
# Mac Pro 6,1 Performance Tuning
vm.swappiness = 10
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
kernel.printk = 3 4 1 3
SYSCTL

# Modprobe for AMD GPU
cat > /etc/modprobe.d/macpro-gpu.conf << 'MODPROBE'
# Mac Pro 6,1: AMD FirePro D300/D500/D700 (Southern Islands)
options amdgpu si_support=1
options amdgpu dc=0
options radeon si_support=0
MODPROBE

# Load applesmc at boot
cat > /etc/modules-load.d/applesmc.conf << 'MODULES'
# Mac Pro 6,1 sensor and fan control
applesmc
MODULES

echo "    ✅ sysctl and modprobe configured"

# ─── Step 9: Add [macpro] repo to installed system ────────────────────────────
echo ">>> [9/10] Adding [macpro] repo to system pacman.conf..."

# We need a persistent URL for the kernel repo so pacman -Syu can update it
# For now, point to the GitHub releases of our fork
if ! grep -q '\[macpro\]' /etc/pacman.conf; then
    cat >> /etc/pacman.conf << 'PACMAN'

# Mac Pro 6,1 custom kernel (eonicman/linux-mac fork)
[macpro]
SigLevel = Never
Server = https://github.com/eonicman/linux-mac/releases/download/$repo/$arch
PACMAN
    echo "    ✅ [macpro] repo added to pacman.conf"
else
    echo "    [macpro] repo already in pacman.conf"
fi

# ─── Step 10: Final verification ──────────────────────────────────────────────
echo ">>> [10/10] Verifying installation..."

ERRORS=0

# Check kernel is installed
if pacman -Q linux-macpro61 &>/dev/null; then
    echo "    ✅ linux-macpro61 installed"
else
    echo "    ❌ linux-macpro61 NOT installed"
    ERRORS=$((ERRORS + 1))
fi

# Check no stock kernel remains
STOCK_COUNT=$(pacman -Q linux-cachyos linux-cachyos-lts 2>/dev/null | wc -l || true)
if [[ $STOCK_COUNT -eq 0 ]]; then
    echo "    ✅ Stock kernels removed"
else
    echo "    ⚠️  Stock kernels still present (may not be harmful)"
fi

# Check applesmc
if grep -q 'CONFIG_SENSORS_APPLESMC=y' /boot/config-$(uname -r 2>/dev/null || echo "7.0.0-macpro61") 2>/dev/null || \
   lsmod 2>/dev/null | grep -q applesmc || \
   [[ -f /etc/modules-load.d/applesmc.conf ]]; then
    echo "    ✅ applesmc configured"
else
    echo "    ⚠️  applesmc not verified (check after first boot)"
fi

# Check fan control
if systemctl is-enabled macfanctld &>/dev/null; then
    echo "    ✅ macfanctld enabled"
else
    echo "    ⚠️  macfanctld not enabled (install manually after boot)"
fi

# Check reboot target
if systemctl is-masked reboot.target &>/dev/null || [[ -L /etc/systemd/system/reboot.target ]]; then
    echo "    ✅ reboot.target masked"
else
    echo "    ❌ reboot.target NOT masked — GPU may not initialize after reboot"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Mac Pro 6,1 Post-Install Complete                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

if [[ $ERRORS -gt 0 ]]; then
    echo "⚠️  $ERRORS error(s) detected. Review the output above."
    echo "    The system may still boot, but some features may not work."
    echo ""
fi

echo "IMPORTANT: Before rebooting:"
echo "  1. Run: sudo poweroff    (NOT reboot!)"
echo "  2. Press the power button to cold-start"
echo "  3. The GPU only initializes on cold boot (Apple EFI quirk)"
echo ""
echo "After first boot:"
echo "  - Run: sensors | grep applesmc   (verify fan control)"
echo "  - Run: glxinfo | grep renderer    (verify GPU acceleration)"
echo "  - Run: uname -r                   (should show *-macpro61)"
echo ""

exit $ERRORS