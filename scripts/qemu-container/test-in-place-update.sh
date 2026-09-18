#!/usr/bin/env bash

set -euo pipefail

# In-place A/B slot update gate. Runs inside the pinned QEMU container.
# Usage: test-in-place-update.sh DISK INIT_SYSTEM FIRMWARE
#
# Boots slot a, stages a new image into slot b over SSH, reboots into b,
# confirms b, rolls back to a and confirms a. QEMU runs with snapshot=on so
# the input disk is never modified; the snapshot overlay persists across the
# guest reboots that make up this single QEMU session.

if (( $# != 3 )); then
	echo "Usage: test-in-place-update.sh DISK INIT_SYSTEM FIRMWARE" >&2
	exit 2
fi

disk=$1
init_system=$2
firmware=$3
timeout_seconds=${VOLATOO_SLOT_QEMU_TIMEOUT:-360}
ssh_key=${VOLATOO_RELEASE_SSH_KEY:-}

[[ -f $disk && ! -L $disk ]] || {
	echo "error: slot disk is missing or unsafe: $disk" >&2
	exit 1
}
[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: init system must be openrc or systemd" >&2
	exit 2
}
[[ $firmware == bios || $firmware == uefi ]] || {
	echo "error: firmware must be bios or uefi" >&2
	exit 2
}
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
	echo "error: VOLATOO_SLOT_QEMU_TIMEOUT must be a positive integer" >&2
	exit 2
}
[[ -n $ssh_key && -f $ssh_key && ! -L $ssh_key ]] || {
	echo "error: VOLATOO_RELEASE_SSH_KEY is missing or unsafe" >&2
	exit 1
}

log=$(mktemp)
vars=
qemu_pid=
cleanup()
{
	if [[ -n $qemu_pid ]]; then
		kill "$qemu_pid" 2>/dev/null || true
		wait "$qemu_pid" 2>/dev/null || true
	fi
	rm -f -- "$log" "$vars"
}
trap cleanup EXIT

firmware_args=()
machine=accel=tcg
if [[ $firmware == uefi ]]; then
	vars=$(mktemp)
	cp /usr/share/OVMF/OVMF_VARS.fd "$vars"
	firmware_args=(
		-drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd"
		-drive "if=pflash,format=raw,file=$vars"
	)
fi

# -no-reboot is deliberately omitted: the gate reboots the guest in place and
# relies on the snapshot overlay to keep the state partition across reboots.
qemu-system-x86_64 \
	-machine "$machine" \
	-m 4096 \
	-smp 2 \
	-nographic \
	"${firmware_args[@]}" \
	-drive "file=$disk,format=raw,if=virtio,snapshot=on" \
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
	-device virtio-net-pci,netdev=net0 \
	>"$log" 2>&1 &
qemu_pid=$!

deadline=$((SECONDS + timeout_seconds))

fail()
{
	echo "error: $*" >&2
	tail -160 "$log" >&2
	exit 1
}

wait_login()
{
	local target=$1
	while (( SECONDS < deadline )); do
		if [[ $target == 1 ]]; then
			if grep -Eq '(^|[^[:alpha:]])login: ' "$log"; then return 0; fi
		else
			local count
			count=$(grep -Ec '(^|[^[:alpha:]])login: ' "$log")
			if (( count >= target )); then return 0; fi
		fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then
			return 1
		fi
		sleep 0.5
	done
	return 1
}

wait_marker()
{
	local pattern=$1
	while (( SECONDS < deadline )); do
		if grep -Eq "$pattern" "$log"; then return 0; fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then return 1; fi
		sleep 0.5
	done
	return 1
}

ssh_cmd=(
	ssh -o BatchMode=yes -o ConnectTimeout=5
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-i "$ssh_key" -p 2222 volatoo@127.0.0.1
)

ssh_run()
{
	local output
	output=$("${ssh_cmd[@]}" "$1" 2>/dev/null)
	printf '%s\n' "$output"
}

wait_ssh()
{
	local output
	while (( SECONDS < deadline )); do
		if output=$(ssh_run "true" 2>/dev/null) && [[ -z $output ]]; then
			return 0
		fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then return 1; fi
		sleep 1
	done
	return 1
}

confirm_slot()
{
	local expect=$1 expect_init=$2
	local slot_id init
	slot_id=$(ssh_run "cat /.volatoo/slot-id 2>/dev/null")
	init=$(ssh_run "cat /.volatoo/slot-init-system 2>/dev/null")
	[[ $slot_id == "$expect" ]] || {
		fail "expected slot $expect, guest reports ${slot_id:-none}"
	}
	[[ $init == "$expect_init" ]] || {
		fail "expected init $expect_init, guest reports ${init:-none}"
	}
}

# The writable root is a disposable tmpfs, so /tmp is wiped on every reboot.
# Re-copy the tool after each boot.
copy_tool()
{
	"${ssh_cmd[@]}" </repo/update/volatoo-slot "cat > /tmp/volatoo-slot" \
		|| fail "could not copy volatoo-slot into the guest"
}

# --- 1. boot slot a ---------------------------------------------------------
wait_login 1 || fail "did not reach the first login prompt"
wait_marker '\[volatoo\] slot a verified' || fail "slot a was not verified"
wait_marker '\[volatoo\] slot overlay root ready' || fail "slot overlay root did not mount"
grep -Eq 'OpenRC .* is starting up' "$log" || fail "OpenRC did not start for slot a"
wait_ssh || fail "SSH did not become available on slot a"
confirm_slot a openrc
echo "slot a (openrc) booted and confirmed"

# --- 2. stage a new image into slot b --------------------------------------
copy_tool
state_root=/.volatoo/state/volatoo/slots/incoming
stage_output=$(ssh_run "sudo -n python3 /tmp/volatoo-slot --state /.volatoo/state stage \
	--slot b \
	--kernel $state_root/kernel --initramfs $state_root/initramfs \
	--rootfs $state_root/root.squashfs --channel v0.1-dev --init-system systemd \
	--signing-key $state_root/release.sec --trusted-key $state_root/release.pub")
[[ $stage_output == *"staged slot b"* ]] || fail "slot b staging failed: $stage_output"
echo "$stage_output"
pending=$(ssh_run "sudo -n python3 /tmp/volatoo-slot --state /.volatoo/state status")
[[ $pending == *"pending: b"* ]] || fail "slot b was not armed as pending: $pending"

# --- 3. reboot into slot b -------------------------------------------------
ssh_run "sudo -n reboot" >/dev/null 2>&1 || true
wait_marker '\[volatoo\] slot b verified' || fail "slot b was not verified after reboot"
wait_marker 'systemd\[[[:space:]]*1\]' || fail "systemd did not start for slot b"
wait_login 2 || fail "did not reach the second login prompt"
wait_ssh || fail "SSH did not become available on slot b"
confirm_slot b systemd
echo "slot b (systemd) booted and confirmed"

# --- 4. roll back to slot a ------------------------------------------------
copy_tool
rollback_output=$(ssh_run "sudo -n python3 /tmp/volatoo-slot --state /.volatoo/state rollback")
[[ $rollback_output == *"rolled back to slot a"* ]] || fail "rollback failed: $rollback_output"
echo "$rollback_output"
ssh_run "sudo -n reboot" >/dev/null 2>&1 || true
wait_marker '\[volatoo\] slot a verified' || fail "slot a was not verified after rollback"
wait_marker 'OpenRC .* is starting up' || fail "OpenRC did not start after rollback"
wait_login 3 || fail "did not reach the third login prompt"
wait_ssh || fail "SSH did not become available after rollback"
confirm_slot a openrc
echo "rollback to slot a (openrc) confirmed"

echo "Volatoo in-place A/B slot update passed $firmware"
