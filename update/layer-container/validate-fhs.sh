#!/bin/sh

set -eu

test "$#" -eq 2 || test "$#" -eq 3
root=$1
target=$2
index_output=${3:-}
temporary=$(mktemp -d)
cleanup()
{
	rm -rf "$temporary"
}
trap cleanup EXIT HUP INT TERM

index-volatoo-fhs-tree "$root" "$target" "$temporary/index"
contract=$(validate-volatoo-fhs-index "$temporary/index" "$target")
if [ -n "$index_output" ]; then
	case $index_output in
		/*) ;;
		*) echo "error: FHS validation index output must be absolute" >&2; exit 1 ;;
	esac
	if [ -e "$index_output" ] || [ -L "$index_output" ]; then
		echo "error: FHS validation index output already exists: $index_output" >&2
		exit 1
	fi
	mv "$temporary/index" "$index_output"
fi
printf '%s\n' "$contract"
