#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SOURCE=
DEVICE=
JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
OVERWRITE_CONFIG=0
CONFIGURE_ONLY=0

usage() {
	printf '%s\n' "usage: $0 --source PATH --device h5000m|ap3000m [--jobs N] [--overwrite-config] [--configure-only]" >&2
	exit 2
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--source)
		[ "$#" -ge 2 ] || usage
		SOURCE=$2
		shift 2
		;;
	--device)
		[ "$#" -ge 2 ] || usage
		DEVICE=$2
		shift 2
		;;
	--jobs)
		[ "$#" -ge 2 ] || usage
		JOBS=$2
		shift 2
		;;
	--overwrite-config)
		OVERWRITE_CONFIG=1
		shift
		;;
	--configure-only)
		CONFIGURE_ONLY=1
		shift
		;;
	-h|--help)
		usage
		;;
	*)
		usage
		;;
	esac
done

[ -n "$SOURCE" ] && [ -n "$DEVICE" ] || usage
case "$JOBS" in
	''|*[!0-9]*) usage ;;
esac
[ "$JOBS" -gt 0 ] || usage
case "$DEVICE" in
	h5000m|ap3000m) ;;
	*) usage ;;
esac

case "$(uname -s)" in
MINGW*|MSYS*|CYGWIN*)
	if [ "${MTWIFI_WSL_REEXEC:-0}" != 1 ]; then
		command -v wsl.exe >/dev/null 2>&1 || {
			printf '%s\n' 'Windows builds require WSL.' >&2
			exit 1
		}
		command -v cygpath >/dev/null 2>&1 || {
			printf '%s\n' 'Git Bash cygpath is required for WSL path conversion.' >&2
			exit 1
		}
		export MSYS_NO_PATHCONV=1
		export MSYS2_ARG_CONV_EXCL='*'
		root_wsl=$(wsl.exe wslpath -u "$(cygpath -m "$ROOT")")
		case "$SOURCE" in
		/home/*|/mnt/[a-z]/*) source_wsl=$SOURCE ;;
		*) source_wsl=$(wsl.exe wslpath -u "$(cygpath -m "$SOURCE")") ;;
		esac
		if [ "$OVERWRITE_CONFIG" -eq 1 ] && [ "$CONFIGURE_ONLY" -eq 1 ]; then
			exec wsl.exe --exec sh "$root_wsl/scripts/build.sh" --source "$source_wsl" --device "$DEVICE" --jobs "$JOBS" --overwrite-config --configure-only
		elif [ "$OVERWRITE_CONFIG" -eq 1 ]; then
			exec wsl.exe --exec sh "$root_wsl/scripts/build.sh" --source "$source_wsl" --device "$DEVICE" --jobs "$JOBS" --overwrite-config
		elif [ "$CONFIGURE_ONLY" -eq 1 ]; then
			exec wsl.exe --exec sh "$root_wsl/scripts/build.sh" --source "$source_wsl" --device "$DEVICE" --jobs "$JOBS" --configure-only
		else
			exec wsl.exe --exec sh "$root_wsl/scripts/build.sh" --source "$source_wsl" --device "$DEVICE" --jobs "$JOBS"
		fi
	fi
	;;
Darwin*)
	printf '%s\n' 'OpenWrt builds require Linux or Windows with WSL.' >&2
	exit 1
	;;
Linux*) ;;
*)
	printf '%s\n' 'Unsupported build host.' >&2
	exit 1
	;;
esac

[ -f "$SOURCE/Makefile" ] || {
	printf 'Not an OpenWrt source tree: %s\n' "$SOURCE" >&2
	exit 1
}
[ -d "$SOURCE/package/kernel/mt76/patches" ] || {
	printf '%s\n' 'The source tree must include package/kernel/mt76/patches.' >&2
	exit 1
}
if [ -e "$SOURCE/.config" ] && [ "$OVERWRITE_CONFIG" -eq 0 ]; then
	printf '%s\n' 'Refusing to overwrite .config; use --overwrite-config after saving local changes.' >&2
	exit 1
fi

case "$DEVICE" in
h5000m)
	expected_device=hiveton_h5000m
	expected_packages='kmod-mt7996e kmod-mt7992-23-firmware kmod-usb-net-cdc-ether kmod-usb-net-cdc-ncm kmod-usb-net-qmi-wwan kmod-usb-net-rtl8152 kmod-nft-offload mtwifi-mainline'
	;;
ap3000m)
	expected_device=airpi_ap3000m
	expected_packages='kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware kmod-usb-net-cdc-ether kmod-usb-net-cdc-ncm kmod-usb-net-qmi-wwan kmod-usb-net-rtl8152 kmod-nft-offload mtwifi-mainline'
	;;
esac

if [ -e "$SOURCE/package/mtwifi-mainline" ]; then
	diff -r "$ROOT/package/mtwifi-mainline" "$SOURCE/package/mtwifi-mainline" >/dev/null || {
		printf '%s\n' 'Refusing to replace an existing package/mtwifi-mainline.' >&2
		exit 1
	}
else
	cp -R "$ROOT/package/mtwifi-mainline" "$SOURCE/package/mtwifi-mainline"
fi

patch_name=100-mt7996-optional-wed-rro.patch
patch_source="$ROOT/patches/mt76/$patch_name"
patch_target="$SOURCE/package/kernel/mt76/patches/$patch_name"
if [ -e "$patch_target" ]; then
	cmp "$patch_source" "$patch_target" >/dev/null || {
		printf 'Refusing to replace existing patch: %s\n' "$patch_target" >&2
		exit 1
	}
else
	cp "$patch_source" "$patch_target"
fi

cp "$ROOT/configs/$DEVICE.config" "$SOURCE/.config"

printf 'Configuring ImmortalWrt for %s in %s\n' "$DEVICE" "$SOURCE"
make -C "$SOURCE" defconfig

grep -q '^CONFIG_TARGET_mediatek_filogic_DEVICE_'"$expected_device"'=y$' "$SOURCE/.config" || {
	printf '%s\n' 'defconfig did not select the requested device.' >&2
	exit 1
}

for package in $expected_packages; do
	grep -q '^CONFIG_PACKAGE_'"$package"'=y$' "$SOURCE/.config" || {
		printf 'defconfig did not select required package: %s\n' "$package" >&2
		exit 1
	}
done

if grep -Eq '^CONFIG_PACKAGE_kmod-mt_wifi7?=y$' "$SOURCE/.config"; then
	printf '%s\n' 'Vendor mt_wifi packages must not be enabled.' >&2
	exit 1
fi

if [ "$CONFIGURE_ONLY" -eq 1 ]; then
	printf '%s\n' 'Configuration completed; build skipped.'
	exit 0
fi

make -C "$SOURCE" -j"$JOBS"
