#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# host-setup.sh —— 编译宿主准备（root 执行）：系统精简、依赖安装、时区

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get -yqq purge firefox >/dev/null 2>&1 || true
apt-get -yqq update
apt-get -yqq full-upgrade
apt-get -yqq autoremove --purge
apt-get -yqq autoclean
apt-get -yqq clean

apt-get install -y --no-install-recommends \
	bc bison build-essential bzip2 ca-certificates ccache clang \
	cmake cpio curl device-tree-compiler dos2unix file flex \
	g++-multilib gawk gcc-multilib genisoimage gettext git jq \
	libbpf-dev libclang-dev libdw-dev libelf-dev libncurses-dev libssl-dev lld \
	llvm ninja-build patch perl pkgconf python3 python3-cryptography \
	python3-dev python3-packaging python3-pyelftools python3-setuptools \
	qemu-utils rsync swig unzip wget xz-utils zlib1g-dev zstd

# rustup（runner 自带，缺了补上；Rust 插件引导用）
if ! command -v rustup >/dev/null 2>&1 && [ ! -x "$HOME/.cargo/bin/rustup" ]; then
	curl -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
fi

timedatectl set-timezone "Asia/Shanghai" 2>/dev/null || true

# 编译目录放系统盘根，规避 runner 主盘 14G 空间瓶颈
mkdir -p /mnt/build_wrt
chown "${USER:-runner}:${USER:-runner}" /mnt/build_wrt
echo "[host] 编译宿主就绪：$(nproc) 核 / $(df -h /mnt | awk 'NR==2{print $4}') 可用于 /mnt"
