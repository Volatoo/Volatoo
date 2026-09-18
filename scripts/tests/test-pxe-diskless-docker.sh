#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/tests/test-pxe-diskless-docker.sh \
  --init-system openrc|systemd --kernel FILE --initramfs FILE \
  --rootfs FILE --iso FILE

Boot the real pinned Volatoo kernel and initramfs over the network through
the pinned QEMU runner: an iPXE PXE option ROM fetches the kernel and initrd
from QEMU's built-in TFTP server, and the live ISO is attached as the image
container. The boot runs in ram-overlay with state=none and asserts the same
markers as the release Gates. The container runs with no external network
access.

The ISO must contain /volatoo/root.squashfs and the rootfs argument must be
that same SquashFS (its SHA-256 is verified by the initramfs at boot).
EOF
}

init_system=
kernel=
initramfs=
rootfs=
iso=
while (( $# > 0 )); do
	case $1 in
		--init-system|--kernel|--initramfs|--rootfs|--iso)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--init-system) init_system=$2 ;;
				--kernel) kernel=$2 ;;
				--initramfs) initramfs=$2 ;;
				--rootfs) rootfs=$2 ;;
				--iso) iso=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
		*) echo "error: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: --init-system must be openrc or systemd" >&2
	exit 2
}
for name in kernel initramfs rootfs iso; do
	value=${!name}
	[[ -n $value ]] || { echo "error: --$name is required" >&2; exit 2; }
	[[ -f $value && ! -L $value ]] || {
		echo "error: --$name must be a regular non-symlink file" >&2
		exit 1
	}
done

if [[ -n ${VOLATOO_PXE_QEMU_TIMEOUT:-} ]]; then
	[[ $VOLATOO_PXE_QEMU_TIMEOUT =~ ^[1-9][0-9]*$ ]] || {
		echo "error: VOLATOO_PXE_QEMU_TIMEOUT must be a positive integer" >&2
		exit 2
	}
fi
if [[ -n ${VOLATOO_PXE_VM_MEMORY:-} ]]; then
	[[ $VOLATOO_PXE_VM_MEMORY =~ ^[1-9][0-9]*$ ]] || {
		echo "error: VOLATOO_PXE_VM_MEMORY must be a positive integer" >&2
		exit 2
	}
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=scripts/require-docker-context.sh
source "$repo_root/scripts/require-docker-context.sh"
volatoo_require_docker_context

absolute_file()
{
	printf '%s/%s\n' "$(cd -- "$(dirname -- "$1")" && pwd)" "$(basename -- "$1")"
}
kernel=$(absolute_file "$kernel")
initramfs=$(absolute_file "$initramfs")
rootfs=$(absolute_file "$rootfs")
iso=$(absolute_file "$iso")

runner_image=${VOLATOO_QEMU_RUNNER_IMAGE:-volatoo-qemu-runner:1}
docker build --tag "$runner_image" "$repo_root/scripts/qemu-container"

environment=(
	--env "VOLATOO_PXE_QEMU_TIMEOUT=${VOLATOO_PXE_QEMU_TIMEOUT:-240}"
	--env "VOLATOO_PXE_VM_MEMORY=${VOLATOO_PXE_VM_MEMORY:-8192}"
)

docker run --rm --network none \
	"${environment[@]}" \
	--mount "type=bind,src=$repo_root,dst=/repo,readonly" \
	--mount "type=bind,src=$kernel,dst=/inputs/kernel,readonly" \
	--mount "type=bind,src=$initramfs,dst=/inputs/initramfs,readonly" \
	--mount "type=bind,src=$rootfs,dst=/inputs/rootfs,readonly" \
	--mount "type=bind,src=$iso,dst=/inputs/live.iso,readonly" \
	"$runner_image" \
	/repo/scripts/qemu-container/test-pxe-diskless.sh \
		/inputs/kernel /inputs/initramfs /inputs/rootfs /inputs/live.iso \
		"$init_system"
