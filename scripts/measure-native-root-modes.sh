#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage:
  scripts/measure-native-root-modes.sh \
    KERNEL INITRAMFS SYSTEMD_SQUASHFS OUTPUT_TSV

Run the Volatoo native x86_64 root-mode performance Gate. The Gate uses KVM,
boots store-overlay, ram-overlay, and copy roots into a shell and systemd,
records versioned TSV metrics, and requires:

  - every systemd boot to finish within the configured limit;
  - both overlay modes to reach the systemd login no slower than copy; and
  - both overlay modes to retain the configured minimum additional available
    RAM over copy.

OUTPUT_TSV must not already exist. Metrics remain available there when a
performance assertion fails.

Optional environment variables:
  VOLATOO_NATIVE_GATE_FIRMWARES
      Comma-separated bios,uefi (default: bios)
  VOLATOO_NATIVE_GATE_TIMEOUT
      Per-VM timeout in seconds (default: 180)
  VOLATOO_NATIVE_GATE_MAX_SYSTEMD_SECONDS
      Maximum login time for either root mode (default: 120)
  VOLATOO_NATIVE_GATE_MIN_AVAILABLE_GAIN_KIB
      Required overlay MemAvailable gain over copy (default: 524288)
  VOLATOO_VM_MEMORY
      QEMU memory (default: 8G)
  VOLATOO_UEFI_FIRMWARE, VOLATOO_UEFI_VARS
      Forwarded to the QEMU boot harness when UEFI is selected
EOF
}

if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
	usage
	exit 0
fi
if (( $# != 4 )); then
	usage >&2
	exit 2
fi

kernel=$1
initramfs=$2
systemd_image=$3
output=$4
firmwares=${VOLATOO_NATIVE_GATE_FIRMWARES:-bios}
timeout=${VOLATOO_NATIVE_GATE_TIMEOUT:-180}
max_systemd_seconds=${VOLATOO_NATIVE_GATE_MAX_SYSTEMD_SECONDS:-120}
min_available_gain_kib=${VOLATOO_NATIVE_GATE_MIN_AVAILABLE_GAIN_KIB:-524288}
vm_memory=${VOLATOO_VM_MEMORY:-8G}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for input_path in "$kernel" "$initramfs" "$systemd_image"; do
	if [[ ! -f $input_path ]]; then
		echo "error: benchmark input does not exist: $input_path" >&2
		exit 1
	fi
done
for setting_name in timeout max_systemd_seconds min_available_gain_kib; do
	setting_value=${!setting_name}
	if [[ ! $setting_value =~ ^[1-9][0-9]*$ ]]; then
		echo "error: $setting_name must be a positive integer" >&2
		exit 2
	fi
done

IFS=, read -r -a selected_firmwares <<<"$firmwares"
(( ${#selected_firmwares[@]} > 0 )) || {
	echo "error: VOLATOO_NATIVE_GATE_FIRMWARES is empty" >&2
	exit 2
}
for firmware in "${selected_firmwares[@]}"; do
	case $firmware in
		bios | uefi) ;;
		*)
			echo "error: unsupported firmware: $firmware" >&2
			exit 2
			;;
	esac
done

host_arch=$(uname -m)
if [[ $host_arch != x86_64 && $host_arch != amd64 ]]; then
	echo "error: native Gate requires an x86_64 host; found: $host_arch" >&2
	exit 1
fi
if [[ ! -c /dev/kvm || ! -r /dev/kvm || ! -w /dev/kvm ]]; then
	echo "error: native Gate requires read-write access to /dev/kvm" >&2
	exit 1
fi
if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
	echo "error: qemu-system-x86_64 is not installed" >&2
	exit 1
fi
if ! qemu-system-x86_64 -accel help 2>/dev/null | grep -qx kvm; then
	echo "error: qemu-system-x86_64 does not provide the KVM accelerator" >&2
	exit 1
fi

output_parent=$(dirname -- "$output")
if [[ ! -d $output_parent ]]; then
	echo "error: output directory does not exist: $output_parent" >&2
	exit 1
fi
if [[ -e $output || -L $output ]]; then
	echo "error: output already exists: $output" >&2
	exit 1
fi
output_parent=$(cd -- "$output_parent" && pwd)
output=$output_parent/$(basename -- "$output")

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-native-root-gate.XXXXXX")
metrics=$work_dir/root-mode-metrics.tsv
cleanup() {
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

if command -v sha256sum >/dev/null 2>&1; then
	checksum_output=$(sha256sum "$systemd_image")
else
	checksum_output=$(shasum -a 256 "$systemd_image")
fi
image_sha256=${checksum_output%% *}

for root_mode in store-overlay ram-overlay copy; do
	echo "measuring $root_mode shell handoff and memory"
	VOLATOO_IMAGE_SHA256="$image_sha256" \
	VOLATOO_QEMU_ACCEL=kvm \
	VOLATOO_TEST_FIRMWARES="$firmwares" \
	VOLATOO_TEST_INIT_SYSTEM=shell \
	VOLATOO_TEST_METRICS_FILE="$metrics" \
	VOLATOO_TEST_ROOT_MODE="$root_mode" \
	VOLATOO_TEST_TIMEOUT="$timeout" \
	VOLATOO_VM_MEMORY="$vm_memory" \
		"$repo_root/scripts/test-qemu-boot.sh" \
			"$kernel" "$initramfs" "$systemd_image"

	echo "measuring $root_mode systemd login"
	VOLATOO_IMAGE_SHA256="$image_sha256" \
	VOLATOO_QEMU_ACCEL=kvm \
	VOLATOO_TEST_FIRMWARES="$firmwares" \
	VOLATOO_TEST_INIT_SYSTEM=systemd \
	VOLATOO_TEST_METRICS_FILE="$metrics" \
	VOLATOO_TEST_ROOT_MODE="$root_mode" \
	VOLATOO_TEST_TIMEOUT="$timeout" \
	VOLATOO_VM_MEMORY="$vm_memory" \
		"$repo_root/scripts/test-qemu-boot.sh" \
			"$kernel" "$initramfs" "$systemd_image"
done

mv -- "$metrics" "$output"

metric_value() {
	metric_firmware=$1
	metric_root_mode=$2
	metric_init_system=$3
	metric_column=$4

	awk -F '\t' \
		-v firmware="$metric_firmware" \
		-v root_mode="$metric_root_mode" \
		-v init_system="$metric_init_system" \
		-v column="$metric_column" \
		'
		NR > 1 &&
		$8 == firmware &&
		$9 == root_mode &&
		$10 == init_system {
			value = $column
			matches += 1
		}
		END {
			if (matches != 1 || value !~ /^[0-9]+$/) {
				exit 1
			}
			print value
		}
		' \
		"$output"
}

gate_failed=0
for firmware in "${selected_firmwares[@]}"; do
	copy_seconds=$(metric_value "$firmware" copy systemd 11)
	store_seconds=$(metric_value "$firmware" store-overlay systemd 11)
	ram_seconds=$(metric_value "$firmware" ram-overlay systemd 11)
	copy_available=$(metric_value "$firmware" copy shell 14)
	store_available=$(metric_value "$firmware" store-overlay shell 14)
	ram_available=$(metric_value "$firmware" ram-overlay shell 14)
	store_available_gain=$((store_available - copy_available))
	ram_available_gain=$((ram_available - copy_available))

	printf '%s: copy=%ss store-overlay=%ss ram-overlay=%ss store-gain=%s KiB ram-gain=%s KiB\n' \
		"$firmware" \
		"$copy_seconds" \
		"$store_seconds" \
		"$ram_seconds" \
		"$store_available_gain" \
		"$ram_available_gain"

	if (( copy_seconds > max_systemd_seconds )); then
		echo "error: $firmware copy exceeded ${max_systemd_seconds}s" >&2
		gate_failed=1
	fi
	if (( ram_seconds > max_systemd_seconds )); then
		echo "error: $firmware ram-overlay exceeded ${max_systemd_seconds}s" >&2
		gate_failed=1
	fi
	if (( store_seconds > max_systemd_seconds )); then
		echo "error: $firmware store-overlay exceeded ${max_systemd_seconds}s" >&2
		gate_failed=1
	fi
	if (( store_seconds > copy_seconds )); then
		echo "error: $firmware store-overlay was slower than copy" >&2
		gate_failed=1
	fi
	if (( ram_seconds > copy_seconds )); then
		echo "error: $firmware ram-overlay was slower than copy" >&2
		gate_failed=1
	fi
	if (( store_available_gain < min_available_gain_kib )); then
		echo "error: $firmware store-overlay RAM gain was below ${min_available_gain_kib} KiB" >&2
		gate_failed=1
	fi
	if (( ram_available_gain < min_available_gain_kib )); then
		echo "error: $firmware ram-overlay RAM gain was below ${min_available_gain_kib} KiB" >&2
		gate_failed=1
	fi
done

if (( gate_failed != 0 )); then
	echo "native root-mode performance Gate failed; metrics: $output" >&2
	exit 1
fi

echo "native root-mode performance Gate passed: $output"
