import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
let mt76;

for (let i = 0; i < args.length; i += 2) {
	if (args[i] === '--mt76' && args[i + 1]) mt76 = resolve(args[i + 1]);
	else {
		console.error(`usage: node ${relative(root, fileURLToPath(import.meta.url))} [--mt76 PATH]`);
		process.exit(2);
	}
}

function files(path) {
	return readdirSync(path).flatMap(name => {
		const child = join(path, name);
		return statSync(child).isDirectory() ? files(child) : [child];
	});
}

const projectFiles = files(root);
for (const path of projectFiles) {
	const data = readFileSync(path);
	if (data.includes(13)) throw new Error(`CRLF found: ${relative(root, path)}`);
}

const requirements = {
	'configs/h5000m.config': [
		'CONFIG_TARGET_mediatek_filogic_DEVICE_hiveton_h5000m=y',
		'CONFIG_PACKAGE_kmod-mt7996e=y',
		'CONFIG_PACKAGE_kmod-mt7992-23-firmware=y',
		'CONFIG_PACKAGE_mtwifi-mainline=y',
		'CONFIG_PACKAGE_kmod-nft-offload=y',
		'# CONFIG_PACKAGE_bridger is not set',
	],
	'configs/ap3000m.config': [
		'CONFIG_TARGET_mediatek_filogic_DEVICE_airpi_ap3000m=y',
		'CONFIG_PACKAGE_kmod-mt7915e=y',
		'CONFIG_PACKAGE_kmod-mt7981-firmware=y',
		'CONFIG_PACKAGE_mt7981-wo-firmware=y',
		'CONFIG_PACKAGE_mtwifi-mainline=y',
		'CONFIG_PACKAGE_kmod-nft-offload=y',
		'# CONFIG_PACKAGE_bridger is not set',
	],
};

for (const [path, lines] of Object.entries(requirements)) {
	const text = readFileSync(join(root, path), 'utf8');
	for (const line of lines) {
		if (!text.includes(line)) throw new Error(`${path} missing ${line}`);
	}
	if (/^CONFIG_PACKAGE_kmod-mt_wifi7?=y$/m.test(text)) {
		throw new Error(`${path} enables the vendor driver`);
	}
}

const buildScript = readFileSync(join(root, 'scripts/build.sh'), 'utf8');
for (const text of ['export MSYS_NO_PATHCONV=1', "export MSYS2_ARG_CONV_EXCL='*'", 'cygpath -m "$ROOT"', 'cygpath -m "$SOURCE"', '/home/*|/mnt/[a-z]/*) source_wsl=$SOURCE']) {
	if (!buildScript.includes(text)) throw new Error(`Windows WSL launcher missing ${text}`);
}

const packageRoot = join(root, 'package/mtwifi-mainline');
for (const path of [
	'files/etc/modprobe.d/mt7915e.conf',
	'files/etc/modprobe.d/mt7996e.conf',
	'files/etc/uci-defaults/90-mtwifi-offload',
	'files/usr/sbin/mtwifi-offload-status',
]) {
	if (!statSync(join(packageRoot, path)).isFile()) throw new Error(`Missing package file: ${path}`);
}

const packageMakefile = readFileSync(join(packageRoot, 'Makefile'), 'utf8');
for (const text of [
	'PKG_NAME:=mtwifi-mainline',
	'include $(INCLUDE_DIR)/package.mk',
	'DEPENDS:=+firewall4 +ethtool +nftables +kmod-nft-offload',
]) {
	if (!packageMakefile.includes(text)) throw new Error(`Package Makefile missing ${text}`);
}

const modprobe = readFileSync(join(packageRoot, 'files/etc/modprobe.d/mt7915e.conf'), 'utf8');
if (!modprobe.includes('options mt7915e wed_enable=1')) {
	throw new Error('AP3000M must enable the mainline WED attach path');
}

const mt7996Modprobe = readFileSync(join(packageRoot, 'files/etc/modprobe.d/mt7996e.conf'), 'utf8');
if (!mt7996Modprobe.includes('wed_enable=1') || !mt7996Modprobe.includes('wed_rro=0')) {
	throw new Error('H5000M must use TX WED without unsupported WO RX offload');
}

const patchPath = join(root, 'patches/mt76/100-mt7996-optional-wed-rro.patch');
const patch = readFileSync(patchPath, 'utf8');
for (const text of [
	'module_param(wed_rro, bool, 0644)',
	'wed->wlan.hw_rro = wed_rro',
	'if (!hif2 && mtk_wed_get_rx_capa(wed))',
	'+\tif (!mt7996_has_hwrro(dev))\n+\t\treturn;',
	'-\t       !mtk_wed_device_active(&dev->mt76.mmio.wed) &&',
	'} else if (mtk_wed_device_active(&dev->mt76.mmio.wed)) {',
	'mtk_wed_device_start(&dev->mt76.mmio.wed, wed_irq_mask);',
	'+\tif (mtk_wed_device_active(&dev->mt76.mmio.wed) &&\n+\t    mt7996_has_hwrro(dev)) {',
]) {
	if (!patch.includes(text)) throw new Error(`Patch missing ${text}`);
}

if (mt76) {
	const scratch = mkdtempSync(join(tmpdir(), 'mtwifi-patch-'));
	try {
		mkdirSync(join(scratch, 'mt7996'), { recursive: true });
		for (const file of ['mmio.c', 'dma.c', 'main.c', 'mac.c']) {
			const source = readFileSync(join(mt76, 'mt7996', file), 'utf8').replaceAll('\r\n', '\n');
			writeFileSync(join(scratch, 'mt7996', file), source, { encoding: 'utf8', flag: 'w' });
		}
		const result = spawnSync('git', ['apply', '--check', patchPath], { cwd: scratch, encoding: 'utf8' });
		if (result.status !== 0) throw new Error(result.stderr || result.stdout || 'git apply --check failed');
	} finally {
		rmSync(scratch, { recursive: true, force: true });
	}
}

console.log(`Verified ${projectFiles.length} files; LF, profiles, package contents and patch checks passed.`);
