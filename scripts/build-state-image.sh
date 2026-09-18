#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/build-state-image.sh [OPTIONS] [OUTPUT]

Build an ext4 Volatoo state filesystem image with Docker. OUTPUT defaults to
out/volatoo-state.ext4. Without --source, an empty compatible layout is
created. The script only creates a regular file and never writes to a block
device.

Options:
  --config PATH          Install a persistence policy.
  --identity-config PATH Install a machine-identity policy.
  --source PATH          Seed from a prepared state-root directory. This
                         cannot be combined with either config option.

Optional environment variables:
  VOLATOO_STATE_SIZE  Filesystem image size (default: 128M)
  VOLATOO_STATE_EPOCH Reference epoch for filesystem timestamps, in seconds
                      since the Unix epoch (default: 0). The image UUID and
                      hash seed are derived from the state content, not from
                      this epoch.
EOF
}

config_path=
identity_config_path=
state_source_path=
output_path=

while (( $# > 0 )); do
	case $1 in
		--config | --identity-config | --source)
			if (( $# < 2 )); then
				echo "error: $1 requires a value" >&2
				exit 2
			fi
			case $1 in
				--config) config_path=$2 ;;
				--identity-config) identity_config_path=$2 ;;
				--source) state_source_path=$2 ;;
			esac
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
state_epoch=${VOLATOO_STATE_EPOCH:-0}

if [[ ! $state_size =~ ^[1-9][0-9]*[MGT]$ ]]; then
	echo "error: VOLATOO_STATE_SIZE must be a positive integer followed by M, G, or T" >&2
	exit 1
fi
if [[ ! $state_epoch =~ ^[0-9]+$ ]]; then
	echo "error: VOLATOO_STATE_EPOCH must be a non-negative integer" >&2
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

if [[ -n $state_source_path && \
	(-n $config_path || -n $identity_config_path) ]]; then
	echo "error: --source cannot be combined with configuration options" >&2
	exit 2
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
if [[ -n $state_source_path ]]; then
	if [[ ! -d $state_source_path ]]; then
		echo "error: state source directory does not exist: $state_source_path" >&2
		exit 1
	fi
	if [[ ! -f $state_source_path/volatoo/layout-version ]]; then
		echo "error: state source has no volatoo/layout-version" >&2
		exit 1
	fi
	state_source_path=$(cd -- "$state_source_path" && pwd)
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
	--env "SOURCE_DATE_EPOCH=$state_epoch"
	--env "HOST_UID=$(id -u)"
	--env "HOST_GID=$(id -g)"
	--env "HAS_CONFIG=no"
	--env "HAS_IDENTITY_CONFIG=no"
	--env "HAS_STATE_SOURCE=no"
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
if [[ -n $state_source_path ]]; then
	docker_args+=(
		--env "HAS_STATE_SOURCE=yes"
		--volume "$state_source_path:/input/state-root:ro"
	)
fi

docker run "${docker_args[@]}" \
	amd64/alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f \
	sh -euxc '
		apk add --no-cache coreutils=9.11-r0 e2fsprogs=1.47.4-r0 >/dev/null
		state_root=/tmp/state-root
		if [ "$HAS_STATE_SOURCE" = yes ]; then
			install -d -m 0755 "$state_root"
			cp -a /input/state-root/. "$state_root/"
			test "$(cat "$state_root/volatoo/layout-version")" = 1
			test "$(cat "$state_root/volatoo/system/layout-version")" = 1
			for path in \
				config \
				data/bind \
				data/identity \
				data/overlay \
				data/sync \
				snapshots \
				system/manifests \
				system/objects/sha256 \
				system/plans \
				system/pins \
				system/realizations \
				system/signatures \
				system/activations \
				system/compactions \
				system/staging
			do
				test -d "$state_root/volatoo/$path"
				test ! -L "$state_root/volatoo/$path"
			done
		else
			install -d -m 0755 "$state_root/volatoo/config"
			install -d -m 0700 \
				"$state_root/volatoo/data/bind" \
				"$state_root/volatoo/data/identity" \
				"$state_root/volatoo/data/overlay" \
				"$state_root/volatoo/data/sync" \
				"$state_root/volatoo/snapshots" \
				"$state_root/volatoo/system/staging"
			install -d -m 0755 \
				"$state_root/volatoo/system/manifests" \
				"$state_root/volatoo/system/objects/sha256" \
				"$state_root/volatoo/system/plans" \
				"$state_root/volatoo/system/pins" \
				"$state_root/volatoo/system/realizations" \
				"$state_root/volatoo/system/signatures" \
				"$state_root/volatoo/system/activations" \
				"$state_root/volatoo/system/compactions"
			printf "1\n" >"$state_root/volatoo/layout-version"
			printf "1\n" >"$state_root/volatoo/system/layout-version"
		fi
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
		derive_hex() {
			label=$1
			first=${2:-32}
			printf "%s:%s" "$state_seed" "$label" | sha256sum \
				| awk -v n="$first" "{ print substr(\$1, 1, n) }"
		}
		guid_from_hex() {
			hex=$1
			printf "%s-%s-%s-%s-%s" \
				"$(printf "%s" "$hex" | cut -c1-8)" \
				"$(printf "%s" "$hex" | cut -c9-12)" \
				"5$(printf "%s" "$hex" | cut -c14-16)" \
				"8$(printf "%s" "$hex" | cut -c18-20)" \
				"$(printf "%s" "$hex" | cut -c21-32)"
		}
		state_content_sha256=$(
			cd "$state_root" || exit 1
			find . -mindepth 1 | LC_ALL=C sort \
				| while IFS= read -r entry; do
					if [ -L "$entry" ]; then
						printf "l %s %s -> %s\n" \
							"$entry" "$(readlink "$entry")"
					elif [ -d "$entry" ]; then
						printf "d %s %s\n" \
							"$(stat -c %a "$entry")" "$entry"
					else
						printf "f %s %s %s\n" \
							"$(stat -c %a "$entry")" \
							"$(stat -c %s "$entry")" "$entry"
						sha256sum "$entry"
					fi
				done \
				| sha256sum | awk "{ print \$1 }"
		)
		state_seed="volatoo-state:$state_content_sha256"
		state_uuid=$(guid_from_hex "$(derive_hex volatoo-state-uuid)")
		state_hash_seed=$(guid_from_hex "$(derive_hex volatoo-hash-seed)")
		find "$state_root" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
		truncate -s "$STATE_SIZE" /output/volatoo-state.ext4
		SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" mkfs.ext4 -q -F \
			-L VOLATOO-STATE \
			-U "$state_uuid" \
			-E hash_seed="$state_hash_seed" \
			-d "$state_root" \
			/output/volatoo-state.ext4
		chown "$HOST_UID:$HOST_GID" /output/volatoo-state.ext4
	'

mv -- "$export_dir/volatoo-state.ext4" "$output_path"
echo "built $output_path"
