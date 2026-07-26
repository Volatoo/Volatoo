#!/bin/sh

set -eu

test "$#" -le 2

input=${1:-/input}
output_directory=${2:-/output}
output=$output_directory/layer.squashfs
temporary=$output_directory/.layer.squashfs.tmp

test -d "$input"
test -d "$output_directory"
test ! -e "$output"
test ! -e "$temporary"

mksquashfs -version |
	sed -n '1s/^mksquashfs version \([^ ]*\).*/\1/p' \
		>"$output_directory/compressor-version"
test "$(cat "$output_directory/compressor-version")" = 4.7.5

mksquashfs "$input" "$temporary" \
	-noappend \
	-comp zstd \
	-Xcompression-level 19 \
	-b 1M \
	-all-time 0 \
	-mkfs-time 0 \
	-reproducible \
	-processors 1 \
	-no-progress

mv "$temporary" "$output"
