#!/bin/sh

set -eu

test "$#" -eq 3

state=$1
generation=$2
workspace=$3
system=$state/volatoo/system
hex=${generation#sha256:}

case $generation in
	sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
	*) echo "error: invalid generation digest" >&2; exit 1 ;;
esac
test "${#hex}" -eq 64
case $hex in
	*[!0-9a-f]*) echo "error: invalid generation digest" >&2; exit 1 ;;
esac
test -d "$system"
test -d "$workspace"
test ! -e "$workspace/root"
test ! -e "$workspace/verify"
test ! -e "$workspace/base.squashfs"

plan_pointer=$system/plans/$hex
test -f "$plan_pointer"
plan_digest=$(cat "$plan_pointer")
case $plan_digest in
	sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
	*) echo "error: invalid boot plan digest" >&2; exit 1 ;;
esac
case ${plan_digest#sha256:} in
	*[!0-9a-f]*) echo "error: invalid boot plan digest" >&2; exit 1 ;;
esac
plan=$system/objects/sha256/${plan_digest#sha256:}
test -f "$plan"

tree_snapshot()
{
	root=$1
	(
		cd "$root"
		find . -exec \
			stat -c '%n|%F|%a|%u|%g|%s|%h|%Y|%t:%T|%N' {} \; |
			LC_ALL=C sort
		find . -type f -exec sha256sum {} \; |
			LC_ALL=C sort
		getfacl -R -n -p . 2>/dev/null
		getfattr -R -d -m- . 2>/dev/null
	)
}

tree_digest()
{
	tree_snapshot "$1" |
		sha256sum |
		cut -d ' ' -f 1
}

line_number=0
layer_digest=
layer_open=no
while IFS= read -r line; do
	line_number=$((line_number + 1))
	case $line_number:$line in
		1:VOLATOO_GENERATION_V1) continue ;;
	esac
	case $line in
		"generation $generation") ;;
		target\ * | context\ *) ;;
		base\ *)
			# The verified boot-plan format uses fixed space-delimited tokens.
			# shellcheck disable=SC2086
			set -- $line
			test "$#" -eq 3
			base_digest=$2
			base=$system/objects/sha256/${base_digest#sha256:}
			test -f "$base"
			unsquashfs -no-progress -d "$workspace/root" "$base" >/dev/null
			;;
		layer\ *)
			test "$layer_open" = no
			# The verified boot-plan format uses fixed space-delimited tokens.
			# shellcheck disable=SC2086
			set -- $line
			test "$#" -eq 5
			layer_digest=$2
			layer_open=yes
			;;
		remove\ *)
			test "$layer_open" = yes
			path=${line#remove }
			case $path in
				/*) ;;
				*) echo "error: non-absolute tombstone" >&2; exit 1 ;;
			esac
			case "$path" in
				*//* | */../* | */./*)
					echo "error: unsafe tombstone" >&2
					exit 1
					;;
			esac
			rm -rf -- "$workspace/root/${path#/}"
			;;
		endlayer)
			test "$layer_open" = yes
			layer=$system/objects/sha256/${layer_digest#sha256:}
			test -f "$layer"
			unsquashfs \
				-no-progress \
				-f \
				-d "$workspace/root" \
				"$layer" >/dev/null
			layer_open=no
			layer_digest=
			;;
		end)
			test "$layer_open" = no
			break
			;;
		*)
			echo "error: malformed boot plan line $line_number" >&2
			exit 1
			;;
	esac
done <"$plan"

test -d "$workspace/root"
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
printf '%s\n' "$after" >"$workspace/verified-tree-digest"
