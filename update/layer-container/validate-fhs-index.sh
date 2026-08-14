#!/bin/sh

set -eu

test "$#" -eq 2
index=$1
target=$2
temporary=$(mktemp -d)
cleanup()
{
	rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

contract=$(
	/usr/local/libexec/validate-volatoo-fhs-index.py \
		"$index" "$target" "$temporary/reports"
)
awk \
	-v root= \
	-v directory_file="$temporary/reports/directories" \
	-v link_file="$temporary/reports/links" \
	-f /usr/local/libexec/validate-volatoo-elf-closure.awk \
	"$temporary/reports/directories" \
	"$temporary/reports/elf" \
	"$temporary/reports/links"
printf '%s\n' "$contract"
