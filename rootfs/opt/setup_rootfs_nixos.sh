#!/bin/bash

# Write the NixOS configuration into a target rootfs directory.
# This does NOT chroot or run nix; it just lays down /etc/nixos/. The
# actual closure build + copy is done by build_rootfs.sh on the host.

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

  ###########################################################################
  # SHIMBOOT BOOT: the ChromeOS shim kernel + shimboot bootloader hand us a
  # rootfs with /proc /sys /dev already mounted (but NOT /dev/pts, /dev/shm,
  # /run, etc.). Stage 2 sees /proc/1 exists and skips its earlyMountScript,
  # then systemd starts and dies with "failed to mount API filesystems"
  # because /dev/pts and friends are missing.
  #
  # Fix: use boot.postBootCommands to mount what's missing BEFORE systemd
  # is exec'd. Stage 2 runs postBootCommands right before 'exec systemd'.
  ###########################################################################
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;
  boot.loader.initScript.enable = true;

  # NOTE: we leave boot.initrd.enable at its default (true) because some
  # nixos-24.05 modules reference system.build.initialRamdisk unconditionally.
  # The initrd is built but never used -- the ChromeOS kernel + shimboot
  # bootloader handle stage 1. ~30MB of wasted disk; harmless.
  boot.initrd.availableKernelModules = lib.mkForce [];
  boot.initrd.kernelModules = lib.mkForce [];
  boot.kernelParams = lib.mkForce [];
  boot.kernelModules = [ "iwlmvm" "ccm" "8021q" "tun" "zram" "lzo" ];

  # The closure's kernel modules path -- modules in the image come from
  # patch_rootfs.sh (copied from the shim). This is just for metadata.
  boot.kernelPackages = pkgs.linuxKernel.packages.linux_6_1;

  # Ensure the API filesystems are present before systemd exec's.
  # shimboot's bootloader 'mount -o move's /proc /sys /dev into newroot but
  # nothing else. Stage 2 sees /proc/1 and skips its own earlyMountScript,
  # so we need to mount the rest by hand here.
  boot.postBootCommands = ''
    # Make existing mounts behave (shimboot used 'mount -n -o move' which
    # doesn't always set propagation flags).
    mount --make-rprivate / 2>/dev/null || true
    for fs in /proc /sys /dev; do
      mount --make-rprivate \$fs 2>/dev/null || true
    done

    # Mount filesystems systemd expects to exist.
    mountpoint -q /run        || mount -t tmpfs    -o mode=0755,nosuid,nodev tmpfs    /run
    mkdir -p /run/wrappers /run/keys /run/lock
    mountpoint -q /dev/pts    || mount -t devpts   -o mode=0620,gid=3,nosuid,noexec devpts /dev/pts
    mountpoint -q /dev/shm    || mount -t tmpfs    -o mode=1777,nosuid,nodev tmpfs    /dev/shm
    mountpoint -q /sys/fs/cgroup || mount -t cgroup2 -o nsdelegate cgroup2 /sys/fs/cgroup 2>/dev/null || true
  '';

  ###########################################################################
  # ROOT FILESYSTEM
  ###########################################################################
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    options = [ "noatime" "commit=30" "errors=remount-ro" ];
  };

  zramSwap.enable = true;
  zramSwap.algorithm = "lzo";

  ###########################################################################
  # SYSTEM BASICS
  ###########################################################################
  networking.hostName = "$hostname";
  networking.networkmanager.enable = true;
  networking.wireless.enable = false;

  time.timeZone = "UTC";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";

  ###########################################################################
  # DISPLAY
  ###########################################################################
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
