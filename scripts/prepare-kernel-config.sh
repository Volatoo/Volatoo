#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/prepare-kernel-config.sh KERNEL_SOURCE [OUTPUT_DIR]

Create an amd64 Linux .config by merging the Volatoo baseline on top of
x86_64_defconfig, resolve dependencies with olddefconfig, and validate that
every baseline requirement remains built in.

OUTPUT_DIR defaults to out/kernel-build. A non-empty directory is accepted
only when it was previously initialized by this script.
EOF
}

if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
	usage
	exit 0
fi

if (( $# < 1 || $# > 2 )); then
	usage >&2
	exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source_dir=$1
output_dir=${2:-"$repo_root/out/kernel-build"}
fragment_path=$repo_root/kernel/config/amd64.fragment

if [[ ! -f $source_dir/Makefile ]] ||
	[[ ! -x $source_dir/scripts/kconfig/merge_config.sh ]]; then
	echo "error: not a complete Linux kernel source tree: $source_dir" >&2
	exit 1
fi
if ! command -v make >/dev/null 2>&1; then
	echo "error: make is required" >&2
	exit 1
fi

source_dir=$(cd -- "$source_dir" && pwd)
mkdir -p "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
marker=$output_dir/.volatoo-kernel-build

if [[ ! -e $marker ]] &&
	find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
	echo "error: refusing to reuse an unmarked non-empty output directory: $output_dir" >&2
	exit 1
fi
: >"$marker"

make -C "$source_dir" O="$output_dir" ARCH=x86_64 x86_64_defconfig
"$source_dir/scripts/kconfig/merge_config.sh" \
	-m -O "$output_dir" "$output_dir/.config" "$fragment_path"
make -C "$source_dir" O="$output_dir" ARCH=x86_64 olddefconfig
"$repo_root/scripts/validate-kernel-config.sh" \
	"$output_dir/.config" "$fragment_path"

echo "prepared $output_dir/.config"
