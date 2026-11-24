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
TARGET_LIBDIR=$("$RUST_ROOT/bin/rustc" --print target-libdir --target "$RUST_TARGET")
printf 'target-libdir: %s\n' "$TARGET_LIBDIR" | tee -a "$REPORT_DIR/rust-toolchain.txt"
test -d "$TARGET_LIBDIR"

# cargo 默认从 PATH 找 rustc；CI 里 staging_dir/host* 会被缓存恢复覆盖，符号链接
# 可能指向旧工具链，cargo 因此找不到 rustup target add 刚装进当前 sysroot 的
# target std（E0463: can't find crate for `core`）。把包内 cargo/rustc 固定到
# 本次引导的 sysroot，绕开 PATH 与缓存的不确定性。
MT5700_MK="$PWD/package/luci-app-mt5700/src/Makefile"
if [ -f "$MT5700_MK" ]; then
	python3 - "$MT5700_MK" "$RUST_ROOT" <<'PY'
import re, sys
path, root = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
pat = re.compile(r"(?m)^\t\tcargo build ")
if not pat.search(s):
    raise SystemExit("[rust] mt5700 src/Makefile 未找到 cargo build 行")
line = (f'\t\tRUSTC="{root}/bin/rustc" RUSTDOC="{root}/bin/rustdoc" '
        f'"{root}/bin/cargo" build ')
s, n = pat.subn(line, s, count=1)
open(path, "w", encoding="utf-8", newline="").write(s)
print(f"[rust] mt5700: cargo/rustc 固定到 {root}（替换 {n} 处）")
PY
fi

# luci-app-fm350 在自己的 Makefile 里直接调 cargo（不经过 src/Makefile）。
# 同样固定到本次 rustup sysroot；变量必须在 $(eval BuildPackage) 之前赋值，
# 否则 Build/Compile 展开时仍会拿到 cargo/rustc 的 PATH 版本。
FM350_MK="$PWD/package/luci-app-fm350/Makefile"
if [ -f "$FM350_MK" ]; then
	python3 - "$FM350_MK" "$RUST_ROOT" <<'PY'
import sys
path, root = sys.argv[1], sys.argv[2]
s = open(path, encoding="utf-8").read()
marker = "# CI-RUST-SYSROOT(fm350)"
if marker in s:
    print("[rust] fm350: 已固定过 sysroot，跳过")
    raise SystemExit(0)
anchor = "$(eval $(call BuildPackage,$(PKG_NAME)))"
if anchor not in s:
    raise SystemExit("[rust] fm350 Makefile 未找到 BuildPackage 锚点")
block = f"""{marker}
# 由 .github/scripts/rust-toolchain.sh 注入：固定官方 rustup 工具链，
# 避免 PATH 上被缓存覆盖的 staging cargo/rustc 导致 E0463。
CARGO := {root}/bin/cargo
export RUSTC := {root}/bin/rustc
export RUSTDOC := {root}/bin/rustdoc

"""
open(path, "w", encoding="utf-8", newline="").write(
    s.replace(anchor, block + anchor, 1))
print(f"[rust] fm350: cargo/rustc 固定到 {root}")
PY
fi

echo "[rust] 已接入 runner 工具链：$RUST_TOOLCHAIN -> $RUST_TARGET"
