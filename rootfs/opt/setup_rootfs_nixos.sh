#!/bin/bash

#setup the NixOS rootfs
#this is meant to be run within a minimal environment after nix is bootstrapped

set -e
if [ "$DEBUG" ]; then
  set -x
fi

rootfs_dir="$1"
hostname="$2"
username="$3"
user_passwd="$4"
root_passwd="$5"
enable_root="$6"
packages="$7"
arch="$8"

#default packages if none specified
if [ -z "$packages" ]; then
  packages="xfce"
fi

#map desktop name to nixos module
desktop_module() {
  case "$1" in
    xfce)         echo "services.xserver.desktopManager.xfce.enable = true;" ;;
    gnome)        echo "services.xserver.desktopManager.gnome.enable = true;" ;;
    kde)          echo "services.xserver.displayManager.sddm.enable = true; services.xserver.desktopManager.plasma5.enable = true;" ;;
    lxde)         echo "services.xserver.desktopManager.lxsession.enable = true;" ;;
    cinnamon)     echo "services.xserver.desktopManager.cinnamon.enable = true;" ;;
    mate)         echo "services.xserver.desktopManager.mate.enable = true;" ;;
    none)         echo "" ;;
    *)            echo "services.xserver.desktopManager.xfce.enable = true;" ;;
  esac
}

extra_desktop="$(desktop_module "$packages")"

#generate the NixOS configuration
mkdir -p "$rootfs_dir/etc/nixos"
cat > "$rootfs_dir/etc/nixos/configuration.nix" << NIXCFG
{ config, pkgs, lib, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  # Shimboot: no bootloader, ChromeOS kernel handles boot
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  boot.loader.initScript.enable = true;

  # Shimboot: load ChromeOS kernel modules for WiFi etc.
  boot.initrd.availableKernelModules = lib.mkForce [];
  boot.initrd.kernelModules = lib.mkForce [];
  boot.kernelModules = [ "iwlmvm" "ccm" "8021q" "tun" "zram" "lzo" ];
  boot.kernelParams = lib.mkForce [];

  # Filesystem: /dev/disk/by-label/nixos written by build script
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Swap via zram
  zramSwap.enable = true;
  zramSwap.algorithm = "lzo";

  networking.hostName = "$hostname";
  networking.networkmanager.enable = true;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";

  # X11 / display
  services.xserver.enable = true;
  services.xserver.displayManager.lightdm.enable = true;
  $extra_desktop

  # Kill frecon before X starts (same as other shimboot distros)
  systemd.services.kill-frecon = {
    description = "Kill frecon to allow Xorg to start";
    wantedBy = [ "graphical.target" ];
    before = [ "display-manager.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [ "\${pkgs.bash}/bin/bash -c 'umount -l /dev/console 2>/dev/null || true; pkill frecon-lite 2>/dev/null || true'" ];
      RemainAfterExit = true;
    };
  };

  # Patched systemd from shimboot repo
  nixpkgs.config.allowUnfree = true;

  users.mutableUsers = false;

  users.users.root = lib.mkIf (lib.elem "$enable_root" [ "1" "true" "yes" ]) {
    password = "$root_passwd";
  };

  users.users.$username = {
    isNormalUser = true;
    extraGroups = [ "wheel" "video" "audio" "networkmanager" ];
    initialPassword = "$user_passwd";
  };

  security.sudo.wheelNeedsPassword = false;

  # Shimboot greeter
  environment.loginShellInit = ''
    if [ -f /run/current-system/sw/bin/shimboot_greeter ]; then
      /run/current-system/sw/bin/shimboot_greeter
    fi
  '';

  environment.systemPackages = with pkgs; [
    wget curl git nano vim
    pciutils usbutils
    networkmanagerapplet
  ];

  # Expand rootfs helper
  environment.systemPackages = lib.mkAfter [ (pkgs.writeShellScriptBin "expand_rootfs" (builtins.readFile /etc/nixos/expand_rootfs.sh)) ];

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = true;

  system.stateVersion = "24.05";
}
NIXCFG

#minimal hardware-configuration stub (real one generated at first boot)
cat > "$rootfs_dir/etc/nixos/hardware-configuration.nix" << 'HWCFG'
{ config, pkgs, lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  hardware.enableRedistributableFirmware = true;
}
HWCFG

#expand_rootfs script (same logic as Debian version, adapted for NixOS)
cat > "$rootfs_dir/etc/nixos/expand_rootfs.sh" << 'EXPAND'
#!/bin/bash
set -e
if [ "$EUID" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi
root_dev="$(findmnt -T / -no SOURCE)"
luks="$(echo "$root_dev" | grep "/dev/mapper" || true)"
if [ "$luks" ]; then
  kname_dev="$(lsblk --list --noheadings --paths --output KNAME "$root_dev")"
  kname="$(basename "$kname_dev")"
  part_dev="/dev/$(basename "/sys/class/block/$kname/slaves/"*)"
else
  part_dev="$root_dev"
fi
disk_dev="$(lsblk --list --noheadings --paths --output PKNAME "$part_dev" | head -n1)"
part_num="$(echo "${part_dev#$disk_dev}" | tr -d 'p')"
echo "Before:"; df -h /
growpart "$disk_dev" "$part_num" || true
if [ "$luks" ]; then
  cryptsetup resize "$root_dev"
fi
resize2fs "$root_dev" || true
echo "After:"; df -h /
echo "Done."
EXPAND
chmod +x "$rootfs_dir/etc/nixos/expand_rootfs.sh"

echo "NixOS configuration written to $rootfs_dir/etc/nixos/"
echo "NOTE: Run 'nixos-install' or 'nixos-rebuild' on first boot to activate."
