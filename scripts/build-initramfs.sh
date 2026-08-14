#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/build-initramfs.sh --busybox PATH [OPTIONS]

Build the standalone Volatoo initramfs around a statically linked x86_64
BusyBox binary.

Options:
  --busybox PATH     Statically linked x86_64 BusyBox binary (required)
  --verity-root DIR  Prepared veritysetup runtime root (recommended)
  --signify-root DIR Prepared signify verifier runtime root (recommended)
  --trust-key PATH   Embed a trusted signify public key; repeat for rotation
  --config PATH      Configuration to embed (default: initramfs/default.conf)
  --output PATH      Output archive (default: out/volatoo-initramfs.cpio.gz)
  -h, --help         Show this help
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
busybox_path=
verity_root=
signify_root=
declare -a trust_keys=()
config_path=$repo_root/initramfs/default.conf
output_path=$repo_root/out/volatoo-initramfs.cpio.gz

while (( $# > 0 )); do
	case $1 in
		--busybox | --verity-root | --signify-root | --trust-key | --config | --output)
			if (( $# < 2 )); then
				echo "error: $1 requires a value" >&2
				exit 2
			fi
			case $1 in
				--busybox) busybox_path=$2 ;;
				--verity-root) verity_root=$2 ;;
				--signify-root) signify_root=$2 ;;
				--trust-key) trust_keys+=("$2") ;;
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
if [[ -n $verity_root && \
	( ! -d $verity_root || ! -x $verity_root/sbin/veritysetup ) ]]; then
	echo "error: --verity-root must contain executable sbin/veritysetup" >&2
	exit 1
fi
if [[ -n $signify_root && \
	( ! -d $signify_root || ! -x $signify_root/usr/bin/signify ) ]]; then
	echo "error: --signify-root must contain executable usr/bin/signify" >&2
	exit 1
fi
if (( ${#trust_keys[@]} > 0 )) && [[ -z $signify_root ]]; then
	echo "error: --trust-key requires --signify-root" >&2
	exit 1
fi
for trust_key in "${trust_keys[@]}"; do
	if [[ -L $trust_key || ! -f $trust_key ]]; then
		echo "error: trusted public key is missing or unsafe: $trust_key" >&2
		exit 1
	fi
done

for command_name in cmp cpio file find gzip install sort; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "error: required host command is not installed: $command_name" >&2
		exit 1
	fi
done

busybox_path=$(cd -- "$(dirname -- "$busybox_path")" && pwd)/$(basename -- "$busybox_path")
config_path=$(cd -- "$(dirname -- "$config_path")" && pwd)/$(basename -- "$config_path")
if [[ -n $verity_root ]]; then
	verity_root=$(cd -- "$verity_root" && pwd)
fi
if [[ -n $signify_root ]]; then
	signify_root=$(cd -- "$signify_root" && pwd)
fi

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
	"$root_dir/run" \
	"$root_dir/sbin" \
	"$root_dir/proc" \
	"$root_dir/sys"

# BusyBox supplies the filesystem, module-loading, rescue, and switch_root
# applets needed before the Gentoo userspace is available.
install -m 0755 "$busybox_path" "$root_dir/bin/busybox"
install -m 0755 "$repo_root/initramfs/init" "$root_dir/init"
install -m 0644 "$config_path" "$root_dir/etc/volatoo/initramfs.conf"

# veritysetup is one of two optional non-BusyBox executables. It programs the
# kernel's dm-verity target so realization-v2 roots and realization-v3 image
# stacks are authenticated lazily.
# The prepared root contains only veritysetup's dynamic runtime closure.
if [[ -n $verity_root ]]; then
	install -m 0755 "$verity_root/sbin/veritysetup" \
		"$root_dir/sbin/veritysetup"
	for library_directory in lib usr/lib; do
		if [[ -d $verity_root/$library_directory ]]; then
			mkdir -p "$root_dir/$library_directory"
			cp -a "$verity_root/$library_directory/." \
				"$root_dir/$library_directory/"
		fi
	done
fi

# signify is the small Ed25519 verifier for exact realization-plan bytes.
# Only public release keys enter the initramfs; private keys remain offline.
if [[ -n $signify_root ]]; then
	mkdir -p "$root_dir/usr/bin"
	install -m 0755 "$signify_root/usr/bin/signify" \
		"$root_dir/usr/bin/signify"
	for library_directory in lib usr/lib; do
		if [[ -d $signify_root/$library_directory ]]; then
			mkdir -p "$root_dir/$library_directory"
			cp -a "$signify_root/$library_directory/." \
				"$root_dir/$library_directory/"
		fi
	done
fi
if (( ${#trust_keys[@]} > 0 )); then
	mkdir -p "$root_dir/etc/volatoo/trusted.d"
	for trust_key in "${trust_keys[@]}"; do
		if command -v sha256sum >/dev/null 2>&1; then
			key_checksum=$(sha256sum "$trust_key")
		else
			key_checksum=$(shasum -a 256 "$trust_key")
		fi
		key_digest=${key_checksum%% *}
		key_destination=$root_dir/etc/volatoo/trusted.d/$key_digest.pub
		if [[ -e $key_destination ]]; then
			cmp -s "$trust_key" "$key_destination" || {
				echo "error: trusted key digest collision: $trust_key" >&2
				exit 1
			}
		else
			install -m 0644 "$trust_key" "$key_destination"
		fi
	done
fi

applets=(blkid cat cp date df dmesg losetup ls mkdir modprobe mount poweroff printf reboot rm setsid sh sha256sum sleep stat switch_root tail umount uname wc)
for applet in "${applets[@]}"; do
	ln -s busybox "$root_dir/bin/$applet"
done

(
	cd "$root_dir"
	find . -print | LC_ALL=C sort | COPYFILE_DISABLE=1 cpio -o -H newc 2>/dev/null
) | gzip -n -9 >"$output_path"

echo "built $output_path"
