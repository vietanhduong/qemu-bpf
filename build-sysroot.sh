#!/bin/bash

set -e
ARCH=""
RELEASE=""
EXCLUDE_PATHS=""

usage() {
  echo "Usage: $(basename $0) -a <arch> -r <debian_release> -e <exclude_path>,<exclude_path>"
  echo "    -a   <arch>                CPU architecture. Default: amd64"
  echo "    -r  <debian_release>       Debian Release name. Default: bookworm"
  echo "    -e  <exclude_path>         Exclude paths. Separate by comma."
  exit 1
}

parse_args() {
  local OPTIND
  while getopts "a:r:e:h" opt; do
    case ${opt} in
    a)
      ARCH=$OPTARG
      ;;
    e)
      EXCLUDE_PATHS=$OPTARG
      ;;
    r)
      RELEASE=$OPTARG
      ;;
    :)
      echo "Invalid option: $OPTARG requires an argument" 1>&2
      ;;
    h)
      usage
      ;;

    *)
      usage
      ;;
    esac
  done
  shift $((OPTIND - 1))
}

parse_args "$@"

ARCH=${ARCH:-amd64}
RELEASE=${RELEASE:-bookworm}
DIR=/tmp/debootstrap
ARCHIVES=${DIR}/var/cache/apt/archives
OUTPUT_TAR_PATH="/builds/sysroot-$ARCH.tar.gz"

EXCLUDE_PATHS=${EXCLUDE_PATHS:-"usr/share/,usr/lib/llvm-15/build"}

declare -A paths_to_exclude
IFS=', ' read -r -a exclude_arr <<<"$EXCLUDE_PATHS"
for path in "${exclude_arr[@]}"; do
  if [ -n "${path}" ]; then
    paths_to_exclude["${path}"]=true
  fi
done

join_by() {
  local IFS="$1"
  shift
  echo "$*"
}

INCLUDE_PKGS=(
  openssh-server
  curl
  ca-certificates
  libtinfo6
  libc6
  libelf1
  libstdc++6
  zlib1g
  libunwind8
  liblzma-dev
  libunwind-dev
  libncurses-dev
  libc6-dev
  libelf-dev
  libgcc-12-dev
  libicu-dev
  libstdc++-12-dev
  linux-libc-dev
  zlib1g-dev
  dash
  bash
  grep
  gawk
  sed
  libc-bin
  binutils
  diffutils
  busybox-static
  coreutils
  iproute2
  git
  vim
)

EXCLUDE_PKGS=(
  dpkg
  libnsl-dev
  rpcsvc-proto
)

DEBOOTSTRAP_PARAMS=(
  --arch=$ARCH
  --include="$(join_by "," "${INCLUDE_PKGS[@]}")"
  --exclude="$(join_by "," "${EXCLUDE_PKGS[@]}")"
  --download-only
  --components=main,contrib,non-free,non-free-firmware
  "$RELEASE"
  "$DIR"
)

relativize_symlinks() {
  dir="$1"
  libdirs=("lib" "lib64" "usr/lib")
  pushd "${dir}" >/dev/null

  while read -r link target; do
    # Skip links targeting non-absolute paths.
    if [[ "${target}" != "/"* ]]; then
      continue
    fi
    # Remove all non-"/" characters from the link name. Then replace each "/" with "../".
    prefix=$(echo "${link}" | sed -e 's|[^/]||g' | sed -e 's|/|../|g')
    ln -snf "${prefix}${target}" "${link}"
  done < <(find "${libdirs[@]}" -type l -printf '%p %l\n')
  popd >/dev/null
}

create_root_cert() {
  root_dir="$1"
  combined_certs="$(find "${root_dir}/usr/share/ca-certificates" -type f -name '*.crt' -exec cat {} +)"
  if [ -n "${combined_certs}" ]; then
    # Only create the root cert file if there were certificates in the ca-certificates directory.
    echo "${combined_certs}" >"${root_dir}/etc/ssl/certs/ca-certificates.crt"
  fi
}

install_bcc() {
  root_dir="$1"
  if [[ ! -d "/bcc" ]]; then
    echo "Not found bcc at /bcc, skip to install"
    return 0
  fi
  echo "Installing BCC at $(realpath $root_dir)..."
  target_dir=$(realpath $root_dir)
  cp -r /bcc/usr/include/bcc $target_dir/usr/include/bcc
  cp -r /bcc/usr/lib/x86_64-linux-gnu/libbcc* $target_dir/usr/lib/x86_64-linux-gnu
}

install_go() {
  root_dir="$1"
  curl -sSLo go.tar.gz https://go.dev/dl/go1.21.3.linux-amd64.tar.gz &&
    tar -xf go.tar.gz -C $(realpath $root_dir)/usr && rm -f go.tar.gz
}

inside_tmpdir() {
  root_dir="root"
  while read -r deb; do
    echo "Installing $deb..."
    dpkg-deb -x "${deb}" "${root_dir}" &>/dev/null
  done < <(ls -- *.deb)

  create_root_cert "${root_dir}"

  install_bcc "${root_dir}"
  install_go "${root_dir}"

  for dir in "${!extra_dirs[@]}"; do
    mkdir -p "${root_dir}/${dir}"
  done

  for path in "${!paths_to_exclude[@]}"; do
    echo "Removing ${path} from sysroot"
    rm -rf "${root_dir:?}/${path:?}"
  done

  relativize_symlinks "${root_dir}"

  # Pick a deterministic mtime so that the sha sums only change if there are actual changes to the sysroot.
  tar --mtime="2023-01-01 00:00:00 UTC" -C "${root_dir}" -czf "${OUTPUT_TAR_PATH}" .
}

tmpdir="$(mktemp -d)"
pushd "${tmpdir}" >/dev/null

debootstrap "${DEBOOTSTRAP_PARAMS[@]}" &&
  echo "Debootstrap completed!" &&
  cp -r ${ARCHIVES}/*.deb .

inside_tmpdir

popd >/dev/null
rm -rf "${tmpdir}" "${DIR}"
