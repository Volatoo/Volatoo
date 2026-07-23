#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/build-initramfs.sh --busybox PATH [OPTIONS]

Build the standalone Volatoo initramfs around a statically linked x86_64
BusyBox binary.

Options:
  --busybox PATH  Statically linked x86_64 BusyBox binary (required)
  --config PATH   Configuration to embed (default: initramfs/default.conf)
  --output PATH   Output archive (default: out/volatoo-initramfs.cpio.gz)
  -h, --help      Show this help
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
busybox_path=
config_path=$repo_root/initramfs/default.conf
output_path=$repo_root/out/volatoo-initramfs.cpio.gz

while (( $# > 0 )); do
	case $1 in
		--busybox | --config | --output)
			if (( $# < 2 )); then
				echo "error: $1 requires a value" >&2
				exit 2
			fi
			case $1 in
				--busybox) busybox_path=$2 ;;
				--config) config_path=$2 ;;
				--output) output_path=$2 ;;
			esac
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			echo "error: unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [[ -z $busybox_path ]]; then
	echo "error: --busybox is required" >&2
	usage >&2
	exit 2
fi

if [[ ! -f $busybox_path ]]; then
	echo "error: BusyBox does not exist: $busybox_path" >&2
	exit 1
fi

if [[ ! -f $config_path ]]; then
	echo "error: configuration does not exist: $config_path" >&2
	exit 1
fi

for command_name in cpio file find gzip install sort; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "error: required host command is not installed: $command_name" >&2
		exit 1
	fi
done

busybox_path=$(cd -- "$(dirname -- "$busybox_path")" && pwd)/$(basename -- "$busybox_path")
config_path=$(cd -- "$(dirname -- "$config_path")" && pwd)/$(basename -- "$config_path")

if ! file "$busybox_path" | grep -Eq 'x86-64|x86_64'; then
	echo "error: BusyBox must be an x86_64 binary: $busybox_path" >&2
	exit 1
fi

if ! file "$busybox_path" | grep -q 'statically linked'; then
	echo "error: BusyBox must be statically linked: $busybox_path" >&2
	exit 1
fi

mkdir -p "$(dirname -- "$output_path")"
output_path=$(cd -- "$(dirname -- "$output_path")" && pwd)/$(basename -- "$output_path")

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-initramfs.XXXXXX")
cleanup() {
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

root_dir=$work_dir/root
mkdir -p \
	"$root_dir/bin" \
	"$root_dir/dev" \
	"$root_dir/etc/volatoo" \
	"$root_dir/proc" \
	"$root_dir/sys"

# BusyBox is the sole executable added to early userspace. It supplies the
# filesystem, module-loading, rescue, and switch_root applets needed before the
# Gentoo userspace is available.
install -m 0755 "$busybox_path" "$root_dir/bin/busybox"
install -m 0755 "$repo_root/initramfs/init" "$root_dir/init"
install -m 0644 "$config_path" "$root_dir/etc/volatoo/initramfs.conf"

applets=(blkid cat cp date df dmesg losetup ls mkdir modprobe mount poweroff printf reboot setsid sh sha256sum sleep switch_root tail umount uname)
for applet in "${applets[@]}"; do
	ln -s busybox "$root_dir/bin/$applet"
done

(
	cd "$root_dir"
	find . -print | LC_ALL=C sort | COPYFILE_DISABLE=1 cpio -o -H newc 2>/dev/null
) | gzip -n -9 >"$output_path"

echo "built $output_path"
