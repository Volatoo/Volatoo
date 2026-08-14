#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/run-phase0-qemu.sh KERNEL [INITRAMFS] [IMAGE]

Boot the Phase 0 prototype with QEMU. INITRAMFS defaults to
out/volatoo-initramfs.cpio.gz. IMAGE may be a raw SquashFS or a filesystem/ISO
containing one. When present, the VM receives 8 GiB of RAM.

Optional environment variables:
  VOLATOO_TARGET_INIT  Program to run after switch_root (default: /bin/bash)
  VOLATOO_VM_MEMORY    QEMU memory with an image attached (default: 8G)
  VOLATOO_QEMU_ACCEL   QEMU accelerator: tcg or kvm (default: tcg)
  VOLATOO_QEMU_CPU     QEMU CPU model (default: max for TCG, host for KVM)
  VOLATOO_ROOT_MODE    Root layout: store-overlay, ram-overlay, copy, or overlay
                       (default: store-overlay)
  VOLATOO_TMPFS_SIZE   Root tmpfs size as a percentage (default: configured)
  VOLATOO_IMAGE        Device path, LABEL=..., or UUID=... (default: /dev/vda)
  VOLATOO_IMAGE_FILE   SquashFS path inside a filesystem/ISO (default: empty)
  VOLATOO_IMAGE_SHA256 Expected lowercase SquashFS SHA-256 (default: unchecked)
  VOLATOO_IMAGE_BUS    Attachment bus: virtio or usb (default: virtio)
  VOLATOO_STATE_IMAGE  Writable state filesystem image to attach (default: none)
  VOLATOO_STATE        State device spec (default with image: LABEL=VOLATOO-STATE)
  VOLATOO_STATE_REQUIRED Require state discovery: yes or no (default: configured)
  VOLATOO_GENERATION   Generation selector: auto, previous, none, or sha256:...
  VOLATOO_SIGNATURE_POLICY Generation trust: required or allow-unsigned
  VOLATOO_QEMU_MACHINE QEMU machine type (default: pc)
  VOLATOO_QEMU_FIRMWARE Optional read-only UEFI code image; BIOS when empty
  VOLATOO_QEMU_VARS    Optional writable UEFI variables image

Press Ctrl-A, then X to stop QEMU if the guest does not power off.
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
image_path=${3:-}
state_image_path=${VOLATOO_STATE_IMAGE:-}

if [[ ! -f $kernel_path ]]; then
	echo "error: kernel does not exist: $kernel_path" >&2
	exit 1
fi

if [[ ! -f $initramfs_path ]]; then
	echo "error: initramfs does not exist: $initramfs_path" >&2
	exit 1
fi

if [[ -n $image_path && ! -f $image_path ]]; then
	echo "error: image does not exist: $image_path" >&2
	exit 1
fi

if [[ -n $state_image_path && ! -f $state_image_path ]]; then
	echo "error: state image does not exist: $state_image_path" >&2
	exit 1
fi

if ! command -v qemu-system-x86_64 >/dev/null 2>&1; then
	echo "error: qemu-system-x86_64 is not installed" >&2
	exit 1
fi

memory=512M
kernel_args="console=ttyS0 rdinit=/init panic=-1"
qemu_machine=${VOLATOO_QEMU_MACHINE:-pc}
qemu_firmware=${VOLATOO_QEMU_FIRMWARE:-}
qemu_vars=${VOLATOO_QEMU_VARS:-}
qemu_accel=${VOLATOO_QEMU_ACCEL:-tcg}
qemu_cpu=${VOLATOO_QEMU_CPU:-}
state_location=${VOLATOO_STATE:-}
state_required=${VOLATOO_STATE_REQUIRED:-}
generation_mode=${VOLATOO_GENERATION:-}
signature_policy=${VOLATOO_SIGNATURE_POLICY:-}

if [[ ! $qemu_machine =~ ^[[:alnum:]_.-]+$ ]]; then
	echo "error: VOLATOO_QEMU_MACHINE contains unsupported characters" >&2
	exit 1
fi

if [[ $qemu_accel != tcg && $qemu_accel != kvm ]]; then
	echo "error: VOLATOO_QEMU_ACCEL must be tcg or kvm" >&2
	exit 1
fi
if [[ -z $qemu_cpu ]]; then
	if [[ $qemu_accel == kvm ]]; then
		qemu_cpu=host
	else
		qemu_cpu=max
	fi
fi
if [[ ! $qemu_cpu =~ ^[[:alnum:]_.+-]+$ ]]; then
	echo "error: VOLATOO_QEMU_CPU contains unsupported characters" >&2
	exit 1
fi

if [[ -n $qemu_firmware && ! -f $qemu_firmware ]]; then
	echo "error: QEMU firmware does not exist: $qemu_firmware" >&2
	exit 1
fi

if [[ -n $qemu_vars && ! -f $qemu_vars ]]; then
	echo "error: QEMU variables image does not exist: $qemu_vars" >&2
	exit 1
fi

if [[ -n $qemu_vars && -z $qemu_firmware ]]; then
	echo "error: VOLATOO_QEMU_VARS requires VOLATOO_QEMU_FIRMWARE" >&2
	exit 1
fi

if [[ -n $state_image_path && -z $state_location ]]; then
	state_location=LABEL=VOLATOO-STATE
fi

if [[ -n $state_location ]]; then
	if [[ $state_location == *[[:space:]]* ]] || \
		[[ $state_location != none && $state_location != /dev/* && \
			$state_location != LABEL=?* && $state_location != UUID=?* ]]; then
		echo "error: VOLATOO_STATE must be none, /dev/..., LABEL=..., or UUID=..." >&2
		exit 1
	fi
	kernel_args="$kernel_args volatoo.state=$state_location"
fi

if [[ -n $state_required ]]; then
	if [[ $state_required != yes && $state_required != no ]]; then
		echo "error: VOLATOO_STATE_REQUIRED must be yes or no" >&2
		exit 1
	fi
	kernel_args="$kernel_args volatoo.state-required=$state_required"
fi

if [[ -n $generation_mode ]]; then
	if [[ $generation_mode != auto && \
		$generation_mode != previous && \
		$generation_mode != none && \
		! $generation_mode =~ ^sha256:[0-9a-f]{64}$ ]]; then
		echo "error: VOLATOO_GENERATION has an invalid selector" >&2
		exit 1
	fi
	kernel_args="$kernel_args volatoo.generation=$generation_mode"
fi

if [[ -n $signature_policy ]]; then
	if [[ $signature_policy != required && \
		$signature_policy != allow-unsigned ]]; then
		echo "error: VOLATOO_SIGNATURE_POLICY must be required or allow-unsigned" >&2
		exit 1
	fi
	kernel_args="$kernel_args volatoo.signature-policy=$signature_policy"
fi

if [[ -n $image_path ]]; then
	memory=${VOLATOO_VM_MEMORY:-8G}
	target_init=${VOLATOO_TARGET_INIT:-/bin/bash}
	root_mode=${VOLATOO_ROOT_MODE:-store-overlay}
	tmpfs_size=${VOLATOO_TMPFS_SIZE:-}
	image_bus=${VOLATOO_IMAGE_BUS:-virtio}
	image_location=${VOLATOO_IMAGE:-}
	image_file=${VOLATOO_IMAGE_FILE:-}
	image_sha256=${VOLATOO_IMAGE_SHA256:-}

	if [[ $image_bus != virtio && $image_bus != usb ]]; then
		echo "error: VOLATOO_IMAGE_BUS must be virtio or usb" >&2
		exit 1
	fi
	if [[ -z $image_location ]]; then
		if [[ $image_bus == usb ]]; then
			image_location=/dev/sda
		else
			image_location=/dev/vda
		fi
	fi

	if [[ $target_init != /* || $target_init == *[[:space:]]* ]]; then
		echo "error: VOLATOO_TARGET_INIT must be an absolute path without whitespace" >&2
		exit 1
	fi
	if [[ $root_mode != copy && \
		$root_mode != overlay && \
		$root_mode != ram-overlay && \
		$root_mode != store-overlay ]]; then
		echo "error: VOLATOO_ROOT_MODE must be store-overlay, ram-overlay, copy, or overlay" >&2
		exit 1
	fi
	if [[ $image_location == *[[:space:]]* ]] || \
		[[ $image_location != /dev/* && $image_location != LABEL=?* && $image_location != UUID=?* ]]; then
		echo "error: VOLATOO_IMAGE must be /dev/..., LABEL=..., or UUID=... without whitespace" >&2
		exit 1
	fi
	if [[ -n $image_file && ($image_file != /* || $image_file == *[[:space:]]*) ]]; then
		echo "error: VOLATOO_IMAGE_FILE must be an absolute path without whitespace" >&2
		exit 1
	fi
	if [[ -n $image_sha256 && ! $image_sha256 =~ ^[0-9a-f]{64}$ ]]; then
		echo "error: VOLATOO_IMAGE_SHA256 must be 64 lowercase hexadecimal characters" >&2
		exit 1
	fi

	kernel_args="$kernel_args volatoo.image=$image_location volatoo.init=$target_init volatoo.root=$root_mode"
	if [[ -n $image_file ]]; then
		kernel_args="$kernel_args volatoo.image-file=$image_file"
	fi
	if [[ -n $image_sha256 ]]; then
		kernel_args="$kernel_args volatoo.image-sha256=$image_sha256"
	fi
	if [[ -n $tmpfs_size ]]; then
		if [[ ! $tmpfs_size =~ ^([1-9]|[1-9][0-9]|100)%$ ]]; then
			echo "error: VOLATOO_TMPFS_SIZE must be from 1% to 100%" >&2
			exit 1
		fi
		kernel_args="$kernel_args volatoo.tmpfs-size=$tmpfs_size"
	fi
fi

qemu_args=(
	-machine "$qemu_machine,accel=$qemu_accel"
	-cpu "$qemu_cpu"
	-m "$memory"
	-kernel "$kernel_path"
	-initrd "$initramfs_path"
	-append "$kernel_args"
	-nographic
	-no-reboot
)

if [[ -n $qemu_firmware ]]; then
	qemu_args+=(
		-drive "if=pflash,unit=0,format=raw,readonly=on,file=$qemu_firmware"
	)
	if [[ -n $qemu_vars ]]; then
		qemu_args+=(
			-drive "if=pflash,unit=1,format=raw,file=$qemu_vars"
		)
	fi
fi

if [[ -n $image_path ]]; then
	qemu_args+=(
		-drive "if=none,id=volatoo-root,file=$image_path,format=raw,readonly=on"
	)
	if [[ $image_bus == usb ]]; then
		qemu_args+=(
			-device qemu-xhci
			-device "usb-storage,drive=volatoo-root,removable=true"
		)
	else
		qemu_args+=(
			-device "virtio-blk-pci,drive=volatoo-root"
		)
	fi
fi

if [[ -n $state_image_path ]]; then
	qemu_args+=(
		-drive "if=none,id=volatoo-state,file=$state_image_path,format=raw"
		-device "virtio-blk-pci,drive=volatoo-state"
	)
fi

exec qemu-system-x86_64 "${qemu_args[@]}"
