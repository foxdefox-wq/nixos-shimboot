#!/bin/bash

# build the rootfs (debian / ubuntu / alpine / nixos)
# Style note: stays as close as possible to ading2210/shimboot upstream.
# The 'nixos' branch is the only addition; everything else is unchanged.

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path release_name"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages - The desktop to install (xfce/gnome/kde/lxde/cinnamon/mate/none)."
  echo "  hostname        - The hostname for the new rootfs."
  echo "  enable_root     - Enable the root user."
  echo "  root_passwd     - The root password (only if enable_root is set)."
  echo "  username        - The unprivileged user name."
  echo "  user_passwd     - The password for the unprivileged user."
  echo "  disable_base    - Disable the base packages (debian/alpine only)."
  echo "  arch            - The CPU architecture (default: amd64)."
  echo "  distro          - 'debian', 'ubuntu', 'alpine', or 'nixos'."
  echo "  nix_channel     - (nixos only) channel name (default: nixos-24.05)."
}

assert_root
assert_deps "realpath debootstrap findmnt wget pcre2grep tar"
assert_args "$2"
parse_args "$@"

rootfs_dir=$(realpath -m "${1}")
release_name="${2}"
packages="${args['custom_packages']-task-xfce-desktop}"
arch="${args['arch']-amd64}"
distro="${args['distro']-debian}"
nix_channel="${args['nix_channel']-nixos-24.05}"
chroot_mounts="proc sys dev run"

mkdir -p $rootfs_dir

unmount_all() {
  for mountpoint in $chroot_mounts; do
    umount -l "$rootfs_dir/$mountpoint"
  done
}

need_remount() {
  local target="$1"
  local mnt_options="$(findmnt -T "$target" | tail -n1 | rev | cut -f1 -d' '| rev)"
  echo "$mnt_options" | grep -e "noexec" -e "nodev"
}

do_remount() {
  local target="$1"
  local mountpoint="$(findmnt -T "$target" | tail -n1 | cut -f1 -d' ')"
  mount -o remount,dev,exec "$mountpoint"
}

# Locate a Nix CLI binary on the host (works on Ubuntu, not just NixOS).
find_nix_bin() {
  local name="$1"
  command -v "$name" 2>/dev/null && return 0
  for c in /nix/var/nix/profiles/default/bin/$name /root/.nix-profile/bin/$name; do
    [ -x "$c" ] && { echo "$c"; return 0; }
  done
  if [ -n "${SUDO_USER:-}" ]; then
    local h="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [ -x "$h/.nix-profile/bin/$name" ] && { echo "$h/.nix-profile/bin/$name"; return 0; }
  fi
  return 1
}

[ "$(need_remount "$rootfs_dir")" ] && do_remount "$rootfs_dir"

if [ "$distro" = "debian" ]; then
  print_info "bootstraping debian chroot"
  debootstrap --arch $arch --components=main,contrib,non-free,non-free-firmware "$release_name" "$rootfs_dir" http://deb.debian.org/debian/
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "ubuntu" ]; then
  print_info "bootstraping ubuntu chroot"
  repo_url="http://archive.ubuntu.com/ubuntu"
  [ "$arch" != "amd64" ] && repo_url="http://ports.ubuntu.com"
  debootstrap --arch $arch "$release_name" "$rootfs_dir" "$repo_url"
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "alpine" ]; then
  print_info "downloading alpine package list"
  pkg_list_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
  pkg_data="$(wget -qO- --show-progress "$pkg_list_url" | grep "apk-tools-static")"
  pkg_url="$pkg_list_url$(echo "$pkg_data" | pcre2grep -o1 '"(.+?.apk)"')"
  pkg_extract_dir="/tmp/apk-tools-static"
  pkg_dl_path="$pkg_extract_dir/pkg.apk"
  apk_static="$pkg_extract_dir/sbin/apk.static"
  mkdir -p "$pkg_extract_dir"
  wget -q --show-progress "$pkg_url" -O "$pkg_dl_path"
  tar --warning=no-unknown-keyword -xzf "$pkg_dl_path" -C "$pkg_extract_dir"
  real_arch="x86_64"
  [ "$arch" = "arm64" ] && real_arch="aarch64"
  $apk_static --arch $real_arch \
    -X http://dl-cdn.alpinelinux.org/alpine/$release_name/main/ \
    -U --allow-untrusted --root "$rootfs_dir" \
    --initdb add alpine-base
  chroot_script="/opt/setup_rootfs_alpine.sh"

elif [ "$distro" = "nixos" ]; then
  print_info "setting up NixOS rootfs (via nix-build on host)"
  # Bootstrapping NixOS into a directory on Ubuntu:
  #   1. Write /etc/nixos/configuration.nix  (setup_rootfs_nixos.sh)
  #   2. nix-build the system closure        (here, on the host)
  #   3. nix copy the closure into the dir   (here)
  #   4. Wire up /nix/var/nix/profiles/system (here)
  #   5. Run the closure's activate script   (here -- the key step!)
  # Step 5 is what produces /sbin/init, /bin/sh, /etc/*, etc. so the
  # bootloader's `exec /sbin/init` actually works.
  NIX_BUILD="$(find_nix_bin nix-build || true)"
  NIX_CHANNEL="$(find_nix_bin nix-channel || true)"
  NIX_CLI="$(find_nix_bin nix || true)"
  if [ -z "$NIX_BUILD" ] || [ -z "$NIX_CHANNEL" ] || [ -z "$NIX_CLI" ]; then
    print_error "Nix is not installed on the host. Install from https://nixos.org/download"
    print_error "  (need nix-build, nix-channel, and 'nix' CLI)"
    exit 1
  fi
  chroot_script=""

else
  print_error "'$distro' is an invalid distro choice."
  exit 1
fi

hostname="${args['hostname']}"
root_passwd="${args['root_passwd']}"
enable_root="${args['enable_root']}"
username="${args['username']}"
user_passwd="${args['user_passwd']}"
disable_base="${args['disable_base']}"

if [ "$distro" = "nixos" ]; then
  print_info "writing NixOS configuration to $rootfs_dir/etc/nixos"
  bash rootfs/opt/setup_rootfs_nixos.sh \
    "$rootfs_dir" \
    "${hostname:-shimboot}" \
    "${username:-user}" \
    "${user_passwd:-user}" \
    "${root_passwd:-}" \
    "${enable_root:-}" \
    "${packages:-xfce}" \
    "$arch"

  print_info "ensuring nixpkgs channel '$nix_channel' is configured"
  if ! "$NIX_CHANNEL" --list | grep -qE '^nixpkgs[[:space:]]'; then
    "$NIX_CHANNEL" --add "https://nixos.org/channels/$nix_channel" nixpkgs
  fi
  "$NIX_CHANNEL" --update

  out_link_dir="$(mktemp -d)"
  out_link="$out_link_dir/nixos-system"
  print_info "building NixOS system closure (this will take a while)"
  "$NIX_BUILD" '<nixpkgs/nixos>' \
    -A config.system.build.toplevel \
    -I "nixos-config=$rootfs_dir/etc/nixos/configuration.nix" \
    --out-link "$out_link"

  system_store_path="$(readlink -f "$out_link")"
  print_info "system closure: $system_store_path"

  print_info "copying closure into rootfs at $rootfs_dir/nix/store"
  mkdir -p "$rootfs_dir/nix/store"
  "$NIX_CLI" --extra-experimental-features 'nix-command' copy \
    --no-check-sigs \
    --to "local?root=$rootfs_dir" \
    "$system_store_path"

  print_info "wiring up /nix/var/nix/profiles/system"
  mkdir -p "$rootfs_dir/nix/var/nix/profiles"
  ln -sfT "$system_store_path" "$rootfs_dir/nix/var/nix/profiles/system"
  mkdir -p "$rootfs_dir/nix/var/nix/profiles/per-user/root"
  mkdir -p "$rootfs_dir/nix/var/nix/gcroots/profiles"
  ln -sfT "../../profiles/system" "$rootfs_dir/nix/var/nix/gcroots/profiles/system" 2>/dev/null || true

  print_info "creating /etc/NIXOS marker and nix.conf"
  mkdir -p "$rootfs_dir/etc/nix"
  : > "$rootfs_dir/etc/NIXOS"
  if [ ! -f "$rootfs_dir/etc/nix/nix.conf" ]; then
    cat > "$rootfs_dir/etc/nix/nix.conf" <<'NIXCONF'
experimental-features = nix-command flakes
build-users-group = nixbld
NIXCONF
  fi

  # Critical: lay down the boot symlinks so the shimboot bootloader's
  # `exec /sbin/init` works. NixOS activation would normally do this on
  # first boot, but we're building offline -- so we do it now.
  print_info "creating /sbin/init -> system/init and /init shims"
  mkdir -p "$rootfs_dir/sbin" "$rootfs_dir/bin"
  ln -sfT /nix/var/nix/profiles/system/init "$rootfs_dir/sbin/init"
  ln -sfT /nix/var/nix/profiles/system/init "$rootfs_dir/init"
  # /bin/sh -- needed by anything that shells out before activation runs.
  # The closure's activate script also creates these, but we want it
  # available before activation too (e.g. for emergency shells).
  if [ -e "$system_store_path/sw/bin/sh" ]; then
    ln -sfT /nix/var/nix/profiles/system/sw/bin/sh "$rootfs_dir/bin/sh"
  fi

  rm -f "$out_link"
  rmdir "$out_link_dir" 2>/dev/null || true

else
  print_info "copying rootfs setup scripts"
  cp -arv rootfs/* "$rootfs_dir"
  cp /etc/resolv.conf "$rootfs_dir/etc/resolv.conf"

  print_info "creating bind mounts for chroot"
  trap unmount_all EXIT
  for mountpoint in $chroot_mounts; do
    mount --make-rslave --rbind "/${mountpoint}" "${rootfs_dir}/$mountpoint"
  done

  chroot_command="$chroot_script \
    '$DEBUG' '$release_name' '$packages' \
    '$hostname' '$root_passwd' '$username' \
    '$user_passwd' '$enable_root' '$disable_base' \
    '$arch'"

  LC_ALL=C chroot $rootfs_dir /bin/sh -c "${chroot_command}"

  trap - EXIT
  unmount_all
fi

print_info "rootfs has been created"
