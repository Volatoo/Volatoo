#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/install-volatoo.sh \
  --device /dev/DEVICE --init-system openrc|systemd \
  --image RELEASE.img [--manifest RELEASE.img.manifest] \
  (--ssh-authorized-key PUBLIC_KEY | --no-provision-access) [--yes]

Write one verified Volatoo release disk to one explicit block device. This
command never discovers or selects a destination automatically. All data on
DEVICE will be overwritten.
EOF
}

device=
init_system=
image=
manifest=
ssh_authorized_key=
provision_access=yes
assume_yes=no
while (( $# > 0 )); do
	case $1 in
		--device|--init-system|--image|--manifest|--ssh-authorized-key)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--device) device=$2 ;;
				--init-system) init_system=$2 ;;
				--image) image=$2 ;;
				--manifest) manifest=$2 ;;
				--ssh-authorized-key) ssh_authorized_key=$2 ;;
			esac
			shift 2
			;;
		--yes) assume_yes=yes; shift ;;
		--no-provision-access) provision_access=no; shift ;;
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
if [[ $provision_access == yes ]]; then
	[[ -n $ssh_authorized_key && -f $ssh_authorized_key && ! -L $ssh_authorized_key ]] || {
		echo "error: --ssh-authorized-key must name a regular non-symlink file" >&2
		exit 1
	}
	awk '
		NF == 0 || $1 ~ /^#/ { next }
		$1 !~ /^(ssh-ed25519|sk-ssh-ed25519@openssh.com|ecdsa-sha2-nistp(256|384|521)|sk-ecdsa-sha2-nistp256@openssh.com|ssh-rsa)$/ { exit 1 }
		$2 !~ /^[A-Za-z0-9+\/=]+$/ { exit 1 }
		{ keys++ }
		END { if (keys == 0) exit 1 }
	' "$ssh_authorized_key" || {
		echo "error: administrator SSH public key file is invalid" >&2
		exit 1
	}
elif [[ -n $ssh_authorized_key ]]; then
	echo "error: --ssh-authorized-key conflicts with --no-provision-access" >&2
	exit 2
fi
for command_name in awk blockdev dd e2fsck findmnt grep install lsblk mount mountpoint partx resize2fs rm sgdisk sha256sum stat sync umount; do
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

wait_for_partition()
{
	local partition=$1
	for _ in {1..50}; do
		if [[ -b $partition ]] && blockdev --getsize64 "$partition" >/dev/null 2>&1; then
			return 0
		fi
		# A container without udev can retain a stale mdev node when a loop
		# device number is reused. Replace only this explicit partition node.
		if ! command -v udevadm >/dev/null 2>&1 && command -v mdev >/dev/null 2>&1; then
			if [[ -e $partition || -L $partition ]]; then rm -f -- "$partition"; fi
			mdev -s 2>/dev/null || true
		fi
		sleep 0.1
	done
	return 1
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

manifest_schema=$(manifest_value schema)
[[ $manifest_schema == org.volatoo.release-media/v1 || \
	$manifest_schema == org.volatoo.release-media/v2 ]] || {
	echo "error: unsupported release manifest schema" >&2
	exit 1
}
[[ $(manifest_value channel) == v0.1-dev ]] || {
	echo "error: unsupported release channel" >&2
	exit 1
}
manifest_disk_file=$(manifest_value disk_file)
[[ $manifest_disk_file =~ ^[A-Za-z0-9._-]+\.img$ ]] || {
	echo "error: invalid disk_file in release manifest" >&2
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
if [[ $manifest_schema == org.volatoo.release-media/v2 ]]; then
	for digest_name in kernel_sha256 initramfs_sha256 rootfs_sha256 state_sha256; do
		digest_value=$(manifest_value "$digest_name")
		[[ $digest_value =~ ^[0-9a-f]{64}$ ]] || {
			echo "error: invalid $digest_name in release manifest" >&2
			exit 1
		}
	done
	manifest_secure_boot=$(manifest_value secure_boot)
	manifest_secure_boot_cert=$(manifest_value secure_boot_cert_sha256)
	manifest_uki=$(manifest_value uki_sha256)
	[[ $manifest_secure_boot == yes || $manifest_secure_boot == no ]] || {
		echo "error: invalid secure_boot in release manifest" >&2
		exit 1
	}
	if [[ $manifest_secure_boot == yes ]]; then
		[[ $manifest_secure_boot_cert =~ ^[0-9a-f]{64}$ && \
			$manifest_uki =~ ^[0-9a-f]{64}$ ]] || {
			echo "error: signed release has invalid Secure Boot provenance" >&2
			exit 1
		}
	else
		[[ $manifest_secure_boot_cert == none && $manifest_uki == none ]] || {
			echo "error: unsigned release claims Secure Boot provenance" >&2
			exit 1
		}
	fi
fi
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

if [[ $device =~ [0-9]$ ]]; then
	state_partition=${device}p4
else
	state_partition=${device}4
fi

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
	wait_for_partition "$state_partition" || {
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

if [[ $provision_access == yes ]]; then
	wait_for_partition "$state_partition" || {
		echo "error: state partition did not appear: $state_partition" >&2
		exit 1
	}
	state_mount=$(mktemp -d /tmp/volatoo-state.XXXXXX)
	cleanup_state_mount()
	{
		if mountpoint -q "$state_mount"; then umount "$state_mount"; fi
		rmdir "$state_mount"
	}
	trap cleanup_state_mount EXIT
	mount -o rw "$state_partition" "$state_mount"
	[[ -d $state_mount/volatoo/config && ! -L $state_mount/volatoo/config ]] || {
		echo "error: destination has no safe Volatoo state configuration directory" >&2
		exit 1
	}
	[[ ! -e $state_mount/volatoo/config/access ||
		(-d $state_mount/volatoo/config/access && ! -L $state_mount/volatoo/config/access) ]] || {
		echo "error: destination has an unsafe access configuration path" >&2
		exit 1
	}
	install -d -m 0700 "$state_mount/volatoo/config/access"
	install -m 0600 "$ssh_authorized_key" \
		"$state_mount/volatoo/config/access/authorized_keys"
	sync
	umount "$state_mount"
	rmdir "$state_mount"
	trap - EXIT
fi
sync
echo "installed Volatoo $init_system on $device"
