#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/test-release-disk-docker.sh \
  --init-system openrc|systemd [--firmwares bios,uefi] \
  [--ssh-private-key KEY] DISK.img

Boot a complete Volatoo raw disk through the pinned QEMU runner in the
OrbStack Docker context. The input disk is mounted read-only and QEMU writes
only to a temporary snapshot.
EOF
}

init_system=
firmwares=bios,uefi
disk=
ssh_private_key=
while (( $# > 0 )); do
	case $1 in
		--init-system|--firmwares|--ssh-private-key)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--init-system) init_system=$2 ;;
				--firmwares) firmwares=$2 ;;
				--ssh-private-key) ssh_private_key=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
		*) [[ -z $disk ]] || { echo "error: only one disk is allowed" >&2; exit 2; }; disk=$1; shift ;;
	esac
done

[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: --init-system must be openrc or systemd" >&2
	exit 2
}
[[ -f $disk && ! -L $disk ]] || {
	echo "error: disk must be a regular non-symlink file" >&2
	exit 1
}
disk=$(cd -- "$(dirname -- "$disk")" && pwd)/$(basename -- "$disk")
if [[ -n $ssh_private_key ]]; then
	[[ -f $ssh_private_key && ! -L $ssh_private_key ]] || {
		echo "error: SSH private key must be a regular non-symlink file" >&2
		exit 1
	}
	ssh_private_key=$(cd -- "$(dirname -- "$ssh_private_key")" && pwd)/$(basename -- "$ssh_private_key")
fi
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}

IFS=, read -r -a selected_firmwares <<<"$firmwares"
(( ${#selected_firmwares[@]} > 0 )) || {
	echo "error: --firmwares must not be empty" >&2
	exit 2
}
for firmware in "${selected_firmwares[@]}"; do
	[[ $firmware == bios || $firmware == uefi ]] || {
		echo "error: unsupported firmware: $firmware" >&2
		exit 2
	}
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runner_image=${VOLATOO_QEMU_RUNNER_IMAGE:-volatoo-qemu-runner:1}
docker build --tag "$runner_image" "$repo_root/scripts/qemu-container"
for firmware in "${selected_firmwares[@]}"; do
	docker_args=(
		run --rm
		--network none
		--env "VOLATOO_RELEASE_QEMU_TIMEOUT=${VOLATOO_RELEASE_QEMU_TIMEOUT:-240}"
		--mount "type=bind,src=$repo_root,dst=/repo,readonly"
		--mount "type=bind,src=$disk,dst=/inputs/disk,readonly"
	)
	if [[ -n $ssh_private_key ]]; then
		docker_args+=(
			--env VOLATOO_RELEASE_SSH_KEY=/inputs/ssh-key
			--mount "type=bind,src=$ssh_private_key,dst=/inputs/ssh-key,readonly"
		)
	fi
	docker "${docker_args[@]}" \
		"$runner_image" \
		/repo/scripts/qemu-container/test-release-disk.sh \
		/inputs/disk "$init_system" "$firmware"
done
