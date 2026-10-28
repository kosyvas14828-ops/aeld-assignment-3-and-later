#!/bin/bash
# Script outline to install and build kernel.
# Author: Siddhant Jajoo.

set -e
set -u

OUTDIR=${1:-/tmp/aeld}
OUTDIR=$(realpath -m "${OUTDIR}")
KERNEL_REPO=https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
KERNEL_VERSION=v5.15.163
BUSYBOX_VERSION=1_33_stable
FINDER_APP_DIR=$(realpath "$(dirname "$0")")
SRC_ROOT=$(realpath "${FINDER_APP_DIR}/..")
ARCH=arm64
CROSS_COMPILE=aarch64-none-linux-gnu-

if [ $# -lt 1 ]
then
	echo "Using default directory ${OUTDIR} for output"
else
	echo "Using passed directory ${OUTDIR} for output"
fi

mkdir -p "${OUTDIR}"

cd "${OUTDIR}"
if [ ! -d "${OUTDIR}/linux-stable" ]; then
    echo "CLONING GIT LINUX STABLE VERSION ${KERNEL_VERSION} IN ${OUTDIR}"
    git clone --depth 1 --single-branch --branch "${KERNEL_VERSION}" "${KERNEL_REPO}" "${OUTDIR}/linux-stable"
fi
if [ ! -e "${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image" ]; then
    cd "${OUTDIR}/linux-stable"
    echo "Checking out version ${KERNEL_VERSION}"
    git checkout "${KERNEL_VERSION}"
    make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" defconfig
    make -j"$(nproc)" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" Image
fi

cp "${OUTDIR}/linux-stable/arch/${ARCH}/boot/Image" "${OUTDIR}/Image"

echo "Adding the Image in outdir"

echo "Creating the staging directory for the root filesystem"
cd "${OUTDIR}"
if [ -d "${OUTDIR}/rootfs" ]
then
	echo "Deleting rootfs directory at ${OUTDIR}/rootfs and starting over"
    rm -rf "${OUTDIR}/rootfs"
fi

mkdir -p "${OUTDIR}/rootfs"
for dir in bin dev etc home proc sbin sys tmp usr var lib; do
    mkdir -p "${OUTDIR}/rootfs/${dir}"
done
mkdir -p "${OUTDIR}/rootfs/home/conf"

cd "${OUTDIR}"
if [ ! -d "${OUTDIR}/busybox" ]
then
    git clone git@github.com:mirror/busybox.git "${OUTDIR}/busybox"
    cd "${OUTDIR}/busybox"
    git checkout "${BUSYBOX_VERSION}"
    make distclean
    make ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" defconfig
else
    cd "${OUTDIR}/busybox"
fi

make -j"$(nproc)" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}"
make CONFIG_PREFIX="${OUTDIR}/rootfs" ARCH="${ARCH}" CROSS_COMPILE="${CROSS_COMPILE}" install

echo "Library dependencies"
${CROSS_COMPILE}readelf -l "${OUTDIR}/rootfs/bin/busybox" | grep "program interpreter" || true
${CROSS_COMPILE}readelf -d "${OUTDIR}/rootfs/bin/busybox" | grep "Shared library" || true

SYSROOT=$(${CROSS_COMPILE}gcc -print-sysroot)
SYSROOT=$(readlink -f "${SYSROOT}")
INTERPRETER=$(${CROSS_COMPILE}readelf -l "${OUTDIR}/rootfs/bin/busybox" | awk '/program interpreter/ {print $NF}' | tr -d '[]')
LIBS=$(${CROSS_COMPILE}readelf -d "${OUTDIR}/rootfs/bin/busybox" | awk '/Shared library/ {print $NF}' | tr -d '[]' | sort -u)

for lib in ${INTERPRETER} ${LIBS}; do
    lib_name=$(basename "${lib}")
    lib_target_dir=$(dirname "${lib}")
    if [ "${lib_target_dir}" = "." ]; then
        lib_target_dir="/lib"
    fi
    src=$(find "${SYSROOT}" -path "*/${lib_name}" 2>/dev/null | head -n 1)
    if [ -n "${src}" ]; then
        mkdir -p "${OUTDIR}/rootfs${lib_target_dir}"
        cp -a "${src}" "${OUTDIR}/rootfs${lib_target_dir}/${lib_name}"
    else
        echo "Warning: could not locate ${lib_name} in ${SYSROOT}"
    fi
done

# Copy the full ARM sysroot library directories; aarch64 commonly places libc/libm in /lib64.
for libdir in lib lib64; do
    if [ -d "${SYSROOT}/${libdir}" ]; then
        mkdir -p "${OUTDIR}/rootfs/${libdir}"
        cp -a "${SYSROOT}/${libdir}/." "${OUTDIR}/rootfs/${libdir}/"
    fi
done

if command -v sudo >/dev/null 2>&1; then
    SUDO=sudo
else
    SUDO=
fi

${SUDO} mknod -m 666 "${OUTDIR}/rootfs/dev/null" c 1 3
${SUDO} mknod -m 666 "${OUTDIR}/rootfs/dev/console" c 5 1

make -C "${FINDER_APP_DIR}" clean all CROSS_COMPILE="${CROSS_COMPILE}"
cp "${FINDER_APP_DIR}/writer" "${OUTDIR}/rootfs/home/"
cp "${FINDER_APP_DIR}/finder.sh" "${OUTDIR}/rootfs/home/"
cp "${FINDER_APP_DIR}/finder-test.sh" "${OUTDIR}/rootfs/home/"
cp "${FINDER_APP_DIR}/autorun-qemu.sh" "${OUTDIR}/rootfs/home/"
cp -r "${SRC_ROOT}/conf" "${OUTDIR}/rootfs/home/"

sed -i 's#\.\./conf/assignment\.txt#conf/assignment.txt#' "${OUTDIR}/rootfs/home/finder-test.sh"
chmod +x "${OUTDIR}/rootfs/home/finder.sh" "${OUTDIR}/rootfs/home/finder-test.sh" "${OUTDIR}/rootfs/home/autorun-qemu.sh" "${OUTDIR}/rootfs/home/writer"

${SUDO} chown -R root:root "${OUTDIR}/rootfs"

cd "${OUTDIR}/rootfs"
find . -print | cpio -H newc -ov --owner root:root | gzip -9 > "${OUTDIR}/initramfs.cpio.gz"
