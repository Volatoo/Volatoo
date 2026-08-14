#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}

docker run --rm \
	--platform linux/amd64 \
	--entrypoint /bin/sh \
	--mount "type=bind,src=$repo_root,dst=/repo,readonly" \
	volatoo-release-builder:0.1-dev \
	-c '
		set -eu
		apk add --no-cache shadow sudo >/dev/null
		root=/tmp/root
		state=/tmp/state
		install -d -m 0755 "$root/etc/ssh" "$root/home" "$root/bin"
		install -d -m 0700 "$state/volatoo/config/access"
		cp /etc/passwd /etc/group /etc/shadow "$root/etc/"
		cp /etc/login.defs "$root/etc/"
		touch "$root/bin/bash"
		chmod 0755 "$root/bin/bash"
		printf "%s\n" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIN8XFE9WwjHvSxBSnbiuupCmyvRetPJYcHARXeTwdtLb firstboot-test" \
			>"$state/volatoo/config/access/authorized_keys"

		for run in 1 2; do
			VOLATOO_ROOT="$root" VOLATOO_STATE_ROOT="$state" \
				/repo/image/catalyst/overlay/usr/libexec/volatoo-firstboot-access
		done
		[[ $(awk -F: '\''$1 == "volatoo" { count++ } END { print count + 0 }'\'' "$root/etc/passwd") == 1 ]]
		[[ $(awk -F: '\''$1 == "volatoo" { print $2 }'\'' "$root/etc/shadow") == x ]]
		grep -Eq "^wheel:.*:.*(^|,)volatoo(,|$)" "$root/etc/group"
		cmp "$state/volatoo/config/access/authorized_keys" \
			"$root/home/volatoo/.ssh/authorized_keys"
		[[ $(stat -c %a "$root/home/volatoo/.ssh/authorized_keys") == 600 ]]
		grep -Fxq "volatoo ALL=(ALL:ALL) NOPASSWD: ALL" \
			"$root/etc/sudoers.d/90-volatoo"
		grep -Fxq "PermitRootLogin no" \
			"$root/etc/ssh/sshd_config.d/20-volatoo-access.conf"

		mv "$state/volatoo/config/access/authorized_keys" /tmp/authorized_keys
		ln -s /tmp/authorized_keys "$state/volatoo/config/access/authorized_keys"
		if VOLATOO_ROOT="$root" VOLATOO_STATE_ROOT="$state" \
			/repo/image/catalyst/overlay/usr/libexec/volatoo-firstboot-access \
			>/tmp/unsafe.stdout 2>/tmp/unsafe.stderr
		then
			echo "error: unsafe access configuration was accepted" >&2
			exit 1
		fi
		grep -q "unsafe administrator access configuration" /tmp/unsafe.stderr
	'

echo "Volatoo first-boot access test passed"
