#!/bin/bash

#build the rootfs (debian / ubuntu / alpine / nixos)

. ./common.sh

print_help() {
  echo "Usage: ./build_rootfs.sh rootfs_path release_name"
  echo "Valid named arguments (specify with 'key=value'):"
  echo "  custom_packages - The packages that will be installed in place of task-xfce-desktop."
  echo "  hostname        - The hostname for the new rootfs."
  echo "  enable_root     - Enable the root user."
  echo "  root_passwd     - The root password. This only has an effect if enable_root is set."
  echo "  username        - The unprivileged user name for the new rootfs."
  echo "  user_passwd     - The password for the unprivileged user."
  echo "  disable_base    - Disable the base packages such as zram, cloud-utils, and command-not-found."
  echo "  arch            - The CPU architecture to build the rootfs for."
  echo "  distro          - The Linux distro to use. This should be either 'debian', 'ubuntu', 'alpine', or 'nixos'."
  echo "  nix_channel     - (nixos only) Channel name to use, e.g. nixos-24.05 (default: nixos-24.05)."
  echo "If you do not specify the hostname and credentials, you will be prompted for them later."
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

# Locate Nix CLI binaries from a host install (works on Ubuntu, not just NixOS).
# Tries (in order): PATH, default profile, per-user profile of the invoking user.
find_nix_bin() {
  local name="$1"
  local invoker_home
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"; return 0
  fi
  for candidate in \
    "/nix/var/nix/profiles/default/bin/$name" \
    "/root/.nix-profile/bin/$name"; do
    [ -x "$candidate" ] && { echo "$candidate"; return 0; }
  done
  if [ -n "${SUDO_USER:-}" ]; then
    invoker_home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    [ -x "$invoker_home/.nix-profile/bin/$name" ] && { echo "$invoker_home/.nix-profile/bin/$name"; return 0; }
  fi
  return 1
}

if [ "$(need_remount "$rootfs_dir")" ]; then
  do_remount "$rootfs_dir"
fi

if [ "$distro" = "debian" ]; then
  print_info "bootstraping debian chroot"
  debootstrap --arch $arch --components=main,contrib,non-free,non-free-firmware "$release_name" "$rootfs_dir" http://deb.debian.org/debian/
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "ubuntu" ]; then
  print_info "bootstraping ubuntu chroot"
  repo_url="http://archive.ubuntu.com/ubuntu"
  if [ "$arch" = "amd64" ]; then
    repo_url="http://archive.ubuntu.com/ubuntu"
  else
    repo_url="http://ports.ubuntu.com"
  fi
  debootstrap --arch $arch "$release_name" "$rootfs_dir" "$repo_url"
  chroot_script="/opt/setup_rootfs.sh"

elif [ "$distro" = "alpine" ]; then
  print_info "downloading alpine package list"
  pkg_list_url="https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/x86_64/"
  pkg_data="$(wget -qO- --show-progress "$pkg_list_url" | grep "apk-tools-static")"
  pkg_url="$pkg_list_url$(echo "$pkg_data" | pcre2grep -o1 '"(.+?.apk)"')"

  print_info "downloading and extracting apk-tools-static"
  pkg_extract_dir="/tmp/apk-tools-static"
  pkg_dl_path="$pkg_extract_dir/pkg.apk"
  apk_static="$pkg_extract_dir/sbin/apk.static"
  mkdir -p "$pkg_extract_dir"
  wget -q --show-progress "$pkg_url" -O "$pkg_dl_path"
  tar --warning=no-unknown-keyword -xzf "$pkg_dl_path" -C "$pkg_extract_dir"

  print_info "bootstraping alpine chroot"
  real_arch="x86_64"
  if [ "$arch" = "arm64" ]; then
    real_arch="aarch64"
  fi
  $apk_static \
    --arch $real_arch \
    -X http://dl-cdn.alpinelinux.org/alpine/$release_name/main/ \
    -U --allow-untrusted \
    --root "$rootfs_dir" \
    --initdb add alpine-base
  chroot_script="/opt/setup_rootfs_alpine.sh"

elif [ "$distro" = "nixos" ]; then
  print_info "setting up NixOS rootfs (host: $(uname -s), via nix-build)"
  # NixOS isn't bootstrapped via chroot. We build the system closure on the
  # host using the installed Nix CLI, then copy the closure into the rootfs
  # tree and wire up /nix/var/nix/profiles/system. This works on any host
  # with single-user or multi-user Nix installed (Ubuntu, Debian, etc.) --
  # nixos-install itself only exists on NixOS hosts and is NOT used here.
  NIX_BUILD="$(find_nix_bin nix-build || true)"
  NIX_CHANNEL="$(find_nix_bin nix-channel || true)"
  NIX_CLI="$(find_nix_bin nix || true)"
  if [ -z "$NIX_BUILD" ] || [ -z "$NIX_CHANNEL" ] || [ -z "$NIX_CLI" ]; then
    print_error "Nix is not installed on the host. Install it from https://nixos.org/download"
    print_error "  (need nix-build, nix-channel, and the 'nix' CLI in PATH or /nix/var/nix/profiles/default/bin)"
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
  print_info "writing NixOS configuration into $rootfs_dir/etc/nixos"
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
  # nix-channel is per-user; we're root here. Add only if missing so we don't
  # clobber the user's existing channels.
  if ! "$NIX_CHANNEL" --list | grep -qE '^nixpkgs[[:space:]]'; then
    "$NIX_CHANNEL" --add "https://nixos.org/channels/$nix_channel" nixpkgs
  fi
  "$NIX_CHANNEL" --update

  out_link="$(mktemp -d)/nixos-system"
  print_info "building NixOS system closure (this may take a while)"
  "$NIX_BUILD" '<nixpkgs/nixos>' \
    -A config.system.build.toplevel \
    -I "nixos-config=$rootfs_dir/etc/nixos/configuration.nix" \
    --out-link "$out_link"

  # Resolve the actual /nix/store/... path so the profile symlink works
  # *inside* the target rootfs after copying (the /tmp out-link doesn't exist there).
  system_store_path="$(readlink -f "$out_link")"
  print_info "system closure: $system_store_path"

  print_info "copying closure into rootfs store at $rootfs_dir/nix/store"
  mkdir -p "$rootfs_dir/nix/store"
  "$NIX_CLI" --extra-experimental-features 'nix-command' copy \
    --no-check-sigs \
    --to "local?root=$rootfs_dir" \
    "$system_store_path"

  print_info "wiring up /nix/var/nix/profiles/system"
  mkdir -p "$rootfs_dir/nix/var/nix/profiles"
  ln -sfT "$system_store_path" "$rootfs_dir/nix/var/nix/profiles/system"
  # Also wire up the per-user default profile dir so first-boot tools don't choke.
  mkdir -p "$rootfs_dir/nix/var/nix/profiles/per-user/root"
  mkdir -p "$rootfs_dir/nix/var/nix/gcroots/profiles"
  ln -sfT "../../profiles/system" "$rootfs_dir/nix/var/nix/gcroots/profiles/system" 2>/dev/null || true

  # Minimal /etc bits so the closure can be booted (activate script lives in the closure).
  mkdir -p "$rootfs_dir/etc"
  # The /etc/NIXOS marker tells the activation scripts this is a NixOS root.
  : > "$rootfs_dir/etc/NIXOS"
  # nix.conf so any in-rootfs nix calls work
  mkdir -p "$rootfs_dir/etc/nix"
  if [ ! -f "$rootfs_dir/etc/nix/nix.conf" ]; then
    cat > "$rootfs_dir/etc/nix/nix.conf" <<'NIXCONF'
experimental-features = nix-command flakes
build-users-group = nixbld
NIXCONF
  fi

  rm -f "$out_link"
  rmdir "$(dirname "$out_link")" 2>/dev/null || true
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
