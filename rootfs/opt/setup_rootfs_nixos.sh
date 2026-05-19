#!/bin/bash

# Write the NixOS configuration into a target rootfs directory.
# This does NOT chroot or run nix; it just lays down /etc/nixos/. The
# actual closure build + copy is done by build_rootfs.sh on the host
# (via nix-build + nix copy). The goal is to stay as close as possible
# to ading2210's original Debian/Alpine flow.

set -e
[ "$DEBUG" ] && set -x

rootfs_dir="$1"
hostname="$2"
username="$3"
user_passwd="$4"
root_passwd="$5"
enable_root="$6"
packages="$7"
arch="$8"

[ -z "$packages" ] && packages="xfce"

desktop_module() {
  case "$1" in
    xfce)     echo "services.xserver.desktopManager.xfce.enable = true;" ;;
    gnome)    echo "services.xserver.desktopManager.gnome.enable = true;" ;;
    kde)      echo "services.xserver.displayManager.sddm.enable = true; services.xserver.desktopManager.plasma5.enable = true;" ;;
    lxde)     echo "services.xserver.desktopManager.lxde.enable = true;" ;;
    cinnamon) echo "services.xserver.desktopManager.cinnamon.enable = true;" ;;
    mate)     echo "services.xserver.desktopManager.mate.enable = true;" ;;
    none|"")  echo "" ;;
    *)        echo "services.xserver.desktopManager.xfce.enable = true;" ;;
  esac
}

extra_desktop="$(desktop_module "$packages")"

mkdir -p "$rootfs_dir/etc/nixos"
cat > "$rootfs_dir/etc/nixos/configuration.nix" << NIXCFG
# Minimal NixOS configuration for shimboot.
# Mirrors the style of ading2210's Debian default: one config, no fluff.
{ config, pkgs, lib, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  ###########################################################################
  # SHIMBOOT BOOT SETUP
  #
  # The ChromeOS shim kernel boots an initramfs (shimboot's bootloader) which
  # finds shimboot_rootfs:* partitions and pivot_roots into the selected one,
  # then 'exec /sbin/init'. So:
  #   - Disable real bootloaders (grub, systemd-boot) -- they can't install on
  #     this disk anyway, and trying would fail.
  #   - Enable boot.loader.initScript -- this is the NixOS knob that tells
  #     activation to create /sbin/init -> system/init and skip bootloader
  #     installation. WITHOUT this, NixOS evaluation will fail because no
  #     bootloader is configured.
  #   - Don't build an initrd -- the ChromeOS kernel already handed off to a
  #     mounted rootfs.
  ###########################################################################
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  boot.loader.initScript.enable = true;

  boot.initrd.availableKernelModules = lib.mkForce [];
  boot.initrd.kernelModules = lib.mkForce [];
  boot.kernelParams = lib.mkForce [];
  # ChromeOS-specific modules the shim kernel needs loaded at runtime.
  boot.kernelModules = [ "iwlmvm" "ccm" "8021q" "tun" "zram" "lzo" ];

  # NixOS-side modules entry. The ACTUAL modules on disk at /lib/modules/<ver>
  # are copied from the shim by patch_rootfs.sh; this just keeps the kernel
  # package metadata consistent.
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_1;

  ###########################################################################
  # OPTIONAL: SYSTEMD PATCH FOR OLD CHROMEOS KERNELS
  #
  # Vanilla NixOS systemd (256+) uses mount_setattr/open_tree syscalls that
  # don't exist on shim kernels <5.12. If your device hangs early in boot with
  # mount errors, uncomment the block below. (Borrowed from popcat/shimboot.)
  ###########################################################################
  systemd.package = pkgs.systemd.overrideAttrs (old: {
    patches = (old.patches or []) ++ [
      (pkgs.fetchpatch {
        url = "https://raw.githubusercontent.com/PopCat19/nixos-shimboot/main/patches/systemd-mountpoint-util-chromeos.patch";
        hash = "sha256-1B2OVcCFDXV4VF8nxHI4J4uw6B7Lzv5stGO1MU14Vv0=";
      })
    ];
  });
  ###########################################################################
  # ROOT FILESYSTEM
  # shimboot's build.sh labels p4 as 'nixos' (truncated from the GPT partname
  # 'shimboot_rootfs:nixos'). build_rootfs.sh's image_utils.sh sets the ext4
  # label to match.
  ###########################################################################
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    options = [ "noatime" "commit=30" "errors=remount-ro" ];
  };

  # No swap (disabled by shim kernel), but zram works fine.
  zramSwap.enable = true;
  zramSwap.algorithm = "lzo";

  ###########################################################################
  # SYSTEM BASICS
  ###########################################################################
  networking.hostName = "$hostname";
  networking.networkmanager.enable = true;
  networking.wireless.enable = false;  # let NM manage wpa_supplicant

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  ###########################################################################
  # DISPLAY (matches ading default: lightdm + xfce, replaceable via 'desktop=')
  ###########################################################################
  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  $extra_desktop

  # Kill frecon-lite before X grabs the console (same as Debian shimboot path).
  systemd.services.kill-frecon = {
    description = "Kill ChromeOS frecon-lite before display-manager";
    wantedBy = [ "multi-user.target" ];
    before = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "kill-frecon" ''
        \${pkgs.util-linux}/bin/umount -l /dev/console 2>/dev/null || true
        \${pkgs.procps}/bin/pkill frecon-lite 2>/dev/null || true
      '';
    };
  };

  ###########################################################################
  # USERS
  ###########################################################################
  users.mutableUsers = true;

  users.users.root = lib.mkIf (lib.elem "$enable_root" [ "1" "true" "yes" ]) {
    initialPassword = "$root_passwd";
  };

  users.users.$username = {
    isNormalUser = true;
    description = "$username";
    extraGroups = [ "wheel" "video" "audio" "networkmanager" "input" ];
    initialPassword = "$user_passwd";
  };

  security.sudo.wheelNeedsPassword = false;

  ###########################################################################
  # PACKAGES
  ###########################################################################
  nixpkgs.config.allowUnfree = true;

  environment.systemPackages = with pkgs; [
    wget curl git vim nano
    pciutils usbutils
    networkmanagerapplet
    cloud-utils e2fsprogs cryptsetup util-linux
    (pkgs.writeShellScriptBin "expand_rootfs" (builtins.readFile ./expand_rootfs.sh))
  ];

  ###########################################################################
  # SERVICES
  ###########################################################################
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = true;

  hardware.enableRedistributableFirmware = true;

  system.stateVersion = "24.05";
}
NIXCFG

cat > "$rootfs_dir/etc/nixos/hardware-configuration.nix" << 'HWCFG'
# Stub hardware-configuration.
# Real hardware detection is bypassed -- the ChromeOS shim kernel handles
# the device-specific bits and patch_rootfs.sh drops the needed modules
# at /lib/modules/<shim-kernel-version>. First-boot nixos-generate-config
# would also work if you want a richer profile later.
{ config, pkgs, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  hardware.enableRedistributableFirmware = true;
}
HWCFG

cat > "$rootfs_dir/etc/nixos/expand_rootfs.sh" << 'EXPAND'
#!/bin/bash
# Drop-in equivalent of ading2210's /usr/local/bin/expand_rootfs.
set -e
[ "$EUID" -ne 0 ] && { echo "Run as root."; exit 1; }
root_dev="$(findmnt -T / -no SOURCE)"
luks="$(echo "$root_dev" | grep "/dev/mapper" || true)"
if [ "$luks" ]; then
  kname_dev="$(lsblk --list --noheadings --paths --output KNAME "$root_dev")"
  part_dev="/dev/$(basename "/sys/class/block/$(basename "$kname_dev")/slaves/"*)"
else
  part_dev="$root_dev"
fi
disk_dev="$(lsblk --list --noheadings --paths --output PKNAME "$part_dev" | head -n1)"
part_num="$(echo "${part_dev#$disk_dev}" | tr -d 'p')"
echo "Before:"; df -h /
growpart "$disk_dev" "$part_num" || true
[ "$luks" ] && cryptsetup resize "$root_dev"
resize2fs "$root_dev" || true
echo "After:"; df -h /
EXPAND
chmod +x "$rootfs_dir/etc/nixos/expand_rootfs.sh"

echo "NixOS configuration written to $rootfs_dir/etc/nixos/"
echo "build_rootfs.sh will now build the system closure via nix-build."
