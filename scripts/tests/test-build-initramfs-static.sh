#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-initramfs-static-test.XXXXXX")

cleanup()
{
	find "$test_root" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$test_root/bin" "$test_root/signify-root/usr/bin"
printf '#!/bin/sh\n' >"$test_root/busybox"
chmod 0755 "$test_root/busybox"
printf '#!/bin/sh\n' >"$test_root/signify-root/usr/bin/signify"
chmod 0755 "$test_root/signify-root/usr/bin/signify"
printf 'untrusted comment: test key\nRWQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' \
	>"$test_root/test.pub"

cat >"$test_root/bin/file" <<'EOF'
#!/bin/sh
printf '%s\n' "$VOLATOO_TEST_FILE_DESCRIPTION"
EOF
chmod 0755 "$test_root/bin/file"

build_with_description()
{
	description=$1
	output=$2
	VOLATOO_TEST_FILE_DESCRIPTION=$description \
		PATH="$test_root/bin:$PATH" \
		"$repo_root/scripts/build-initramfs.sh" \
			--busybox "$test_root/busybox" \
			--signify-root "$test_root/signify-root" \
			--trust-key "$test_root/test.pub" \
			--output "$output" >/dev/null
}

build_with_description \
	'ELF 64-bit LSB executable, x86-64, statically linked, stripped' \
	"$test_root/static.cpio.gz"
build_with_description \
	'ELF 64-bit LSB pie executable, x86-64, static-pie linked, stripped' \
	"$test_root/static-pie.cpio.gz"

if build_with_description \
	'ELF 64-bit LSB pie executable, x86-64, dynamically linked, stripped' \
	"$test_root/dynamic.cpio.gz" 2>/dev/null; then
	echo 'error: dynamically linked BusyBox was accepted' >&2
	exit 1
fi

echo 'initramfs BusyBox linkage policy tests passed'
