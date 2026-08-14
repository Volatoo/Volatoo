#!/usr/bin/env bash

set -euo pipefail

if (( $# != 1 )); then
	echo "Usage: test-install-volatoo-docker.sh RELEASE.img" >&2
	exit 2
fi
image=$1
manifest=$image.manifest
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ -f $image && -f $manifest ]] || {
	echo "error: release image and manifest are required" >&2
	exit 1
}
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}
image=$(cd -- "$(dirname -- "$image")" && pwd)/$(basename -- "$image")
manifest=$(cd -- "$(dirname -- "$manifest")" && pwd)/$(basename -- "$manifest")

docker run --rm --privileged \
	--platform linux/amd64 \
	--entrypoint /bin/bash \
	--mount "type=bind,src=$repo_root,dst=/repo,readonly" \
	--mount "type=bind,src=$image,dst=/input/release.img,readonly" \
	--mount "type=bind,src=$manifest,dst=/input/release.img.manifest,readonly" \
	volatoo-release-builder:0.1-dev \
	-c '
		set -euo pipefail
		size=$(stat -c %s /input/release.img)
		extra_size=$((64 * 1024 * 1024))
		original_state_start=$(sgdisk --info=4 /input/release.img | awk "/First sector:/ { print \$3 }")
		original_state_end=$(sgdisk --info=4 /input/release.img | awk "/Last sector:/ { print \$3 }")
		original_state_sectors=$((original_state_end - original_state_start + 1))
		system_start=$(sgdisk --info=3 /input/release.img | awk "/First sector:/ { print \$3 }")
		system_end=$(sgdisk --info=3 /input/release.img | awk "/Last sector:/ { print \$3 }")
		system_offset=$((system_start * 512))
		system_size=$(((system_end - system_start + 1) * 512))
		truncate -s "$((size + extra_size))" /tmp/target
		printf "%s\n" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8XFE9WwjHvSxBSnbiuupCmyvRetPJYcHARXeTwdtLb volatoo-installer-test" >/tmp/authorized_key
		loop=$(losetup --find --show /tmp/target)
		cleanup() { losetup -d "$loop" 2>/dev/null || true; }
		trap cleanup EXIT
		/repo/scripts/install-volatoo.sh \
			--device "$loop" \
			--init-system openrc \
			--image /input/release.img \
			--ssh-authorized-key /tmp/authorized_key \
			--yes
		cmp -n "$system_size" /input/release.img "$loop" "$system_offset" "$system_offset"
		expanded_state_start=$(sgdisk --info=4 "$loop" | awk "/First sector:/ { print \$3 }")
		expanded_state_end=$(sgdisk --info=4 "$loop" | awk "/Last sector:/ { print \$3 }")
		expanded_state_sectors=$((expanded_state_end - expanded_state_start + 1))
		[[ $expanded_state_start == "$original_state_start" ]]
		(( expanded_state_sectors > original_state_sectors ))
		if [[ $loop =~ [0-9]$ ]]; then state_partition=${loop}p4; else state_partition=${loop}4; fi
		e2fsck -fn "$state_partition"
		mkdir /tmp/state
		mount -o ro "$state_partition" /tmp/state
		cmp /tmp/authorized_key /tmp/state/volatoo/config/access/authorized_keys
		[[ $(stat -c %a /tmp/state/volatoo/config/access/authorized_keys) == 600 ]]
		umount /tmp/state
		if /repo/scripts/install-volatoo.sh \
			--device "$loop" \
			--init-system systemd \
			--image /input/release.img \
			--no-provision-access \
			--yes >/tmp/wrong-target.stdout 2>/tmp/wrong-target.stderr
		then
			echo "error: installer accepted the wrong init system" >&2
			exit 1
		fi
		grep -q "release targets openrc, not systemd" /tmp/wrong-target.stderr
		disk_digest=$(sed -n "s/^disk_sha256=//p" /input/release.img.manifest)
		case $disk_digest in
			0*) replacement=1 ;;
			*) replacement=0 ;;
		esac
		sed "s/^disk_sha256=./disk_sha256=$replacement/" \
			/input/release.img.manifest >/tmp/bad.manifest
		if /repo/scripts/install-volatoo.sh \
			--device "$loop" \
			--init-system openrc \
			--image /input/release.img \
			--manifest /tmp/bad.manifest \
			--no-provision-access \
			--yes >/tmp/bad-digest.stdout 2>/tmp/bad-digest.stderr
		then
			echo "error: installer accepted a mismatched digest" >&2
			exit 1
		fi
		grep -q "release image digest does not match" /tmp/bad-digest.stderr
		sed "s/^channel=.*/channel=stable/" \
			/input/release.img.manifest >/tmp/bad-channel.manifest
		if /repo/scripts/install-volatoo.sh \
			--device "$loop" \
			--init-system openrc \
			--image /input/release.img \
			--manifest /tmp/bad-channel.manifest \
			--no-provision-access \
			--yes >/tmp/bad-channel.stdout 2>/tmp/bad-channel.stderr
		then
			echo "error: installer accepted an unsupported release channel" >&2
			exit 1
		fi
		grep -q "unsupported release channel" /tmp/bad-channel.stderr
		sed \
			-e "s#^schema=.*#schema=org.volatoo.release-media/v2#" \
			-e "/^kernel_sha256=/d" \
			/input/release.img.manifest >/tmp/incomplete-v2.manifest
		if /repo/scripts/install-volatoo.sh \
			--device "$loop" \
			--init-system openrc \
			--image /input/release.img \
			--manifest /tmp/incomplete-v2.manifest \
			--no-provision-access \
			--yes >/tmp/incomplete-v2.stdout 2>/tmp/incomplete-v2.stderr
		then
			echo "error: installer accepted incomplete v2 provenance" >&2
			exit 1
		fi
		grep -q "exactly one kernel_sha256" /tmp/incomplete-v2.stderr
	'

echo "Volatoo explicit-device installer test passed"
