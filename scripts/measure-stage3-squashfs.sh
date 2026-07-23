#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/measure-stage3-squashfs.sh [ZSTD_LEVEL ...]

Measure complete Docker build time, image size, and single-core native
unsquashfs extraction time for each SquashFS Zstd level. The default matrix
is: 3 10 15 19.

The extraction result is a host-native Docker reference. It does not represent
the initramfs mount-and-copy path or an emulated target architecture.

Results and per-level build logs are written below out/measurements/. Temporary
SquashFS images are removed when the script exits.
EOF
}

if [[ ${1:-} == --help ]]; then
	usage
	exit 0
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if (( $# == 0 )); then
	levels=(3 10 15 19)
else
	levels=("$@")
fi
results_dir=$repo_root/out/measurements
report_path=$results_dir/squashfs.tsv

for level in "${levels[@]}"; do
	if ! [[ $level =~ ^([1-9]|1[0-9]|2[0-2])$ ]]; then
		echo "error: Zstd levels must be integers from 1 to 22: $level" >&2
		exit 1
	fi
done

mkdir -p "$results_dir"

work_dir=$(mktemp -d "$results_dir/work.XXXXXX")
cleanup() {
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

file_size() {
	if stat -f '%z' "$1" >/dev/null 2>&1; then
		stat -f '%z' "$1"
	else
		stat -c '%s' "$1"
	fi
}

file_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

measure_native_extract() {
	local image_path=$1

	docker run --rm \
		--tmpfs /extract:rw,size=5g \
		--volume "$image_path:/input/root.squashfs:ro" \
		alpine:3.24 sh -eu -c '
			apk add --no-cache squashfs-tools >/dev/null 2>&1
			started=$(date +%s)
			unsquashfs -processors 1 -no-progress \
				-d /extract/root /input/root.squashfs >/dev/null
			finished=$(date +%s)
			echo $((finished - started))
		'
}

printf 'zstd_level\tbuild_seconds\timage_bytes\tnative_extract_seconds_1cpu\tsha256\n' \
	>"$report_path"

for level in "${levels[@]}"; do
	image_path=$work_dir/volatoo-stage3.squashfs
	log_path=$results_dir/build-zstd-$level.log
	build_nonce="measure-$(date +%s)-$$-$level"
	started=$(date +%s)

	echo "measuring Zstd level $level"
	if ! VOLATOO_ZSTD_LEVEL=$level \
		VOLATOO_BUILD_NONCE=$build_nonce \
		"$repo_root/scripts/build-stage3-squashfs.sh" "$image_path" \
		>"$log_path" 2>&1; then
		tail -n 80 "$log_path" >&2
		exit 1
	fi

	finished=$(date +%s)
	elapsed=$((finished - started))
	bytes=$(file_size "$image_path")
	checksum=$(file_sha256 "$image_path")
	extract_seconds=$(measure_native_extract "$image_path")

	printf '%s\t%s\t%s\t%s\t%s\n' \
		"$level" "$elapsed" "$bytes" "$extract_seconds" "$checksum" \
		>>"$report_path"
	printf '  build %ss, %s bytes, native extract %ss\n' \
		"$elapsed" "$bytes" "$extract_seconds"
done

echo "wrote $report_path"
