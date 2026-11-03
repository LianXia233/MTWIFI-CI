#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
# 基于 VIKINGYFY/CloseWRT-CI 同名机制的改编实现
#
# rust-toolchain.sh —— 用 runner 的 rustup 预置目标平台 Rust 工具链，
# 并把 feeds/packages 的 rust host 引导替换为预编译直连，
# 避免 CI 里从源码 bootstrap rustc（1h+ 的纯浪费）。
# 在 wrt 根目录执行。

set -euo pipefail

RUST_FEED="$PWD/feeds/packages/lang/rust"
RUST_MAKEFILE="$RUST_FEED/Makefile"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="${GITHUB_WORKSPACE:-$PWD}/build-reports"
mkdir -p "$REPORT_DIR"

[ -f "$RUST_MAKEFILE" ] || { echo "[rust] feeds/packages/lang/rust 不存在，跳过"; exit 0; }

# 向 feed 询问目标三元组，保证与 OpenWrt 的 musl 目标一致
RUST_TARGET=$(make --no-print-directory -s -f - TOPDIR="$PWD" ci-rust-target <<'MAKE'
include $(TOPDIR)/rules.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-values.mk
.PHONY: ci-rust-target
ci-rust-target:
	@printf '%s\n' '$(RUSTC_TARGET_ARCH)'
MAKE
)

RUSTUP_BIN=$(command -v rustup || true)
if [ -z "$RUSTUP_BIN" ] && [ -x "$HOME/.cargo/bin/rustup" ]; then
	RUSTUP_BIN="$HOME/.cargo/bin/rustup"
fi
[ -n "$RUSTUP_BIN" ] || { echo "[rust] runner 缺少 rustup" >&2; exit 1; }
PATH="$(dirname "$RUSTUP_BIN"):$PATH"
export PATH

RUST_TOOLCHAIN=$(rustup show active-toolchain | awk '{print $1}')
printf 'Rust toolchain: %s\nRust target: %s\n' "$RUST_TOOLCHAIN" "$RUST_TARGET" \
	| tee "$REPORT_DIR/rust-toolchain.txt"

rustup target add --toolchain "$RUST_TOOLCHAIN" "$RUST_TARGET"
RUST_ROOT=$(rustup run "$RUST_TOOLCHAIN" rustc --print sysroot)
test -d "$RUST_ROOT/lib/rustlib/$RUST_TARGET/lib"
for tool in cargo rustc rustdoc; do test -x "$RUST_ROOT/bin/$tool"; done

# 把源码 bootstrap 换成预编译直连（在 OpenWrt 展开 host 规则之前注入）
{
	printf 'CI_RUST_ROOT:=%s\n' "$RUST_ROOT"
	cat "$SCRIPT_DIR/rust-host.mk"
} > "$RUST_FEED/ci-prebuilt.mk"
sed -i '/^include \.\/ci-prebuilt\.mk$/d; /^$(eval $(call HostBuild))$/i include ./ci-prebuilt.mk' \
	"$RUST_MAKEFILE"
grep -Fxq 'include ./ci-prebuilt.mk' "$RUST_MAKEFILE"

"$RUST_ROOT/bin/rustc" --version | tee -a "$REPORT_DIR/rust-toolchain.txt"
echo "[rust] 已接入 runner 工具链：$RUST_TOOLCHAIN -> $RUST_TARGET"
