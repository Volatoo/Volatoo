#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
merger=$repo_root/update/layer-container/merge-fhs-index.py
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-fhs-index-merge.XXXXXX")
trap 'find "$work_dir" -depth -delete 2>/dev/null || true' EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

write_index()
{
	output=$1
	shift
	{
		printf 'VOLATOO_FHS_ELF_INDEX_V1\n'
		printf 'target volatoo/amd64/glibc/openrc/23.0/base-v1\n'
		printf '%s\n' "$@" | LC_ALL=C sort -u
		printf 'end\n'
	} >"$output"
}

write_index "$work_dir/parent" \
	'L|/bin|usr/bin' \
	'P|/|d|755' \
	'P|/bin|l|777' \
	'P|/opt|d|755' \
	'P|/opt/old|f|644' \
	'P|/replace|d|755' \
	'P|/replace/child|f|644' \
	'P|/usr|d|755' \
	'P|/usr/bin|d|755'
write_index "$work_dir/child" \
	'L|/bin|usr/bin' \
	'P|/|d|755' \
	'P|/bin|l|777' \
	'P|/opt|d|700' \
	'P|/opt/new|f|755' \
	'P|/replace|f|600' \
	'P|/usr|d|755' \
	'P|/usr/bin|d|755'
printf '%s\n' /opt /opt/new /replace >"$work_dir/affected"
printf '%s\n' /opt >"$work_dir/tombstones"

python3 "$merger" \
	"$work_dir/parent" \
	"$work_dir/child" \
	"$work_dir/affected" \
	"$work_dir/tombstones" \
	"$work_dir/merged"
cmp "$work_dir/merged" "$work_dir/child" ||
	fail "merged validation index differs from the complete child index"

printf '%s\n' /missing >"$work_dir/missing-affected"
if python3 "$merger" \
	"$work_dir/parent" \
	"$work_dir/child" \
	"$work_dir/missing-affected" \
	"$work_dir/tombstones" \
	"$work_dir/rejected" 2>"$work_dir/rejected.stderr"; then
	fail "index merger accepted an affected path absent from the child index"
fi
grep -F 'affected path is absent from child index' \
	"$work_dir/rejected.stderr" >/dev/null ||
	fail "index merger did not diagnose the absent affected path"

echo "Volatoo FHS/ELF index merge tests passed"
