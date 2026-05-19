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
{ config, pkgs, lib, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  # SHIMBOOT BOOT SETUP
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  boot.loader.initScript.enable = true;

  boot.initrd.availableKernelModules = lib.mkForce [];
  boot.initrd.kernelModules = lib.mkForce [];
  boot.kernelParams = lib.mkForce [];
  boot.kernelModules = [ "iwlmvm" "ccm" "8021q" "tun" "zram" "lzo" ];
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_1;

  # ROOT FILESYSTEM
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    options = [ "noatime" "commit=30" "errors=remount-ro" ];
  };

  zramSwap.enable = true;
  zramSwap.algorithm = "lzo";

  # SYSTEM BASICS
  networking.hostName = "$hostname";
  networking.networkmanager.enable = true;
  networking.wireless.enable = false;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  # DISPLAY
  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  $extra_desktop

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

  # USERS
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

  # PACKAGES
  nixpkgs.config.allowUnfree = true;
  environment.systemPackages = with pkgs; [
    wget curl git vim nano
    pciutils usbutils
    networkmanagerapplet
    cloud-utils e2fsprogs cryptsetup util-linux
    (pkgs.writeShellScriptBin "expand_rootfs" (builtins.readFile ./expand_rootfs.sh))
  ];

  # SERVICES
  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = true;
  hardware.enableRedistributableFirmware = true;

  system.stateVersion = "24.05";
}
NIXCFG

cat > "$rootfs_dir/etc/nixos/hardware-configuration.nix" << 'HWCFG'
{ config, pkgs, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  hardware.enableRedistributableFirmware = true;
}
HWCFG

cat > "$rootfs_dir/etc/nixos/expand_rootfs.sh" << 'EXPAND'
#!/bin/bash
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
