#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/test-qemu-boot-docker.sh KERNEL INITRAMFS IMAGE

Run scripts/test-qemu-boot.sh inside a pinned QEMU container. The regular
VOLATOO_TEST_* variables are forwarded. VOLATOO_STATE_IMAGE is mounted
writable when set. Docker is required.
EOF
}

if (( $# != 3 )); then
	usage >&2
	exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kernel=$1
initramfs=$2
image=$3
runner_image=${VOLATOO_QEMU_RUNNER_IMAGE:-volatoo-qemu-runner:1}

for path in "$kernel" "$initramfs" "$image"; do
	[[ -f $path && ! -L $path ]] || {
		echo "error: QEMU input is missing or unsafe: $path" >&2
		exit 1
	}
done
command -v docker >/dev/null 2>&1 || {
	echo "error: docker is not installed" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "error: the Docker daemon is not available" >&2
	exit 1
}

kernel=$(cd -- "$(dirname -- "$kernel")" && pwd)/$(basename -- "$kernel")
initramfs=$(cd -- "$(dirname -- "$initramfs")" && pwd)/$(basename -- "$initramfs")
image=$(cd -- "$(dirname -- "$image")" && pwd)/$(basename -- "$image")

docker build \
	--tag "$runner_image" \
	"$repo_root/scripts/qemu-container"

mounts=(
	--mount "type=bind,src=$repo_root,dst=/repo,readonly"
	--mount "type=bind,src=$kernel,dst=/inputs/kernel,readonly"
	--mount "type=bind,src=$initramfs,dst=/inputs/initramfs,readonly"
	--mount "type=bind,src=$image,dst=/inputs/rootfs,readonly"
)
state_argument=
if [[ -n ${VOLATOO_STATE_IMAGE:-} ]]; then
	[[ -f $VOLATOO_STATE_IMAGE && ! -L $VOLATOO_STATE_IMAGE ]] || {
		echo "error: state image is missing or unsafe: $VOLATOO_STATE_IMAGE" >&2
		exit 1
	}
	state=$(cd -- "$(dirname -- "$VOLATOO_STATE_IMAGE")" && pwd)/$(basename -- "$VOLATOO_STATE_IMAGE")
	mounts+=(--mount "type=bind,src=$state,dst=/inputs/state")
	state_argument=/inputs/state
fi

metrics_argument=
if [[ -n ${VOLATOO_TEST_METRICS_FILE:-} ]]; then
	metrics_parent=$(dirname -- "$VOLATOO_TEST_METRICS_FILE")
	[[ -d $metrics_parent ]] || {
		echo "error: metrics output directory does not exist: $metrics_parent" >&2
		exit 1
	}
	[[ ! -L $VOLATOO_TEST_METRICS_FILE ]] || {
		echo "error: metrics output must not be a symbolic link" >&2
		exit 1
	}
	if [[ -e $VOLATOO_TEST_METRICS_FILE && ! -f $VOLATOO_TEST_METRICS_FILE ]]; then
		echo "error: metrics output is not a regular file" >&2
		exit 1
	fi
	metrics_parent=$(cd -- "$metrics_parent" && pwd)
	metrics=$metrics_parent/$(basename -- "$VOLATOO_TEST_METRICS_FILE")
	: >>"$metrics"
	mounts+=(--mount "type=bind,src=$metrics,dst=/outputs/metrics.tsv")
	metrics_argument=/outputs/metrics.tsv
fi

forwarded=(
	VOLATOO_IMAGE_SHA256
	VOLATOO_GENERATION
	VOLATOO_STATE_REQUIRED
	VOLATOO_TEST_POLICIES
	VOLATOO_TEST_IDENTITY
	VOLATOO_TEST_SHUTDOWN_SYNC
	VOLATOO_TEST_INIT_SYSTEM
	VOLATOO_TEST_GENERATION
	VOLATOO_TEST_GENERATION_REALIZED
	VOLATOO_TEST_GENERATION_VERITY
	VOLATOO_TEST_GENERATION_PAYLOAD
	VOLATOO_TEST_GENERATION_FALLBACK
	VOLATOO_TEST_GENERATION_SIGNATURE
	VOLATOO_TEST_SERVICE_READY
	VOLATOO_TEST_UPDATE_VIEW
	VOLATOO_TEST_FIRMWARES
	VOLATOO_TEST_ROOT_MODE
	VOLATOO_TEST_TIMEOUT
	VOLATOO_TEST_EXPECT_FAILURE_CODE
	VOLATOO_VM_MEMORY
)
environment=(
	--env "VOLATOO_STATE_IMAGE=$state_argument"
	--env "VOLATOO_TEST_METRICS_FILE=$metrics_argument"
	--env VOLATOO_QEMU_ACCEL=tcg
)
for name in "${forwarded[@]}"; do
	if [[ -n ${!name+x} ]]; then
		environment+=(--env "$name=${!name}")
	fi
done

docker run --rm \
	--network none \
	"${mounts[@]}" \
	"${environment[@]}" \
	"$runner_image" \
	/repo/scripts/test-qemu-boot.sh \
		/inputs/kernel /inputs/initramfs /inputs/rootfs
