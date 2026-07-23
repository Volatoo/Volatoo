#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/test-qemu-boot.sh KERNEL [INITRAMFS] [IMAGE]

Boot a Volatoo image with both legacy BIOS and UEFI, verify that the Gentoo
userspace is reached, and power each VM off. INITRAMFS defaults to
out/volatoo-initramfs.cpio.gz and IMAGE defaults to
out/volatoo-stage3.squashfs.

Optional environment variables:
  VOLATOO_UEFI_FIRMWARE   x86_64 UEFI code image (auto-detected when empty)
  VOLATOO_UEFI_VARS       UEFI variables template (auto-detected when empty)
  VOLATOO_IMAGE_SHA256    Expected image SHA-256 (calculated when empty)
  VOLATOO_STATE_IMAGE     Optional writable state filesystem image
  VOLATOO_STATE_REQUIRED  Require state discovery: yes or no
  VOLATOO_TEST_POLICIES   Verify example persistence policies: yes or no
  VOLATOO_TEST_IDENTITY   Verify default identity and logs: yes or no
  VOLATOO_TEST_SHUTDOWN_SYNC
                            Use normal OpenRC shutdown for the BIOS sync: yes or no
  VOLATOO_TEST_ROOT_MODE  Root layout: copy or overlay (default: copy)
  VOLATOO_TEST_TIMEOUT    Per-VM timeout in seconds (default: 900)
  VOLATOO_VM_MEMORY       QEMU memory (default: 8G)
EOF
}

if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
	usage
	exit 0
fi

if (( $# < 1 || $# > 3 )); then
	usage >&2
	exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
kernel_path=$1
initramfs_path=${2:-"$repo_root/out/volatoo-initramfs.cpio.gz"}
image_path=${3:-"$repo_root/out/volatoo-stage3.squashfs"}
root_mode=${VOLATOO_TEST_ROOT_MODE:-copy}
test_timeout=${VOLATOO_TEST_TIMEOUT:-900}
image_sha256=${VOLATOO_IMAGE_SHA256:-}
state_image_path=${VOLATOO_STATE_IMAGE:-}
state_required=${VOLATOO_STATE_REQUIRED:-}
test_policies=${VOLATOO_TEST_POLICIES:-no}
test_identity=${VOLATOO_TEST_IDENTITY:-no}
test_shutdown_sync=${VOLATOO_TEST_SHUTDOWN_SYNC:-no}

for input_path in "$kernel_path" "$initramfs_path" "$image_path"; do
	if [[ ! -f $input_path ]]; then
		echo "error: test input does not exist: $input_path" >&2
		exit 1
	fi
done

if [[ -n $state_image_path && ! -f $state_image_path ]]; then
	echo "error: state image does not exist: $state_image_path" >&2
	exit 1
fi

if [[ -n $state_image_path && -z $state_required ]]; then
	state_required=yes
fi

if [[ -n $state_required && $state_required != yes && $state_required != no ]]; then
	echo "error: VOLATOO_STATE_REQUIRED must be yes or no" >&2
	exit 1
fi

if [[ $test_policies != yes && $test_policies != no ]]; then
	echo "error: VOLATOO_TEST_POLICIES must be yes or no" >&2
	exit 1
fi

if [[ $test_identity != yes && $test_identity != no ]]; then
	echo "error: VOLATOO_TEST_IDENTITY must be yes or no" >&2
	exit 1
fi

if [[ $test_shutdown_sync != yes && $test_shutdown_sync != no ]]; then
	echo "error: VOLATOO_TEST_SHUTDOWN_SYNC must be yes or no" >&2
	exit 1
fi

if [[ $test_policies == yes && -z $state_image_path ]]; then
	echo "error: VOLATOO_TEST_POLICIES=yes requires VOLATOO_STATE_IMAGE" >&2
	exit 1
fi

if [[ $test_identity == yes && -z $state_image_path ]]; then
	echo "error: VOLATOO_TEST_IDENTITY=yes requires VOLATOO_STATE_IMAGE" >&2
	exit 1
fi

if [[ $test_shutdown_sync == yes && $test_policies != yes ]]; then
	echo "error: VOLATOO_TEST_SHUTDOWN_SYNC=yes requires VOLATOO_TEST_POLICIES=yes" >&2
	exit 1
fi

if [[ $root_mode != copy && $root_mode != overlay ]]; then
	echo "error: VOLATOO_TEST_ROOT_MODE must be copy or overlay" >&2
	exit 1
fi

if [[ ! $test_timeout =~ ^[1-9][0-9]*$ ]]; then
	echo "error: VOLATOO_TEST_TIMEOUT must be a positive integer" >&2
	exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
	echo "error: qemu-system-x86_64 is not installed" >&2
	exit 1
fi

if [[ -z $image_sha256 ]]; then
	if command -v sha256sum >/dev/null 2>&1; then
		checksum_output=$(sha256sum "$image_path")
	elif command -v shasum >/dev/null 2>&1; then
		checksum_output=$(shasum -a 256 "$image_path")
	else
		echo "error: sha256sum or shasum is required" >&2
		exit 1
	fi
	image_sha256=${checksum_output%% *}
fi

if [[ ! $image_sha256 =~ ^[0-9a-f]{64}$ ]]; then
	echo "error: VOLATOO_IMAGE_SHA256 must be 64 lowercase hexadecimal characters" >&2
	exit 1
fi

find_uefi_firmware() {
	if [[ -n ${VOLATOO_UEFI_FIRMWARE:-} ]]; then
		printf '%s\n' "$VOLATOO_UEFI_FIRMWARE"
		return
	fi

	qemu_binary=$(command -v qemu-system-x86_64)
	qemu_prefix=$(cd -- "$(dirname -- "$qemu_binary")/.." && pwd -P)
	for candidate in \
		"$qemu_prefix/share/qemu/edk2-x86_64-code.fd" \
		/usr/share/qemu/edk2-x86_64-code.fd \
		/usr/share/OVMF/OVMF_CODE.fd \
		/usr/share/edk2/x64/OVMF_CODE.fd \
		/usr/share/edk2-ovmf/x64/OVMF_CODE.fd; do
		if [[ -f $candidate ]]; then
			printf '%s\n' "$candidate"
			return
		fi
	done

	echo "error: x86_64 UEFI firmware was not found; set VOLATOO_UEFI_FIRMWARE" >&2
	return 1
}

find_uefi_vars() {
	if [[ -n ${VOLATOO_UEFI_VARS:-} ]]; then
		printf '%s\n' "$VOLATOO_UEFI_VARS"
		return
	fi

	qemu_binary=$(command -v qemu-system-x86_64)
	qemu_prefix=$(cd -- "$(dirname -- "$qemu_binary")/.." && pwd -P)
	for candidate in \
		"$qemu_prefix/share/qemu/edk2-i386-vars.fd" \
		/usr/share/OVMF/OVMF_VARS.fd \
		/usr/share/edk2/x64/OVMF_VARS.fd \
		/usr/share/edk2-ovmf/x64/OVMF_VARS.fd; do
		if [[ -f $candidate ]]; then
			printf '%s\n' "$candidate"
			return
		fi
	done

	echo "error: a UEFI variables template was not found; set VOLATOO_UEFI_VARS" >&2
	return 1
}

uefi_firmware=$(find_uefi_firmware)
uefi_vars_template=$(find_uefi_vars)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-qemu-test.XXXXXX")
uefi_vars=$work_dir/uefi-vars.fd
cp -- "$uefi_vars_template" "$uefi_vars"
qemu_pid=

cleanup() {
	if [[ -n $qemu_pid ]] && kill -0 "$qemu_pid" 2>/dev/null; then
		kill "$qemu_pid" 2>/dev/null || true
		wait "$qemu_pid" 2>/dev/null || true
	fi
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

run_boot_test() {
	mode=$1
	machine=$2
	firmware=$3
	vars_image=$4
	console_log=$work_dir/$mode.log
	console_input=$work_dir/$mode.input
	success_marker="[volatoo-test] $mode userspace verified"
	failure_marker="[volatoo-test] $mode userspace verification failed"
	guest_init=/bin/bash
	if [[ $test_shutdown_sync == yes && $mode == bios ]]; then
		guest_init=/sbin/init
	fi

	mkfifo "$console_input"
	exec 3<>"$console_input"

	echo "testing $mode boot with QEMU machine $machine"
	VOLATOO_IMAGE_SHA256=$image_sha256 \
	VOLATOO_STATE_IMAGE=$state_image_path \
	VOLATOO_STATE_REQUIRED=$state_required \
	VOLATOO_QEMU_MACHINE=$machine \
	VOLATOO_QEMU_FIRMWARE=$firmware \
	VOLATOO_QEMU_VARS=$vars_image \
	VOLATOO_ROOT_MODE=$root_mode \
	VOLATOO_TARGET_INIT=$guest_init \
		"$repo_root/scripts/run-phase0-qemu.sh" \
		"$kernel_path" "$initramfs_path" "$image_path" \
		<"$console_input" >"$console_log" 2>&1 &
	qemu_pid=$!
	test_started=$(date +%s)

	while ! grep -Fq \
		"[volatoo] switching to $root_mode root; init=$guest_init" \
		"$console_log"; do
		if grep -Fq "=== Volatoo boot failure ===" "$console_log"; then
			echo "error: $mode boot entered the rescue environment" >&2
			tail -80 "$console_log" >&2
			return 1
		fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then
			wait "$qemu_pid" || qemu_status=$?
			echo "error: $mode QEMU exited before the userspace handoff" >&2
			echo "QEMU exit status: ${qemu_status:-0}" >&2
			tail -80 "$console_log" >&2
			return 1
		fi
		test_now=$(date +%s)
		if (( test_now - test_started >= test_timeout )); then
			echo "error: $mode boot exceeded ${test_timeout}s" >&2
			tail -80 "$console_log" >&2
			return 1
		fi
		sleep 1
	done

	if [[ $test_shutdown_sync == yes && $mode == bios ]]; then
		while ! grep -Fq "login: root (automatic login)" "$console_log"; do
			if ! kill -0 "$qemu_pid" 2>/dev/null; then
				wait "$qemu_pid" || qemu_status=$?
				echo "error: $mode QEMU exited before the OpenRC login" >&2
				echo "QEMU exit status: ${qemu_status:-0}" >&2
				tail -80 "$console_log" >&2
				return 1
			fi
			test_now=$(date +%s)
			if (( test_now - test_started >= test_timeout )); then
				echo "error: $mode OpenRC login exceeded ${test_timeout}s" >&2
				tail -80 "$console_log" >&2
				return 1
			fi
			sleep 1
		done
		sleep 2
	fi

	if [[ $root_mode == copy ]]; then
		root_filesystem=tmpfs
	else
		root_filesystem=overlay
	fi
	state_test=
	if [[ -n $state_image_path ]]; then
		state_test=" && grep -q ' /.volatoo/state ' /proc/mounts && grep -qx '1' /.volatoo/state/volatoo/layout-version"
	fi
	policy_test=
	policy_action=
	if [[ $test_policies == yes ]]; then
		policy_test=" && grep -q ' /home ' /proc/mounts && grep -q '^overlay /var/lib overlay ' /proc/mounts"
		if [[ $mode == bios ]]; then
			policy_action="printf 'bind-survived\\n' > /home/.volatoo-qemu-policy-test; printf 'overlay-survived\\n' > /var/lib/.volatoo-qemu-policy-test; printf 'sync-survived\\n' > /etc/.volatoo-qemu-policy-test; "
			if [[ $test_shutdown_sync == no ]]; then
				policy_action+="/usr/sbin/volatoo-persist sync && "
			fi
		else
			policy_test="$policy_test && grep -qx 'bind-survived' /home/.volatoo-qemu-policy-test && grep -qx 'overlay-survived' /var/lib/.volatoo-qemu-policy-test && grep -qx 'sync-survived' /etc/.volatoo-qemu-policy-test"
		fi
	fi
	identity_test=
	identity_action=
	if [[ $test_identity == yes ]]; then
		identity_test=" && grep -Eq '^[0-9a-f]{32}$' /etc/machine-id && test -s /etc/ssh/ssh_host_ed25519_key && test -s /etc/ssh/ssh_host_ed25519_key.pub && grep -q ' /var/log ' /proc/mounts"
		if [[ $mode == bios ]]; then
			identity_action="cp /etc/machine-id /var/log/.volatoo-qemu-machine-id && cp /etc/ssh/ssh_host_ed25519_key.pub /var/log/.volatoo-qemu-host-key.pub && "
		else
			identity_test="$identity_test && cmp -s /var/log/.volatoo-qemu-machine-id /etc/machine-id && cmp -s /var/log/.volatoo-qemu-host-key.pub /etc/ssh/ssh_host_ed25519_key.pub"
		fi
	fi
	poweroff_command="poweroff -f"
	if [[ $test_shutdown_sync == yes && $mode == bios ]]; then
		poweroff_command=poweroff
	fi
	printf '%s\n' \
		"if grep -q '^Gentoo Base System release ' /etc/gentoo-release && grep -q '^$root_filesystem / $root_filesystem ' /proc/mounts$state_test$policy_test$identity_test; then ${policy_action}${identity_action}printf '[volatoo-test] %s userspace verified\\n' '$mode'; else printf '[volatoo-test] %s userspace verification failed\\n' '$mode'; fi; $poweroff_command" \
		>&3

	while kill -0 "$qemu_pid" 2>/dev/null; do
		test_now=$(date +%s)
		if (( test_now - test_started >= test_timeout )); then
			echo "error: $mode guest did not power off within ${test_timeout}s" >&2
			tail -80 "$console_log" >&2
			return 1
		fi
		sleep 1
	done
	if ! wait "$qemu_pid"; then
		echo "error: $mode QEMU reported a failed exit" >&2
		tail -80 "$console_log" >&2
		return 1
	fi
	qemu_pid=
	exec 3>&-

	if grep -Fq "$failure_marker" "$console_log" || \
		! grep -Fq "$success_marker" "$console_log"; then
		echo "error: $mode userspace verification failed" >&2
		tail -80 "$console_log" >&2
		return 1
	fi
	if [[ $test_shutdown_sync == yes && $mode == bios ]] && \
		! grep -Fq "synchronized /etc:" "$console_log"; then
		echo "error: OpenRC shutdown did not synchronize /etc" >&2
		tail -80 "$console_log" >&2
		return 1
	fi

	test_finished=$(date +%s)
	echo "$mode boot passed in $((test_finished - test_started))s"
}

run_boot_test bios pc "" ""
run_boot_test uefi q35 "$uefi_firmware" "$uefi_vars"

echo "BIOS and UEFI boot tests passed"
