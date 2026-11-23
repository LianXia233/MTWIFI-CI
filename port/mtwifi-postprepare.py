#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# legacy mt_wifi（7.6.7.3 tarball）6.18 适配。由包内 Hooks/Prepare/Post 调用，
# 在 Build/Prepare 解包并应用 chasey patches-7673（001..041）之后就地修改。
#
# 之所以不在 patches-7673 里追加 quilt 补丁：该包的 Makefile/config.mk 在
# OpenWrt 的 prepare 流程里会被 chasey 补丁按不同上下文改写，追加的 050/051
# 在 CI 上出现过 hunk 全部失配（本地同样的 tarball+41 补丁却能应用），
# 这里改成幂等的后处理脚本，既避开上下文漂移，也便于断言。

import os
import sys

root = sys.argv[1]

def path(rel):
    return os.path.join(root, rel)

def read(rel):
    p = path(rel)
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8", errors="replace", newline="") as f:
        return f.read()

def write(rel, s):
    with open(path(rel), "w", encoding="utf-8", newline="") as f:
        f.write(s)

def sub(rel, old, new, required=True):
    s = read(rel)
    if s is None:
        if required:
            raise SystemExit("missing file: " + rel)
        return False
    if old not in s:
        return False
    write(rel, s.replace(old, new))
    return True

def must(cond, msg):
    if not cond:
        raise SystemExit("mtwifi-postprepare: " + msg)

# ---------------------------------------------------------------------------
# 1. 关掉源码自带的 -Werror；追加 GCC14 三类降级；强制 KTHREAD_SUPPORT
# ---------------------------------------------------------------------------
mk = read("mt_wifi_ap/Makefile")
must(mk is not None, "mt_wifi_ap/Makefile 不存在")
if "-Werror" in mk:
    mk = mk.replace("-Werror", "-Wno-error")
    write("mt_wifi_ap/Makefile", mk)
mk = read("mt_wifi_ap/Makefile")
must("-Werror" not in mk, "mt_wifi_ap/Makefile 仍有 -Werror")

cfg = read("mt_wifi/os/linux/config.mk")
if cfg is not None and "-Werror" in cfg:
    write("mt_wifi/os/linux/config.mk", cfg.replace("-Werror", "-Wno-error"))

gcc14 = ("ccflags-y += -Wno-error=incompatible-pointer-types "
         "-Wno-error=int-conversion -Wno-error=return-mismatch\n"
         "EXTRA_CFLAGS += -Wno-error=incompatible-pointer-types "
         "-Wno-error=int-conversion -Wno-error=return-mismatch\n")
mk = read("mt_wifi_ap/Makefile")
if "Wno-error=incompatible-pointer-types" not in mk:
    mk = mk.rstrip("\n") + "\n\n" + gcc14
    write("mt_wifi_ap/Makefile", mk)

anchor = ("ifeq ($(CONFIG_KTHREAD),y)\n"
          "    EXTRA_CFLAGS += -DKTHREAD_SUPPORT\n"
          "endif\n")
mk = read("mt_wifi_ap/Makefile")
if "-DKTHREAD_SUPPORT" not in mk:
    must(anchor in mk, "mt_wifi_ap/Makefile 缺 CONFIG_KTHREAD 块")
    mk = mk.replace(anchor,
                    anchor +
                    "# 6.18: kernel_thread() 已不再导出（且 5.10 起 4 参数）\n"
                    "EXTRA_CFLAGS += -DKTHREAD_SUPPORT\n", 1)
    write("mt_wifi_ap/Makefile", mk)
must("-DKTHREAD_SUPPORT" in read("mt_wifi_ap/Makefile"), "KTHREAD_SUPPORT 未生效")

# ---------------------------------------------------------------------------
# 2. trace.h：时间 API（050 的核心内容）
# ---------------------------------------------------------------------------
tr = read("mt_wifi/include/os/trace.h")
must(tr is not None, "trace.h 不存在")
if "linux/timekeeping.h" not in tr:
    tr = tr.replace("#include <linux/time.h>\n",
                    "#include <linux/time.h>\n#include <linux/timekeeping.h>\n", 1)
if "struct timeval time;" in tr:
    tr = tr.replace("struct timeval time;", "struct timespec64 time;")
if "do_gettimeofday(&time);" in tr:
    tr = tr.replace("do_gettimeofday(&time);", "ktime_get_real_ts64(&time);")
if "rtc_time_to_tm(local_time, &tm);" in tr:
    tr = tr.replace("rtc_time_to_tm(local_time, &tm);",
                    "rtc_time64_to_tm(local_time, &tm);")
write("mt_wifi/include/os/trace.h", tr)
tr = read("mt_wifi/include/os/trace.h")
must("do_gettimeofday(&time);" not in tr, "trace.h 仍有 do_gettimeofday")
must("rtc_time_to_tm(" not in tr, "trace.h 仍有 rtc_time_to_tm")

# ---------------------------------------------------------------------------
# 3. hif_pci.c：page_frag_cache 字段（6.18）
# ---------------------------------------------------------------------------
hp = read("mt_wifi/embedded/common/hif_pci.c")
must(hp is not None, "hif_pci.c 不存在")
if "linux/page_frag_cache.h" not in hp:
    must('#include "rt_config.h"\n' in hp, "hif_pci.c 缺 rt_config.h")
    hp = hp.replace('#include "rt_config.h"\n',
                    '#include "rt_config.h"\n'
                    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n"
                    "#include <linux/page_frag_cache.h>\n"
                    "#endif\n", 1)

old_pf = (
    "#if LINUX_VERSION_CODE > KERNEL_VERSION(4, 3, 0)\n"
    "\t\tif (rx_ring->buf_type == DYNAMIC_PAGE_ALLOC) {\n"
    "\n"
    "\t\t\tif (rx_ring->rx_page.va) {\n"
    "\t\t\t\tstruct page *page;\n"
    "\n"
    "\t\t\t\tpage = virt_to_page(rx_ring->rx_page.va);\n"
    "\t\t\t\trx_page_frag_cache_drain(page, rx_ring->rx_page.pagecnt_bias);\n"
    "\t\t\t\tNdisZeroMemory(&rx_ring->rx_page, sizeof(rx_ring->rx_page));\n"
    "\t\t\t}\n"
    "\t\t}\n"
    "#endif\n")
new_pf = (
    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n"
    "\t\tif (rx_ring->buf_type == DYNAMIC_PAGE_ALLOC) {\n"
    "\t\t\tpage_frag_cache_drain(&rx_ring->rx_page);\n"
    "\t\t\tNdisZeroMemory(&rx_ring->rx_page, sizeof(rx_ring->rx_page));\n"
    "\t\t}\n"
    "#else\n" + old_pf + "#endif\n")
if old_pf in hp:
    hp = hp.replace(old_pf, new_pf, 1)
must("page_frag_cache_drain(&rx_ring->rx_page)" in hp,
     "hif_pci.c 未切到 page_frag_cache_drain")
write("mt_wifi/embedded/common/hif_pci.c", hp)

# ---------------------------------------------------------------------------
# 4. netif_rx_ni → netif_rx（SNIFFER 开启时才会编译）
# ---------------------------------------------------------------------------
for rel in ("mt_wifi/os/linux/rt_profile.c",
            "mt_wifi/embedded/common/sniffer_radiotap.c"):
    s = read(rel)
    if s is not None and "netif_rx_ni(" in s:
        write(rel, s.replace("netif_rx_ni(", "netif_rx("))

# ---------------------------------------------------------------------------
# 5. rt_linux.c：del_timer_sync 改名；kill_proc 移除
# ---------------------------------------------------------------------------
rl = read("mt_wifi/os/linux/rt_linux.c")
must(rl is not None, "rt_linux.c 不存在")
if "del_timer_sync(" in rl:
    rl = rl.replace("del_timer_sync(", "timer_delete_sync(")
if "linux/sched/signal.h" not in rl:
    must("#include <linux/mm.h>\n" in rl, "rt_linux.c 缺 linux/mm.h")
    rl = rl.replace("#include <linux/mm.h>\n",
                    "#include <linux/mm.h>\n"
                    "#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 18, 0)\n"
                    "#include <linux/sched/signal.h>\n"
                    "#endif\n", 1)

print("mtwifi-postprepare: 6.18 适配完成")
