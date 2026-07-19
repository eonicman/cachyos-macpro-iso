#!/bin/bash
# macpro-installer-launch.sh — Wrapper that runs Calamares then applies Mac Pro fixes
#
# This replaces the standard calamares-online.sh to add a post-install step.
# After Calamares finishes installing the base system, we chroot in and run
# the macpro-postinstall.sh script to fix the kernel, fan control, and boot config.
#
# This is the fix for Bug #6: Calamares pacstrap installs the wrong kernel.

main() {
    # Step 1: Run the standard Calamares installer prep
    echo ">>> Preparing Calamares installer..."

    # Remove current keyring first
    sudo rm -rf /etc/pacman.d/gnupg

    # Install latest keyrings
    sudo pacman -Sy --noconfirm archlinux-keyring cachyos-keyring
    sudo pacman-key --init
    sudo pacman-key --populate archlinux cachyos

    # Sync time
    timedatectl set-ntp true

    local progname="$(basename "$0")"
    local log="/home/liveuser/cachy-install.log"
    local mode="online"

    local SYSTEM=""
    if [ -d /sys/firmware/efi ]; then
        SYSTEM="UEFI SYSTEM"
    else
        SYSTEM="BIOS/MBR SYSTEM"
    fi

    local ISO_VERSION="$(cat /etc/version-tag 2>/dev/null || echo 'unknown')"
    echo "USING ISO VERSION: ${ISO_VERSION}"

    # Install/update Calamares
    sudo pacman -Sy --noconfirm cachyos-calamares-next

    # Get hardware info for log
    inxi -F > "$log"

    cat <<EOF >> "$log"
########## $log by $progname
########## Started (UTC): $(date -u "+%x %X")
########## ISO version: $ISO_VERSION
########## System: $SYSTEM
########## Mac Pro 6,1 Custom Installer
EOF

    # Copy settings
    sudo cp "/usr/share/calamares/settings_${mode}.conf" /etc/calamares/settings.conf

    # ─── Mac Pro 6,1 Custom Step ──────────────────────────────────────────
    # Cache the kernel package so the post-install script can find it
    echo ">>> Caching linux-macpro61 package for post-install..."
    if pacman -Si linux-macpro61 &>/dev/null; then
        sudo pacman -Sw --noconfirm linux-macpro61 linux-macpro61-headers 2>/dev/null || true
    fi
    # Also try to find it in the local repo
    for pkg in /home/michael/linux-mac/cachyos-iso/local-repo/linux-macpro61-*.pkg.tar.zst \
               /var/cache/pacman/pkg/linux-macpro61-*.pkg.tar.zst; do
        if [[ -f "$pkg" ]]; then
            echo "    Found cached kernel: $pkg"
            sudo cp "$pkg" /var/cache/pacman/pkg/ 2>/dev/null || true
        fi
    done

    # ─── Run Calamares ─────────────────────────────────────────────────────
    echo ">>> Starting Calamares installer..."
    echo ">>> After installation completes, Mac Pro 6,1 fixes will be applied."
    echo ""

    sudo pkexec-wrapper calamares -D6 >> "$log" 2>&1
    CALAMARES_EXIT=$?

    if [[ $CALAMARES_EXIT -ne 0 ]]; then
        echo ">>> Calamares exited with code $CALAMARES_EXIT"
        echo ">>> Check $log for details"
        exit $CALAMARES_EXIT
    fi

    # ─── Post-Install: Apply Mac Pro 6,1 fixes ────────────────────────────
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║   Applying Mac Pro 6,1 post-install fixes...               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # Find the installed system mount point
    # Calamares mounts the target at /mnt or similar
    TARGET="/mnt"

    if [[ ! -d "$TARGET/etc" ]]; then
        # Try to find the mounted target
        for mnt in /mnt /target /install; do
            if [[ -d "$mnt/etc" ]] && [[ -f "$mnt/etc/fstab" ]]; then
                TARGET="$mnt"
                break
            fi
        done
    fi

    if [[ -d "$TARGET/etc" ]]; then
        echo ">>> Found installed system at $TARGET"

        # Copy the kernel package cache from live ISO to installed system
        echo ">>> Copying kernel packages to installed system cache..."
        sudo mkdir -p "$TARGET/var/cache/pacman/pkg/"
        for pkg in /var/cache/pacman/pkg/linux-macpro61-*.pkg.tar.zst; do
            if [[ -f "$pkg" ]]; then
                sudo cp "$pkg" "$TARGET/var/cache/pacman/pkg/"
                echo "    Copied: $(basename $pkg)"
            fi
        done

        # Copy our modprobe, sysctl, and modules-load configs
        echo ">>> Copying Mac Pro configs to installed system..."
        sudo mkdir -p "$TARGET/etc/modprobe.d/" "$TARGET/etc/sysctl.d/" "$TARGET/etc/modules-load.d/"
        sudo cp /etc/modprobe.d/macpro-gpu.conf "$TARGET/etc/modprobe.d/" 2>/dev/null || true
        sudo cp /etc/sysctl.d/99-macpro.conf "$TARGET/etc/sysctl.d/" 2>/dev/null || true
        sudo cp /etc/modules-load.d/applesmc.conf "$TARGET/etc/modules-load.d/" 2>/dev/null || true

        # Copy the post-install script into the chroot
        sudo cp /usr/local/bin/macpro-postinstall.sh "$TARGET/usr/local/bin/"
        sudo chmod +x "$TARGET/usr/local/bin/macpro-postinstall.sh"

        # Run the post-install script inside the chroot
        echo ">>> Running Mac Pro 6,1 post-install script in chroot..."
        sudo arch-chroot "$TARGET" /usr/local/bin/macpro-postinstall.sh 2>&1 | tee -a "$log"

        echo ""
        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║   Mac Pro 6,1 installation complete!                       ║"
        echo "║                                                             ║"
        echo "║   ⚠️  IMPORTANT: Always power off, never reboot!           ║"
        echo "║   The Mac Pro 6,1 GPU requires a cold boot to initialize.  ║"
        echo "║                                                             ║"
        echo "║   Run: sudo poweroff                                        ║"
        echo "║   Then press the power button to start.                    ║"
        echo "╚══════════════════════════════════════════════════════════════╝"
    else
        echo "⚠️  Could not find installed system mount point."
        echo "    The Mac Pro 6,1 post-install fixes were NOT applied."
        echo ""
        echo "    To apply them manually after first boot:"
        echo "    1. Boot from the live ISO"
        echo "    2. Mount the installed root partition"
        echo "    3. Run: arch-chroot /mnt /usr/local/bin/macpro-postinstall.sh"
        echo ""
        echo "    Or install linux-macpro61 manually after booting with the"
        echo "    stock kernel (graphics may not work properly)."
    fi
}

main "$@"