#!/usr/bin/env bash

set -euo pipefail

usage()
{
	echo "Usage: scripts/test-live-iso-docker.sh --init-system openrc|systemd [--firmwares bios,uefi] ISO" >&2
}
init_system=
firmwares=bios,uefi
iso=
while (( $# > 0 )); do
	case $1 in
		--init-system|--firmwares)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			if [[ $1 == --init-system ]]; then init_system=$2; else firmwares=$2; fi
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
		*) [[ -z $iso ]] || { echo "error: only one ISO is allowed" >&2; exit 2; }; iso=$1; shift ;;
	esac
done
[[ $init_system == openrc || $init_system == systemd ]] || { usage; exit 2; }
[[ -f $iso && ! -L $iso ]] || { echo "error: ISO is missing or unsafe" >&2; exit 1; }
[[ $(docker context show) == orbstack ]] || { echo "error: Docker context must be orbstack" >&2; exit 1; }
iso=$(cd -- "$(dirname -- "$iso")" && pwd)/$(basename -- "$iso")
IFS=, read -r -a selected_firmwares <<<"$firmwares"
(( ${#selected_firmwares[@]} > 0 )) || { echo "error: firmware list is empty" >&2; exit 2; }
for firmware in "${selected_firmwares[@]}"; do
	[[ $firmware == bios || $firmware == uefi ]] || { echo "error: unsupported firmware: $firmware" >&2; exit 2; }
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=${VOLATOO_QEMU_RUNNER_IMAGE:-volatoo-qemu-runner:1}
docker build --tag "$image" "$repo_root/scripts/qemu-container"
for firmware in "${selected_firmwares[@]}"; do
	docker run --rm --network none \
		--env "VOLATOO_LIVE_QEMU_TIMEOUT=${VOLATOO_LIVE_QEMU_TIMEOUT:-240}" \
		--mount "type=bind,src=$repo_root,dst=/repo,readonly" \
		--mount "type=bind,src=$iso,dst=/inputs/live.iso,readonly" \
		"$image" /repo/scripts/qemu-container/test-live-iso.sh \
		/inputs/live.iso "$init_system" "$firmware"
done
