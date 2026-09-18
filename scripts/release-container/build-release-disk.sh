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
secure_boot=${VOLATOO_SECURE_BOOT:-no}
slot_boot=${VOLATOO_SLOTS:-no}
source_date_epoch=${SOURCE_DATE_EPOCH:-0}
[[ $output_name =~ ^[A-Za-z0-9._-]+\.img$ ]] || {
	echo "error: unsafe release output name: $output_name" >&2
	exit 1
}
[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: INIT_SYSTEM must be openrc or systemd" >&2
	exit 1
}
[[ $secure_boot == yes || $secure_boot == no ]] || {
	echo "error: VOLATOO_SECURE_BOOT must be yes or no" >&2
	exit 1
}
[[ $slot_boot == yes || $slot_boot == no ]] || {
	echo "error: VOLATOO_SLOTS must be yes or no" >&2
	exit 1
}
if [[ $slot_boot == yes && $secure_boot == yes ]]; then
	echo "error: VOLATOO_SLOTS=yes requires VOLATOO_SECURE_BOOT=no" >&2
	exit 1
fi
[[ $source_date_epoch =~ ^[0-9]+$ ]] || {
	echo "error: SOURCE_DATE_EPOCH must be a non-negative integer" >&2
	exit 1
}
if [[ $secure_boot == yes ]]; then
	for secure_boot_input in secure-boot.key secure-boot.crt; do
		[[ -f /input/$secure_boot_input && ! -L /input/$secure_boot_input ]] || {
			echo "error: secure boot input is missing or unsafe: $secure_boot_input" >&2
			exit 1
		}
	done
fi

# A deterministic timezone and collation keep `sort`, `date` and the tools'
# own local-time conversions from varying with the host environment.
export TZ=UTC
export LC_ALL=C

efi_mib=128
rootfs_bytes=$(stat -c %s /input/rootfs)
state_bytes=$(stat -c %s /input/state)
system_mib=$(( (rootfs_bytes + 1048575) / 1048576 + 64 ))
state_mib=$(( (state_bytes + 1048575) / 1048576 + 8 ))
disk_mib=$(( 4 + efi_mib + system_mib + state_mib + 16 ))
kernel_sha256=$(sha256sum /input/kernel | awk '{print $1}')
initramfs_sha256=$(sha256sum /input/initramfs | awk '{print $1}')
rootfs_sha256=$(sha256sum /input/rootfs | awk '{print $1}')
state_sha256=$(sha256sum /input/state | awk '{print $1}')
secure_boot_cert_sha256=none
if [[ $secure_boot == yes ]]; then
	secure_boot_cert_sha256=$(sha256sum /input/secure-boot.crt | awk '{print $1}')
fi

# Every untracked identifier in the output (GPT disk/partition GUIDs, FAT
# volume id, ext4 UUID and hash seed) is derived from the SHA-256 of the
# pinned inputs. Identical inputs therefore produce identical identifiers, and
# any input change rotates them. The derivation domain is documented in
# docs/design/release-media.md; do not change the label strings without
# updating that note.
seed="volatoo-release:$kernel_sha256:$initramfs_sha256:$rootfs_sha256:$state_sha256:$secure_boot_cert_sha256"

derive_hex()
{
	local label=$1 first=${2:-32}
	printf '%s' "$seed:$label" | sha256sum | awk -v n="$first" '{ print substr($1, 1, n) }'
}

# Render 32 hex chars as a RFC 4122 version-5 / variant-8 UUID (name-based
# SHA-1), which sgdisk and mke2fs both accept.
guid_from_hex()
{
	local hex=$1
	printf '%s-%s-%s-%s-%s' \
		"${hex:0:8}" "${hex:8:4}" "5${hex:13:3}" "8${hex:17:3}" "${hex:20:12}"
}

disk_guid=$(guid_from_hex "$(derive_hex volatoo-disk-guid)")
part_1_guid=$(guid_from_hex "$(derive_hex volatoo-part1-guid)")
part_2_guid=$(guid_from_hex "$(derive_hex volatoo-part2-guid)")
part_3_guid=$(guid_from_hex "$(derive_hex volatoo-part3-guid)")
part_4_guid=$(guid_from_hex "$(derive_hex volatoo-part4-guid)")
fat_volid=$(derive_hex volatoo-fat-volid 8)
system_uuid=$(guid_from_hex "$(derive_hex volatoo-system-uuid)")
system_hash_seed=$(guid_from_hex "$(derive_hex volatoo-hash-seed)")

# FAT directory entries cannot represent timestamps before 1980, so the
# closest reproducible reference epoch for the FAT tree is
# 1980-01-01T00:00:00Z. Larger SOURCE_DATE_EPOCH values are honored as given.
fat_epoch=$source_date_epoch
(( fat_epoch < 315532800 )) && fat_epoch=315532800

staging=/output/.${output_name}.$$
staging_manifest=${staging}.manifest
loop_device=
boot_mount=/mnt/volatoo-boot
esp_staging=/staging-esp
system_staging=/staging-system
cleanup()
{
	if mountpoint -q "$boot_mount"; then umount "$boot_mount"; fi
	if [[ -n $loop_device ]]; then losetup -d "$loop_device"; fi
	rm -rf -- "$staging" "$staging_manifest" "$esp_staging" "$system_staging"
	rm -f -- /tmp/volatoo-esp.img /tmp/volatoo-system.img
}
trap cleanup EXIT

[[ ! -e /output/$output_name && ! -e /output/$output_name.manifest ]] || {
	echo "error: release output already exists: /output/$output_name" >&2
	exit 1
}
truncate -s "${disk_mib}M" "$staging"
sgdisk --clear \
	--disk-guid="$disk_guid" \
	--new=1:2048:+2M --typecode=1:ef02 --change-name=1:VOLATOO-BIOS --partition-guid=1:"$part_1_guid" \
	--new=2:0:+${efi_mib}M --typecode=2:ef00 --change-name=2:VOLATOO-BOOT --partition-guid=2:"$part_2_guid" \
	--new=3:0:+${system_mib}M --typecode=3:8300 --change-name=3:VOLATOO-SYSTEM --partition-guid=3:"$part_3_guid" \
	--new=4:0:+${state_mib}M --typecode=4:8300 --change-name=4:VOLATOO-STATE --partition-guid=4:"$part_4_guid" \
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

# p4 (state): the pinned state image is copied and grown into the partition.
# e2fsck, resize2fs and e2label all rewrite superblock fields (last check,
# last write) with the wall clock, so each runs under faketime pinned to the
# reference epoch. The input state image already carries a deterministic
# VOLATOO-STATE UUID and hash seed, derived from its content by
# scripts/build-state-image.sh, so the assembler must grow it without
# overriding that identity.
dd if=/input/state of="${loop_device}p4" bs=4M conv=fsync status=none
faketime "@$source_date_epoch" e2fsck -fy "${loop_device}p4" >/dev/null
faketime "@$source_date_epoch" resize2fs "${loop_device}p4" >/dev/null
faketime "@$source_date_epoch" e2label "${loop_device}p4" VOLATOO-STATE

# Populate a FAT image offline from a staging tree whose mtimes are pinned.
# mkfs.vfat stamps the volume-label entry from the clock, so it runs under
# faketime (the only command that may). Directory entries are created by
# mcopy -s -m of a single empty directory whose mtime is pinned, which carries
# the pinned mtime into both the creation and last-write fields without ever
# consulting the wall clock (faketime's localtime interception corrupts mmd,
# so mmd is avoided). Files are copied with mcopy -m, which likewise preserves
# the pinned source mtimes. Every entry is written in a globally sorted order
# so the FAT directory layout does not depend on the source readdir order.
populate_esp()
{
	local img=$1 src=$2 rel empty_dir

	faketime "@$fat_epoch" mkfs.vfat -F 32 -n VOLATOOESP -i "$fat_volid" "$img" >/dev/null

	empty_dir=$(mktemp -d)
	touch -h -d "@$fat_epoch" "$empty_dir"
	while IFS= read -r rel; do
		rel=${rel#./}
		[[ $rel == . ]] && continue
		mcopy -s -m -i "$img" "$empty_dir" "::/$rel"
	done < <(cd "$src" && find . -type d | sort)
	rmdir "$empty_dir"

	while IFS= read -r rel; do
		rel=${rel#./}
		mcopy -o -m -i "$img" "$src/$rel" "::/$rel"
	done < <(cd "$src" && find . -type f | sort)
}

# p2 (ESP) population must run through a real mount because grub-install
# resolves the boot device from the mounted filesystem. The kernel records
# wall-clock directory-entry times for every file it writes, so those bytes are
# discarded: the populated tree is lifted into a plain staging directory and
# the FAT image is rebuilt offline from the pinned tree (see populate_esp).
mkfs.vfat -F 32 -n VOLATOOESP -i "$fat_volid" "${loop_device}p2" >/dev/null
install -d "$boot_mount"
mount "${loop_device}p2" "$boot_mount"
install -d "$boot_mount/boot"
if [[ $slot_boot == no ]]; then
	install -m 0644 /input/kernel "$boot_mount/boot/vmlinuz"
	install -m 0644 /input/initramfs "$boot_mount/boot/initramfs.cpio.gz"
fi

grub-install \
	--target=i386-pc \
	--boot-directory="$boot_mount/boot" \
	--modules="part_gpt ext2 fat normal linux echo serial search" \
	"$loop_device" >/dev/null
kernel_command_line="console=tty0 console=ttyS0,115200 volatoo.image=LABEL=VOLATOO-SYSTEM volatoo.image-file=/volatoo/root.squashfs volatoo.image-sha256=$rootfs_sha256 volatoo.root=store-overlay volatoo.state=LABEL=VOLATOO-STATE volatoo.state-required=yes volatoo.generation=none"
uki_sha256=none
if [[ $secure_boot == yes ]]; then
	uki_dir=$boot_mount/EFI/BOOT
	mkdir -p "$uki_dir"
	printf 'ID=volatoo\nNAME=Volatoo\nVERSION_ID=0.1-dev\n' \
		>/tmp/volatoo-os-release
	printf '%s\n' "$kernel_command_line" >/tmp/volatoo-cmdline
	stub=/usr/lib/systemd/boot/efi/linuxx64.efi.stub
	stub_image_base=$(objdump -p "$stub" | awk '$1 == "ImageBase" { print $2 }')
	[[ $stub_image_base =~ ^[0-9A-Fa-f]+$ ]] || {
		echo "error: could not read EFI stub image base" >&2
		exit 1
	}
	printf -v osrel_vma '0x%x' "$((0x$stub_image_base + 0x20000))"
	printf -v cmdline_vma '0x%x' "$((0x$stub_image_base + 0x30000))"
	printf -v linux_vma '0x%x' "$((0x$stub_image_base + 0x2000000))"
	printf -v initrd_vma '0x%x' "$((0x$stub_image_base + 0x3000000))"
	objcopy \
		--add-section .osrel=/tmp/volatoo-os-release \
		--change-section-vma ".osrel=$osrel_vma" \
		--add-section .cmdline=/tmp/volatoo-cmdline \
		--change-section-vma ".cmdline=$cmdline_vma" \
		--add-section .linux=/input/kernel \
		--change-section-vma ".linux=$linux_vma" \
		--add-section .initrd=/input/initramfs \
		--change-section-vma ".initrd=$initrd_vma" \
		"$stub" \
		/tmp/volatoo-unsigned.efi
	faketime "@$source_date_epoch" sbsign \
		--key /input/secure-boot.key \
		--cert /input/secure-boot.crt \
		--output "$uki_dir/BOOTX64.EFI" \
		/tmp/volatoo-unsigned.efi >/dev/null
	sbverify --cert /input/secure-boot.crt \
		"$uki_dir/BOOTX64.EFI" >/dev/null
	uki_sha256=$(sha256sum "$uki_dir/BOOTX64.EFI" | awk '{print $1}')
else
	grub-install \
		--target=x86_64-efi \
		--efi-directory="$boot_mount" \
		--boot-directory="$boot_mount/boot" \
		--removable \
		--no-nvram >/dev/null
fi
if [[ $slot_boot == yes ]]; then
	cat >"$boot_mount/boot/grub/grub.cfg" <<'EOF'
set timeout=3
set default=0
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial

search --no-floppy --label VOLATOO-STATE --set=stateroot
if [ -e ($stateroot)/volatoo/slots/pending-a ]; then
	set boot_slot=a
fi
if [ -e ($stateroot)/volatoo/slots/pending-b ]; then
	set boot_slot=b
fi
if [ -z "$boot_slot" ]; then
	if [ -e ($stateroot)/volatoo/slots/active-b ]; then
		set boot_slot=b
	else
		set boot_slot=a
	fi
fi
linux ($stateroot)/volatoo/slots/$boot_slot/kernel console=tty0 console=ttyS0,115200 volatoo.root=slot volatoo.slot=$boot_slot volatoo.state=LABEL=VOLATOO-STATE volatoo.state-required=yes volatoo.generation=none
initrd ($stateroot)/volatoo/slots/$boot_slot/initramfs
boot
EOF
else
	cat >"$boot_mount/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial

menuentry "Volatoo v0.1-dev ($init_system)" {
	linux /boot/vmlinuz $kernel_command_line
	initrd /boot/initramfs.cpio.gz
}
EOF
fi

sync
mkdir -p "$esp_staging"
cp -a "$boot_mount/." "$esp_staging/"
umount "$boot_mount"
find "$esp_staging" -exec touch -h -d "@$fat_epoch" {} +
esp_bytes=$(blockdev --getsize64 "${loop_device}p2")
truncate -s "$esp_bytes" /tmp/volatoo-esp.img
populate_esp /tmp/volatoo-esp.img "$esp_staging"
dd if=/tmp/volatoo-esp.img of="${loop_device}p2" bs=4M conv=fsync status=none

# p3 (system): no kernel writes at all. Build the filesystem offline from a
# pinned staging tree so the superblock UUID, hash seed and every inode
# timestamp come from the reference epoch (SOURCE_DATE_EPOCH) and derived
# values, then dd the finished image into the partition.
mkdir -p "$system_staging/volatoo"
install -m 0644 /input/rootfs "$system_staging/volatoo/root.squashfs"
cat >"$system_staging/volatoo/release.env" <<EOF
schema=org.volatoo.release-media/v2
channel=v0.1-dev
init_system=$init_system
kernel_sha256=$kernel_sha256
initramfs_sha256=$initramfs_sha256
rootfs_sha256=$rootfs_sha256
state_sha256=$state_sha256
secure_boot=$secure_boot
secure_boot_cert_sha256=$secure_boot_cert_sha256
uki_sha256=$uki_sha256
EOF
find "$system_staging" -exec touch -h -d "@$source_date_epoch" {} +
system_bytes=$(blockdev --getsize64 "${loop_device}p3")
truncate -s "$system_bytes" /tmp/volatoo-system.img
SOURCE_DATE_EPOCH="$source_date_epoch" mkfs.ext4 -q -F \
	-L VOLATOO-SYSTEM \
	-U "$system_uuid" \
	-E hash_seed="$system_hash_seed" \
	-d "$system_staging" \
	/tmp/volatoo-system.img
dd if=/tmp/volatoo-system.img of="${loop_device}p3" bs=4M conv=fsync status=none

sync
losetup -d "$loop_device"
loop_device=
chown "$host_uid:$host_gid" "$staging"
disk_sha256=$(sha256sum "$staging" | awk '{print $1}')
disk_size=$(stat -c %s "$staging")
cat >"$staging_manifest" <<EOF
schema=org.volatoo.release-media/v2
channel=v0.1-dev
init_system=$init_system
disk_file=$output_name
disk_size=$disk_size
disk_sha256=$disk_sha256
kernel_sha256=$kernel_sha256
initramfs_sha256=$initramfs_sha256
rootfs_sha256=$rootfs_sha256
state_sha256=$state_sha256
secure_boot=$secure_boot
secure_boot_cert_sha256=$secure_boot_cert_sha256
uki_sha256=$uki_sha256
EOF
chown "$host_uid:$host_gid" "$staging_manifest"
mv "$staging" "/output/$output_name"
mv "$staging_manifest" "/output/$output_name.manifest"
trap - EXIT
echo "built /output/$output_name"
