#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
gentoo_image=${GENTOO_IMAGE:-gentoo/stage3:latest}

docker run --rm -i --privileged \
	--mount "type=bind,src=${repo_root},dst=/repo,readonly" \
	"${gentoo_image}" /bin/bash -s <<'CONTAINER'
set -euo pipefail

identity()
{
	VOLATOO_ROOT=/test/root \
	VOLATOO_STATE_ROOT=/test/state \
	VOLATOO_UUID_SOURCE=/test/random-uuid \
		/usr/bin/python3 /repo/persist/volatoo-identity "$@"
}

assert_not_mounted()
{
	if awk '$2 == "/test/root/var/log" { found = 1 } END { exit !found }' \
		/proc/mounts; then
		echo '/test/root/var/log is unexpectedly mounted' >&2
		exit 1
	fi
}

mkdir -p \
	/test/root/etc/ssh \
	/test/root/var/log \
	/test/state/volatoo/config \
	/test/state/volatoo/data
printf '1\n' > /test/state/volatoo/layout-version
printf '12345678-1234-4abc-8def-1234567890ab\n' > /test/random-uuid
printf 'image log\n' > /test/root/var/log/image.log

identity apply
grep -qx '1234567812344abc8def1234567890ab' \
	/test/root/etc/machine-id
test -s /test/root/etc/ssh/ssh_host_ed25519_key
test -s /test/root/etc/ssh/ssh_host_ed25519_key.pub
grep -q ' /test/root/var/log ' /proc/mounts
[[ $(stat -c '%a' /test/root/var/log) == 755 ]]

mkdir -p /test/expected
cp /test/root/etc/machine-id /test/expected/machine-id
cp /test/root/etc/ssh/ssh_host_ed25519_key /test/expected/host-key
printf 'persistent log\n' > /test/root/var/log/persistent.log
grep -qx 'persistent log' \
	/test/state/volatoo/data/identity/logs/persistent.log
umount /test/root/var/log

rm -rf /test/root/etc/ssh /test/root/var/log
rm -f /test/root/etc/machine-id
mkdir -p /test/root/etc/ssh /test/root/var/log
identity apply
cmp /test/expected/machine-id /test/root/etc/machine-id
cmp /test/expected/host-key /test/root/etc/ssh/ssh_host_ed25519_key
grep -qx 'persistent log' /test/root/var/log/persistent.log
identity status
umount /test/root/var/log

printf 'sync /var/log var-log\n' \
	> /test/state/volatoo/config/persist.conf
identity apply
assert_not_mounted

printf '%s\n' \
	'machine-id no' \
	'ssh-host-keys no' \
	'logs no' \
	> /test/state/volatoo/config/identity.conf
rm -f /test/root/etc/machine-id /test/root/etc/ssh/ssh_host_*_key*
identity apply
test ! -e /test/root/etc/machine-id
if compgen -G '/test/root/etc/ssh/ssh_host_*_key*' >/dev/null; then
	echo 'SSH host keys were created despite opt-out' >&2
	exit 1
fi
assert_not_mounted

rm -rf /test/state/volatoo/data/identity
ln -s /test/escape /test/state/volatoo/data/identity
set +e
unsafe_output=$(identity status 2>&1)
unsafe_status=$?
set -e
printf '%s\n' "${unsafe_output}"
[[ ${unsafe_status} -eq 1 ]]
grep -Fq 'must not be a symbolic link' <<<"${unsafe_output}"

echo 'volatoo-identity integration test passed'
CONTAINER
