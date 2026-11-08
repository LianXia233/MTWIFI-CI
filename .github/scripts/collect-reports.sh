#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# collect-reports.sh —— 汇总移植与构建报告（在构建失败或成功时都执行）
#
# 基准约定（全脚本单一基准，避免路径混用）：
#   BASE   = 本仓库 checkout 根目录，默认取 $GITHUB_WORKSPACE
#   WRT    = $BASE/wrt          固定基线树（工作流用软链固定到该路径）
#   REPORT = $BASE/build-reports 报告输出目录
# 脚本不依赖调用时的 cwd，可在任意目录执行。

set -uo pipefail

BASE="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
WRT="$BASE/wrt"
REPORT="$BASE/build-reports"
mkdir -p "$REPORT"

log() { echo "[reports] $*"; }

# ---------------------------------------------------------------------------
# 基线提交：BASE_COMMIT 由工作流在固定快照时写入环境；同时记录看到的 HEAD，
# 两者不一致时说明快照被改动过，直接写出来而不是只留一份含糊的哈希。
# ---------------------------------------------------------------------------
{
	echo "base_commit=${BASE_COMMIT:-unknown}"
	echo "wrt_head=$(git -C "$WRT" rev-parse HEAD 2>/dev/null || echo unavailable)"
	echo "repo_head=$(git -C "$BASE" rev-parse HEAD 2>/dev/null || echo unavailable)"
	echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$REPORT/base-commit.txt"

# 合成后的构建配置
if [ -f "$WRT/.config" ]; then
	cp -f "$WRT/.config" "$REPORT/config.txt"
else
	echo "missing: $WRT/.config" > "$REPORT/config.txt"
fi

# ---------------------------------------------------------------------------
# 内核版本：优先取产物 manifest（构建成功才有），并始终写入声明版本，
# 保证构建失败时该文件也有可核对的内容。
# ---------------------------------------------------------------------------
MAKEFILE="$WRT/target/linux/mediatek/Makefile"
DECLARED=""
[ -f "$MAKEFILE" ] && DECLARED=$(sed -n 's/^KERNEL_PATCHVER:=//p' "$MAKEFILE" | head -n1 | tr -d ' \t')
KDIR=$(ls -d "$WRT"/build_dir/target-*/linux-*/linux-* 2>/dev/null | head -n1)
{
	MANIFEST=$(find "$WRT/bin/targets" -name '*.manifest' 2>/dev/null | head -n1)
	if [ -n "${MANIFEST:-}" ]; then
		printf 'manifest_kernel=%s\n' \
			"$(grep -hoP '^kernel - \K[^ ]+' "$MANIFEST" 2>/dev/null | head -n1)"
	else
		echo "manifest_kernel=unavailable (no manifest in $WRT/bin/targets)"
	fi
	echo "declared_patchver=${DECLARED:-unknown}"
	if [ -n "${KDIR:-}" ]; then
		echo "kernel_dir=$(basename "$KDIR")"
	else
		echo "kernel_dir=unavailable"
	fi
} > "$REPORT/kernel-version.txt"

# ---------------------------------------------------------------------------
# 编译断点：并行日志给出首次失败，串行 V=s 日志给出可定位的断点。
# 无论是否命中，文件里都写一行状态，便于直接判断"没有断点"还是"没采到"。
# ---------------------------------------------------------------------------
for log in "$REPORT/parallel.log" "$REPORT/serial.log"; do
	if [ -f "$log" ] && [ "$(wc -l < "$log")" -gt 800 ]; then
		tail -n 500 "$log" > "${log%.log}.tail.txt"
		grep -nE 'Error [0-9]+|error:|undefined reference|No rule to make target' "$log" \
			| tail -n 100 > "${log%.log}.errors.txt" || true
	fi
done

{
	echo "# 内核补丁 / 代码断点（来源：build-reports/serial.log）"
	if [ -f "$REPORT/serial.log" ]; then
		HITS=$(grep -nE 'Patch failed!|Please fix |Hunk #[0-9]+ FAILED|Applying .*patches-|Error [0-9]+' \
			"$REPORT/serial.log" | tail -n 120)
		if [ -n "$HITS" ]; then
			printf '%s\n' "$HITS"
		else
			echo "no breakpoint pattern matched in serial.log ($(wc -l < "$REPORT/serial.log") lines)"
		fi
	else
		echo "serial.log absent: parallel build did not fall back (no compile breakpoint captured)"
	fi
} > "$REPORT/patch-breakpoints.txt"

# ccache 统计
CCACHE="$WRT/staging_dir/host/bin/ccache"
[ -x "$CCACHE" ] && "$CCACHE" -s > "$REPORT/ccache.txt" 2>/dev/null

log "报告目录：$REPORT"
ls -la "$REPORT" 2>/dev/null | head -20
