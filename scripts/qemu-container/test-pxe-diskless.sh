#!/usr/bin/env bash

set -euo pipefail

if (( $# != 5 )); then
	echo "Usage: test-pxe-diskless.sh KERNEL INITRAMFS ROOTFS ISO INIT_SYSTEM" >&2
	exit 2
fi

kernel=$1
initramfs=$2
rootfs=$3
iso=$4
init_system=$5
timeout_seconds=${VOLATOO_PXE_QEMU_TIMEOUT:-240}
vm_memory=${VOLATOO_PXE_VM_MEMORY:-8192}
pxe_rom=${VOLATOO_PXE_ROM:-/usr/lib/ipxe/qemu/pxe-e1000.rom}

for path in "$kernel" "$initramfs" "$rootfs" "$iso"; do
	[[ -f $path && ! -L $path ]] || {
		echo "error: PXE input is missing or unsafe: $path" >&2
		exit 1
	}
done
[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: init system must be openrc or systemd" >&2
	exit 2
}
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
	echo "error: VOLATOO_PXE_QEMU_TIMEOUT must be a positive integer" >&2
	exit 2
}
[[ $vm_memory =~ ^[1-9][0-9]*$ ]] || {
	echo "error: VOLATOO_PXE_VM_MEMORY must be a positive integer" >&2
	exit 2
}
[[ -f $pxe_rom && ! -L $pxe_rom ]] || {
	echo "error: iPXE PXE option ROM is missing or unsafe: $pxe_rom" >&2
	exit 1
}

rootfs_digest=$(sha256sum "$rootfs" | awk '{ print $1 }')
[[ $rootfs_digest =~ ^[0-9a-f]{64}$ ]] || {
	echo "error: could not hash the root SquashFS" >&2
	exit 1
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-pxe.XXXXXX")
log=$work_dir/qemu.log
tftp_dir=$work_dir/tftp
qemu_pid=
cleanup()
{
	if [[ -n $qemu_pid ]]; then
		kill "$qemu_pid" 2>/dev/null || true
		wait "$qemu_pid" 2>/dev/null || true
	fi
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

mkdir -p "$tftp_dir"
cp -- "$kernel" "$tftp_dir/vmlinuz"
cp -- "$initramfs" "$tftp_dir/initramfs.cpio.gz"

# QEMU user networking assigns the guest 10.0.2.15 and runs its built-in
# DHCP and TFTP servers on 10.0.2.2. The shipped iPXE PXE option ROM fetches
# this script, then the kernel and initrd, over that in-process TFTP server,
# so no external network access is required.
cat >"$tftp_dir/volatoo.ipxe" <<EOF
#!ipxe
dhcp
kernel tftp://10.0.2.2/vmlinuz console=tty0 console=ttyS0,115200 volatoo.image=/dev/vda volatoo.image-file=/volatoo/root.squashfs volatoo.image-sha256=$rootfs_digest volatoo.root=ram-overlay volatoo.state=none volatoo.generation=none volatoo.init=/sbin/init
initrd tftp://10.0.2.2/initramfs.cpio.gz
boot
EOF

qemu-system-x86_64 \
	-machine accel=tcg \
	-m "$vm_memory" \
	-smp 2 \
	-nographic \
	-no-reboot \
	-boot order=n \
	-netdev "user,id=net0,tftp=$tftp_dir,bootfile=volatoo.ipxe" \
	-device "e1000,netdev=net0,romfile=$pxe_rom" \
	-drive "if=none,id=root,file=$iso,format=raw,readonly=on" \
	-device virtio-blk-pci,drive=root \
	>"$log" 2>&1 &
qemu_pid=$!

deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
	if grep -Eq '(^|[^[:alpha:]])login: ' "$log"; then
		break
	fi
	if ! kill -0 "$qemu_pid" 2>/dev/null; then
		echo "error: PXE QEMU exited before the login prompt" >&2
		tail -160 "$log" >&2
		exit 1
	fi
	sleep 0.5
done
if ! grep -Eq '(^|[^[:alpha:]])login: ' "$log"; then
	echo "error: PXE boot did not reach a login prompt in ${timeout_seconds}s" >&2
	tail -160 "$log" >&2
	exit 1
fi

required_patterns=(
	'iPXE'
	'tftp://10\.0\.2\.2/vmlinuz\.\.\. ok'
	'tftp://10\.0\.2\.2/initramfs\.cpio\.gz\.\.\. ok'
	'\[volatoo\] initramfs started'
	'\[volatoo\] image device resolved: /dev/vda'
	'\[volatoo\] state partition discovery disabled'
	'\[volatoo\] SHA-256 verified in [0-9]+s'
	'\[volatoo\] source image released; RAM lower attached:'
	'\[volatoo\] RAM-backed overlay root ready'
	'\[volatoo\] switching to ram-overlay root; init=/sbin/init'
)
case $init_system in
	openrc) required_patterns+=('OpenRC .* is starting up') ;;
	systemd) required_patterns+=('systemd\[[[:space:]]*1\]') ;;
esac
for pattern in "${required_patterns[@]}"; do
	if ! grep -Eq "$pattern" "$log"; then
		echo "error: PXE boot log is missing: $pattern" >&2
		tail -160 "$log" >&2
		exit 1
	fi
done

echo "Volatoo $init_system PXE diskless boot passed (ram-overlay, state=none)"
