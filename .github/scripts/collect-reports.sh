#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 LianXia233
#
# collect-reports.sh —— 汇总移植与构建报告（在 wrt 根目录执行，always()）

set -uo pipefail

WRT_DIR="$PWD"
REPORT_DIR="${GITHUB_WORKSPACE:-$WRT_DIR}/build-reports"
mkdir -p "$REPORT_DIR"

# 基线与配置快照
git rev-parse HEAD > "$REPORT_DIR/base-commit.txt" 2>/dev/null || true
[ -f .config ] && cp .config "$REPORT_DIR/config.txt"

# 内核版本（从产物 manifest 抓取，供 Release 说明）
find bin/targets -name '*.manifest' 2>/dev/null | head -n1 | xargs -r grep -hoP '^kernel - \K[\d\.]+' \
	> "$REPORT_DIR/kernel-version.txt" || true

# 编译失败断点：串行 V=s 日志的最后 500 行最有价值
for log in "$REPORT_DIR"/parallel.log "$REPORT_DIR"/serial.log; do
	if [ -f "$log" ] && [ "$(wc -l < "$log")" -gt 800 ]; then
		tail -n 500 "$log" > "${log%.log}.tail.txt"
		grep -nE 'Error [0-9]+|error:|undefined reference|No rule to make target' "$log" \
			| tail -n 100 > "${log%.log}.errors.txt" || true
	fi
done

# ccache 统计
[ -x ./staging_dir/host/bin/ccache ] && ./staging_dir/host/bin/ccache -s > "$REPORT_DIR/ccache.txt" 2>/dev/null

echo "[reports] 报告目录：$REPORT_DIR"
ls -la "$REPORT_DIR" 2>/dev/null | head -20
