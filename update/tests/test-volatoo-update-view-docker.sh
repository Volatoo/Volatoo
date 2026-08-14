#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
helper=$repo_root/update/volatoo-update-view
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-update-view-test.XXXXXX")

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

command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"

mkdir -p "$work_dir/state/volatoo/system/staging"
printf '1\n' >"$work_dir/state/volatoo/layout-version"
printf '1\n' >"$work_dir/state/volatoo/system/layout-version"

docker run --rm \
	--privileged \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/state,dst=/state" \
	--mount "type=bind,src=$helper,dst=/usr/local/bin/volatoo-update-view,readonly" \
	alpine:3.24.1 \
	/bin/sh -c '
		set -eu
		apk add --no-cache util-linux >/dev/null
		mkdir -p /.volatoo/state
		mount --bind /state /.volatoo/state
		system=/.volatoo/state/volatoo/system
		if /usr/local/bin/volatoo-update-view /bin/true \
			>/tmp/unprotected.stdout 2>/tmp/unprotected.stderr
		then
			exit 9
		fi
		grep -q "public system store is writable" \
			/tmp/unprotected.stderr
		mount --bind "$system" "$system"
		mount -o remount,bind,ro "$system"
		if (: >"$system/staging/public-write") 2>/dev/null; then
			exit 10
		fi
		/usr/local/bin/volatoo-update-view \
			/bin/sh -c \
			": >\"\$VOLATOO_UPDATE_STATE/volatoo/system/staging/published\""
		test -f "$system/staging/published"
		if (: >"$system/staging/public-write-after") 2>/dev/null; then
			exit 11
		fi
		test ! -e /run/volatoo/update-state
	'

[[ -f $work_dir/state/volatoo/system/staging/published ]] ||
	fail "private update view did not publish to the underlying store"

echo "volatoo private update-view Docker tests passed"
