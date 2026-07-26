#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
openrc_stage3=gentoo/stage3@sha256:ffc1ede408d1f7f0194c13259679630533913a9473e7adcef367375932c7e8cb
systemd_stage3=gentoo/stage3@sha256:0107bcedb0f12f4e905aa9dd4c7e00054b3339fe8cb7080b06e160e5a166c22d
portage_image=gentoo/portage@sha256:6c49dbf51f9e52e3edeb43ca83e79025394b0a9b4c6cab1ed2b2f629e05c78e8
compressor_image=volatoo-layer-compressor:test-$$
platform=linux/amd64
repo_container=volatoo-layer-test-portage-$$
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-layer-test.XXXXXX")
overlay_revision=dddddddddddddddddddddddddddddddddddddddd
fixture_atom='=app-misc/volatoo-layer-fixture-1'
declare -a generation_volumes=()

cleanup()
{
	docker rm "$repo_container" >/dev/null 2>&1 || true
	for volume in "${generation_volumes[@]}"; do
		docker volume rm "$volume" >/dev/null 2>&1 || true
	done
	find "$work_dir" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

overlay=$work_dir/overlay
mkdir -p \
	"$overlay/app-misc/volatoo-layer-fixture/files" \
	"$overlay/metadata" \
	"$overlay/profiles"
printf '%s\n' "$overlay_revision" >"$overlay/.volatoo-revision"
cat >"$overlay/metadata/layout.conf" <<'EOF'
masters = gentoo
thin-manifests = true
EOF
printf '%s\n' 'volatoo-test' >"$overlay/profiles/repo_name"
printf '%s\n' 'layer fixture' \
	>"$overlay/app-misc/volatoo-layer-fixture/files/marker"
cat >"$overlay/app-misc/volatoo-layer-fixture/volatoo-layer-fixture-1.ebuild" <<'EOF'
EAPI=8

DESCRIPTION="Volatoo binary-only layer integration fixture"
HOMEPAGE="https://volatoo.invalid/"
S="${WORKDIR}"
LICENSE="MIT"
SLOT="0"
KEYWORDS="amd64"

src_install() {
	insinto /usr/share/volatoo-layer-fixture
	doins "${FILESDIR}/marker"
}
EOF

repos_conf=$work_dir/volatoo-test.conf
cat >"$repos_conf" <<'EOF'
[volatoo-test]
location = /var/db/repos/volatoo-test
EOF

docker pull --platform "$platform" "$openrc_stage3" >/dev/null
docker pull --platform "$platform" "$systemd_stage3" >/dev/null
docker pull --platform "$platform" "$portage_image" >/dev/null
docker create \
	--platform "$platform" \
	--name "$repo_container" \
	"$portage_image" >/dev/null

revision=$(
	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--entrypoint /bin/sh \
		"$openrc_stage3" \
		-c 'sed -n "s/ .*//p" /var/db/repos/gentoo/metadata/timestamp.commit'
)

for init_system in openrc systemd; do
	if [[ $init_system == openrc ]]; then
		stage3_image=$openrc_stage3
		context_example=$repo_root/update/examples/build-context-v1.json
	else
		stage3_image=$systemd_stage3
		context_example=$repo_root/update/examples/build-context-systemd-v1.json
	fi
	portage_version=$(
		docker run --rm \
			--platform "$platform" \
			--entrypoint /usr/bin/python3 \
			"$stage3_image" \
			-c 'import portage; print(portage.VERSION)'
	)
	jq \
		--arg revision "$revision" \
		--arg overlay_revision "$overlay_revision" \
		--arg portage_version "$portage_version" \
		'
		.target.profile_revision = $revision
		| .sources = [
		    {
		      "name": "gentoo",
		      "revision": $revision,
		      "tree_digest": ("sha256:" + ("2" * 64))
		    },
		    {
		      "name": "volatoo-test",
		      "revision": $overlay_revision,
		      "tree_digest": ("sha256:" + ("d" * 64))
		    }
		  ]
		| .toolchain.portage_version = $portage_version
		' \
		"$context_example" \
		>"$work_dir/context-$init_system.json"
	target_id=$(
		jq -r '.target.id' "$work_dir/context-$init_system.json"
	)

	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--mount "type=bind,src=$repo_root,dst=/work,readonly" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--mount "type=bind,src=$overlay,dst=/var/db/repos/volatoo-test,readonly" \
		--mount "type=bind,src=$repos_conf,dst=/etc/portage/repos.conf/volatoo-test.conf,readonly" \
		--entrypoint /usr/bin/python3 \
		"$stage3_image" \
		/work/update/volatoo-plan \
			--build-context "/result/context-$init_system.json" \
			--output "/result/build-spec-$init_system.json" \
			--query-output "/result/query-$init_system.json" \
			"$fixture_atom"

	mkdir -p "$work_dir/pkgdir/$target_id"
	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--mount "type=bind,src=$overlay,dst=/var/db/repos/volatoo-test,readonly" \
		--mount "type=bind,src=$repos_conf,dst=/etc/portage/repos.conf/volatoo-test.conf,readonly" \
		--entrypoint /bin/sh \
		"$stage3_image" \
		-c 'PKGDIR=$1 emerge --buildpkgonly --oneshot --quiet $2' \
		sh "/result/pkgdir/$target_id" "$fixture_atom"

	jq -n \
		--arg target "$target_id" \
		--arg location "/result/pkgdir/$target_id" \
		'{
		  schema: "org.volatoo.package-source-catalog/v1",
		  target_id: $target,
		  sources: [{
		    id: "local",
		    kind: "local",
		    priority: 100,
		    location: $location,
		    signature_policy: "machine-local",
		    compatibility: "portage-resolved",
		    gpg_home: "",
		    trusted_fingerprints: []
		  }]
		}' >"$work_dir/catalog-$init_system.json"

	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--mount "type=bind,src=$repo_root,dst=/work,readonly" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--mount "type=bind,src=$overlay,dst=/var/db/repos/volatoo-test,readonly" \
		--mount "type=bind,src=$repos_conf,dst=/etc/portage/repos.conf/volatoo-test.conf,readonly" \
		--entrypoint /usr/bin/python3 \
		"$stage3_image" \
		/work/update/volatoo-acquire \
			--build-context "/result/context-$init_system.json" \
			--build-spec "/result/build-spec-$init_system.json" \
			--source-catalog "/result/catalog-$init_system.json" \
			--store "/result/store-$init_system" \
			--receipt "/result/acquisition-$init_system.json"

	context_digest=$(
		"$repo_root/update/volatoo-manifest" digest \
			"$work_dir/context-$init_system.json"
	)
	jq -n \
		--arg target "$target_id" \
		--arg context_digest "$context_digest" \
		'{
		  schema: "org.volatoo.generation/v1",
		  target_id: $target,
		  build_context_digest: $context_digest,
		  base: {
		    rootfs_digest: ("sha256:" + ("4" * 64)),
		    rootfs_size: 1,
		    format: "squashfs"
		  },
		  layers: []
		}' >"$work_dir/parent-$init_system.json"

	mkdir "$work_dir/layer-$init_system"
	VOLATOO_LAYER_COMPRESSOR_IMAGE=$compressor_image \
		"$repo_root/update/compose-layer-docker.sh" \
		--stage-image "$stage3_image" \
		--portage-image "$portage_image" \
		--repository "volatoo-test=$overlay" \
		--build-context "$work_dir/context-$init_system.json" \
		--build-spec "$work_dir/build-spec-$init_system.json" \
		--acquisition "$work_dir/acquisition-$init_system.json" \
		--parent-generation "$work_dir/parent-$init_system.json" \
		--store "$work_dir/store-$init_system" \
		--output-dir "$work_dir/layer-$init_system"

	"$repo_root/update/volatoo-manifest" verify-layer-transaction \
		"$work_dir/layer-$init_system/transaction.json" \
		"$work_dir/layer-$init_system/generation.json" \
		"$work_dir/parent-$init_system.json" \
		"$work_dir/context-$init_system.json" \
		"$work_dir/build-spec-$init_system.json" \
		"$work_dir/acquisition-$init_system.json" \
		"$work_dir/layer-$init_system/changed-paths.json" \
		"$work_dir/layer-$init_system/tombstones.json"
	jq -e '
		.paths | index("/usr/share/volatoo-layer-fixture/marker") != null
	' "$work_dir/layer-$init_system/changed-paths.json" >/dev/null ||
		fail "$init_system: fixture marker is missing from changed paths"
	jq -e '.paths == []' \
		"$work_dir/layer-$init_system/tombstones.json" >/dev/null ||
		fail "$init_system: unexpected tombstones"
	jq -e '.layers | length == 1' \
		"$work_dir/layer-$init_system/generation.json" >/dev/null ||
		fail "$init_system: generation candidate did not append one layer"

	generation_volume=volatoo-layer-generation-$init_system-$$
	generation_volumes+=("$generation_volume")
	docker volume create "$generation_volume" >/dev/null
	docker run --rm \
		--platform "$platform" \
		--mount "type=bind,src=$work_dir/layer-$init_system/layer.squashfs,dst=/input/layer.squashfs,readonly" \
		--mount "type=volume,src=$generation_volume,dst=/generation" \
		--entrypoint /usr/bin/unsquashfs \
		"$compressor_image" \
		-no-progress \
		-d /generation \
		/input/layer.squashfs

	mkdir "$work_dir/recompressed-$init_system"
	docker run --rm \
		--platform "$platform" \
		--mount "type=volume,src=$generation_volume,dst=/input,readonly" \
		--mount "type=bind,src=$work_dir/recompressed-$init_system,dst=/output" \
		"$compressor_image"
	cmp -s \
		"$work_dir/layer-$init_system/layer.squashfs" \
		"$work_dir/recompressed-$init_system/layer.squashfs" ||
		fail "$init_system: SquashFS output is not reproducible"

	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--mount "type=volume,src=$generation_volume,dst=/candidate-layer,readonly" \
		--entrypoint /bin/bash \
		"$stage3_image" \
		-c '
			set -euo pipefail
			tar -C /candidate-layer \
				--create --file=- --numeric-owner --acls --xattrs . |
				tar -C / \
					--extract --file=- --numeric-owner \
					--same-owner --same-permissions --acls --xattrs
			test "$(cat /usr/share/volatoo-layer-fixture/marker)" = \
				"layer fixture"
			python3 -c '"'"'
import portage
vardb = portage.db[portage.settings["EROOT"]]["vartree"].dbapi
cpv = "app-misc/volatoo-layer-fixture-1"
assert vardb.cpv_exists(cpv)
assert vardb.aux_get(cpv, ["repository"])[0] == "volatoo-test"
'"'"'
		'
done

echo "volatoo layer Docker tests passed"
