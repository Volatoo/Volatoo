#!/bin/sh

set -eu

test "$#" -eq 5

state=$1
generation=$2
expected_plan_digest=$3
workspace=$4
target=$5
test -d "$workspace"
test ! -e "$workspace/root"
test ! -e "$workspace/verify"
test ! -e "$workspace/base.squashfs"
test ! -e "$workspace/base.verity"

materialize-volatoo-generation \
	"$state" \
	"$generation" \
	"$expected_plan_digest" \
	"$workspace/root" \
	"$target"

fhs_contract=$(
	validate-volatoo-fhs "$workspace/root" "$target"
)
printf '%s\n' "$fhs_contract" >"$workspace/fhs-contract"

tree_snapshot()
{
	root=$1
	(
		cd "$root"
		# The reproducible builder deliberately normalizes every mtime to zero,
		# so timestamps are not part of filesystem equivalence.
		# Do not compare st_size: directory sizes are filesystem allocation
		# details, not tree contents. Regular-file contents are hashed below,
		# and %N records symlink targets.
		find . -exec \
			stat -c '%n|%F|%a|%u|%g|%h|%t:%T|%N' {} + |
			LC_ALL=C sort
		find . -type f -exec sha256sum {} + |
			LC_ALL=C sort
		# Recursive ACL/xattr walkers use filesystem traversal order, which is
		# not stable across the materialized and extracted trees.
		getfacl -R -n -p . 2>/dev/null |
			LC_ALL=C sort
		getfattr -R -d -m- . 2>/dev/null |
			LC_ALL=C sort
	)
}

tree_digest()
{
	tree_snapshot "$1" |
		sha256sum |
		cut -d ' ' -f 1
}

before=$(tree_digest "$workspace/root")
printf '%s\n' "$before" >"$workspace/tree-digest"

mksquashfs "$workspace/root" "$workspace/.base.squashfs.tmp" \
	-noappend \
	-comp zstd \
	-Xcompression-level 19 \
	-b 1M \
	-all-time 0 \
	-mkfs-time 0 \
	-reproducible \
	-processors 1 \
	-no-progress >/dev/null
mv "$workspace/.base.squashfs.tmp" "$workspace/base.squashfs"

rootfs_digest=$(
	sha256sum "$workspace/base.squashfs" |
		cut -d ' ' -f 1
)
rootfs_size=$(stat -c %s "$workspace/base.squashfs")
if [ $((rootfs_size % 4096)) -ne 0 ]; then
	echo "error: SquashFS size is not aligned for dm-verity" >&2
	exit 1
fi
verity_data_blocks=$((rootfs_size / 4096))
verity_salt=$rootfs_digest
: >"$workspace/.base.verity.tmp"
veritysetup format \
	--no-superblock \
	--hash=sha256 \
	--data-block-size=4096 \
	--hash-block-size=4096 \
	--salt="$verity_salt" \
	--root-hash-file="$workspace/verity-root-hash" \
	"$workspace/base.squashfs" \
	"$workspace/.base.verity.tmp" >/dev/null
# Very small fixtures can have a root hash without any lower hash-tree block.
# Keep one unused block so the object can still be attached to a loop device.
if [ ! -s "$workspace/.base.verity.tmp" ]; then
	truncate -s 4096 "$workspace/.base.verity.tmp"
fi
mv "$workspace/.base.verity.tmp" "$workspace/base.verity"
verity_root_hash=$(cat "$workspace/verity-root-hash")
case $verity_root_hash in
	????????????????????????????????????????????????????????????????) ;;
	*)
		echo "error: veritysetup returned an invalid root hash" >&2
		exit 1
		;;
esac
case $verity_root_hash in
	*[!0123456789abcdef]*)
		echo "error: veritysetup returned a non-hex root hash" >&2
		exit 1
		;;
esac
printf '%s\n' "$verity_salt" >"$workspace/verity-salt"
printf '%s\n' "$verity_data_blocks" >"$workspace/verity-data-blocks"
veritysetup verify \
	--no-superblock \
	--hash=sha256 \
	--data-block-size=4096 \
	--hash-block-size=4096 \
	--data-blocks="$verity_data_blocks" \
	--salt="$verity_salt" \
	"$workspace/base.squashfs" \
	"$workspace/base.verity" \
	"$verity_root_hash"

unsquashfs \
	-no-progress \
	-d "$workspace/verify" \
	"$workspace/base.squashfs" >/dev/null
after=$(tree_digest "$workspace/verify")
if [ "$before" != "$after" ]; then
	echo "error: compacted filesystem tree differs ($before != $after)" >&2
	for root in root verify; do
		tree_snapshot "$workspace/$root" >"$workspace/$root.snapshot"
	done
	diff -u "$workspace/root.snapshot" "$workspace/verify.snapshot" >&2 || true
	exit 1
fi
# tree_digest covers every regular-file byte, symlink target, inode type,
# permission, owner, link count, device number, ACL and xattr. Once the
# extracted tree is equivalent, the deterministic FHS/ELF gate would receive
# identical input; running its full filesystem scan again adds no evidence.
printf '%s\n' "$after" >"$workspace/verified-tree-digest"
