#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
validator=$repo_root/update/layer-container/validate-elf-closure.awk
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-elf-closure-test.XXXXXX")

cleanup()
{
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

root=$work_dir/root
directories=$work_dir/directories
links=$work_dir/links
report=$work_dir/elf

printf '%s\n' /lib64 /usr/lib64 >"$directories"
printf '%s\n' \
	"$root/usr/lib64/libanswer.so.1|libanswer.so.1.2" >"$links"
printf '%s\n' \
	"$root/usr/bin/tool|ELFCLASS64|EM_X86_64|LE|NONE||libanswer.so.1| - |/lib64/ld-linux-x86-64.so.2" \
	"$root/usr/lib64/libanswer.so.1.2|ELFCLASS64|EM_X86_64|LE|NONE|libanswer.so.1||| " \
	"$root/opt/app/bin/helper|ELFCLASS64|EM_X86_64|LE|NONE||libprivate.so.1|\$ORIGIN/../lib|/lib64/ld-linux-x86-64.so.2" \
	"$root/opt/app/lib/libprivate.so.1|ELFCLASS64|EM_X86_64|LE|NONE|libprivate.so.1||| " \
	"$root/opt/tool/deep/wrapped-helper|ELFCLASS64|EM_X86_64|LE|NONE||libwrapped.so.1| - |/lib64/ld-linux-x86-64.so.2" \
	"$root/opt/tool/lib/libwrapped.so.1|ELFCLASS64|EM_X86_64|LE|NONE|libwrapped.so.1||| " \
	>"$report"

awk \
	-v root="$root" \
	-v directory_file="$directories" \
	-v link_file="$links" \
	-f "$validator" \
	"$directories" \
	"$report" \
	"$links" ||
	fail "ELF validator rejected resolvable default, RPATH or private providers"

cp "$report" "$work_dir/missing"
printf '%s\n' \
	"$root/usr/bin/broken|ELFCLASS64|EM_X86_64|LE|NONE||libmissing.so.1| - |/lib64/ld-linux-x86-64.so.2" \
	>>"$work_dir/missing"
if awk \
	-v root="$root" \
	-v directory_file="$directories" \
	-v link_file="$links" \
	-f "$validator" \
	"$directories" \
	"$work_dir/missing" \
	"$links" \
	>"$work_dir/missing.stdout" \
	2>"$work_dir/missing.stderr"
then
	fail "ELF validator accepted a missing public dependency"
fi
grep -q '/usr/bin/broken -> libmissing.so.1' \
	"$work_dir/missing.stderr" ||
	fail "ELF validator did not diagnose the missing public dependency"

printf '%s\n' \
	"$root/usr/bin/wrong-abi|ELFCLASS64|EM_X86_64|LE|NONE||libwrong.so.1| - |/lib64/ld-linux-x86-64.so.2" \
	"$root/usr/lib64/libwrong.so.1|ELFCLASS32|EM_386|LE|NONE|libwrong.so.1||| " \
	>"$work_dir/wrong-abi"
if awk \
	-v root="$root" \
	-v directory_file="$directories" \
	-v link_file="$links" \
	-f "$validator" \
	"$directories" \
	"$work_dir/wrong-abi" \
	"$links" \
	>"$work_dir/wrong-abi.stdout" \
	2>"$work_dir/wrong-abi.stderr"
then
	fail "ELF validator accepted an ABI-incompatible provider"
fi
grep -q '/usr/bin/wrong-abi -> libwrong.so.1' \
	"$work_dir/wrong-abi.stderr" ||
	fail "ELF validator did not diagnose the ABI-incompatible provider"

printf '%s\n' \
	"$root/usr/bin/relative-rpath|ELFCLASS64|EM_X86_64|LE|NONE||libanswer.so.1|relative/lib|/lib64/ld-linux-x86-64.so.2" \
	"$root/usr/lib64/libanswer.so.1.2|ELFCLASS64|EM_X86_64|LE|NONE|libanswer.so.1||| " \
	>"$work_dir/relative-rpath"
if awk \
	-v root="$root" \
	-v directory_file="$directories" \
	-v link_file="$links" \
	-f "$validator" \
	"$directories" \
	"$work_dir/relative-rpath" \
	"$links" \
	>"$work_dir/relative-rpath.stdout" \
	2>"$work_dir/relative-rpath.stderr"
then
	fail "ELF validator accepted a relative runtime search path"
fi
grep -q 'uses a non-deterministic path' \
	"$work_dir/relative-rpath.stderr" ||
	fail "ELF validator did not diagnose the relative runtime search path"

echo "volatoo ELF closure tests passed"
