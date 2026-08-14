#!/usr/bin/env bash

set -euo pipefail

if (( $# != 2 )); then
	echo "Usage: scripts/tamper-release-efi-docker.sh INPUT.img OUTPUT.img" >&2
	exit 2
fi

input=$1
output=$2
[[ -f $input && ! -L $input ]] || {
	echo "error: input must be a regular non-symlink file" >&2
	exit 1
}
[[ ! -e $output && ! -L $output ]] || {
	echo "error: output already exists or is a symlink: $output" >&2
	exit 1
}
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
input=$(cd -- "$(dirname -- "$input")" && pwd)/$(basename -- "$input")
output_dir=$(cd -- "$(dirname -- "$output")" && pwd)
output_name=$(basename -- "$output")
[[ $output_name =~ ^[A-Za-z0-9._-]+\.img$ ]] || {
	echo "error: unsafe output name: $output_name" >&2
	exit 1
}

builder_image=${VOLATOO_RELEASE_BUILDER_IMAGE:-volatoo-release-builder:0.1-dev}
docker build --tag "$builder_image" \
	--platform linux/amd64 \
	--file "$repo_root/scripts/release-container/Dockerfile" "$repo_root"
docker run --rm --privileged \
	--platform linux/amd64 \
	--env "HOST_UID=$(id -u)" \
	--env "HOST_GID=$(id -g)" \
	--env "OUTPUT_NAME=$output_name" \
	--mount "type=bind,src=$input,dst=/input/release.img,readonly" \
	--mount "type=bind,src=$output_dir,dst=/output" \
	--entrypoint /bin/bash \
	"$builder_image" -c '
		set -euo pipefail
		staging=/output/.${OUTPUT_NAME}.tmp
		cleanup()
		{
			if [[ -n ${efi_mount:-} ]]; then umount "$efi_mount" 2>/dev/null || true; fi
			if [[ -n ${loop:-} ]]; then losetup -d "$loop" 2>/dev/null || true; fi
			rm -f -- "$staging"
		}
		trap cleanup EXIT
		[[ ! -e /output/$OUTPUT_NAME && ! -L /output/$OUTPUT_NAME ]]
		cp /input/release.img "$staging"
		loop=$(losetup --find --show --partscan "$staging")
		partx --update "$loop" >/dev/null
		mdev -s >/dev/null 2>&1 || true
		for _ in $(seq 1 100); do
			if [[ -b ${loop}p2 ]] && blockdev --getsize64 "${loop}p2" >/dev/null 2>&1; then
				break
			fi
			if [[ -e ${loop}p2 || -L ${loop}p2 ]]; then rm -f -- "${loop}p2"; fi
			mdev -s >/dev/null 2>&1 || true
			sleep 0.05
		done
		[[ -b ${loop}p2 ]] && blockdev --getsize64 "${loop}p2" >/dev/null
		efi_mount=$(mktemp -d)
		mount "${loop}p2" "$efi_mount"
		uki=$efi_mount/EFI/BOOT/BOOTX64.EFI
		[[ -f $uki ]]
		read -r original_sha256 _ < <(sha256sum "$uki")
		offset=4096
		old_byte=$(od -An -tu1 -j "$offset" -N 1 "$uki")
		new_byte=$(( (old_byte + 1) % 256 ))
		printf "\\$(printf "%03o" "$new_byte")" |
			dd of="$uki" bs=1 seek="$offset" count=1 conv=notrunc status=none
		read -r tampered_sha256 _ < <(sha256sum "$uki")
		[[ $tampered_sha256 != "$original_sha256" ]]
		sync
		umount "$efi_mount"
		rmdir "$efi_mount"
		efi_mount=
		losetup -d "$loop"
		loop=
		chown "$HOST_UID:$HOST_GID" "$staging"
		mv "$staging" "/output/$OUTPUT_NAME"
	'

echo "tampered EFI executable in $output"
