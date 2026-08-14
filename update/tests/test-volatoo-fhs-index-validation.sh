#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
validator=$repo_root/update/layer-container/validate-fhs-index.py
merger=$repo_root/update/layer-container/merge-fhs-index.py
elf_validator=$repo_root/update/layer-container/validate-elf-closure.awk
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-fhs-index-validation.XXXXXX")
trap 'find "$work_dir" -depth -delete 2>/dev/null || true' EXIT
target=volatoo/amd64/glibc/openrc/23.0/base-v1

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
		printf 'target %s\n' "$target"
		printf '%s\n' "$@" | LC_ALL=C sort -u
		printf 'end\n'
	} >"$output"
}

parent_records=(
	'L|/bin|usr/bin'
	'L|/lib|usr/lib'
	'L|/lib64|usr/lib64'
	'L|/sbin|usr/bin'
	'P|/|d|755'
	'P|/bin|l|777'
	'P|/etc|d|755'
	'P|/etc/init.d|d|755'
	'P|/etc/portage|d|755'
	'P|/lib|l|777'
	'P|/lib64|l|777'
	'P|/sbin|l|777'
	'P|/usr|d|755'
	'P|/usr/bin|d|755'
	'P|/usr/bin/init|f|755'
	'P|/usr/bin/openrc|f|755'
	'P|/usr/bin/sh|f|755'
	'P|/usr/lib|d|755'
	'P|/usr/lib64|d|755'
	'P|/usr/lib64/ld-linux-x86-64.so.2|f|755'
	'P|/usr/lib64/libparent.so.1|f|755'
	'P|/var|d|755'
	'P|/var/db|d|755'
	'P|/var/db/pkg|d|755'
	'E|/usr/lib64/libparent.so.1|ELFCLASS64|EM_X86_64|LE|NONE|libparent.so.1|||'
)
write_index "$work_dir/parent" "${parent_records[@]}"
write_index "$work_dir/delta" \
	'P|/usr/bin/new-tool|f|755' \
	'S|/usr/bin/new-tool|/bin/sh' \
	'E|/usr/bin/new-tool|ELFCLASS64|EM_X86_64|LE|NONE||libparent.so.1||/lib64/ld-linux-x86-64.so.2'
printf '%s\n' /usr/bin/new-tool >"$work_dir/affected"
: >"$work_dir/tombstones"
python3 "$merger" \
	"$work_dir/parent" \
	"$work_dir/delta" \
	"$work_dir/affected" \
	"$work_dir/tombstones" \
	"$work_dir/merged"
contract=$(python3 "$validator" "$work_dir/merged" "$target" "$work_dir/reports")
[[ $contract == org.volatoo.gentoo-fhs/v1 ]] ||
	fail "merged validation index returned the wrong FHS contract"
awk \
	-v root= \
	-v directory_file="$work_dir/reports/directories" \
	-v link_file="$work_dir/reports/links" \
	-f "$elf_validator" \
	"$work_dir/reports/directories" \
	"$work_dir/reports/elf" \
	"$work_dir/reports/links" ||
	fail "new-layer shebang and ELF edges did not resolve through the parent index"

printf '%s\n' /usr/lib64/libparent.so.1 >"$work_dir/provider-tombstone"
python3 "$merger" \
	"$work_dir/parent" \
	"$work_dir/delta" \
	"$work_dir/affected" \
	"$work_dir/provider-tombstone" \
	"$work_dir/missing-provider"
python3 "$validator" \
	"$work_dir/missing-provider" "$target" "$work_dir/missing-reports" \
	>/dev/null
if awk \
	-v root= \
	-v directory_file="$work_dir/missing-reports/directories" \
	-v link_file="$work_dir/missing-reports/links" \
	-f "$elf_validator" \
	"$work_dir/missing-reports/directories" \
	"$work_dir/missing-reports/elf" \
	"$work_dir/missing-reports/links" \
	>"$work_dir/missing.stdout" 2>"$work_dir/missing.stderr"
then
	fail "merged validation index accepted a tombstoned ELF provider"
fi
grep -F '/usr/bin/new-tool -> libparent.so.1' "$work_dir/missing.stderr" >/dev/null ||
	fail "ELF validator did not diagnose the tombstoned parent provider"

echo "Volatoo authenticated FHS/ELF index validation tests passed"
