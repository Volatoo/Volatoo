#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/build-state-image.sh [--config PATH] [--identity-config PATH] [OUTPUT]

Build an empty ext4 Volatoo state filesystem image with Docker. OUTPUT defaults
to out/volatoo-state.ext4. The script only creates a regular file and never
writes to a block device.

Optional environment variables:
  VOLATOO_STATE_SIZE  Filesystem image size (default: 128M)
EOF
}

config_path=
identity_config_path=
output_path=

while (( $# > 0 )); do
	case $1 in
		--config | --identity-config)
			if (( $# < 2 )); then
				echo "error: $1 requires a value" >&2
				exit 2
			fi
			if [[ $1 == --config ]]; then
				config_path=$2
			else
				identity_config_path=$2
			fi
			shift 2
			;;
		-h | --help)
			usage
			exit 0
			;;
		-*)
			echo "error: unknown argument: $1" >&2
			usage >&2
			exit 2
			;;
		*)
			if [[ -n $output_path ]]; then
				echo "error: only one output path may be supplied" >&2
				exit 2
			fi
			output_path=$1
			shift
			;;
	esac
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_path=${output_path:-"$repo_root/out/volatoo-state.ext4"}
state_size=${VOLATOO_STATE_SIZE:-128M}

if [[ ! $state_size =~ ^[1-9][0-9]*[MGT]$ ]]; then
	echo "error: VOLATOO_STATE_SIZE must be a positive integer followed by M, G, or T" >&2
	exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "error: docker is not installed" >&2
	exit 1
fi

if ! docker info >/dev/null 2>&1; then
	echo "error: the Docker daemon is not available" >&2
	exit 1
fi

if [[ -n $config_path ]]; then
	if [[ ! -f $config_path ]]; then
		echo "error: persistence configuration does not exist: $config_path" >&2
		exit 1
	fi
	config_path=$(cd -- "$(dirname -- "$config_path")" && pwd)/$(basename -- "$config_path")
fi
if [[ -n $identity_config_path ]]; then
	if [[ ! -f $identity_config_path ]]; then
		echo "error: identity configuration does not exist: $identity_config_path" >&2
		exit 1
	fi
	identity_config_path=$(cd -- "$(dirname -- "$identity_config_path")" && pwd)/$(basename -- "$identity_config_path")
fi

mkdir -p "$(dirname -- "$output_path")"
output_path=$(cd -- "$(dirname -- "$output_path")" && pwd)/$(basename -- "$output_path")
export_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-state.XXXXXX")

cleanup() {
	rm -rf -- "$export_dir"
}
trap cleanup EXIT

docker_args=(
	--rm
	--env "STATE_SIZE=$state_size"
	--env "HOST_UID=$(id -u)"
	--env "HOST_GID=$(id -g)"
	--env "HAS_CONFIG=no"
	--env "HAS_IDENTITY_CONFIG=no"
	--volume "$export_dir:/output"
)
if [[ -n $config_path ]]; then
	docker_args+=(
		--env "HAS_CONFIG=yes"
		--volume "$config_path:/input/persist.conf:ro"
	)
fi
if [[ -n $identity_config_path ]]; then
	docker_args+=(
		--env "HAS_IDENTITY_CONFIG=yes"
		--volume "$identity_config_path:/input/identity.conf:ro"
	)
fi

docker run "${docker_args[@]}" \
	alpine:3.24 \
	sh -euxc '
		apk add --no-cache coreutils e2fsprogs >/dev/null
		state_root=/tmp/state-root
		install -d -m 0755 "$state_root/volatoo/config"
		install -d -m 0700 \
			"$state_root/volatoo/data/bind" \
			"$state_root/volatoo/data/identity" \
			"$state_root/volatoo/data/overlay" \
			"$state_root/volatoo/data/sync" \
			"$state_root/volatoo/snapshots"
		printf "1\n" >"$state_root/volatoo/layout-version"
		if [ "$HAS_CONFIG" = yes ]; then
			install -m 0600 \
				/input/persist.conf \
				"$state_root/volatoo/config/persist.conf"
		fi
		if [ "$HAS_IDENTITY_CONFIG" = yes ]; then
			install -m 0600 \
				/input/identity.conf \
				"$state_root/volatoo/config/identity.conf"
		fi
		truncate -s "$STATE_SIZE" /output/volatoo-state.ext4
		mkfs.ext4 -q -F \
			-L VOLATOO-STATE \
			-d "$state_root" \
			/output/volatoo-state.ext4
		chown "$HOST_UID:$HOST_GID" /output/volatoo-state.ext4
	'

mv -- "$export_dir/volatoo-state.ext4" "$output_path"
echo "built $output_path"
