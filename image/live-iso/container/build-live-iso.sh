#!/usr/bin/env bash

set -euo pipefail

for name in kernel initramfs rootfs release.pub; do
	path=/input/$name
	[[ -f $path && ! -L $path ]] || {
		echo "error: live ISO input is missing or unsafe: $path" >&2
		exit 1
	}
done
[[ -d /input/publication && ! -L /input/publication ]] || {
	echo "error: publication is missing or unsafe" >&2
	exit 1
}
if find /input/publication -type l -print -quit | grep -q . ||
	find /input/publication ! -type f ! -type d -print -quit | grep -q .; then
	echo "error: publication contains an unsupported file type" >&2
	exit 1
fi

output_name=${OUTPUT_NAME:?missing OUTPUT_NAME}
init_system=${INIT_SYSTEM:?missing INIT_SYSTEM}
host_uid=${HOST_UID:?missing HOST_UID}
host_gid=${HOST_GID:?missing HOST_GID}
[[ $output_name =~ ^[A-Za-z0-9._-]+\.iso$ ]] || {
	echo "error: unsafe ISO output name" >&2
	exit 1
}
[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: invalid live ISO init system" >&2
	exit 1
}
[[ ! -e /output/$output_name && ! -e /output/$output_name.manifest ]] || {
	echo "error: live ISO output already exists" >&2
	exit 1
}

publication=/input/publication
channel=$publication/releases/amd64/channels/v0.1-dev
signify -V -p /input/release.pub -m "$channel/index.json" -x "$channel/index.json.sig"
signify -V -p /input/release.pub -m "$channel/live-media-inputs.json" \
	-x "$channel/live-media-inputs.json.sig"
(cd "$publication" && sha256sum --check SHA256SUMS)
verify-volatoo-live-inputs
# shellcheck disable=SC1091
source /run/live-inputs.env

rootfs_digest=$(sha256sum /input/rootfs | awk '{print $1}')
unsquashfs -cat /input/rootfs usr/sbin/volatoo-installer >/run/volatoo-installer
chmod 0755 /run/volatoo-installer
[[ $(sha256sum /run/volatoo-installer | awk '{print $1}') == "$INSTALLER_DIGEST" && \
	$(/run/volatoo-installer version) == "$INSTALLER_VERSION" ]] || {
	echo "error: live root installer differs from signed live-media inputs" >&2
	exit 1
}
unsquashfs -cat /input/rootfs \
	"usr/share/volatoo/keyring/release/$KEY_DIGEST.pub" >/run/release.pub
[[ $(sha256sum /run/release.pub | awk '{print $1}') == "$KEY_DIGEST" ]] || {
	echo "error: live root keyring differs from signed live-media inputs" >&2
	exit 1
}
unsquashfs -ll /input/rootfs >/run/rootfs.list
for command in blockdev e2fsck findmnt lsblk resize2fs sgdisk zstd; do
	grep -Eq " squashfs-root/usr/(bin|sbin)/$command$" /run/rootfs.list || {
		echo "error: live root is missing installer command: $command" >&2
		exit 1
	}
done

tree=$(mktemp -d /run/volatoo-live-iso.XXXXXX)
staging=/output/.${output_name}.$$
staging_manifest=$staging.manifest
cleanup()
{
	rm -rf -- "$tree"
	rm -f -- "$staging" "$staging_manifest"
}
trap cleanup EXIT
install -d "$tree/boot/grub" "$tree/volatoo"
install -m 0644 /input/kernel "$tree/boot/vmlinuz"
install -m 0644 /input/initramfs "$tree/boot/initramfs.cpio.gz"
install -m 0644 /input/rootfs "$tree/volatoo/root.squashfs"
cp -a "$publication" "$tree/volatoo/distfiles"
cat >"$tree/boot/grub/grub.cfg" <<EOF
set timeout=3
set default=0
serial --unit=0 --speed=115200
terminal_input console serial
terminal_output console serial

menuentry "Volatoo installer ($init_system)" {
	linux /boot/vmlinuz console=tty0 console=ttyS0,115200 volatoo.image=LABEL=VOLATOO_LIVE volatoo.image-file=/volatoo/root.squashfs volatoo.image-sha256=$rootfs_digest volatoo.root=store-overlay volatoo.state=LABEL=VOLATOO-STATE volatoo.state-required=no volatoo.generation=none
	initrd /boot/initramfs.cpio.gz
}
EOF
find "$tree" -exec touch -h -d @946684800 {} +

gpt_guid=${rootfs_digest:0:8}-${rootfs_digest:8:4}-${rootfs_digest:12:4}-${rootfs_digest:16:4}-${rootfs_digest:20:12}
SOURCE_DATE_EPOCH=946684800 grub-mkrescue \
	--output="$staging" \
	--modules="part_gpt part_msdos iso9660 normal linux echo serial" \
	"$tree" -- \
	-volid VOLATOO_LIVE \
	-alter_date_r b 2000010100000000 / -- \
	-volume_date c 2000010100000000 \
	-volume_date m 2000010100000000 \
	-volume_date x 2000010100000000 \
	-volume_date f 2000010100000000 \
	-volume_date uuid 2000010100000000 \
	-boot_image any "gpt_disk_guid=$gpt_guid"
normalize-volatoo-live-iso "$staging"
iso_digest=$(sha256sum "$staging" | awk '{print $1}')
iso_size=$(stat -c %s "$staging")
cat >"$staging_manifest" <<EOF
schema=org.volatoo.live-media/v1
channel=v0.1-dev
init_system=$init_system
iso_file=$output_name
iso_size=$iso_size
iso_sha256=$iso_digest
rootfs_sha256=$rootfs_digest
release_index_sha256=$INDEX_DIGEST
installer_sha256=$INSTALLER_DIGEST
release_key_sha256=$KEY_DIGEST
EOF
chown "$host_uid:$host_gid" "$staging" "$staging_manifest"
mv "$staging" "/output/$output_name"
mv "$staging_manifest" "/output/$output_name.manifest"
trap - EXIT
rm -rf -- "$tree"
echo "built authenticated live ISO /output/$output_name"
