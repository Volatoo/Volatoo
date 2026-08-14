#!/bin/sh

set -eu

test "$#" -eq 5 || test "$#" -eq 6 || test "$#" -eq 7

state=$1
generation=$2
expected_plan_digest=$3
workspace=$4
target=$5
reuse_realization=${6:-none}
parent_generation=${7:-none}
system=$state/volatoo/system
generation_hex=${generation#sha256:}
plan_hex=${expected_plan_digest#sha256:}
verified_objects=$workspace/verified-objects
plan=$verified_objects/$plan_hex

test -d "$workspace"
test ! -e "$workspace/root"
test ! -e "$workspace/realization.plan"
test ! -e "$workspace/publish"
mkdir "$workspace/publish"

materialize-volatoo-generation \
	"$state" \
	"$generation" \
	"$expected_plan_digest" \
	"$workspace/root" \
	"$target" \
	"$verified_objects"

test -f "$plan"
actual_plan_digest=$(
	sha256sum "$plan" |
		cut -d ' ' -f 1
)
test "$actual_plan_digest" = "$plan_hex"

records=$workspace/source-images
tombstone_prefix=$workspace/tombstones
awk -v records="$records" -v tombstones="$tombstone_prefix" '
	BEGIN {
		layer = 0
		open = 0
	}
	$1 == "base" {
		if (NF != 3 || layer != 0 || open != 0) exit 1
		print "0 base " $2 " " $3 > records
		next
	}
	$1 == "layer" {
		if (NF != 5 || open != 0) exit 1
		layer++
		open = 1
		print layer " layer " $2 " " $3 >> records
		next
	}
	$1 == "remove" {
		if (open != 1) exit 1
		print substr($0, 8) >> (tombstones "." layer)
		next
	}
	$1 == "endlayer" {
		if (NF != 1 || open != 1) exit 1
		open = 0
		next
	}
	END {
		if (open != 0 || layer > 64) exit 1
	}
' "$plan"
test -s "$records"

valid_sha256_digest()
{
	digest=$1
	case $digest in
		sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
		*) return 1 ;;
	esac
	test "${#digest}" -eq 71 || return 1
	case ${digest#sha256:} in
		*[!0-9a-f]*) return 1 ;;
	esac
}

case $parent_generation in
	none) ;;
	sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
		test "${#parent_generation}" -eq 71
		case ${parent_generation#sha256:} in
			*[!0-9a-f]*) exit 1 ;;
		esac
		;;
	*) echo "error: invalid parent generation digest" >&2; exit 1 ;;
esac
if [ "$reuse_realization" != none ]; then
	test "$parent_generation" != none
fi

reuse_records=$workspace/reuse-image-records
reuse_receipt_digest_file=$workspace/reuse-receipt-digest
: >"$reuse_records"
: >"$reuse_receipt_digest_file"
if [ "$reuse_realization" != none ]; then
	case $reuse_realization in
		sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
		*) echo "error: invalid reusable realization digest" >&2; exit 1 ;;
	esac
	reuse_hex=${reuse_realization#sha256:}
	test "${#reuse_hex}" -eq 64
	case $reuse_hex in
		*[!0-9a-f]*) echo "error: invalid reusable realization digest" >&2; exit 1 ;;
	esac
	reuse_plan=$system/objects/sha256/$reuse_hex
	test -f "$reuse_plan"
	test ! -L "$reuse_plan"
	test "$(stat -c %s "$reuse_plan")" -le 1048576
	actual_reuse_digest=$(
		sha256sum "$reuse_plan" |
			cut -d ' ' -f 1
	)
	test "$actual_reuse_digest" = "$reuse_hex"
	awk -v records="$reuse_records" -v receipt_file="$reuse_receipt_digest_file" '
		NR == 1 {
			if ($0 != "VOLATOO_REALIZATION_V3") exit 1
			next
		}
		NR == 2 { if ($1 != "generation" || NF != 2) exit 1; next }
		NR == 3 { if ($1 != "boot-plan" || NF != 2) exit 1; next }
		NR == 4 { if ($1 != "target" || NF != 2) exit 1; next }
		NR == 5 { if ($1 != "context" || NF != 2) exit 1; next }
		NR == 6 { if ($1 != "tree" || NF != 2) exit 1; next }
		header == 0 && $1 == "tree-receipt" {
			if (NF != 2 || receipt != 0) exit 1
			receipt = 1
			print $2 > receipt_file
			next
		}
		header == 0 {
			if ($0 != "fhs org.volatoo.gentoo-fhs/v1") exit 1
			header = 1
			next
		}
		header == 1 {
			if ($0 != "composition overlayfs-lowerdir whiteout-char-0-0") exit 1
			header = 2
			stage = 1
			next
		}
		stage == 1 && $1 == "image" {
			if (NF != 11 || $2 != image) exit 1
			if ((image == 0 && $3 != "base") ||
			    (image > 0 && $3 != "layer")) exit 1
			print > records
			image++
			next
		}
		stage == 1 {
			if ($0 != "verity-format 1 sha256 4096 4096 no-superblock" ||
			    image < 1) exit 1
			stage = 2
			next
		}
		stage == 2 {
			if ($0 != "builder squashfs-tools 4.7.5 zstd 19 1048576 reproducible") exit 1
			stage = 3
			next
		}
		stage == 3 {
			if ($0 != "end") exit 1
			stage = 4
			next
		}
		{ exit 1 }
		END { if (stage != 4) exit 1 }
	' "$reuse_plan"
fi

parent_validation_index=
parent_tree_state_digest=none
if [ -s "$reuse_receipt_digest_file" ]; then
	reuse_receipt_digest=$(cat "$reuse_receipt_digest_file")
	valid_sha256_digest "$reuse_receipt_digest" || {
		echo "error: reusable realization receipt digest is invalid" >&2
		exit 1
	}
	reuse_receipt=$system/objects/sha256/${reuse_receipt_digest#sha256:}
	test -f "$reuse_receipt"
	test ! -L "$reuse_receipt"
	actual_reuse_receipt_digest=sha256:$(
		sha256sum "$reuse_receipt" |
			cut -d ' ' -f 1
	)
	test "$actual_reuse_receipt_digest" = "$reuse_receipt_digest"
	reuse_receipt_header=$(sed -n '1p' "$reuse_receipt")
	case $reuse_receipt_header in
		VOLATOO_PARENT_TREE_RECEIPT_V1)
			# V1 authenticates the full validation result but has no
			# mergeable path and ELF index.
			;;
		VOLATOO_PARENT_TREE_RECEIPT_V2 | VOLATOO_PARENT_TREE_RECEIPT_V3)
			reuse_plan_boot=$(awk '$1 == "boot-plan" { print $2; exit }' "$reuse_plan")
			reuse_plan_target=$(awk '$1 == "target" { print $2; exit }' "$reuse_plan")
			reuse_plan_context=$(awk '$1 == "context" { print $2; exit }' "$reuse_plan")
			reuse_plan_tree=$(awk '$1 == "tree" { print $2; exit }' "$reuse_plan")
			parent_index_record=$(
				awk \
					-v header="$reuse_receipt_header" \
					-v generation="$parent_generation" \
					-v plan="$reuse_plan_boot" \
					-v target="$reuse_plan_target" \
					-v context="$reuse_plan_context" \
					-v tree="$reuse_plan_tree" '
					NR == 1 { if ($0 != header) exit 1; next }
					NR == 2 { if ($0 != "generation " generation) exit 1; next }
					NR == 3 { if ($0 != "boot-plan " plan) exit 1; next }
					NR == 4 { if ($1 != "parent-generation" || NF != 2) exit 1; next }
					NR == 5 { if ($1 != "parent-realization" || NF != 2) exit 1; next }
					NR == 6 { if ($0 != "target " target) exit 1; next }
					NR == 7 { if ($0 != "context " context) exit 1; next }
					NR == 8 { if ($0 != "tree " tree) exit 1; next }
					NR == 9 { if ($0 != "fhs org.volatoo.gentoo-fhs/v1") exit 1; next }
					NR == 10 {
						if ($1 != "validation-index" || NF != 3) exit 1
						print $2 " " $3
						next
					}
					header == "VOLATOO_PARENT_TREE_RECEIPT_V3" && NR == 11 {
						if ($1 != "tree-state" || NF != 3) exit 1
						print $2 " " $3 > state_record
						next
					}
					(header == "VOLATOO_PARENT_TREE_RECEIPT_V2" && NR == 11) ||
					(header == "VOLATOO_PARENT_TREE_RECEIPT_V3" && NR == 12) {
						if ($0 != "validation indexed-fhs-elf-v1") exit 1
						next
					}
					(header == "VOLATOO_PARENT_TREE_RECEIPT_V2" && NR == 12) ||
					(header == "VOLATOO_PARENT_TREE_RECEIPT_V3" && NR == 13) {
						if ($0 != "end") exit 1
						ended = 1
						next
					}
					{ exit 1 }
					END { if (ended != 1) exit 1 }
				' state_record="$workspace/parent-tree-state-record" \
					"$reuse_receipt"
			)
			# The authenticated receipt uses fixed, space-separated fields.
			# shellcheck disable=SC2086
			set -- $parent_index_record
			test "$#" -eq 2
			parent_index_digest=$1
			parent_index_size=$2
			valid_sha256_digest "$parent_index_digest"
			case $parent_index_size in
				"" | *[!0-9]*) exit 1 ;;
			esac
			test "$parent_index_size" -gt 0
			parent_validation_index=$system/objects/sha256/${parent_index_digest#sha256:}
			test -f "$parent_validation_index"
			test ! -L "$parent_validation_index"
			test "$(stat -c %s "$parent_validation_index")" -eq "$parent_index_size"
			actual_parent_index_digest=sha256:$(
				sha256sum "$parent_validation_index" |
					cut -d ' ' -f 1
			)
			test "$actual_parent_index_digest" = "$parent_index_digest"
			if [ "$reuse_receipt_header" = VOLATOO_PARENT_TREE_RECEIPT_V3 ]; then
				# The authenticated receipt uses fixed, space-separated fields.
				# shellcheck disable=SC2046,SC2086
				set -- $(cat "$workspace/parent-tree-state-record")
				test "$#" -eq 2
				parent_tree_state_digest=$1
				parent_tree_state_size=$2
				valid_sha256_digest "$parent_tree_state_digest"
				case $parent_tree_state_size in
					"" | *[!0-9]*) exit 1 ;;
				esac
				test "$parent_tree_state_size" -gt 0
				parent_tree_state=$system/objects/sha256/${parent_tree_state_digest#sha256:}
				test -f "$parent_tree_state"
				test ! -L "$parent_tree_state"
				test "$(stat -c %s "$parent_tree_state")" -eq "$parent_tree_state_size"
				actual_parent_tree_state_digest=sha256:$(
					sha256sum "$parent_tree_state" |
						cut -d ' ' -f 1
				)
				test "$actual_parent_tree_state_digest" = "$parent_tree_state_digest"
			fi
			;;
		*)
			echo "error: reusable realization receipt is unsupported" >&2
			exit 1
			;;
	esac
fi

validation_audit=${VOLATOO_VALIDATION_AUDIT:-0}
case $validation_audit in
	0 | 1) ;;
	*) echo "error: VOLATOO_VALIDATION_AUDIT must be 0 or 1" >&2; exit 1 ;;
esac
validation_index=$workspace/validation.index
validation_method=full
if [ -n "$parent_validation_index" ]; then
	parent_image_count=$(wc -l <"$reuse_records" | tr -d ' ')
	current_image_count=$(wc -l <"$records" | tr -d ' ')
	test "$current_image_count" -eq $((parent_image_count + 1)) || {
		echo "error: indexed validation requires one direct-parent layer delta" >&2
		exit 1
	}
	delta_sequence=$parent_image_count
	delta_source_digest=$(
		awk -v sequence="$delta_sequence" '
			$1 == sequence && $2 == "layer" { print $3; found++ }
			END { if (found != 1) exit 1 }
		' "$records"
	)
	delta_source=$verified_objects/${delta_source_digest#sha256:}
	test -f "$delta_source"
	test ! -L "$delta_source"
	delta_root=$workspace/validation-delta
	test ! -e "$delta_root"
	unsquashfs -no-progress -d "$delta_root" "$delta_source" >/dev/null
	affected_paths=$workspace/affected-paths
	find "$delta_root" -mindepth 1 -printf '/%P\n' |
		LC_ALL=C sort -u >"$affected_paths"
	delta_tombstones=$workspace/delta-tombstones
	if [ -s "$tombstone_prefix.$delta_sequence" ]; then
		LC_ALL=C sort -u "$tombstone_prefix.$delta_sequence" \
			>"$delta_tombstones"
	else
		: >"$delta_tombstones"
	fi
	delta_validation_index=$workspace/delta-validation.index
	index-volatoo-fhs-tree \
		"$delta_root" "$target" "$delta_validation_index"
	merge-volatoo-fhs-index \
		"$parent_validation_index" \
		"$delta_validation_index" \
		"$affected_paths" \
		"$delta_tombstones" \
		"$validation_index"
	fhs_contract=$(validate-volatoo-fhs-index "$validation_index" "$target")
	validation_method=indexed-delta
	if [ "$validation_audit" -eq 1 ]; then
		full_validation_index=$workspace/full-validation.index
		full_contract=$(
			validate-volatoo-fhs \
				"$workspace/root" "$target" "$full_validation_index"
		)
		test "$full_contract" = "$fhs_contract"
		if ! cmp "$validation_index" "$full_validation_index"; then
			echo "error: parent FHS/ELF index merge differs from full validation" >&2
			exit 1
		fi
		validation_method=indexed-delta-audited
	fi
else
	fhs_contract=$(
		validate-volatoo-fhs "$workspace/root" "$target" "$validation_index"
	)
fi
test "$fhs_contract" = org.volatoo.gentoo-fhs/v1
test -f "$validation_index"
test ! -L "$validation_index"
validation_index_digest=sha256:$(
	sha256sum "$validation_index" |
		cut -d ' ' -f 1
)
validation_index_size=$(stat -c %s "$validation_index")
test "$validation_index_size" -gt 0

publish_file()
{
	source=$1
	digest=$2
	destination=$workspace/publish/${digest#sha256:}
	if [ -e "$destination" ]; then
		cmp "$source" "$destination"
	else
		cp "$source" "$destination"
	fi
}

context_digest=$(awk '$1 == "context" { print $2; exit }' "$plan")
tree_state=$workspace/tree.state
{
	printf 'VOLATOO_TREE_STATE_V1\n'
	printf 'generation %s\n' "$generation"
	printf 'boot-plan %s\n' "$expected_plan_digest"
	printf 'parent-state %s\n' "$parent_tree_state_digest"
	printf 'target %s\n' "$target"
	printf 'context %s\n' "$context_digest"
	printf 'validation-index %s %s\n' \
		"$validation_index_digest" "$validation_index_size"
	printf 'composition generation-plan-and-index-v1\n'
	printf 'end\n'
} >"$tree_state"
tree_state_digest=sha256:$(
	sha256sum "$tree_state" |
		cut -d ' ' -f 1
)
tree_state_size=$(stat -c %s "$tree_state")
test "$tree_state_size" -gt 0
tree_digest=${tree_state_digest#sha256:}
publish_file "$tree_state" "$tree_state_digest"

prepare_verity()
{
	sequence=$1
	data=$2
	rootfs_digest=$3
	rootfs_size=$4
	hash=$workspace/image-$sequence.verity
	root_hash_file=$workspace/image-$sequence.root-hash
	salt=${rootfs_digest#sha256:}

	test $((rootfs_size % 4096)) -eq 0
	data_blocks=$((rootfs_size / 4096))
	test "$data_blocks" -gt 0
	: >"$hash.tmp"
	veritysetup format \
		--no-superblock \
		--hash=sha256 \
		--data-block-size=4096 \
		--hash-block-size=4096 \
		--salt="$salt" \
		--root-hash-file="$root_hash_file" \
		"$data" \
		"$hash.tmp" >/dev/null
	if [ ! -s "$hash.tmp" ]; then
		truncate -s 4096 "$hash.tmp"
	fi
	mv "$hash.tmp" "$hash"
	root_hash=$(cat "$root_hash_file")
	test "${#root_hash}" -eq 64
	case $root_hash in
		*[!0123456789abcdef]*) exit 1 ;;
	esac
	veritysetup verify \
		--no-superblock \
		--hash=sha256 \
		--data-block-size=4096 \
		--hash-block-size=4096 \
		--data-blocks="$data_blocks" \
		--salt="$salt" \
		"$data" \
		"$hash" \
		"$root_hash"
	hash_digest=sha256:$(
		sha256sum "$hash" |
			cut -d ' ' -f 1
	)
	hash_size=$(stat -c %s "$hash")
	test "$hash_size" -ge 4096
	test $((hash_size % 4096)) -eq 0
	publish_file "$hash" "$hash_digest"
	printf '%s %s %s %s %s\n' \
		"$hash_digest" \
		"$hash_size" \
		"$root_hash" \
		"$salt" \
		"$data_blocks"
}

reuse_verity()
{
	sequence=$1
	kind=$2
	source_digest=$3
	source_size=$4
	awk \
		-v sequence="$sequence" \
		-v kind="$kind" \
		-v source="$source_digest" \
		-v size="$source_size" '
			$1 == "image" &&
			$2 == sequence &&
			$3 == kind &&
			$4 == source &&
			$5 == source &&
			$6 == size {
				print
				exit
			}
		' "$reuse_records"
}

copy_directory_metadata()
{
	relative=$1
	destination=$2
	test "$relative" != .
	test -d "$workspace/root/$relative"
	parent=$(dirname "$relative")
	if [ "$parent" != . ] && [ ! -d "$destination/$parent" ]; then
		copy_directory_metadata "$parent" "$destination"
	fi
	if [ ! -d "$destination/$relative" ]; then
		metadata_archive=$workspace/directory-metadata.tar
		rm -f "$metadata_archive"
		tar \
			-C "$workspace/root" \
			--create \
			--file="$metadata_archive" \
			--no-recursion \
			--numeric-owner \
			--acls \
			--xattrs \
			-- "$relative"
		tar \
			-C "$destination" \
			--extract \
			--file="$metadata_archive" \
			--numeric-owner \
			--same-owner \
			--same-permissions \
			--acls \
			--xattrs
	fi
}

image_records=$workspace/image-records
: >"$image_records"
reused_images=0
generated_images=0
while IFS=' ' read -r sequence kind source_digest source_size; do
	source=$verified_objects/${source_digest#sha256:}
	test -f "$source"
	test ! -L "$source"
	test "$(stat -c %s "$source")" -eq "$source_size"

	data=$source
	rootfs_digest=$source_digest
	rootfs_size=$source_size
	tombstones=$tombstone_prefix.$sequence
	reused_record=
	if [ ! -s "$tombstones" ]; then
		reused_record=$(reuse_verity \
			"$sequence" \
			"$kind" \
			"$source_digest" \
			"$source_size")
	fi
	if [ -n "$reused_record" ]; then
		# The source and runtime image digests must be identical. Transformed
		# tombstone layers are deliberately excluded until their semantic
		# source-to-runtime mapping has its own authenticated cache contract.
		# shellcheck disable=SC2086
		set -- $reused_record
		test "$#" -eq 11
		hash_digest=$7
		hash_size=$8
		root_hash=$9
		salt=${10}
		data_blocks=${11}
		valid_sha256_digest "$hash_digest"
		test "${#root_hash}" -eq 64
		test "${#salt}" -eq 64
		case $root_hash:$salt in
			*[!0-9a-f:]*) exit 1 ;;
		esac
		test "$salt" = "${source_digest#sha256:}"
		case $hash_size:$data_blocks in
			*[!0-9:]*) exit 1 ;;
		esac
		test "$hash_size" -ge 4096
		test $((hash_size % 4096)) -eq 0
		test "$data_blocks" -eq $((source_size / 4096))
		hash=$system/objects/sha256/${hash_digest#sha256:}
		test -f "$hash"
		test ! -L "$hash"
		test "$(stat -c %s "$hash")" -eq "$hash_size"
		actual_hash_digest=sha256:$(
			sha256sum "$hash" |
				cut -d ' ' -f 1
		)
		test "$actual_hash_digest" = "$hash_digest"
		printf '%s\n' "$reused_record" >>"$image_records"
		reused_images=$((reused_images + 1))
		continue
	fi
	if [ "$kind" = layer ] && [ -s "$tombstones" ]; then
		layer_root=$workspace/layer-$sequence
		test ! -e "$layer_root"
		unsquashfs -no-progress -d "$layer_root" "$source" >/dev/null
		while IFS= read -r removed_path || [ -n "$removed_path" ]; do
			relative=${removed_path#/}
			test -n "$relative"
			if [ -e "$layer_root/$relative" ] || \
				[ -L "$layer_root/$relative" ]; then
				# Legacy composition removes before extracting the layer. A
				# replacement non-directory already hides the lower inode. A
				# replacement directory must be opaque so unmentioned children
				# from the removed lower directory cannot merge back in.
				if [ -d "$layer_root/$relative" ] && \
					! setfattr \
						-n trusted.overlay.opaque \
						-v y \
						"$layer_root/$relative"; then
					echo "error: could not make replacement directory opaque: $removed_path" >&2
					exit 1
				fi
				continue
			fi
			parent=$(dirname "$relative")
			if [ "$parent" != . ] && [ ! -d "$layer_root/$parent" ]; then
				copy_directory_metadata "$parent" "$layer_root"
			fi
			mknod "$layer_root/$relative" c 0 0
			chmod 000 "$layer_root/$relative"
		done <"$tombstones"
		data=$workspace/image-$sequence.squashfs
		mksquashfs "$layer_root" "$data.tmp" \
			-noappend \
			-comp zstd \
			-Xcompression-level 19 \
			-b 1M \
			-all-time 0 \
			-mkfs-time 0 \
			-reproducible \
			-processors 1 \
			-no-progress >/dev/null
		mv "$data.tmp" "$data"
		rootfs_digest=sha256:$(
			sha256sum "$data" |
				cut -d ' ' -f 1
		)
		rootfs_size=$(stat -c %s "$data")
		publish_file "$data" "$rootfs_digest"
	fi
	verity_record=$(
		prepare_verity \
			"$sequence" \
			"$data" \
			"$rootfs_digest" \
			"$rootfs_size"
	)
	printf 'image %s %s %s %s %s %s\n' \
		"$sequence" \
		"$kind" \
		"$source_digest" \
		"$rootfs_digest" \
		"$rootfs_size" \
		"$verity_record" \
		>>"$image_records"
	generated_images=$((generated_images + 1))
done <"$records"

tree_receipt=$workspace/parent-tree.receipt
publish_file "$validation_index" "$validation_index_digest"
{
	printf 'VOLATOO_PARENT_TREE_RECEIPT_V3\n'
	printf 'generation %s\n' "$generation"
	printf 'boot-plan %s\n' "$expected_plan_digest"
	printf 'parent-generation %s\n' "$parent_generation"
	printf 'parent-realization %s\n' "$reuse_realization"
	printf 'target %s\n' "$target"
	printf 'context %s\n' "$(
		awk '$1 == "context" { print $2; exit }' "$plan"
	)"
	printf 'tree sha256:%s\n' "$tree_digest"
	printf 'fhs %s\n' "$fhs_contract"
	printf 'validation-index %s %s\n' \
		"$validation_index_digest" "$validation_index_size"
	printf 'tree-state %s %s\n' \
		"$tree_state_digest" "$tree_state_size"
	printf 'validation indexed-fhs-elf-v1\n'
	printf 'end\n'
} >"$tree_receipt"
tree_receipt_digest=sha256:$(
	sha256sum "$tree_receipt" |
		cut -d ' ' -f 1
)
publish_file "$tree_receipt" "$tree_receipt_digest"

{
	printf 'VOLATOO_REALIZATION_V3\n'
	printf 'generation %s\n' "$generation"
	printf 'boot-plan %s\n' "$expected_plan_digest"
	printf 'target %s\n' "$target"
	printf 'context %s\n' "$(
		awk '$1 == "context" { print $2; exit }' "$plan"
	)"
	printf 'tree sha256:%s\n' "$tree_digest"
	printf 'tree-receipt %s\n' "$tree_receipt_digest"
	printf 'fhs %s\n' "$fhs_contract"
	printf 'composition overlayfs-lowerdir whiteout-char-0-0\n'
	cat "$image_records"
	printf 'verity-format 1 sha256 4096 4096 no-superblock\n'
	printf 'builder squashfs-tools 4.7.5 zstd 19 1048576 reproducible\n'
	printf 'end\n'
} >"$workspace/realization.plan"

printf '%s\n' "$fhs_contract" >"$workspace/fhs-contract"
printf '%s\n' "$tree_digest" >"$workspace/tree-digest"
printf '%s\n' "$generation_hex" >"$workspace/generation"
{
	printf 'reused %s\n' "$reused_images"
	printf 'generated %s\n' "$generated_images"
	printf 'validation %s\n' "$validation_method"
} >"$workspace/reuse-report"
