#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage:
  update/tests/test-volatoo-generation-qemu.sh \
    KERNEL INITRAMFS OPENRC_SQUASHFS SYSTEMD_SQUASHFS

Build generation state fixtures and boot the real OpenRC and systemd init
systems under both BIOS and UEFI.

Optional environment variables:
  VOLATOO_GENERATION_QEMU_CASES
      Comma-separated normal,corrupt,interrupted (default: all three)
  VOLATOO_GENERATION_QEMU_FIRMWARES
      Comma-separated bios,uefi passed to the boot harness (default: both)
  VOLATOO_GENERATION_QEMU_PAYLOAD_ROOT_MODES
      Comma-separated store-overlay,ram-overlay,copy,overlay, or none
      (default: store-overlay,ram-overlay,copy)
  VOLATOO_GENERATION_QEMU_PAYLOAD_TIMEOUT
      Per-VM payload timeout, including full-copy expansion (default: 900)
  VOLATOO_GENERATION_QEMU_REALIZED
      Build and boot signed realized OpenRC and systemd closures: yes or no
      (default: no)
  VOLATOO_GENERATION_QEMU_REALIZATION_VERSION
      Realization contract for the realized lane: 2 or 3 (default: 2)
  VOLATOO_GENERATION_QEMU_CONTAINER
      Run QEMU through the pinned Docker runner: yes or no (default: no)
  VOLATOO_GENERATION_QEMU_VERITY_TAMPER
      Corrupt realized data/hash/signature inputs and require fail-closed boot
      (default: yes when the realized lane is enabled)
  VOLATOO_GENERATION_QEMU_SIGNING_KEY
      Optional signify secret key for the realized lane
  VOLATOO_GENERATION_QEMU_TRUSTED_KEY
      Matching public key, which must also be embedded in INITRAMFS
  VOLATOO_TEST_TIMEOUT
      Per-VM lifecycle timeout passed to the boot harness (default: 300)
  VOLATOO_VM_MEMORY
      QEMU memory (default: 8G)
EOF
}

if (( $# != 4 )); then
	usage >&2
	exit 2
fi

kernel=$1
initramfs=$2
openrc_image=$3
systemd_image=$4
cases=${VOLATOO_GENERATION_QEMU_CASES:-normal,corrupt,interrupted}
firmwares=${VOLATOO_GENERATION_QEMU_FIRMWARES:-bios,uefi}
payload_modes=${VOLATOO_GENERATION_QEMU_PAYLOAD_ROOT_MODES:-store-overlay,ram-overlay,copy}
payload_timeout=${VOLATOO_GENERATION_QEMU_PAYLOAD_TIMEOUT:-900}
test_realized=${VOLATOO_GENERATION_QEMU_REALIZED:-no}
realization_version=${VOLATOO_GENERATION_QEMU_REALIZATION_VERSION:-2}
qemu_container=${VOLATOO_GENERATION_QEMU_CONTAINER:-no}
test_verity_tamper=${VOLATOO_GENERATION_QEMU_VERITY_TAMPER:-yes}
signing_key=${VOLATOO_GENERATION_QEMU_SIGNING_KEY:-}
trusted_key=${VOLATOO_GENERATION_QEMU_TRUSTED_KEY:-}
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-generation-qemu-test.XXXXXX")

cleanup()
{
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

for path in "$kernel" "$initramfs" "$openrc_image" "$systemd_image"; do
	[[ -f $path ]] || {
		echo "error: test input does not exist: $path" >&2
		exit 1
	}
done

IFS=, read -r -a selected_cases <<<"$cases"
(( ${#selected_cases[@]} > 0 )) || {
	echo "error: VOLATOO_GENERATION_QEMU_CASES is empty" >&2
	exit 2
}
for selected_case in "${selected_cases[@]}"; do
	case $selected_case in
		normal | corrupt | interrupted) ;;
		*)
			echo "error: unsupported generation QEMU case: $selected_case" >&2
			exit 2
			;;
	esac
done

IFS=, read -r -a selected_firmwares <<<"$firmwares"
(( ${#selected_firmwares[@]} > 0 )) || {
	echo "error: VOLATOO_GENERATION_QEMU_FIRMWARES is empty" >&2
	exit 2
}
for selected_firmware in "${selected_firmwares[@]}"; do
	case $selected_firmware in
		bios | uefi) ;;
		*)
			echo "error: unsupported QEMU firmware: $selected_firmware" >&2
			exit 2
			;;
	esac
done

declare -a selected_payload_modes=()
payload_mode_count=0
if [[ $payload_modes != none ]]; then
	IFS=, read -r -a selected_payload_modes <<<"$payload_modes"
	(( ${#selected_payload_modes[@]} > 0 )) || {
		echo "error: payload root mode list is empty" >&2
		exit 2
	}
	payload_mode_count=${#selected_payload_modes[@]}
	for selected_payload_mode in "${selected_payload_modes[@]}"; do
		case $selected_payload_mode in
			copy | overlay | ram-overlay | store-overlay) ;;
			*)
				echo "error: unsupported payload root mode: $selected_payload_mode" >&2
				exit 2
				;;
		esac
	done
fi
if [[ ! $payload_timeout =~ ^[1-9][0-9]*$ ]]; then
	echo "error: payload timeout must be a positive integer" >&2
	exit 2
fi
if [[ $test_realized != yes && $test_realized != no ]]; then
	echo "error: VOLATOO_GENERATION_QEMU_REALIZED must be yes or no" >&2
	exit 2
fi
if [[ $realization_version != 2 && $realization_version != 3 ]]; then
	echo "error: VOLATOO_GENERATION_QEMU_REALIZATION_VERSION must be 2 or 3" >&2
	exit 2
fi
if [[ $qemu_container != yes && $qemu_container != no ]]; then
	echo "error: VOLATOO_GENERATION_QEMU_CONTAINER must be yes or no" >&2
	exit 2
fi
boot_harness=$repo_root/scripts/test-qemu-boot.sh
if [[ $qemu_container == yes ]]; then
	boot_harness=$repo_root/scripts/test-qemu-boot-docker.sh
fi
if [[ $test_verity_tamper != yes && $test_verity_tamper != no ]]; then
	echo "error: VOLATOO_GENERATION_QEMU_VERITY_TAMPER must be yes or no" >&2
	exit 2
fi
if [[ -n $signing_key || -n $trusted_key ]]; then
	[[ -n $signing_key && -n $trusted_key ]] || {
		echo "error: QEMU signing and trusted keys are required together" >&2
		exit 2
	}
	[[ $test_realized == yes ]] || {
		echo "error: QEMU signing requires the realized lane" >&2
		exit 2
	}
	for key_path in "$signing_key" "$trusted_key"; do
		[[ -f $key_path && ! -L $key_path ]] || {
			echo "error: QEMU signing key is missing or unsafe: $key_path" >&2
			exit 1
		}
	done
	signing_key=$(cd -- "$(dirname -- "$signing_key")" && pwd)/$(basename -- "$signing_key")
	trusted_key=$(cd -- "$(dirname -- "$trusted_key")" && pwd)/$(basename -- "$trusted_key")
fi

for init_system in openrc systemd; do
	if [[ $init_system == openrc ]]; then
		base_image=$openrc_image
		context=$repo_root/update/examples/build-context-v1.json
	else
		base_image=$systemd_image
		context=$repo_root/update/examples/build-context-systemd-v1.json
	fi

	for selected_case in "${selected_cases[@]}"; do
		fixture=$work_dir/$init_system-$selected_case
		mkdir "$fixture"
		corrupt_current=no
		interrupt_selection=no
		require_fallback=no
		case $selected_case in
			corrupt)
				corrupt_current=yes
				require_fallback=yes
				;;
			interrupted) interrupt_selection=yes ;;
		esac
		echo "preparing $init_system $selected_case generation fixture"
		VOLATOO_GENERATION_FIXTURE_CORRUPT_CURRENT=$corrupt_current \
		VOLATOO_GENERATION_FIXTURE_INTERRUPT_SELECTION=$interrupt_selection \
			"$repo_root/update/tests/prepare-generation-qemu-fixture.sh" \
				"$init_system" \
				"$base_image" \
				"$context" \
				"$fixture"

		expected_generation=$(<"$fixture/boot.digest")
		echo "testing $init_system $selected_case generation boot"
		VOLATOO_STATE_IMAGE="$fixture/state.ext4" \
		VOLATOO_STATE_REQUIRED=yes \
		VOLATOO_TEST_ROOT_MODE=store-overlay \
		VOLATOO_TEST_GENERATION="$expected_generation" \
		VOLATOO_TEST_GENERATION_SIGNATURE=allow-unsigned \
		VOLATOO_TEST_GENERATION_FALLBACK="$require_fallback" \
		VOLATOO_TEST_FIRMWARES="$firmwares" \
		VOLATOO_TEST_INIT_SYSTEM="$init_system" \
		VOLATOO_TEST_TIMEOUT=${VOLATOO_TEST_TIMEOUT:-300} \
		VOLATOO_VM_MEMORY=${VOLATOO_VM_MEMORY:-8G} \
			"$boot_harness" \
				"$kernel" \
				"$initramfs" \
				"$base_image"
	done
done

if (( payload_mode_count > 0 )); then
	payload_fixture=$work_dir/openrc-normal
	if [[ ! -f $payload_fixture/state.ext4 ]]; then
		payload_fixture=$work_dir/openrc-payload
		mkdir "$payload_fixture"
		echo "preparing OpenRC generation payload fixture"
		"$repo_root/update/tests/prepare-generation-qemu-fixture.sh" \
			openrc \
			"$openrc_image" \
			"$repo_root/update/examples/build-context-v1.json" \
			"$payload_fixture"
	fi
	payload_generation=$(<"$payload_fixture/boot.digest")
	for ((
		index = 0;
		index < payload_mode_count;
		index += 1
	)); do
		payload_mode=${selected_payload_modes[index]}
		echo "testing generation payload in $payload_mode root"
		VOLATOO_STATE_IMAGE="$payload_fixture/state.ext4" \
		VOLATOO_STATE_REQUIRED=yes \
		VOLATOO_TEST_ROOT_MODE="$payload_mode" \
		VOLATOO_TEST_GENERATION="$payload_generation" \
		VOLATOO_TEST_GENERATION_SIGNATURE=allow-unsigned \
		VOLATOO_TEST_GENERATION_PAYLOAD=yes \
		VOLATOO_TEST_FIRMWARES="$firmwares" \
		VOLATOO_TEST_INIT_SYSTEM=shell \
		VOLATOO_TEST_TIMEOUT="$payload_timeout" \
		VOLATOO_VM_MEMORY=${VOLATOO_VM_MEMORY:-8G} \
			"$boot_harness" \
				"$kernel" \
				"$initramfs" \
				"$openrc_image"
	done
fi

if [[ $test_realized == yes ]]; then
	realized_fixture=$work_dir/openrc-realized
	mkdir "$realized_fixture"
	echo "preparing realized OpenRC generation fixture"
	realized_signature_policy=allow-unsigned
	if [[ -n $signing_key ]]; then
		realized_signature_policy=required
	fi
	VOLATOO_GENERATION_FIXTURE_REALIZE=yes \
	VOLATOO_GENERATION_FIXTURE_REALIZATION_VERSION="$realization_version" \
	VOLATOO_GENERATION_FIXTURE_SIGNING_KEY="$signing_key" \
	VOLATOO_GENERATION_FIXTURE_TRUSTED_KEY="$trusted_key" \
		"$repo_root/update/tests/prepare-generation-qemu-fixture.sh" \
			openrc \
			"$openrc_image" \
			"$repo_root/update/examples/build-context-v1.json" \
			"$realized_fixture"
	realized_generation=$(<"$realized_fixture/boot.digest")
	echo "testing realized generation in store-overlay root"
	VOLATOO_STATE_IMAGE="$realized_fixture/state.ext4" \
	VOLATOO_STATE_REQUIRED=yes \
	VOLATOO_TEST_ROOT_MODE=store-overlay \
	VOLATOO_TEST_GENERATION="$realized_generation" \
	VOLATOO_TEST_GENERATION_SIGNATURE="$realized_signature_policy" \
	VOLATOO_TEST_GENERATION_REALIZED=yes \
	VOLATOO_TEST_GENERATION_VERITY=yes \
	VOLATOO_TEST_GENERATION_PAYLOAD=yes \
	VOLATOO_TEST_SERVICE_READY=yes \
	VOLATOO_TEST_FIRMWARES="$firmwares" \
	VOLATOO_TEST_INIT_SYSTEM=openrc \
	VOLATOO_TEST_TIMEOUT="$payload_timeout" \
	VOLATOO_VM_MEMORY=${VOLATOO_VM_MEMORY:-8G} \
		"$boot_harness" \
			"$kernel" \
			"$initramfs" \
			"$openrc_image"

	if [[ $realization_version == 3 && -n $trusted_key ]]; then
		realized_rollback_state=$work_dir/openrc-realized-rollback.ext4
		cp "$realized_fixture/state.ext4" "$realized_rollback_state"
		"$repo_root/update/tests/corrupt-state-object-docker.sh" \
			"$realized_rollback_state" \
			"$(<"$realized_fixture/realization-rootfs.digest")"
		realized_previous_generation=$(<"$realized_fixture/previous.digest")
		echo "testing signed realized generation rollback"
		VOLATOO_STATE_IMAGE="$realized_rollback_state" \
		VOLATOO_STATE_REQUIRED=yes \
		VOLATOO_TEST_ROOT_MODE=store-overlay \
		VOLATOO_TEST_GENERATION="$realized_previous_generation" \
		VOLATOO_TEST_GENERATION_SIGNATURE=required \
		VOLATOO_TEST_GENERATION_FALLBACK=yes \
		VOLATOO_TEST_GENERATION_REALIZED=yes \
		VOLATOO_TEST_GENERATION_VERITY=yes \
		VOLATOO_TEST_SERVICE_READY=yes \
		VOLATOO_TEST_FIRMWARES="$firmwares" \
		VOLATOO_TEST_INIT_SYSTEM=openrc \
		VOLATOO_TEST_TIMEOUT="$payload_timeout" \
		VOLATOO_VM_MEMORY=${VOLATOO_VM_MEMORY:-8G} \
			"$boot_harness" \
				"$kernel" \
				"$initramfs" \
				"$openrc_image"
	fi

	if [[ $test_verity_tamper == yes ]]; then
		declare -a tamper_kinds=(data hash)
		if [[ $realization_version == 3 ]]; then
			tamper_kinds+=(receipt)
		fi
		for tamper_kind in "${tamper_kinds[@]}"; do
			expected_tamper_failure=image.squashfs-mount
			case $tamper_kind in
				data)
					tamper_digest=$(<"$realized_fixture/realization-rootfs.digest")
					if [[ $realization_version == 3 ]]; then
						expected_tamper_failure=generation.incremental-squashfs
					fi
					;;
				hash)
					tamper_digest=$(<"$realized_fixture/verity-hash.digest")
					if [[ $realization_version == 3 ]]; then
						expected_tamper_failure=generation.incremental-squashfs
					fi
					;;
				receipt)
					tamper_digest=$(<"$realized_fixture/parent-tree-receipt.digest")
					expected_tamper_failure=generation.selected
					;;
			esac
			tampered_state=$work_dir/openrc-realized-$tamper_kind.ext4
			cp "$realized_fixture/state.ext4" "$tampered_state"
			"$repo_root/update/tests/corrupt-state-object-docker.sh" \
				"$tampered_state" \
				"$tamper_digest"
			echo "testing fail-closed realized $tamper_kind corruption"
			VOLATOO_STATE_IMAGE="$tampered_state" \
			VOLATOO_STATE_REQUIRED=yes \
			VOLATOO_GENERATION="$realized_generation" \
			VOLATOO_TEST_ROOT_MODE=store-overlay \
			VOLATOO_TEST_GENERATION="$realized_generation" \
			VOLATOO_TEST_GENERATION_SIGNATURE="$realized_signature_policy" \
			VOLATOO_TEST_GENERATION_REALIZED=yes \
			VOLATOO_TEST_GENERATION_VERITY=yes \
			VOLATOO_TEST_EXPECT_FAILURE_CODE="$expected_tamper_failure" \
			VOLATOO_TEST_FIRMWARES=bios \
			VOLATOO_TEST_INIT_SYSTEM=shell \
			VOLATOO_TEST_TIMEOUT="$payload_timeout" \
			VOLATOO_VM_MEMORY=${VOLATOO_VM_MEMORY:-8G} \
				"$boot_harness" \
					"$kernel" \
					"$initramfs" \
					"$openrc_image"
		done
		if [[ -n $trusted_key ]]; then
			tampered_signature_state=$work_dir/openrc-realized-signature.ext4
			cp "$realized_fixture/state.ext4" "$tampered_signature_state"
			"$repo_root/update/tests/corrupt-state-signature-docker.sh" \
				"$tampered_signature_state" \
				"$(<"$realized_fixture/realization.digest")" \
				"$(<"$realized_fixture/signature-key.digest")"
			echo "testing fail-closed realized signature corruption"
			VOLATOO_STATE_IMAGE="$tampered_signature_state" \
			VOLATOO_STATE_REQUIRED=yes \
			VOLATOO_GENERATION="$realized_generation" \
			VOLATOO_TEST_ROOT_MODE=store-overlay \
			VOLATOO_TEST_GENERATION="$realized_generation" \
			VOLATOO_TEST_GENERATION_REALIZED=yes \
			VOLATOO_TEST_GENERATION_VERITY=yes \
			VOLATOO_TEST_GENERATION_SIGNATURE=required \
			VOLATOO_TEST_EXPECT_FAILURE_CODE=generation.selected \
			VOLATOO_TEST_FIRMWARES=bios \
			VOLATOO_TEST_INIT_SYSTEM=shell \
			VOLATOO_TEST_TIMEOUT="$payload_timeout" \
			VOLATOO_VM_MEMORY=${VOLATOO_VM_MEMORY:-8G} \
				"$boot_harness" \
					"$kernel" \
					"$initramfs" \
					"$openrc_image"
		fi
	fi

	systemd_realized_fixture=$work_dir/systemd-realized
	mkdir "$systemd_realized_fixture"
	echo "preparing realized systemd generation fixture"
	VOLATOO_GENERATION_FIXTURE_REALIZE=yes \
	VOLATOO_GENERATION_FIXTURE_REALIZATION_VERSION="$realization_version" \
	VOLATOO_GENERATION_FIXTURE_SIGNING_KEY="$signing_key" \
	VOLATOO_GENERATION_FIXTURE_TRUSTED_KEY="$trusted_key" \
		"$repo_root/update/tests/prepare-generation-qemu-fixture.sh" \
			systemd \
			"$systemd_image" \
			"$repo_root/update/examples/build-context-systemd-v1.json" \
			"$systemd_realized_fixture"
	systemd_realized_generation=$(<"$systemd_realized_fixture/boot.digest")
	echo "testing realized systemd generation with the real PID 1"
	VOLATOO_STATE_IMAGE="$systemd_realized_fixture/state.ext4" \
	VOLATOO_STATE_REQUIRED=yes \
	VOLATOO_TEST_ROOT_MODE=store-overlay \
	VOLATOO_TEST_GENERATION="$systemd_realized_generation" \
	VOLATOO_TEST_GENERATION_SIGNATURE="$realized_signature_policy" \
	VOLATOO_TEST_GENERATION_REALIZED=yes \
	VOLATOO_TEST_GENERATION_VERITY=yes \
	VOLATOO_TEST_GENERATION_PAYLOAD=yes \
	VOLATOO_TEST_SERVICE_READY=yes \
	VOLATOO_TEST_FIRMWARES="$firmwares" \
	VOLATOO_TEST_INIT_SYSTEM=systemd \
	VOLATOO_TEST_TIMEOUT="$payload_timeout" \
	VOLATOO_VM_MEMORY=${VOLATOO_VM_MEMORY:-8G} \
		"$boot_harness" \
			"$kernel" \
			"$initramfs" \
			"$systemd_image"
fi

echo "OpenRC/systemd lifecycle and generation payload QEMU tests passed"
