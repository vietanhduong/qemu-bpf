#!/bin/bash

# KERNEL_VERSIONS=($(curl -sSL https://raw.githubusercontent.com/vietanhduong/kernel-builder/master/KERNEL_VERSIONS))

function required {
  if [[ -z "${!1}" ]]; then
    echo "The environment variable $1 is needs to be set" >&2
    exit 1
  fi
}

required KERNEL_VERSION
required DOCKER_BASE_IMAGE

ARCH=${ARCH:-amd64}
DEBIAN_RELEASE=${DEBIAN_RELEASE:-bookworm}

REPO_ROOT=$(git rev-parse --show-toplevel)
BUILDS_DIR="${REPO_ROOT}/.builds"
OUTPUT_NAME="qemu-${KERNEL_VERSION}"
SYSROOT="${BUILDS_DIR}/sysroot-$ARCH.tar.gz"
OUTPUT_DISK="${BUILDS_DIR}/${OUTPUT_NAME}.qcow2"
KERNEL_PACKAGE="${BUILDS_DIR}/linux-build.tar.gz"
BUSYBOX="${BUILDS_DIR}/busybox"

INSTALL_GO=${INSTALL_GO:-true}
INSTALL_BCC=${INSTALL_BCC:-true}

FS_TYPE=ext4
DISK_SIZE="4096M"

# Download the kernel package from kernel-builder repo
curl -s https://api.github.com/repos/vietanhduong/kernel-builder/releases/latest |
  grep "browser_download_url.*.tar.gz" |
  grep "${KERNEL_VERSION}" |
  cut -d : -f 2,3 |
  tr -d \" |
  xargs -n1 curl -sSLo $KERNEL_PACKAGE

# Download busybox
curl -sSLo $BUSYBOX https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox

mkdir -p $BUILDS_DIR &&
  sudo rm -f "${SYSROOT}"

docker run --rm -v $BUILDS_DIR:/builds -v ./build-sysroot.sh:/scripts/build-sysroot.sh \
  -e INSTALL_GO=${INSTALL_GO} \
  -e INSTALL_BCC=${INSTALL_BCC} \
  $DOCKER_BASE_IMAGE -a "$ARCH" -r "${DEBIAN_RELEASE}" &&
  sudo chown $USER:$USER $SYSROOT

build_dir=$(mktemp -d)
echo "tmp: $build_dir" # for debug

sysroot_build_dir="${build_dir}/sysroot"
mkdir -p "${sysroot_build_dir}"

tar -C "${sysroot_build_dir}" -xf "${SYSROOT}"

# Extract the kernel modules.
tar -C "${sysroot_build_dir}" -xf "${KERNEL_PACKAGE}" \
  --strip-components=2 pkg/root

cp "${REPO_ROOT}/init" "${sysroot_build_dir}/bin/init"
cp "${REPO_ROOT}/hostname" "${sysroot_build_dir}/etc/hostname"
cp "${REPO_ROOT}/passwd" "${sysroot_build_dir}/etc/passwd"
cp "${BUSYBOX}" "${sysroot_build_dir}/bin/busybox"
chmod +x "${sysroot_build_dir}/bin/busybox"

tmpdisk_image="$(mktemp --suffix .img)"

# We need the files to be owned by root so we unshare
# and then chown the sysroot files before building the FS.
unshare -r bash <<EOF

chroot "${sysroot_build_dir}" /bin/busybox --install -s /bin

chown -R 0:0 "${sysroot_build_dir}"

# Actually create the file system.
mke2fs \
  -q \
  -L '' \
  -O ^64bit \
  -d "${sysroot_build_dir}" \
  -m 5 \
  -r 1 \
  -t "${FS_TYPE}" \
  -E root_owner=0:0 \
  "${tmpdisk_image}" \
  "${DISK_SIZE}"
EOF

qemu-img convert \
  -f raw -O qcow2 \
  "${tmpdisk_image}" "${OUTPUT_DISK}"

rm -f "${tmpdisk_image}"
rm -rf "${build_dir}"
