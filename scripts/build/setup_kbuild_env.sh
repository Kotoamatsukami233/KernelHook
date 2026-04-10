#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Set up a kbuild environment for building out-of-tree GKI modules.
#
# Installs host toolchain (if apt available), clones kernel source (if
# KERNEL_DIR is empty), runs defconfig + modules_prepare + vmlinux.
#
# Toolchain compatibility is handled by the CI matrix: older kernels
# (5.10, 5.15) run on ubuntu-22.04 (clang-14), newer on ubuntu-24.04.
#
# Required env:
#   BRANCH       — GKI branch (e.g., android14-6.1)
#   KERNEL_DIR   — where to clone/find kernel source
#   KERNEL_OUT   — kernel output directory (O=)
#
# Optional env:
#   SKIP_APT=1   — skip apt install (for local use on non-Debian hosts)

set -euo pipefail

: "${BRANCH:?BRANCH is required (e.g., android14-6.1)}"
: "${KERNEL_DIR:?KERNEL_DIR is required}"
: "${KERNEL_OUT:?KERNEL_OUT is required}"

# ---------- Host toolchain ----------

if [ "${SKIP_APT:-0}" != "1" ] && command -v apt-get >/dev/null 2>&1; then
    echo "==> Installing host toolchain"
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        bc bison flex libssl-dev libelf-dev libdw-dev cpio kmod python3 ccache \
        clang lld llvm llvm-dev \
        gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu \
        rsync zstd xz-utils \
        dwarves

    # Kernel 5.10 needs clang <= 13 (stack_pointer.h global register var).
    # Ubuntu 22.04 ships clang-14 by default; install clang-12 for 5.10.
    KVER="${BRANCH##*-}"
    KVER_MAJOR="${KVER%%.*}"
    KVER_MINOR="${KVER#*.}"
    if [ "$KVER_MAJOR" -eq 5 ] && [ "$KVER_MINOR" -le 10 ] 2>/dev/null; then
        echo "==> Kernel $KVER: installing clang-12 for compatibility"
        sudo apt-get install -y --no-install-recommends clang-12 lld-12 llvm-12
        LLVM_VER=-12
    fi

    # Persist LLVM version suffix for build step
    if [ -n "${LLVM_VER:-}" ] && [ -n "${GITHUB_ENV:-}" ]; then
        echo "LLVM_VER=$LLVM_VER" >> "$GITHUB_ENV"
    fi

    clang${LLVM_VER:-} --version
    ld.lld${LLVM_VER:-} --version
fi

# ---------- Kernel source ----------

if [ ! -d "$KERNEL_DIR/.git" ]; then
    echo "==> Cloning kernel/common branch $BRANCH"
    git clone --depth=1 --single-branch \
        --branch "$BRANCH" \
        https://android.googlesource.com/kernel/common "$KERNEL_DIR"
else
    echo "==> Kernel source already present at $KERNEL_DIR"
fi

# ---------- Check for cached build output ----------

if [ -f "$KERNEL_OUT/Module.symvers" ] && [ -f "$KERNEL_OUT/.config" ]; then
    echo "==> Cached build output found, skipping configure + vmlinux build"
    make -C "$KERNEL_DIR" O="$KERNEL_OUT" ARCH=arm64 LLVM="${LLVM_VER:-1}" \
         modules_prepare -j"$(nproc)"
    echo "==> Kbuild environment ready (cached)"
    exit 0
fi

# ---------- Configure ----------

if [ -f "$KERNEL_DIR/arch/arm64/configs/gki_defconfig" ]; then
    CFG=gki_defconfig
else
    CFG=defconfig
fi
echo "==> Configuring with $CFG"
make -C "$KERNEL_DIR" O="$KERNEL_OUT" ARCH=arm64 LLVM="${LLVM_VER:-1}" "$CFG"

# Kernel 6.12+ needs pahole >= 1.26 for BTF; Ubuntu 24.04 has 1.25.
# We only need Module.symvers for out-of-tree builds, not BTF.
KVER="${BRANCH##*-}"
KVER_MAJOR="${KVER%%.*}"
KVER_MINOR="${KVER#*.}"
if [ "$KVER_MAJOR" -ge 6 ] && [ "$KVER_MINOR" -ge 12 ] 2>/dev/null; then
    echo "==> Disabling BTF for kernel $KVER (pahole too old)"
    "$KERNEL_DIR/scripts/config" --file "$KERNEL_OUT/.config" --disable DEBUG_INFO_BTF
    make -C "$KERNEL_DIR" O="$KERNEL_OUT" ARCH=arm64 LLVM="${LLVM_VER:-1}" olddefconfig
fi

# ---------- modules_prepare ----------

echo "==> modules_prepare"
make -C "$KERNEL_DIR" O="$KERNEL_OUT" ARCH=arm64 LLVM="${LLVM_VER:-1}" \
     modules_prepare -j"$(nproc)"

# ---------- vmlinux (for Module.symvers) ----------

echo "==> Building vmlinux (for Module.symvers)"
make -C "$KERNEL_DIR" O="$KERNEL_OUT" ARCH=arm64 LLVM="${LLVM_VER:-1}" \
     vmlinux -j"$(nproc)" || \
make -C "$KERNEL_DIR" O="$KERNEL_OUT" ARCH=arm64 LLVM="${LLVM_VER:-1}" \
     Image -j"$(nproc)"

echo "==> Kbuild environment ready"
