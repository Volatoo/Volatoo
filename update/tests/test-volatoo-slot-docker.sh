#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

command -v docker >/dev/null 2>&1 || {
	echo "error: docker is not installed" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "error: the Docker daemon is not available" >&2
	exit 1
}

docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$repo_root,dst=/workspace,readonly" \
	--workdir /workspace \
	amd64/alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f \
	sh -euxc '
		set -eu
		apk add --no-cache python3 signify=32-r1 >/dev/null

		work=/tmp/volatoo-slot-test
		rm -rf "$work"
		mkdir -p "$work/state/volatoo" "$work/blobs"
		printf "1\n" > "$work/state/volatoo/layout-version"

		signify -G -n -p "$work/blobs/test.pub" -s "$work/blobs/test.sec" \
			-c "volatoo slot test" >/dev/null
		signify -G -n -p "$work/blobs/other.pub" -s "$work/blobs/other.sec" \
			-c "volatoo other" >/dev/null

		# Two distinct release payloads so a switch is observable.
		printf "kernel-A" > "$work/blobs/kernel-a"
		printf "initramfs-A" > "$work/blobs/initramfs-a"
		printf "root-A-squashfs" > "$work/blobs/root-a.squashfs"
		printf "kernel-B" > "$work/blobs/kernel-b"
		printf "initramfs-B" > "$work/blobs/initramfs-b"
		printf "root-B-squashfs" > "$work/blobs/root-b.squashfs"

		stage_a="update/volatoo-slot --state $work/state stage --slot a \
			--kernel $work/blobs/kernel-a --initramfs $work/blobs/initramfs-a \
			--rootfs $work/blobs/root-a.squashfs --channel v0.1-dev \
			--init-system openrc --signing-key $work/blobs/test.sec \
			--trusted-key $work/blobs/test.pub"
		stage_b="update/volatoo-slot --state $work/state stage --slot b \
			--kernel $work/blobs/kernel-b --initramfs $work/blobs/initramfs-b \
			--rootfs $work/blobs/root-b.squashfs --channel v0.1-dev \
			--init-system systemd --signing-key $work/blobs/test.sec \
			--trusted-key $work/blobs/test.pub"

		update/volatoo-slot --state "$work/state" provision
		# Stage the factory image into a, commit it, then stage b.
		$stage_a
		update/volatoo-slot --state "$work/state" verify --slot a \
			--trusted-key "$work/blobs/test.pub" --require-signature
		update/volatoo-slot --state "$work/state" commit --slot a
		test "$(update/volatoo-slot --state "$work/state" status | awk "/^active:/ {print \$2}")" = a

		$stage_b
		update/volatoo-slot --state "$work/state" verify --slot b \
			--trusted-key "$work/blobs/test.pub" --require-signature
		update/volatoo-slot --state "$work/state" commit --slot b
		test "$(update/volatoo-slot --state "$work/state" status | awk "/^active:/ {print \$2}")" = b

		update/volatoo-slot --state "$work/state" rollback
		test "$(update/volatoo-slot --state "$work/state" status | awk "/^active:/ {print \$2}")" = a

		# Rollback while a candidate is pending returns to the committed slot
		# (a), not to the other slot.
		$stage_b >/dev/null
		test "$(update/volatoo-slot --state "$work/state" status | awk "/^pending:/ {print \$2}")" = b
		update/volatoo-slot --state "$work/state" rollback
		test "$(update/volatoo-slot --state "$work/state" status | awk "/^active:/ {print \$2}")" = a
		test "$(update/volatoo-slot --state "$work/state" status | awk "/^pending:/ {print \$2}")" = none

		# Failure: stage into the active slot must be refused.
		if $stage_a 2>/dev/null; then
			echo "error: staging into the active slot succeeded" >&2
			exit 1
		fi

		# Failure: a corrupt root blob must fail verification.
		printf "corrupt" > "$work/state/volatoo/slots/b/root.squashfs"
		if update/volatoo-slot --state "$work/state" verify --slot b \
			--trusted-key "$work/blobs/test.pub" --require-signature 2>/dev/null; then
			echo "error: corrupt slot b root verified" >&2
			exit 1
		fi

		# Failure: re-stage slot b with only a different key, then the trusted
		# test key must not verify it. Use distinct blobs so a fresh manifest
		# digest (and signature directory) is produced.
		printf "kernel-B2" > "$work/blobs/kernel-b2"
		printf "initramfs-B2" > "$work/blobs/initramfs-b2"
		printf "root-B2-squashfs" > "$work/blobs/root-b2.squashfs"
		update/volatoo-slot --state "$work/state" stage --slot b \
			--kernel "$work/blobs/kernel-b2" --initramfs "$work/blobs/initramfs-b2" \
			--rootfs "$work/blobs/root-b2.squashfs" --channel v0.1-dev \
			--init-system systemd --signing-key "$work/blobs/other.sec" \
			--trusted-key "$work/blobs/other.pub" >/dev/null
		if update/volatoo-slot --state "$work/state" verify --slot b \
			--trusted-key "$work/blobs/test.pub" --require-signature \
			> "$work/verify.out" 2>&1; then
			echo "error: slot b verified with a non-trusted key" >&2
			exit 1
		fi
		grep -q "no signature from a trusted public key" "$work/verify.out"
		update/volatoo-slot --state "$work/state" verify --slot b \
			--trusted-key "$work/blobs/other.pub" --require-signature

		# Failure: commit for a slot that is not the pending candidate.
		if update/volatoo-slot --state "$work/state" commit --slot a 2>/dev/null; then
			echo "error: committed a while b was pending" >&2
			exit 1
		fi

		echo "volatoo-slot contract test passed"
	'

echo "Volatoo whole-image slot contract tests passed"
