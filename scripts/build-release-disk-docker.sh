#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/build-release-disk-docker.sh \
  --init-system openrc|systemd \
  --kernel PATH --initramfs PATH --rootfs PATH --state PATH \
  OUTPUT.img

Build a new BIOS/UEFI v0.1-dev raw disk image inside the OrbStack Docker
context. OUTPUT must not exist. This command never accepts a block device.
EOF
}

init_system=
kernel=
initramfs=
rootfs=
state=
output=
while (( $# > 0 )); do
	case $1 in
		--init-system|--kernel|--initramfs|--rootfs|--state)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--init-system) init_system=$2 ;;
				--kernel) kernel=$2 ;;
				--initramfs) initramfs=$2 ;;
				--rootfs) rootfs=$2 ;;
				--state) state=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
		*) [[ -z $output ]] || { echo "error: only one output is allowed" >&2; exit 2; }; output=$1; shift ;;
	esac
done

[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: --init-system must be openrc or systemd" >&2
	exit 2
}
[[ -n $output ]] || { echo "error: OUTPUT.img is required" >&2; exit 2; }
[[ $output == *.img ]] || { echo "error: OUTPUT must end in .img" >&2; exit 2; }
[[ ! -e $output && ! -e $output.manifest ]] || {
	echo "error: output or manifest already exists: $output" >&2
	exit 1
}
for variable in kernel initramfs rootfs state; do
	path=${!variable}
	[[ -f $path && ! -L $path ]] || {
		echo "error: --$variable must name a regular non-symlink file" >&2
		exit 1
	}
	printf -v "$variable" '%s/%s' "$(cd -- "$(dirname -- "$path")" && pwd)" "$(basename -- "$path")"
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_dir=$(cd -- "$(dirname -- "$output")" && pwd)
output_name=$(basename -- "$output")
[[ $output_name =~ ^[A-Za-z0-9._-]+\.img$ ]] || {
	echo "error: unsafe output filename: $output_name" >&2
	exit 1
}
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}

image=volatoo-release-builder:0.1-dev
docker build \
	--platform linux/amd64 \
	--tag "$image" \
	--file "$repo_root/scripts/release-container/Dockerfile" \
	"$repo_root"
docker run --rm --privileged \
	--platform linux/amd64 \
	--env "INIT_SYSTEM=$init_system" \
	--env "OUTPUT_NAME=$output_name" \
	--env "HOST_UID=$(id -u)" \
	--env "HOST_GID=$(id -g)" \
	--mount "type=bind,src=$kernel,dst=/input/kernel,readonly" \
	--mount "type=bind,src=$initramfs,dst=/input/initramfs,readonly" \
	--mount "type=bind,src=$rootfs,dst=/input/rootfs,readonly" \
	--mount "type=bind,src=$state,dst=/input/state,readonly" \
	--mount "type=bind,src=$output_dir,dst=/output" \
	"$image"
