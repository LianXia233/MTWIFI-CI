// SPDX-License-Identifier: GPL-2.0
/*
 * 6.18 移植层：wifi_utility EEPROM 统一后端
 *
 * pdn 的 wifi_utility 只导出按分区名读写的 mt_mtd_read_nm_wifi() /
 * mt_mtd_write_nm_wifi()。chasey 的 legacy 栈里，conninfra 与旧版 mt_wifi
 * （767x）通过 999-zzz-5203 补丁引入的 mt_eeprom_read_wifi() /
 * mt_eeprom_write_wifi() 访问 EEPROM。
 *
 * 6.18 移植只搬了 pdn 的 wifi_utility，缺这两个符号，模块 modpost 阶段会报
 * undefined。这里补最小等价实现：先 "Factory"，失败再试小写 "factory"
 * （AP3000M 的 eMMC 分区名即 factory）。
 *
 * chasey 5203 的 OF / nvmem 读取优先级暂未移植：AP3000M 由
 * AP3000M-EEPROM/99-ap3000m-eeprom 在首启时把模板写进 factory 分区，
 * mtd 路径即可覆盖；H5000M（wifi7 栈）不调用这两个符号。
 */

#include <linux/kernel.h>
#include <linux/types.h>
#include <linux/errno.h>
#include <linux/module.h>

int mt_mtd_read_nm_wifi(char *name, loff_t from, size_t len, u_char *buf);
int mt_mtd_write_nm_wifi(char *name, loff_t to, size_t len, const u_char *buf);

int mt_eeprom_read_wifi(loff_t from, size_t len, u_char *buf);
int mt_eeprom_write_wifi(loff_t to, size_t len, const u_char *buf);

int mt_eeprom_read_wifi(loff_t from, size_t len, u_char *buf)
{
	int ret;

	if (!buf && len)
		return -EINVAL;

	ret = mt_mtd_read_nm_wifi("Factory", from, len, buf);
	if (!ret)
		return 0;

	ret = mt_mtd_read_nm_wifi("factory", from, len, buf);
	if (!ret)
		return 0;

	pr_err("mt_eeprom_read_wifi: failed from=0x%llx len=0x%zx ret=%d\n",
	       (unsigned long long)from, len, ret);
	return ret;
}
EXPORT_SYMBOL(mt_eeprom_read_wifi);

int mt_eeprom_write_wifi(loff_t to, size_t len, const u_char *buf)
{
	int ret;

	if (!buf && len)
		return -EINVAL;

	ret = mt_mtd_write_nm_wifi("Factory", to, len, buf);
	if (!ret)
		return 0;

	ret = mt_mtd_write_nm_wifi("factory", to, len, buf);
	if (!ret)
		return 0;

	pr_err("mt_eeprom_write_wifi: failed to=0x%llx len=0x%zx ret=%d\n",
	       (unsigned long long)to, len, ret);
	return ret;
}
EXPORT_SYMBOL(mt_eeprom_write_wifi);
