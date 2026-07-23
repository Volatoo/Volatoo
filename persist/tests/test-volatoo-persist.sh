#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
gentoo_image=${GENTOO_IMAGE:-gentoo/stage3:latest}

docker run --rm -i \
	--mount "type=bind,src=${repo_root},dst=/repo,readonly" \
	"${gentoo_image}" /bin/bash -s <<'CONTAINER'
set -euo pipefail

persist()
{
	VOLATOO_ROOT=/test/root \
	VOLATOO_STATE_ROOT=/test/state \
		/usr/bin/python3 /repo/persist/volatoo-persist "$@"
}

assert_content()
{
	expected=$1
	path=$2
	actual=$(cat "${path}")
	if [[ ${actual} != "${expected}" ]]; then
		printf 'expected %s in %s, got %s\n' \
			"${expected}" "${path}" "${actual}" >&2
		exit 1
	fi
}

image_a=$(printf 'a%.0s' {1..64})
image_b=$(printf 'b%.0s' {1..64})

mkdir -p \
	/test/root/.volatoo \
	/test/root/etc \
	/test/root/var/lib/volatoo-test \
	/test/state/volatoo/config \
	/test/state/volatoo/data/sync \
	/test/state/volatoo/snapshots
printf '1\n' > /test/state/volatoo/layout-version
printf '%s\n' \
	'sync /etc etc' \
	'sync /var/lib/volatoo-test var-lib-test' \
	> /test/state/volatoo/config/persist.conf
printf '%s\n' "${image_a}" > /test/root/.volatoo/image-id

printf 'base\n' > /test/root/etc/unchanged
printf 'base\n' > /test/root/etc/local-change
printf 'base\n' > /test/root/etc/image-change
printf 'base\n' > /test/root/etc/conflict
printf 'base\n' > /test/root/etc/deleted-locally
printf 'base\n' > /test/root/etc/shape
printf 'base\n' > /test/root/var/lib/volatoo-test/value

persist restore
printf 'local\n' > /test/root/etc/local-change
printf 'local\n' > /test/root/etc/conflict
printf 'local\n' > /test/root/etc/local-only
printf 'local\n' > /test/root/etc/shape
rm /test/root/etc/deleted-locally
printf 'local\n' > /test/root/var/lib/volatoo-test/value
persist sync

rm -rf /test/root/etc /test/root/var/lib/volatoo-test
mkdir -p /test/root/etc/shape/nested /test/root/var/lib/volatoo-test
printf 'base\n' > /test/root/etc/unchanged
printf 'base\n' > /test/root/etc/local-change
printf 'image\n' > /test/root/etc/image-change
printf 'image\n' > /test/root/etc/conflict
printf 'base\n' > /test/root/etc/deleted-locally
printf 'image\n' > /test/root/etc/image-only
printf 'image subtree\n' > /test/root/etc/shape/nested/file
printf 'image\n' > /test/root/var/lib/volatoo-test/value
printf '%s\n' "${image_b}" > /test/root/.volatoo/image-id

set +e
restore_output=$(persist restore 2>&1)
restore_status=$?
set -e
printf '%s\n' "${restore_output}"
[[ ${restore_status} -eq 2 ]]

assert_content base /test/root/etc/unchanged
assert_content local /test/root/etc/local-change
assert_content image /test/root/etc/image-change
assert_content local /test/root/etc/conflict
assert_content local /test/root/etc/local-only
assert_content image /test/root/etc/image-only
assert_content local /test/root/etc/shape
[[ ! -e /test/root/etc/deleted-locally ]]
assert_content local /test/root/var/lib/volatoo-test/value

cfg_file=$(find /test/root/etc -maxdepth 1 \
	-name '._cfg????_conflict' -print -quit)
[[ -n ${cfg_file} ]]
assert_content image "${cfg_file}"

archived_shape=$(find \
	/test/state/volatoo/snapshots/etc-conflicts \
	-path '*/new/shape/nested/file' -print -quit)
[[ -n ${archived_shape} ]]
assert_content 'image subtree' "${archived_shape}"

persist sync
status_output=$(persist status)
printf '%s\n' "${status_output}"
if grep -q $'\tnever$' <<<"${status_output}"; then
	echo 'expected every sync policy to have a current generation' >&2
	exit 1
fi

rm -rf /test/root/etc /test/root/var/lib/volatoo-test
mkdir -p /test/root/etc/shape/nested /test/root/var/lib/volatoo-test
printf 'base\n' > /test/root/etc/unchanged
printf 'base\n' > /test/root/etc/local-change
printf 'image\n' > /test/root/etc/image-change
printf 'image\n' > /test/root/etc/conflict
printf 'base\n' > /test/root/etc/deleted-locally
printf 'image\n' > /test/root/etc/image-only
printf 'image subtree\n' > /test/root/etc/shape/nested/file
printf 'image\n' > /test/root/var/lib/volatoo-test/value

persist restore
assert_content local /test/root/etc/local-change
assert_content local /test/root/etc/conflict
assert_content local /test/root/etc/shape
[[ ! -e /test/root/etc/deleted-locally ]]
assert_content local /test/root/var/lib/volatoo-test/value

rm -rf /test/state/volatoo/data/sync/etc/bases
ln -s /test/escape /test/state/volatoo/data/sync/etc/bases
set +e
unsafe_output=$(persist status 2>&1)
unsafe_status=$?
set -e
printf '%s\n' "${unsafe_output}"
[[ ${unsafe_status} -eq 1 ]]
grep -Fq 'must not be a symbolic link' <<<"${unsafe_output}"

echo 'volatoo-persist integration test passed'
CONTAINER
