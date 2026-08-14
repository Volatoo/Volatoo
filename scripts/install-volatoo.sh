#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/install-volatoo.sh \
  --device /dev/DEVICE --init-system openrc|systemd \
  --image RELEASE.img [--manifest RELEASE.img.manifest] [--yes]

Write one verified Volatoo release disk to one explicit block device. This
command never discovers or selects a destination automatically. All data on
DEVICE will be overwritten.
EOF
}

device=
init_system=
image=
manifest=
assume_yes=no
while (( $# > 0 )); do
	case $1 in
		--device|--init-system|--image|--manifest)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--device) device=$2 ;;
				--init-system) init_system=$2 ;;
				--image) image=$2 ;;
				--manifest) manifest=$2 ;;
			esac
			shift 2
			;;
		--yes) assume_yes=yes; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[[ $EUID -eq 0 ]] || { echo "error: installer must run as root" >&2; exit 1; }
[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: --init-system must be openrc or systemd" >&2
	exit 2
}
[[ -n $device && $device == /dev/* ]] || {
	echo "error: --device must be an explicit /dev path" >&2
	exit 2
}
[[ -b $device && ! -L $device ]] || {
	echo "error: destination is not a non-symlink block device: $device" >&2
	exit 1
}
[[ -f $image && ! -L $image ]] || {
	echo "error: release image is missing or unsafe: $image" >&2
	exit 1
}
manifest=${manifest:-$image.manifest}
[[ -f $manifest && ! -L $manifest ]] || {
	echo "error: release manifest is missing or unsafe: $manifest" >&2
	exit 1
}
for command_name in awk blockdev dd e2fsck findmnt grep lsblk partx resize2fs sgdisk sha256sum stat sync; do
	command -v "$command_name" >/dev/null 2>&1 || {
		echo "error: required command is unavailable: $command_name" >&2
		exit 1
	}
done

reread_partitions()
{
	if ! blockdev --rereadpt "$device" 2>/dev/null && ! partx --update "$device" 2>/dev/null; then
		echo "error: kernel refused to reload the destination partition table" >&2
		return 1
	fi
	if command -v udevadm >/dev/null 2>&1; then udevadm settle; fi
	if command -v mdev >/dev/null 2>&1; then mdev -s 2>/dev/null; fi
}

manifest_value()
{
	local key=$1
	local value
	value=$(awk -F= -v key="$key" '$1 == key { count++; value=substr($0, length(key) + 2) } END { if (count != 1) exit 1; print value }' "$manifest") || {
		echo "error: manifest must contain exactly one $key" >&2
		exit 1
	}
	printf '%s\n' "$value"
}

[[ $(manifest_value schema) == org.volatoo.release-media/v1 ]] || {
	echo "error: unsupported release manifest schema" >&2
	exit 1
}
manifest_init=$(manifest_value init_system)
[[ $manifest_init == "$init_system" ]] || {
	echo "error: release targets $manifest_init, not $init_system" >&2
	exit 1
}
expected_size=$(manifest_value disk_size)
expected_sha256=$(manifest_value disk_sha256)
[[ $expected_size =~ ^[1-9][0-9]*$ ]] || {
	echo "error: invalid disk_size in release manifest" >&2
	exit 1
}
[[ $expected_sha256 =~ ^[0-9a-f]{64}$ ]] || {
	echo "error: invalid disk_sha256 in release manifest" >&2
	exit 1
}
actual_size=$(stat -c %s "$image")
[[ $actual_size == "$expected_size" ]] || {
	echo "error: release image size does not match its manifest" >&2
	exit 1
}
actual_sha256=$(sha256sum "$image" | awk '{print $1}')
[[ $actual_sha256 == "$expected_sha256" ]] || {
	echo "error: release image digest does not match its manifest" >&2
	exit 1
}

target_size=$(blockdev --getsize64 "$device")
(( target_size >= expected_size )) || {
	echo "error: destination is smaller than the release image" >&2
	exit 1
}
if lsblk -nrpo MOUNTPOINTS "$device" | grep -q '[^[:space:]]'; then
	echo "error: destination or one of its partitions is mounted: $device" >&2
	exit 1
fi
root_source=$(findmnt -nro SOURCE / 2>/dev/null || true)
if [[ $root_source == "$device" ]] ||
	lsblk -nrpo NAME "$device" | grep -Fqx -- "$root_source"; then
	echo "error: refusing to overwrite the current root disk: $device" >&2
	exit 1
fi

if [[ $assume_yes != yes ]]; then
	echo "WARNING: all data on $device will be overwritten." >&2
	printf 'Type the exact device path to continue: ' >&2
	IFS= read -r confirmation
	[[ $confirmation == "$device" ]] || {
		echo "error: installation confirmation did not match" >&2
		exit 1
	}
fi

echo "installing Volatoo $init_system on $device"
dd if="$image" of="$device" bs=16M conv=fsync status=progress
reread_partitions

if (( target_size > expected_size )); then
	echo "expanding the state partition to fill $device"
	sgdisk --move-second-header "$device" >/dev/null
	state_info=$(LC_ALL=C sgdisk --info=4 "$device")
	state_start=$(awk '/First sector:/ { print $3 }' <<<"$state_info")
	state_guid=$(awk '/Partition unique GUID:/ { print $4 }' <<<"$state_info")
	[[ $state_start =~ ^[1-9][0-9]*$ && $state_guid =~ ^[0-9A-Fa-f-]{36}$ ]] || {
		echo "error: could not read the state partition identity" >&2
		exit 1
	}
	sgdisk \
		--delete=4 \
		--new="4:${state_start}:0" \
		--typecode=4:8300 \
		--change-name=4:VOLATOO-STATE \
		--partition-guid="4:${state_guid}" \
		"$device" >/dev/null
	reread_partitions
	if [[ $device =~ [0-9]$ ]]; then
		state_partition=${device}p4
	else
		state_partition=${device}4
	fi
	for _ in {1..50}; do
		[[ -b $state_partition ]] && break
		sleep 0.1
	done
	[[ -b $state_partition ]] || {
		echo "error: state partition did not appear: $state_partition" >&2
		exit 1
	}
	set +e
	e2fsck -fy "$state_partition"
	fsck_status=$?
	set -e
	(( fsck_status <= 1 )) || {
		echo "error: state filesystem check failed with status $fsck_status" >&2
		exit 1
	}
	resize2fs "$state_partition"
fi
sync
echo "installed Volatoo $init_system on $device"
