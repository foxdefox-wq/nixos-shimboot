#!/bin/bash

# Write the NixOS configuration into a target rootfs directory.
# Unlike the Debian/Alpine scripts, this does NOT run inside a chroot --
# it just lays down /etc/nixos/{configuration,hardware-configuration}.nix
# and an expand_rootfs helper. The actual system closure is built and
# copied in by build_rootfs.sh using nix-build + nix copy on the host
# (see the 'nixos' branch there). nixos-install is intentionally NOT
# invoked, because it only exists on NixOS hosts.

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

#default desktop if none specified
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
    none|"")      echo "" ;;
    *)            echo "services.xserver.desktopManager.xfce.enable = true;" ;;
  esac
}

extra_desktop="$(desktop_module "$packages")"

mkdir -p "$rootfs_dir/etc/nixos"
cat > "$rootfs_dir/etc/nixos/configuration.nix" << NIXCFG
{ config, pkgs, lib, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  # Shimboot: no bootloader, ChromeOS kernel handles boot.
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;

  # Shimboot: ChromeOS kernel handles modules; don't try to build an initrd.
  boot.initrd.availableKernelModules = lib.mkForce [];
  boot.initrd.kernelModules = lib.mkForce [];
  boot.kernelModules = [ "iwlmvm" "ccm" "8021q" "tun" "zram" "lzo" ];
  boot.kernelParams = lib.mkForce [];

  # Rootfs is whatever shimboot labels 'nixos' at build time.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # zram swap (real swap is disabled by the shim kernel anyway).
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

  # Kill frecon before X starts (matches the Debian/Alpine shimboot path).
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

  # Shimboot greeter on login (best-effort -- file may not exist).
  environment.loginShellInit = ''
    if [ -f /run/current-system/sw/bin/shimboot_greeter ]; then
      /run/current-system/sw/bin/shimboot_greeter
    fi
  '';

  environment.systemPackages = with pkgs; [
    wget curl git nano vim
    pciutils usbutils
    networkmanagerapplet
    cloud-utils  # provides growpart for expand_rootfs
    e2fsprogs
    cryptsetup
    util-linux
    (pkgs.writeShellScriptBin "expand_rootfs" (builtins.readFile /etc/nixos/expand_rootfs.sh))
  ];

  services.openssh.enable = true;
  services.openssh.settings.PasswordAuthentication = true;

  system.stateVersion = "24.05";
}
NIXCFG

#minimal hardware-configuration; first boot can regenerate via nixos-generate-config.
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
echo "build_rootfs.sh will now build the system closure via nix-build and copy it in."
