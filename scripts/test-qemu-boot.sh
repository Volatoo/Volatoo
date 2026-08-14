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
  VOLATOO_TEST_INIT_SYSTEM
                            Boot shell, openrc, or systemd (default: shell)
  VOLATOO_TEST_GENERATION Expected selected sha256:<digest> (default: none)
  VOLATOO_TEST_GENERATION_REALIZED
                            Require a realized closure marker: yes or no
  VOLATOO_TEST_GENERATION_VERITY
                            Require an active dm-verity root: yes or no
  VOLATOO_TEST_GENERATION_PAYLOAD
                            Verify the P3U-4 fixture layer: yes or no
  VOLATOO_TEST_GENERATION_FALLBACK
                            Require current-to-previous fallback: yes or no
  VOLATOO_TEST_GENERATION_SIGNATURE
                            Require signed release or allow unsigned generations
  VOLATOO_TEST_SERVICE_READY
                            Require the fixture's init-owned readiness marker
  VOLATOO_TEST_UPDATE_VIEW Verify the private updater mount view (default: yes)
  VOLATOO_TEST_FIRMWARES    Comma-separated bios,uefi (default: both)
  VOLATOO_TEST_ROOT_MODE  Root layout: store-overlay, ram-overlay, copy, or overlay
                          (default: store-overlay)
  VOLATOO_TEST_TIMEOUT    Per-VM timeout in seconds (default: 900)
  VOLATOO_TEST_EXPECT_FAILURE_CODE
                            Pass only when early boot fails with this code
  VOLATOO_TEST_METRICS_FILE
                            Append successful boot metrics as versioned TSV
  VOLATOO_VM_MEMORY       QEMU memory (default: 8G)
  VOLATOO_QEMU_ACCEL      QEMU accelerator: tcg or kvm (default: tcg)
  VOLATOO_QEMU_CPU        QEMU CPU model (default: max for TCG, host for KVM)
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
root_mode=${VOLATOO_TEST_ROOT_MODE:-store-overlay}
test_timeout=${VOLATOO_TEST_TIMEOUT:-900}
image_sha256=${VOLATOO_IMAGE_SHA256:-}
state_image_path=${VOLATOO_STATE_IMAGE:-}
state_required=${VOLATOO_STATE_REQUIRED:-}
test_policies=${VOLATOO_TEST_POLICIES:-no}
test_identity=${VOLATOO_TEST_IDENTITY:-no}
test_shutdown_sync=${VOLATOO_TEST_SHUTDOWN_SYNC:-no}
test_init_system=${VOLATOO_TEST_INIT_SYSTEM:-shell}
test_generation=${VOLATOO_TEST_GENERATION:-}
test_generation_realized=${VOLATOO_TEST_GENERATION_REALIZED:-}
test_generation_verity=${VOLATOO_TEST_GENERATION_VERITY:-}
test_generation_payload=${VOLATOO_TEST_GENERATION_PAYLOAD:-no}
test_generation_fallback=${VOLATOO_TEST_GENERATION_FALLBACK:-no}
test_generation_signature=${VOLATOO_TEST_GENERATION_SIGNATURE:-}
test_service_ready=${VOLATOO_TEST_SERVICE_READY:-no}
test_update_view=${VOLATOO_TEST_UPDATE_VIEW:-yes}
expected_failure_code=${VOLATOO_TEST_EXPECT_FAILURE_CODE:-}
firmwares=${VOLATOO_TEST_FIRMWARES:-bios,uefi}
metrics_file=${VOLATOO_TEST_METRICS_FILE:-}
qemu_accel=${VOLATOO_QEMU_ACCEL:-tcg}
vm_memory=${VOLATOO_VM_MEMORY:-8G}
metrics_schema=org.volatoo.qemu-boot-metrics/v4
metrics_header=$'schema\thost_arch\thost_cpu\thost_kernel\tqemu_version\tqemu_accel\tvm_memory\tfirmware\troot_mode\tinit_system\telapsed_seconds\timage_bytes\tmem_total_kib\tmem_available_kib\troot_used_kib\troot_available_kib\troot_auth_seconds\thandoff_seconds\tpid1_seconds\tservice_ready_seconds\tlate_services_seconds\tuserspace_ready_seconds'

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

if [[ $test_init_system != shell && \
	$test_init_system != openrc && \
	$test_init_system != systemd ]]; then
	echo "error: VOLATOO_TEST_INIT_SYSTEM must be shell, openrc, or systemd" >&2
	exit 1
fi

if [[ $test_init_system != shell && $test_shutdown_sync == yes ]]; then
	echo "error: init-system boot and shutdown-sync modes cannot be combined" >&2
	exit 1
fi

if [[ $test_service_ready != yes && $test_service_ready != no ]]; then
	echo "error: VOLATOO_TEST_SERVICE_READY must be yes or no" >&2
	exit 1
fi
if [[ $test_service_ready == yes && $test_init_system == shell ]]; then
	echo "error: service readiness requires an OpenRC or systemd boot" >&2
	exit 1
fi

if [[ -n $test_generation && \
	! $test_generation =~ ^sha256:[0-9a-f]{64}$ ]]; then
	echo "error: VOLATOO_TEST_GENERATION must be a sha256:<digest>" >&2
	exit 1
fi
if [[ -n $test_generation_realized && \
	$test_generation_realized != yes && \
	$test_generation_realized != no ]]; then
	echo "error: VOLATOO_TEST_GENERATION_REALIZED must be yes or no" >&2
	exit 1
fi
if [[ -n $test_generation_realized && -z $test_generation ]]; then
	echo "error: realized generation verification requires a generation digest" >&2
	exit 1
fi
if [[ -n $test_generation_verity && \
	$test_generation_verity != yes && \
	$test_generation_verity != no ]]; then
	echo "error: VOLATOO_TEST_GENERATION_VERITY must be yes or no" >&2
	exit 1
fi
if [[ $test_generation_verity == yes && \
	$test_generation_realized != yes ]]; then
	echo "error: dm-verity verification requires a realized generation" >&2
	exit 1
fi
if [[ $test_generation_verity == yes && $root_mode == ram-overlay ]]; then
	echo "error: ram-overlay uses eager SHA-256 instead of dm-verity" >&2
	exit 1
fi
if [[ -n $expected_failure_code && \
	! $expected_failure_code =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
	echo "error: VOLATOO_TEST_EXPECT_FAILURE_CODE is invalid" >&2
	exit 1
fi

if [[ $test_generation_payload != yes && \
	$test_generation_payload != no ]]; then
	echo "error: VOLATOO_TEST_GENERATION_PAYLOAD must be yes or no" >&2
	exit 1
fi
if [[ $test_generation_payload == yes && -z $test_generation ]]; then
	echo "error: generation payload verification requires a generation digest" >&2
	exit 1
fi
if [[ $test_generation_fallback != yes && \
	$test_generation_fallback != no ]]; then
	echo "error: VOLATOO_TEST_GENERATION_FALLBACK must be yes or no" >&2
	exit 1
fi
if [[ $test_generation_fallback == yes && -z $test_generation ]]; then
	echo "error: generation fallback verification requires a generation digest" >&2
	exit 1
fi
if [[ -n $test_generation_signature && \
	$test_generation_signature != required && \
	$test_generation_signature != allow-unsigned ]]; then
	echo "error: VOLATOO_TEST_GENERATION_SIGNATURE must be required or allow-unsigned" >&2
	exit 1
fi
if [[ -n $test_generation_signature && -z $test_generation ]]; then
	echo "error: generation signature verification requires a generation digest" >&2
	exit 1
fi
if [[ $test_update_view != yes && $test_update_view != no ]]; then
	echo "error: VOLATOO_TEST_UPDATE_VIEW must be yes or no" >&2
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

if [[ $root_mode != copy && \
	$root_mode != overlay && \
	$root_mode != ram-overlay && \
	$root_mode != store-overlay ]]; then
	echo "error: VOLATOO_TEST_ROOT_MODE must be store-overlay, ram-overlay, copy, or overlay" >&2
	exit 1
fi

IFS=, read -r -a selected_firmwares <<<"$firmwares"
(( ${#selected_firmwares[@]} > 0 )) || {
	echo "error: VOLATOO_TEST_FIRMWARES is empty" >&2
	exit 1
}
uefi_selected=no
for selected_firmware in "${selected_firmwares[@]}"; do
	case $selected_firmware in
		bios) ;;
		uefi) uefi_selected=yes ;;
		*)
			echo "error: unsupported QEMU firmware: $selected_firmware" >&2
			exit 1
			;;
	esac
done

if [[ ! $test_timeout =~ ^[1-9][0-9]*$ ]]; then
	echo "error: VOLATOO_TEST_TIMEOUT must be a positive integer" >&2
	exit 1
fi

if [[ -n $metrics_file ]]; then
	metrics_parent=$(dirname -- "$metrics_file")
	if [[ ! -d $metrics_parent ]]; then
		echo "error: metrics output directory does not exist: $metrics_parent" >&2
		exit 1
	fi
	if [[ -L $metrics_file ]]; then
		echo "error: metrics output must not be a symbolic link: $metrics_file" >&2
		exit 1
	elif [[ -e $metrics_file ]]; then
		if [[ ! -f $metrics_file ]]; then
			echo "error: metrics output is not a regular file: $metrics_file" >&2
			exit 1
		fi
		if [[ -s $metrics_file ]]; then
			IFS= read -r existing_metrics_header <"$metrics_file" || true
			if [[ $existing_metrics_header != "$metrics_header" ]]; then
				echo "error: metrics output has an incompatible header" >&2
				exit 1
			fi
		else
			printf '%s\n' "$metrics_header" >"$metrics_file"
		fi
	else
		printf '%s\n' "$metrics_header" >"$metrics_file"
	fi
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
	echo "error: qemu-system-x86_64 is not installed" >&2
	exit 1
fi

host_arch=$(uname -m)
host_kernel=$(uname -sr)
if [[ -r /proc/cpuinfo ]]; then
	host_cpu=$(
		awk -F: '/^model name[[:space:]]*:/ {
			sub(/^[[:space:]]+/, "", $2)
			print $2
			exit
		}' /proc/cpuinfo
	)
elif command -v sysctl >/dev/null 2>&1; then
	host_cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -p)
else
	host_cpu=$(uname -p)
fi
host_cpu=${host_cpu:-$host_arch}
host_cpu=${host_cpu//$'\t'/ }
host_cpu=${host_cpu//$'\n'/ }
host_kernel=${host_kernel//$'\t'/ }
qemu_version=$(qemu-system-x86_64 --version | head -n 1)
qemu_version=${qemu_version//$'\t'/ }
image_bytes=$(wc -c <"$image_path" | tr -d '[:space:]')

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

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-qemu-test.XXXXXX")
uefi_firmware=
uefi_vars=
if [[ $uefi_selected == yes ]]; then
	uefi_firmware=$(find_uefi_firmware)
	uefi_vars_template=$(find_uefi_vars)
	uefi_vars=$work_dir/uefi-vars.fd
	cp -- "$uefi_vars_template" "$uefi_vars"
fi
qemu_pid=

write_boot_metrics() {
	metrics_firmware=$1
	metrics_elapsed=$2
	metrics_mem_total=${3:-}
	metrics_mem_available=${4:-}
	metrics_root_used=${5:-}
	metrics_root_available=${6:-}
	metrics_root_auth=${7:-}
	metrics_handoff=${8:-}
	metrics_pid1=${9:-}
	metrics_service_ready=${10:-}
	metrics_late_services=${11:-}
	metrics_userspace_ready=${12:-}

	if [[ -z $metrics_file ]]; then
		return
	fi
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$metrics_schema" \
		"$host_arch" \
		"$host_cpu" \
		"$host_kernel" \
		"$qemu_version" \
		"$qemu_accel" \
		"$vm_memory" \
		"$metrics_firmware" \
		"$root_mode" \
		"$test_init_system" \
		"$metrics_elapsed" \
		"$image_bytes" \
		"$metrics_mem_total" \
		"$metrics_mem_available" \
		"$metrics_root_used" \
		"$metrics_root_available" \
		"$metrics_root_auth" \
		"$metrics_handoff" \
		"$metrics_pid1" \
		"$metrics_service_ready" \
		"$metrics_late_services" \
		"$metrics_userspace_ready" \
		>>"$metrics_file"
}

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
	root_auth_marker="[volatoo] root authentication stage complete"
	root_auth_seconds=
	handoff_seconds=
	pid1_seconds=
	service_ready_seconds=
	late_services_seconds=
	userspace_ready_seconds=
	pid1_marker=
	service_ready_marker='[volatoo] service readiness reached'
	late_services_marker=
	guest_init=/bin/bash
	if [[ $test_init_system != shell ]] || \
		[[ $test_shutdown_sync == yes && $mode == bios ]]; then
		guest_init=/sbin/init
	fi
	case $test_init_system in
		openrc)
			pid1_marker='OpenRC '
			late_services_marker='Starting local'
			;;
		systemd)
			pid1_marker='systemd[1]: systemd '
			late_services_marker='Multi-User System'
			;;
	esac

	mkfifo "$console_input"
	exec 3<>"$console_input"

	echo "testing $mode boot with QEMU machine $machine"
	VOLATOO_IMAGE_SHA256=$image_sha256 \
	VOLATOO_STATE_IMAGE=$state_image_path \
	VOLATOO_STATE_REQUIRED=$state_required \
	VOLATOO_SIGNATURE_POLICY=$test_generation_signature \
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
		if [[ -z $root_auth_seconds ]] && \
			grep -Fq "$root_auth_marker" "$console_log"; then
			test_now=$(date +%s)
			root_auth_seconds=$((test_now - test_started))
		fi
		if grep -Fq "=== Volatoo boot failure ===" "$console_log"; then
			if [[ -n $expected_failure_code ]] && \
				grep -Fq "code: $expected_failure_code" "$console_log"; then
				printf '\001x' >&3
				wait "$qemu_pid" || true
				qemu_pid=
				exec 3>&-
				echo "$mode rejected the corrupted root with $expected_failure_code"
				return
			fi
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
	test_now=$(date +%s)
	if [[ -z $root_auth_seconds ]] && \
		grep -Fq "$root_auth_marker" "$console_log"; then
		root_auth_seconds=$((test_now - test_started))
	fi
	handoff_seconds=$((test_now - test_started))
	if [[ -n $expected_failure_code ]]; then
		echo "error: $mode boot unexpectedly accepted the corrupted root" >&2
		tail -80 "$console_log" >&2
		return 1
	fi

	if [[ $test_generation_fallback == yes ]] && \
		! grep -Fq \
			"[volatoo] warning: booting verified previous generation" \
			"$console_log"; then
		echo "error: $mode did not report generation fallback" >&2
		tail -80 "$console_log" >&2
		return 1
	fi

	if [[ $test_init_system != shell ]]; then
		while ! grep -Fq " login:" "$console_log"; do
			if [[ -z $pid1_seconds ]] && \
				grep -Fq "$pid1_marker" "$console_log"; then
				test_now=$(date +%s)
				pid1_seconds=$((test_now - test_started))
			fi
			if [[ -z $service_ready_seconds ]] && \
				grep -Fq "$service_ready_marker" "$console_log"; then
				test_now=$(date +%s)
				service_ready_seconds=$((test_now - test_started))
			fi
			if [[ -z $late_services_seconds ]] && \
				grep -Fq "$late_services_marker" "$console_log"; then
				test_now=$(date +%s)
				late_services_seconds=$((test_now - test_started))
			fi
			if grep -Fq "=== Volatoo boot failure ===" "$console_log"; then
				echo "error: $mode boot entered the rescue environment" >&2
				tail -80 "$console_log" >&2
				return 1
			fi
			if ! kill -0 "$qemu_pid" 2>/dev/null; then
				wait "$qemu_pid" || qemu_status=$?
				echo "error: $mode QEMU exited before the login prompt" >&2
				echo "QEMU exit status: ${qemu_status:-0}" >&2
				tail -80 "$console_log" >&2
				return 1
			fi
			test_now=$(date +%s)
			if (( test_now - test_started >= test_timeout )); then
				echo "error: $mode $test_init_system boot exceeded ${test_timeout}s" >&2
				tail -80 "$console_log" >&2
				return 1
			fi
			sleep 1
		done
		test_now=$(date +%s)
		if [[ -z $pid1_seconds ]] && \
			grep -Fq "$pid1_marker" "$console_log"; then
			pid1_seconds=$((test_now - test_started))
		fi
		if [[ -z $late_services_seconds ]] && \
			grep -Fq "$late_services_marker" "$console_log"; then
			late_services_seconds=$((test_now - test_started))
		fi
		if [[ -z $service_ready_seconds ]] && \
			grep -Fq "$service_ready_marker" "$console_log"; then
			service_ready_seconds=$((test_now - test_started))
		fi
		userspace_ready_seconds=$((test_now - test_started))
		if [[ -n $metrics_file && \
			( -z $pid1_seconds || -z $late_services_seconds ) ]]; then
			echo "error: $mode did not report required $test_init_system phase markers" >&2
			tail -80 "$console_log" >&2
			return 1
		fi
		if [[ $test_service_ready == yes && -z $service_ready_seconds ]]; then
			echo "error: $mode did not report the required service-readiness marker" >&2
			tail -80 "$console_log" >&2
			return 1
		fi

		case $test_init_system in
			openrc)
				init_pattern='OpenRC'
				if grep -Fq "ERROR: sysklogd failed to start" "$console_log"; then
					echo "error: $mode OpenRC sysklogd service failed" >&2
					tail -80 "$console_log" >&2
					return 1
				fi
				;;
			systemd)
				init_pattern='systemd[1]'
				;;
		esac
		if ! grep -Fq "$init_pattern" "$console_log"; then
			echo "error: $mode did not show the expected $test_init_system PID 1" >&2
			tail -80 "$console_log" >&2
			return 1
		fi
		if [[ -n $test_generation ]] && \
			! grep -Fq \
				"[volatoo] generation verified: $test_generation" \
				"$console_log" && \
			! grep -Fq \
				"[volatoo] generation verified from realized closure: $test_generation" \
				"$console_log" && \
			! grep -Fq \
				"[volatoo] generation binding verified for authenticated reads: $test_generation" \
				"$console_log"; then
			echo "error: $mode did not verify the expected generation" >&2
			tail -80 "$console_log" >&2
			return 1
		fi

		# QEMU's Ctrl-a x escape terminates a successful non-interactive boot
		# without requiring a test password or modifying the release image.
		printf '\001x' >&3
		if ! wait "$qemu_pid"; then
			echo "error: $mode QEMU reported a failed exit" >&2
			tail -80 "$console_log" >&2
			return 1
		fi
		qemu_pid=
		exec 3>&-
		test_finished=$(date +%s)
		elapsed_seconds=$((test_finished - test_started))
		write_boot_metrics \
			"$mode" \
			"$elapsed_seconds" \
			"" "" "" "" \
			"$root_auth_seconds" \
			"$handoff_seconds" \
			"$pid1_seconds" \
			"$service_ready_seconds" \
			"$late_services_seconds" \
			"$userspace_ready_seconds"
		echo "$mode $test_init_system boot passed in ${elapsed_seconds}s"
		return
	fi

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
	root_backing_test=
	if [[ $root_mode == store-overlay ]]; then
		root_backing_test=" && grep -Eq ' /.volatoo/lower (squashfs|overlay) ro,' /proc/mounts && grep -q '^tmpfs /.volatoo/writable tmpfs rw,' /proc/mounts && test ! -e /.volatoo/ram-lower"
	elif [[ $root_mode == ram-overlay ]]; then
		root_backing_test=" && grep -Eq '^/dev/loop[0-9]+ /.volatoo/lower squashfs ro,' /proc/mounts && grep -q '^tmpfs /.volatoo/ram-lower tmpfs ro,' /proc/mounts && grep -q '^tmpfs /.volatoo/writable tmpfs rw,' /proc/mounts && test -f /.volatoo/ram-lower/root.squashfs && test ! -e /.volatoo/source"
	fi
	state_test=
	state_action=
	if [[ -n $state_image_path ]]; then
		state_test=" && grep -q ' /.volatoo/state ' /proc/mounts && grep -qx '1' /.volatoo/state/volatoo/layout-version"
	fi
	if [[ -n $test_generation ]]; then
		state_test="$state_test && grep -qx '$test_generation' /.volatoo/generation-id && grep -Eq '^(signify-ed25519|unsigned)$' /.volatoo/release-authentication && grep -q ' /.volatoo/state/volatoo/system .* ro[,)]' /proc/mounts && ! touch /.volatoo/state/volatoo/system/staging/.volatoo-public-write-test 2>/dev/null"
		if [[ $test_update_view == yes ]]; then
			state_test="$state_test && test -x /usr/libexec/volatoo-update-view"
			state_action="/usr/libexec/volatoo-update-view sh -c 'test \"\$VOLATOO_UPDATE_STATE\" = /run/volatoo/update-state && probe=\$VOLATOO_UPDATE_STATE/volatoo/system/staging/.volatoo-private-write-test && : > \"\$probe\" && rm -f \"\$probe\"' && "
		fi
	fi
	if [[ $test_generation_signature == required ]]; then
		state_test="$state_test && grep -qx 'signify-ed25519' /.volatoo/release-authentication && grep -Eq '^sha256:[0-9a-f]{64}$' /.volatoo/signature-key"
	elif [[ $test_generation_signature == allow-unsigned ]]; then
		state_test="$state_test && grep -qx 'unsigned' /.volatoo/release-authentication && test ! -e /.volatoo/signature-key"
	fi
	if [[ $test_generation_realized == yes ]]; then
		state_test="$state_test && grep -Eq '^sha256:[0-9a-f]{64}$' /.volatoo/realization-id && grep -Eq '^sha256:[0-9a-f]{64}$' /.volatoo/realization-tree-id && grep -qx 'org.volatoo.gentoo-fhs/v1' /.volatoo/fhs-contract && grep -Eq '^[123]$' /.volatoo/realization-version && grep -Eq '^(sha256-eager|dm-verity|dm-verity-layer-stack)$' /.volatoo/root-authentication"
	elif [[ $test_generation_realized == no ]]; then
		state_test="$state_test && test ! -e /.volatoo/realization-id && test ! -e /.volatoo/realization-tree-id && test ! -e /.volatoo/fhs-contract && test ! -e /.volatoo/realization-version && test ! -e /.volatoo/root-authentication"
	fi
	if [[ $test_generation_verity == yes ]]; then
		state_test="$state_test && { { grep -qx '2' /.volatoo/realization-version && grep -qx 'dm-verity' /.volatoo/root-authentication && grep -Eq '^[0-9a-f]{64}$' /.volatoo/verity-root-hash && grep -qx 'volatoo-root' /sys/block/dm-*/dm/name; } || { grep -qx '3' /.volatoo/realization-version && grep -qx 'dm-verity-layer-stack' /.volatoo/root-authentication && grep -Eq '^[1-9][0-9]*$' /.volatoo/authenticated-image-count && grep -q '^volatoo-lower-[0-9][0-9]*$' /sys/block/dm-*/dm/name; }; }"
	elif [[ $test_generation_verity == no ]]; then
		state_test="$state_test && test ! -e /.volatoo/verity-root-hash"
	fi
	if [[ $test_generation_payload == yes ]]; then
		state_test="$state_test && test ! -e /etc/volatoo-layer-one && grep -qx 'replacement-v2' /etc/volatoo-replaced && grep -qx 'layer-two' /etc/volatoo-layer-two"
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
	metrics_action=
	if [[ -n $metrics_file ]]; then
		metrics_action="set -- \$(grep '^MemTotal:' /proc/meminfo); metric_mem_total=\$2; set -- \$(grep '^MemAvailable:' /proc/meminfo); metric_mem_available=\$2; set -- \$(df -Pk / | tail -n 1); metric_root_used=\$3; metric_root_available=\$4; printf '[volatoo-test-metrics] $mode %s %s %s %s\\n' \"\$metric_mem_total\" \"\$metric_mem_available\" \"\$metric_root_used\" \"\$metric_root_available\"; "
	fi
	poweroff_command="poweroff -f"
	if [[ $test_shutdown_sync == yes && $mode == bios ]]; then
		poweroff_command=poweroff
	fi
	printf '%s\n' \
			"if grep -q '^Gentoo Base System release ' /etc/gentoo-release && grep -q '^$root_filesystem / $root_filesystem ' /proc/mounts$root_backing_test$state_test$policy_test$identity_test; then ${state_action}${policy_action}${identity_action}${metrics_action}printf '[volatoo-test] %s userspace verified\\n' '$mode'; else printf '[volatoo-test] %s userspace verification failed\\n' '$mode'; fi; $poweroff_command" \
		>&3

	while kill -0 "$qemu_pid" 2>/dev/null; do
		if [[ -z $userspace_ready_seconds ]] && \
			grep -Fq "$success_marker" "$console_log"; then
			test_now=$(date +%s)
			userspace_ready_seconds=$((test_now - test_started))
		fi
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
	elapsed_seconds=$((test_finished - test_started))
	if [[ -z $userspace_ready_seconds ]] && \
		grep -Fq "$success_marker" "$console_log"; then
		userspace_ready_seconds=$elapsed_seconds
	fi
	metrics_mem_total=
	metrics_mem_available=
	metrics_root_used=
	metrics_root_available=
	if [[ -n $metrics_file ]]; then
		metrics_line=$(
			tr -d '\r' <"$console_log" |
				grep -F "[volatoo-test-metrics] $mode " |
				tail -n 1 ||
				true
		)
		if [[ -z $metrics_line ]]; then
			echo "error: $mode guest did not report boot metrics" >&2
			tail -80 "$console_log" >&2
			return 1
		fi
		metrics_payload=${metrics_line#*"[volatoo-test-metrics] "}
		read -r \
			metrics_mode \
			metrics_mem_total \
			metrics_mem_available \
			metrics_root_used \
			metrics_root_available \
			<<<"$metrics_payload"
		if [[ $metrics_mode != "$mode" ]] || \
			[[ ! $metrics_mem_total =~ ^[0-9]+$ ]] || \
			[[ ! $metrics_mem_available =~ ^[0-9]+$ ]] || \
			[[ ! $metrics_root_used =~ ^[0-9]+$ ]] || \
			[[ ! $metrics_root_available =~ ^[0-9]+$ ]]; then
			echo "error: $mode guest reported malformed boot metrics" >&2
			echo "$metrics_line" >&2
			return 1
		fi
	fi
	write_boot_metrics \
		"$mode" \
		"$elapsed_seconds" \
		"$metrics_mem_total" \
		"$metrics_mem_available" \
		"$metrics_root_used" \
		"$metrics_root_available" \
		"$root_auth_seconds" \
		"$handoff_seconds" \
		"$pid1_seconds" \
		"$service_ready_seconds" \
		"$late_services_seconds" \
		"$userspace_ready_seconds"
	echo "$mode boot passed in ${elapsed_seconds}s"
}

for selected_firmware in "${selected_firmwares[@]}"; do
	case $selected_firmware in
		bios) run_boot_test bios pc "" "" ;;
		uefi) run_boot_test uefi q35 "$uefi_firmware" "$uefi_vars" ;;
	esac
done

echo "selected firmware boot tests passed: $firmwares"
