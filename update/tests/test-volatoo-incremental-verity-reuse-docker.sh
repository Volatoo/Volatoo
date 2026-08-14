#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
platform=linux/amd64
image=${VOLATOO_LAYER_COMPRESSOR_IMAGE:-volatoo-layer-compressor:1}

command -v docker >/dev/null 2>&1 || {
	echo "error: docker is not installed" >&2
	exit 1
}
docker info >/dev/null 2>&1 || {
	echo "error: the Docker daemon is not available" >&2
	exit 1
}

docker build \
	--platform "$platform" \
	--tag "$image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root"

docker run --rm \
	--network none \
	--platform "$platform" \
	--tmpfs /state:exec,size=16m \
	--tmpfs /stubs:exec,size=1m \
	--tmpfs /workspace:exec,size=32m \
	--entrypoint /bin/sh \
	"$image" \
	-c '
		set -eu
		stage=setup
		cleanup()
		{
			status=$?
			if [ "$status" -ne 0 ]; then
				echo "error: incremental reuse test failed during $stage" >&2
			fi
			exit "$status"
		}
		trap cleanup EXIT

		system=/state/volatoo/system
		objects=$system/objects/sha256
		mkdir -p "$objects" "$system/manifests" "$system/plans" /stubs

		printf "{\"fixture\":\"incremental-reuse\"}\n" >/workspace/manifest.json
		generation_hex=$(sha256sum /workspace/manifest.json | cut -d " " -f 1)
		generation=sha256:$generation_hex
		cp /workspace/manifest.json "$system/manifests/$generation_hex.json"

		printf context >/workspace/context
		context_hex=$(sha256sum /workspace/context | cut -d " " -f 1)
		context=sha256:$context_hex
		cp /workspace/context "$objects/$context_hex"
		parent=sha256:3333333333333333333333333333333333333333333333333333333333333333
		tree=sha256:4444444444444444444444444444444444444444444444444444444444444444
		target=amd64-openrc

		mkdir -p /workspace/source-root/etc
		printf validated >/workspace/source-root/etc/cache-test
		mksquashfs /workspace/source-root /workspace/source \
			-noappend \
			-comp zstd \
			-Xcompression-level 19 \
			-b 1M \
			-all-time 0 \
			-mkfs-time 0 \
			-reproducible \
			-processors 1 \
			-no-progress >/dev/null
		test "$(stat -c %s /workspace/source)" -eq 4096
		source_hex=$(sha256sum /workspace/source | cut -d " " -f 1)
		source=sha256:$source_hex
		cp /workspace/source "$objects/$source_hex"

		{
			printf "VOLATOO_GENERATION_V1\n"
			printf "generation %s\n" "$generation"
			printf "target %s\n" "$target"
			printf "context %s\n" "$context"
			printf "base %s 4096\n" "$source"
			printf "end\n"
		} >/workspace/boot.plan
		plan_hex=$(sha256sum /workspace/boot.plan | cut -d " " -f 1)
		plan=sha256:$plan_hex
		cp /workspace/boot.plan "$objects/$plan_hex"
		printf "%s\n" "$plan" >"$system/plans/$generation_hex"

		stage=retained-cache-boundary
		if /usr/local/sbin/materialize-volatoo-generation \
			/state \
			"$generation" \
			"$plan" \
			/workspace/rejected-root \
			"$target" \
			/workspace/rejected-root/cache; then
			echo "error: materializer accepted a cache inside its output root" >&2
			exit 1
		fi
		test ! -e /workspace/rejected-root

		stage=retained-materializer-cache
		/usr/local/sbin/materialize-volatoo-generation \
			/state \
			"$generation" \
			"$plan" \
			/workspace/actual-root \
			"$target" \
			/workspace/actual-cache
		test "$(cat /workspace/actual-root/etc/cache-test)" = validated
		test -f "/workspace/actual-cache/$source_hex"
		test -f "/workspace/actual-cache/$context_hex"
		test -f "/workspace/actual-cache/$plan_hex"

		: >/workspace/cached.verity.tmp
		veritysetup format \
			--no-superblock \
			--hash=sha256 \
			--data-block-size=4096 \
			--hash-block-size=4096 \
			--salt="$source_hex" \
			--root-hash-file=/workspace/cached.root-hash \
			/workspace/source \
			/workspace/cached.verity.tmp >/dev/null
		if [ ! -s /workspace/cached.verity.tmp ]; then
			truncate -s 4096 /workspace/cached.verity.tmp
		fi
		mv /workspace/cached.verity.tmp /workspace/cached.verity
		hash_hex=$(sha256sum /workspace/cached.verity | cut -d " " -f 1)
		hash=sha256:$hash_hex
		cp /workspace/cached.verity "$objects/$hash_hex"
		root_hash=$(cat /workspace/cached.root-hash)
		veritysetup verify \
			--no-superblock \
			--hash=sha256 \
			--data-block-size=4096 \
			--hash-block-size=4096 \
			--data-blocks=1 \
			--salt="$source_hex" \
			/workspace/source \
			/workspace/cached.verity \
			"$root_hash"
		{
			printf "VOLATOO_PARENT_TREE_RECEIPT_V1\n"
			printf "generation %s\n" "$parent"
			printf "boot-plan %s\n" "$plan"
			printf "parent-generation none\n"
			printf "parent-realization none\n"
			printf "target %s\n" "$target"
			printf "context %s\n" "$context"
			printf "tree %s\n" "$tree"
			printf "fhs org.volatoo.gentoo-fhs/v1\n"
			printf "validation full-fhs-elf-v1\n"
			printf "end\n"
		} >/workspace/reuse.receipt
		receipt_hex=$(sha256sum /workspace/reuse.receipt | cut -d " " -f 1)
		receipt=sha256:$receipt_hex
		cp /workspace/reuse.receipt "$objects/$receipt_hex"
		{
			printf "VOLATOO_REALIZATION_V3\n"
			printf "generation %s\n" "$parent"
			printf "boot-plan %s\n" "$plan"
			printf "target %s\n" "$target"
			printf "context %s\n" "$context"
			printf "tree %s\n" "$tree"
			printf "tree-receipt %s\n" "$receipt"
			printf "fhs org.volatoo.gentoo-fhs/v1\n"
			printf "composition overlayfs-lowerdir whiteout-char-0-0\n"
			printf "image 0 base %s %s 4096 %s 4096 %s %s 1\n" \
				"$source" "$source" "$hash" "$root_hash" "$source_hex"
			printf "verity-format 1 sha256 4096 4096 no-superblock\n"
			printf "builder squashfs-tools 4.7.5 zstd 19 1048576 reproducible\n"
			printf "end\n"
		} >/workspace/reuse.plan
		reuse_hex=$(sha256sum /workspace/reuse.plan | cut -d " " -f 1)
		reuse=sha256:$reuse_hex
		cp /workspace/reuse.plan "$objects/$reuse_hex"

		printf "%s\n" \
			"#!/bin/sh" \
			"set -eu" \
			"mkdir \"\$6\"" \
			"cp /workspace/source \"\$6/$source_hex\"" \
			"cp /workspace/boot.plan \"\$6/$plan_hex\"" \
			"mkdir -p \"\$4/etc\"" \
			"printf validated >\"\$4/etc/cache-test\"" \
			> /stubs/materialize-volatoo-generation
		printf "%s\n" \
			"#!/bin/sh" \
			"set -eu" \
			"test \"\$#\" -eq 3" \
			"printf \"VOLATOO_FHS_ELF_INDEX_V1\\ntarget %s\\nP|/|d|755\\nend\\n\" \"\$2\" >\"\$3\"" \
			"printf \"%s\\n\" org.volatoo.gentoo-fhs/v1" \
			> /stubs/validate-volatoo-fhs
		cat > /stubs/veritysetup <<"EOF"
#!/bin/sh
set -eu
printf "%s\n" "$*" >>/workspace/verity-calls
case $1 in
	format)
		root_hash_file=
		last=
		for argument do
			last=$argument
			case $argument in
				--root-hash-file=*) root_hash_file=${argument#*=} ;;
			esac
		done
		test -n "$root_hash_file"
		truncate -s 4096 "$last"
		printf bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
			>"$root_hash_file"
		;;
	verify) ;;
	*) exit 1 ;;
esac
EOF
		chmod 0755 /stubs/*
		mkdir /workspace/hit /workspace/miss /workspace/corrupt

		stage=cache-hit
		PATH=/stubs:$PATH \
			/usr/local/sbin/prepare-volatoo-incremental-realization \
			/state "$generation" "$plan" /workspace/hit "$target" "$reuse" "$parent"
		test ! -e /workspace/verity-calls
		grep -Fx "reused 1" /workspace/hit/reuse-report >/dev/null
		grep -Fx "generated 0" /workspace/hit/reuse-report >/dev/null
		grep -F "image 0 base $source $source 4096 $hash " \
			/workspace/hit/realization.plan >/dev/null
		grep -Fx "VOLATOO_PARENT_TREE_RECEIPT_V3" \
			/workspace/hit/parent-tree.receipt >/dev/null
		grep -F "parent-generation $parent" \
			/workspace/hit/parent-tree.receipt >/dev/null
		grep -F "parent-realization $reuse" \
			/workspace/hit/parent-tree.receipt >/dev/null
		grep -E "^tree-receipt sha256:[0-9a-f]{64}$" \
			/workspace/hit/realization.plan >/dev/null
		grep -E "^validation-index sha256:[0-9a-f]{64} [1-9][0-9]*$" \
			/workspace/hit/parent-tree.receipt >/dev/null
		grep -E "^tree-state sha256:[0-9a-f]{64} [1-9][0-9]*$" \
			/workspace/hit/parent-tree.receipt >/dev/null
		test "$(find /workspace/hit/publish -type f | wc -l)" -eq 3
		receipt_hex=$(sha256sum /workspace/hit/parent-tree.receipt | cut -d " " -f 1)
		index_hex=$(sha256sum /workspace/hit/validation.index | cut -d " " -f 1)
		cmp /workspace/hit/parent-tree.receipt /workspace/hit/publish/$receipt_hex
		cmp /workspace/hit/validation.index /workspace/hit/publish/$index_hex

		stage=cache-miss
		PATH=/stubs:$PATH \
			/usr/local/sbin/prepare-volatoo-incremental-realization \
			/state "$generation" "$plan" /workspace/miss "$target" none
		grep -Fq format /workspace/verity-calls
		grep -Fx "reused 0" /workspace/miss/reuse-report >/dev/null
		grep -Fx "generated 1" /workspace/miss/reuse-report >/dev/null
		test -n "$(find /workspace/miss/publish -type f -print -quit)"

		stage=cache-corruption
		printf corrupt >>"$objects/$hash_hex"
		if PATH=/stubs:$PATH \
			/usr/local/sbin/prepare-volatoo-incremental-realization \
			/state "$generation" "$plan" /workspace/corrupt "$target" "$reuse" "$parent"; then
			echo "error: corrupt cached verity object was accepted" >&2
			exit 1
		fi
	'

echo "incremental dm-verity reuse tests passed"
