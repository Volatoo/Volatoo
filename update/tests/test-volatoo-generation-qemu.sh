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
  VOLATOO_TEST_TIMEOUT
      Per-VM timeout passed to scripts/test-qemu-boot.sh (default: 300)
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
		VOLATOO_TEST_ROOT_MODE=overlay \
		VOLATOO_TEST_GENERATION="$expected_generation" \
		VOLATOO_TEST_GENERATION_FALLBACK="$require_fallback" \
		VOLATOO_TEST_INIT_SYSTEM="$init_system" \
		VOLATOO_TEST_TIMEOUT=${VOLATOO_TEST_TIMEOUT:-300} \
		VOLATOO_VM_MEMORY=${VOLATOO_VM_MEMORY:-8G} \
			"$repo_root/scripts/test-qemu-boot.sh" \
				"$kernel" \
				"$initramfs" \
				"$base_image"
	done
done

echo "OpenRC and systemd generation QEMU tests passed"
