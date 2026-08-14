#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
manifest=$repo_root/update/volatoo-manifest
fixture_tool=$repo_root/update/tests/make-generation-fixture.py
compressor_image=volatoo-layer-compressor:compaction-test
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-compaction-test.XXXXXX")

cleanup()
{
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

canonical_digest()
{
	"$manifest" digest "$1"
}

command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"
command -v jq >/dev/null 2>&1 || fail "jq is not installed"

state=$work_dir/state
system=$state/volatoo/system
mkdir -p \
	"$state/volatoo/config" \
	"$state/volatoo/data/bind" \
	"$state/volatoo/data/identity" \
	"$state/volatoo/data/overlay" \
	"$state/volatoo/data/sync" \
	"$state/volatoo/snapshots" \
	"$work_dir/base-root/etc/init.d" \
	"$work_dir/base-root/etc/portage" \
	"$work_dir/base-root/usr/bin" \
	"$work_dir/base-root/usr/lib" \
	"$work_dir/base-root/usr/lib64" \
	"$work_dir/base-root/var/db/pkg" \
	"$work_dir/layer-1/etc" \
	"$work_dir/layer-2/etc" \
	"$work_dir/base-output" \
	"$work_dir/layer-output-1" \
	"$work_dir/layer-output-2"
printf '1\n' >"$state/volatoo/layout-version"
"$generation_tool" migrate-state --state "$state" >/dev/null

printf 'base\n' >"$work_dir/base-root/etc/base"
printf 'remove-me\n' >"$work_dir/base-root/etc/removed"
printf 'old\n' >"$work_dir/base-root/etc/replaced"
printf 'placeholder shell\n' >"$work_dir/base-root/usr/bin/sh"
printf 'placeholder init\n' >"$work_dir/base-root/usr/bin/init"
printf 'placeholder openrc\n' >"$work_dir/base-root/usr/bin/openrc"
chmod 0755 \
	"$work_dir/base-root/usr/bin/sh" \
	"$work_dir/base-root/usr/bin/init" \
	"$work_dir/base-root/usr/bin/openrc"
ln -s usr/bin "$work_dir/base-root/bin"
ln -s usr/lib "$work_dir/base-root/lib"
ln -s usr/lib64 "$work_dir/base-root/lib64"
ln -s usr/bin "$work_dir/base-root/sbin"
printf 'layer-one\n' >"$work_dir/layer-1/etc/layer-one"
printf 'v1\n' >"$work_dir/layer-1/etc/replaced"
printf 'layer-two\n' >"$work_dir/layer-2/etc/layer-two"
printf 'v2\n' >"$work_dir/layer-2/etc/replaced"

docker build \
	--platform linux/amd64 \
	--tag "$compressor_image" \
	--file "$repo_root/update/layer-container/Dockerfile" \
	"$repo_root" >/dev/null
fhs_result=$(
	docker run --rm \
		--platform linux/amd64 \
		--mount "type=bind,src=$work_dir/base-root,dst=/root,readonly" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--entrypoint /usr/local/sbin/validate-volatoo-fhs \
		"$compressor_image" \
		/root \
		volatoo/amd64/glibc/openrc/23.0/base-v1 \
		/result/fhs-validation.index
)
[[ $fhs_result == org.volatoo.gentoo-fhs/v1 ]] ||
	fail "valid FHS fixture did not produce the expected contract"
grep -Fx 'VOLATOO_FHS_ELF_INDEX_V1' "$work_dir/fhs-validation.index" >/dev/null ||
	fail "FHS validator did not emit the validation index header"
grep -Fx 'target volatoo/amd64/glibc/openrc/23.0/base-v1' \
	"$work_dir/fhs-validation.index" >/dev/null ||
	fail "FHS validation index did not bind the target"
grep -Fx 'P|/usr/bin/openrc|f|755' "$work_dir/fhs-validation.index" >/dev/null ||
	fail "FHS validation index omitted a runtime path"
grep -Fx 'L|/bin|usr/bin' "$work_dir/fhs-validation.index" >/dev/null ||
	fail "FHS validation index omitted a runtime symlink"
[[ $(tail -n 1 "$work_dir/fhs-validation.index") == end ]] ||
	fail "FHS validation index has no end record"

cp -a "$work_dir/base-root" "$work_dir/fhs-elf-root"
docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/fhs-elf-root,dst=/root" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c '
		set -eu
		cp /usr/bin/scanelf /root/usr/bin/elf-ok
		cp /lib/ld-musl-x86_64.so.1 \
			/root/usr/lib/ld-musl-x86_64.so.1
		ln -s ld-musl-x86_64.so.1 \
			/root/usr/lib/libc.musl-x86_64.so.1
	'
fhs_elf_result=$(
	docker run --rm \
		--platform linux/amd64 \
		--mount "type=bind,src=$work_dir/fhs-elf-root,dst=/root,readonly" \
		--entrypoint /usr/local/sbin/validate-volatoo-fhs \
		"$compressor_image" \
		/root \
		volatoo/amd64/musl/openrc/23.0/base-v1
)
[[ $fhs_elf_result == org.volatoo.gentoo-fhs/v1 ]] ||
	fail "FHS validator rejected a complete ELF dependency closure"

cp -a "$work_dir/fhs-elf-root" "$work_dir/fhs-missing-elf-root"
docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/fhs-missing-elf-root,dst=/root" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c 'cp /usr/bin/mksquashfs /root/usr/bin/missing-elf-dependency'
if docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/fhs-missing-elf-root,dst=/root,readonly" \
	--entrypoint /usr/local/sbin/validate-volatoo-fhs \
	"$compressor_image" \
	/root \
	volatoo/amd64/musl/openrc/23.0/base-v1 \
	>"$work_dir/fhs-missing-elf.stdout" \
	2>"$work_dir/fhs-missing-elf.stderr"
then
	fail "FHS validator accepted a missing ELF dependency"
fi
grep -q 'ELF dependency is missing from the FHS closure' \
	"$work_dir/fhs-missing-elf.stderr" ||
	fail "FHS validator did not diagnose the missing ELF dependency"

cp -a "$work_dir/base-root" "$work_dir/fhs-leak-root"
ln -s /nix/store/unsafe-package/bin/tool \
	"$work_dir/fhs-leak-root/usr/bin/store-tool"
if docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/fhs-leak-root,dst=/root,readonly" \
	--entrypoint /usr/local/sbin/validate-volatoo-fhs \
	"$compressor_image" \
	/root \
	volatoo/amd64/glibc/openrc/23.0/base-v1 \
	>"$work_dir/fhs-leak.stdout" \
	2>"$work_dir/fhs-leak.stderr"
then
	fail "FHS validator accepted a package-store runtime symlink"
fi
grep -q 'symlink leaks a build/store path' "$work_dir/fhs-leak.stderr" ||
	fail "FHS validator did not diagnose the package-store symlink"

cp -a "$work_dir/base-root" "$work_dir/fhs-shebang-root"
printf '#!/nix/store/unsafe-shell/bin/sh\nexit 0\n' \
	>"$work_dir/fhs-shebang-root/usr/bin/store-script"
chmod 0755 "$work_dir/fhs-shebang-root/usr/bin/store-script"
if docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/fhs-shebang-root,dst=/root,readonly" \
	--entrypoint /usr/local/sbin/validate-volatoo-fhs \
	"$compressor_image" \
	/root \
	volatoo/amd64/glibc/openrc/23.0/base-v1 \
	>"$work_dir/fhs-shebang.stdout" \
	2>"$work_dir/fhs-shebang.stderr"
then
	fail "FHS validator accepted a package-store shebang"
fi
grep -q 'shebang leaks a build/store path' "$work_dir/fhs-shebang.stderr" ||
	fail "FHS validator did not diagnose the package-store shebang"

cp -a "$work_dir/base-root" "$work_dir/fhs-work-root"
mkdir -p "$work_dir/fhs-work-root/work/cache"
printf 'builder residue\n' >"$work_dir/fhs-work-root/work/cache/object"
if docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/fhs-work-root,dst=/root,readonly" \
	--entrypoint /usr/local/sbin/validate-volatoo-fhs \
	"$compressor_image" \
	/root \
	volatoo/amd64/glibc/openrc/23.0/base-v1 \
	>"$work_dir/fhs-work.stdout" \
	2>"$work_dir/fhs-work.stderr"
then
	fail "FHS validator accepted data below a reserved build mountpoint"
fi
grep -q 'contains data below reserved mountpoint' "$work_dir/fhs-work.stderr" ||
	fail "FHS validator did not diagnose reserved build data"

for entry in \
	base:"$work_dir/base-root":"$work_dir/base-output" \
	1:"$work_dir/layer-1":"$work_dir/layer-output-1" \
	2:"$work_dir/layer-2":"$work_dir/layer-output-2"
do
	input=${entry#*:}
	input=${input%%:*}
	output=${entry##*:}
	docker run --rm \
		--platform linux/amd64 \
		--mount "type=bind,src=$input,dst=/input,readonly" \
		--mount "type=bind,src=$output,dst=/output" \
		"$compressor_image" >/dev/null
done
mv "$work_dir/base-output/layer.squashfs" \
	"$work_dir/base-output/base.squashfs"

base=$work_dir/base-output/base.squashfs
python3 "$fixture_tool" context \
	--build-context "$repo_root/update/examples/build-context-v1.json" \
	--base "$base" \
	--output-dir "$work_dir/provenance"
context=$work_dir/provenance/build-context.json
build_spec=$work_dir/provenance/build-spec.json
source_catalog=$work_dir/provenance/source-catalog.json
acquisition=$work_dir/provenance/acquisition.json
base_generation=$work_dir/provenance/base-generation.json
target_id=$(jq -r '.target.id' "$context")

for number in 1 2; do
	if [[ $number == 1 ]]; then
		paths='["/etc/removed"]'
	else
		paths='["/etc/layer-one","/etc/replaced"]'
	fi
	jq -n \
		--arg target "$target_id" \
		--argjson paths "$paths" \
		'{
		  schema: "org.volatoo.tombstones/v1",
		  target_id: $target,
		  paths: $paths
		}' |
		"$manifest" canonicalize - >"$work_dir/tombstones-$number.json"
	jq -n \
		--arg target "$target_id" \
		--arg first "/etc/layer-$number" \
		--arg second /etc/replaced \
		'{
		  schema: "org.volatoo.layer-paths/v1",
		  target_id: $target,
		  paths: [$first, $second]
		}' |
		"$manifest" canonicalize - >"$work_dir/changed-$number.json"
done

python3 "$fixture_tool" layer \
	--generation-version 2 \
	--build-context "$context" \
	--build-spec "$build_spec" \
	--acquisition "$acquisition" \
	--parent "$base_generation" \
	--changed-paths "$work_dir/changed-1.json" \
	--tombstones "$work_dir/tombstones-1.json" \
	--layer "$work_dir/layer-output-1/layer.squashfs" \
	--output-dir "$work_dir/generation-1"
python3 "$fixture_tool" layer \
	--generation-version 2 \
	--build-context "$context" \
	--build-spec "$build_spec" \
	--acquisition "$acquisition" \
	--parent "$work_dir/generation-1/generation.json" \
	--changed-paths "$work_dir/changed-2.json" \
	--tombstones "$work_dir/tombstones-2.json" \
	--layer "$work_dir/layer-output-2/layer.squashfs" \
	--output-dir "$work_dir/generation-2"
common_objects=(
	--object "$context"
	--object "$build_spec"
	--object "$source_catalog"
	--object "$acquisition"
	--object "$base"
	--object "$work_dir/layer-output-1/layer.squashfs"
	--object "$work_dir/changed-1.json"
	--object "$work_dir/tombstones-1.json"
	--object "$work_dir/generation-1/transaction.json"
	--object "$work_dir/generation-1/portage-state.json"
)
"$generation_tool" publish \
	--state "$state" \
	--generation "$base_generation" \
	--object "$context" \
	--object "$base" \
	--activate \
	--expected-current none >/dev/null
base_generation_digest=$(canonical_digest "$base_generation")
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-1/generation.json" \
	"${common_objects[@]}" \
	--activate \
	--expected-current "$base_generation_digest" >/dev/null
generation_one=$(
	canonical_digest "$work_dir/generation-1/generation.json"
)
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-2/generation.json" \
	"${common_objects[@]}" \
	--object "$work_dir/layer-output-2/layer.squashfs" \
	--object "$work_dir/changed-2.json" \
	--object "$work_dir/tombstones-2.json" \
	--object "$work_dir/generation-2/transaction.json" \
	--object "$work_dir/generation-2/portage-state.json" \
	--activate \
	--expected-current "$generation_one" >/dev/null
source_generation=$(canonical_digest "$work_dir/generation-2/generation.json")
source_inspection=$(
	"$generation_tool" inspect --state "$state" "$source_generation"
)
source_plan_digest=$(jq -r '.boot_plan_digest' <<<"$source_inspection")

cp -a "$state" "$work_dir/corrupt-state"
current_layer_digest=$(
	jq -r '.layers[-1].rootfs_digest' \
		"$work_dir/generation-2/generation.json"
)
current_layer_object=$work_dir/corrupt-state/volatoo/system/objects/sha256/${current_layer_digest#sha256:}
chmod u+w "$current_layer_object"
printf 'corrupt layer\n' >"$current_layer_object"
mkdir "$work_dir/corrupt-output"
if docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/corrupt-state,dst=/state,readonly" \
	--mount "type=bind,src=$work_dir/corrupt-output,dst=/output" \
	--entrypoint /usr/local/sbin/materialize-volatoo-generation \
	"$compressor_image" \
	/state \
	"$source_generation" \
	"$source_plan_digest" \
	/output/root \
	>"$work_dir/corrupt-materialize.stdout" \
	2>"$work_dir/corrupt-materialize.stderr"
then
	fail "parent materializer accepted a corrupt layer object"
fi
grep -q 'object digest mismatch' \
	"$work_dir/corrupt-materialize.stderr" ||
	fail "parent materializer did not diagnose the corrupt layer"

cp -a "$state" "$work_dir/swapped-plan-state"
first_plan_digest=$(
	"$generation_tool" inspect --state "$state" "$generation_one" |
		jq -r '.boot_plan_digest'
)
chmod u+w \
	"$work_dir/swapped-plan-state/volatoo/system/plans/${source_generation#sha256:}"
printf '%s\n' "$first_plan_digest" \
	>"$work_dir/swapped-plan-state/volatoo/system/plans/${source_generation#sha256:}"
mkdir "$work_dir/swapped-plan-output"
if docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/swapped-plan-state,dst=/state,readonly" \
	--mount "type=bind,src=$work_dir/swapped-plan-output,dst=/output" \
	--entrypoint /usr/local/sbin/materialize-volatoo-generation \
	"$compressor_image" \
	/state \
	"$source_generation" \
	"$source_plan_digest" \
	/output/root \
	>"$work_dir/swapped-plan.stdout" \
	2>"$work_dir/swapped-plan.stderr"
then
	fail "parent materializer accepted a changed boot plan pointer"
fi
grep -q 'boot plan pointer changed after validation' \
	"$work_dir/swapped-plan.stderr" ||
	fail "parent materializer did not diagnose the changed boot plan pointer"

"$repo_root/update/realize-generation-docker.sh" \
	--state "$state" \
	--generation "$source_generation" \
	--output-dir "$work_dir/realized"
realization_inspection=$(
	"$generation_tool" inspect --state "$state" "$source_generation"
)
jq -e \
	--arg generation "$source_generation" \
	'.generation_digest == $generation
	 and .realized == true
	 and .layer_count == 2
	 and .realization.contract_version == 2
	 and .realization.fhs_contract == "org.volatoo.gentoo-fhs/v1"
	 and (.realization.rootfs_digest | startswith("sha256:"))
	 and (.realization.verity.hash_digest | startswith("sha256:"))
	 and (.realization.verity.root_hash | test("^[0-9a-f]{64}$"))
	 and (.realization.verity.salt | test("^[0-9a-f]{64}$"))
	 and .realization.verity.data_block_size == 4096
	 and .realization.verity.hash_block_size == 4096
	 and .realization.verity.superblock == false
	 and (.realization.tree_digest | startswith("sha256:"))' \
	<<<"$realization_inspection" \
	>/dev/null ||
	fail "realization did not bind the complete source generation"
verity_root_hash=$(<"$work_dir/realized/verity-root-hash")
verity_salt=$(<"$work_dir/realized/verity-salt")
verity_data_blocks=$(<"$work_dir/realized/verity-data-blocks")
docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/realized/closure.squashfs,dst=/closure.squashfs,readonly" \
	--mount "type=bind,src=$work_dir/realized/closure.verity,dst=/closure.verity,readonly" \
	--entrypoint /sbin/veritysetup \
	"$compressor_image" \
	verify \
	/closure.squashfs \
	/closure.verity \
	"$verity_root_hash" \
	--no-superblock \
	--hash=sha256 \
	--data-block-size=4096 \
	--hash-block-size=4096 \
	--data-blocks="$verity_data_blocks" \
	--salt="$verity_salt"
docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/realized/closure.squashfs,dst=/closure.squashfs,readonly" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c '
		set -eu
		unsquashfs -no-progress -d /verify /closure.squashfs >/dev/null
		test "$(cat /verify/etc/base)" = base
		test "$(cat /verify/etc/replaced)" = v2
		test "$(cat /verify/etc/layer-two)" = layer-two
		test ! -e /verify/etc/removed
		test ! -e /verify/etc/layer-one
	'

"$repo_root/update/compact-generation-docker.sh" \
	--state "$state" \
	--output-dir "$work_dir/compacted" \
	--force \
	--activate
compacted_generation=$(canonical_digest "$work_dir/compacted/generation.json")
[[ $(<"$system/current") == "$compacted_generation" ]] ||
	fail "compacted generation was not selected"
[[ $(<"$system/previous") == "$source_generation" ]] ||
	fail "compaction did not preserve the source as previous"
jq -e \
	'
		.schema == "org.volatoo.generation/v2"
		and .parent_generation_digest == null
		and .portage_state_digest != null
		and .layer_count == 0
		and .valid == true
	' \
	< <("$generation_tool" inspect --state "$state") >/dev/null ||
	fail "compacted generation still has layers"
[[ -f $system/compactions/${compacted_generation#sha256:}.json ]] ||
	fail "compaction receipt was not recorded"

docker run --rm \
	--platform linux/amd64 \
	--mount "type=bind,src=$work_dir/compacted/base.squashfs,dst=/base.squashfs,readonly" \
	--entrypoint /bin/sh \
	"$compressor_image" \
	-c '
		set -eu
		unsquashfs -no-progress -d /verify /base.squashfs >/dev/null
		test "$(cat /verify/etc/base)" = base
		test "$(cat /verify/etc/replaced)" = v2
		test "$(cat /verify/etc/layer-two)" = layer-two
		test ! -e /verify/etc/removed
		test ! -e /verify/etc/layer-one
	'

"$generation_tool" forget-previous \
	--state "$state" \
	--confirm "$source_generation" >/dev/null
gc_result=$("$generation_tool" gc --state "$state" --delete)
jq -e \
	'.garbage.manifests >= 2 and .garbage.objects >= 4' \
	<<<"$gc_result" >/dev/null ||
	fail "garbage collection did not reclaim the old layer chain"
"$generation_tool" inspect --state "$state" >/dev/null

echo "volatoo compaction Docker test passed"
