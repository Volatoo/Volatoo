#!/usr/bin/env bash

set -euo pipefail

for name in kernel initramfs rootfs state; do
	path=/input/$name
	[[ -f $path && ! -L $path ]] || {
		echo "error: release input is missing or unsafe: $path" >&2
		exit 1
	}
done

output_name=${OUTPUT_NAME:?missing OUTPUT_NAME}
init_system=${INIT_SYSTEM:?missing INIT_SYSTEM}
host_uid=${HOST_UID:?missing HOST_UID}
host_gid=${HOST_GID:?missing HOST_GID}
[[ $output_name =~ ^[A-Za-z0-9._-]+\.img$ ]] || {
	echo "error: unsafe release output name: $output_name" >&2
	exit 1
}
[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: INIT_SYSTEM must be openrc or systemd" >&2
	exit 1
}

efi_mib=128
rootfs_bytes=$(stat -c %s /input/rootfs)
state_bytes=$(stat -c %s /input/state)
system_mib=$(( (rootfs_bytes + 1048575) / 1048576 + 64 ))
state_mib=$(( (state_bytes + 1048575) / 1048576 + 8 ))
disk_mib=$(( 4 + efi_mib + system_mib + state_mib + 16 ))
rootfs_sha256=$(sha256sum /input/rootfs | awk '{print $1}')

staging=/output/.${output_name}.$$
staging_manifest=${staging}.manifest
loop_device=
boot_mount=/mnt/volatoo-boot
system_mount=/mnt/volatoo-system
cleanup()
{
	if mountpoint -q "$system_mount"; then umount "$system_mount"; fi
	if mountpoint -q "$boot_mount"; then umount "$boot_mount"; fi
	if [[ -n $loop_device ]]; then losetup -d "$loop_device"; fi
	rm -f -- "$staging" "$staging_manifest"
}
trap cleanup EXIT

[[ ! -e /output/$output_name && ! -e /output/$output_name.manifest ]] || {
	echo "error: release output already exists: /output/$output_name" >&2
	exit 1
}
truncate -s "${disk_mib}M" "$staging"
sgdisk --clear \
	--new=1:2048:+2M --typecode=1:ef02 --change-name=1:VOLATOO-BIOS \
	--new=2:0:+${efi_mib}M --typecode=2:ef00 --change-name=2:VOLATOO-BOOT \
	--new=3:0:+${system_mib}M --typecode=3:8300 --change-name=3:VOLATOO-SYSTEM \
	--new=4:0:+${state_mib}M --typecode=4:8300 --change-name=4:VOLATOO-STATE \
	"$staging" >/dev/null

loop_device=$(losetup --find --show --partscan "$staging")
partx --update "$loop_device" >/dev/null || {
	echo "error: kernel refused to load the release partition table" >&2
	exit 1
}
# The kernel publishes loop partitions immediately, while a container's /dev
# does not necessarily receive their device nodes from the host device manager.
mdev -s >/dev/null 2>&1 || true
for number in 1 2 3 4; do
	for _ in $(seq 1 100); do
		if [[ -b ${loop_device}p$number ]] &&
			blockdev --getsize64 "${loop_device}p$number" >/dev/null 2>&1; then
			break
		fi
		# mdev does not replace a stale node left by a reused loop number.
		if [[ -e ${loop_device}p$number || -L ${loop_device}p$number ]]; then
			rm -f -- "${loop_device}p$number"
		fi
		mdev -s >/dev/null 2>&1 || true
		sleep 0.05
	done
	if [[ ! -b ${loop_device}p$number ]] ||
		! blockdev --getsize64 "${loop_device}p$number" >/dev/null 2>&1; then
		echo "error: partition device did not appear: ${loop_device}p$number" >&2
		exit 1
	fi
done

mkfs.vfat -F 32 -n VOLATOOESP "${loop_device}p2" >/dev/null
mkfs.ext4 -q -F -L VOLATOO-SYSTEM "${loop_device}p3"
dd if=/input/state of="${loop_device}p4" bs=4M conv=fsync status=none
e2fsck -fy "${loop_device}p4" >/dev/null
resize2fs "${loop_device}p4" >/dev/null
e2label "${loop_device}p4" VOLATOO-STATE

install -d "$boot_mount" "$system_mount"
mount "${loop_device}p2" "$boot_mount"
mount "${loop_device}p3" "$system_mount"
install -d "$boot_mount/boot" "$system_mount/volatoo"
install -m 0644 /input/kernel "$boot_mount/boot/vmlinuz"
install -m 0644 /input/initramfs "$boot_mount/boot/initramfs.cpio.gz"
install -m 0644 /input/rootfs "$system_mount/volatoo/root.squashfs"
cat >"$system_mount/volatoo/release.env" <<EOF
schema=org.volatoo.release-media/v1
channel=v0.1-dev
init_system=$init_system
rootfs_sha256=$rootfs_sha256
EOF

grub-install \
	--target=i386-pc \
	--boot-directory="$boot_mount/boot" \
	--modules="part_gpt ext2 fat normal linux echo serial" \
	"$loop_device" >/dev/null
grub-install \
	--target=x86_64-efi \
	--efi-directory="$boot_mount" \
	--boot-directory="$boot_mount/boot" \
	--removable \
	--no-nvram >/dev/null
cat >"$boot_mount/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial

menuentry "Volatoo v0.1-dev ($init_system)" {
	linux /boot/vmlinuz console=tty0 console=ttyS0,115200 volatoo.image=LABEL=VOLATOO-SYSTEM volatoo.image-file=/volatoo/root.squashfs volatoo.image-sha256=$rootfs_sha256 volatoo.root=store-overlay volatoo.state=LABEL=VOLATOO-STATE volatoo.state-required=yes volatoo.generation=none
	initrd /boot/initramfs.cpio.gz
}
EOF

sync
umount "$system_mount"
umount "$boot_mount"
losetup -d "$loop_device"
loop_device=
chown "$host_uid:$host_gid" "$staging"
disk_sha256=$(sha256sum "$staging" | awk '{print $1}')
disk_size=$(stat -c %s "$staging")
cat >"$staging_manifest" <<EOF
schema=org.volatoo.release-media/v1
channel=v0.1-dev
init_system=$init_system
disk_file=$output_name
disk_size=$disk_size
disk_sha256=$disk_sha256
rootfs_sha256=$rootfs_sha256
EOF
chown "$host_uid:$host_gid" "$staging_manifest"
mv "$staging" "/output/$output_name"
mv "$staging_manifest" "/output/$output_name.manifest"
trap - EXIT
echo "built /output/$output_name"
