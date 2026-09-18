#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/tests/test-state-image-reproducible-docker.sh \
  [--config PATH] [--identity-config PATH] [--source PATH] \
  [--evidence PATH]

Build the Volatoo state filesystem image twice from the same inputs in the
OrbStack Docker context and assert that both images are byte-identical. The
image and its SHA-256 are the reproducibility claim. When --evidence is
given, the two digests and the build commands are written there for audit.
EOF
}

config=
identity_config=
source_dir=
evidence=
while (( $# > 0 )); do
	case $1 in
		--config|--identity-config|--source|--evidence)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--config) config=$2 ;;
				--identity-config) identity_config=$2 ;;
				--source) source_dir=$2 ;;
				--evidence) evidence=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
		*) echo "error: unexpected positional argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

if [[ -n $source_dir && (-n $config || -n $identity_config) ]]; then
	echo "error: --source cannot be combined with configuration options" >&2
	exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder=$repo_root/scripts/build-state-image.sh
[[ -x $builder ]] || {
	echo "error: state builder is missing: $builder" >&2
	exit 1
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-state-reproducible.XXXXXX")
cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

build_args=()
[[ -z $config ]] || build_args+=(--config "$config")
[[ -z $identity_config ]] || build_args+=(--identity-config "$identity_config")
[[ -z $source_dir ]] || build_args+=(--source "$source_dir")

echo "building first image"
"$builder" "${build_args[@]+"${build_args[@]}"}" "$work_dir/first.ext4"
echo "building second image"
"$builder" "${build_args[@]+"${build_args[@]}"}" "$work_dir/second.ext4"

checksum_file()
{
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

first_sha256=$(checksum_file "$work_dir/first.ext4")
second_sha256=$(checksum_file "$work_dir/second.ext4")

echo "first image  SHA-256: $first_sha256"
echo "second image SHA-256: $second_sha256"

if [[ $first_sha256 != "$second_sha256" ]]; then
	echo "error: state image is not bit-reproducible" >&2
	cmp -l "$work_dir/first.ext4" "$work_dir/second.ext4" 2>/dev/null | head -20 >&2 || true
	exit 1
fi

echo "state image is bit-reproducible: two builds produced identical images"

if [[ -n $evidence ]]; then
	build_command=$builder
	if (( ${#build_args[@]} > 0 )); then
		build_command="$build_command ${build_args[*]}"
	fi
	build_command="$build_command OUTPUT"
	{
		echo "schema=org.volatoo.reproducibility/v1"
		echo "artifact=state"
		echo "state_sha256=$first_sha256"
		if [[ -n $config ]]; then
			echo "config=$config"
		fi
		if [[ -n $identity_config ]]; then
			echo "identity_config=$identity_config"
		fi
		if [[ -n $source_dir ]]; then
			echo "source=$source_dir"
		fi
		echo "build_command=$build_command"
	} >"$evidence"
	echo "evidence written: $evidence"
fi
