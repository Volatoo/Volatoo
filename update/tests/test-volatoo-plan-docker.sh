#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
openrc_stage3=gentoo/stage3@sha256:ffc1ede408d1f7f0194c13259679630533913a9473e7adcef367375932c7e8cb
systemd_stage3=gentoo/stage3@sha256:0107bcedb0f12f4e905aa9dd4c7e00054b3339fe8cb7080b06e160e5a166c22d
portage_image=gentoo/portage@sha256:6c49dbf51f9e52e3edeb43ca83e79025394b0a9b4c6cab1ed2b2f629e05c78e8
platform=linux/amd64
repo_container=volatoo-plan-portage-$$
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-plan-test.XXXXXX")

cleanup()
{
	docker rm -f -- "$repo_container" >/dev/null 2>&1 || true
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

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
		--arg portage_version "$portage_version" \
		'
		.target.profile_revision = $revision
		| .sources = [{
		    "name": "gentoo",
		    "revision": $revision,
		    "tree_digest": ("sha256:" + ("2" * 64))
		  }]
		| .toolchain.portage_version = $portage_version
		' \
		"$context_example" \
		>"$work_dir/context-$init_system.json"

	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--mount "type=bind,src=$repo_root,dst=/work,readonly" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--entrypoint /usr/bin/python3 \
		"$stage3_image" \
		/work/update/volatoo-plan \
			--build-context "/result/context-$init_system.json" \
			--output "/result/build-spec-$init_system.json" \
			--query-output "/result/query-$init_system.json" \
			app-misc/jq

	"$repo_root/update/volatoo-manifest" \
		verify-build-spec \
		"$work_dir/build-spec-$init_system.json" \
		"$work_dir/context-$init_system.json"
	"$repo_root/update/volatoo-manifest" \
		verify-package-source-query \
		"$work_dir/query-$init_system.json" \
		"$work_dir/build-spec-$init_system.json" \
		"$work_dir/context-$init_system.json"

	package_count=$(
		jq '.packages | length' \
			"$work_dir/build-spec-$init_system.json"
	)
	[[ $package_count -eq 2 ]] ||
		fail "$init_system: expected a two-package closure, got $package_count"
	jq -e '
		.packages[0].cpv | startswith("dev-libs/oniguruma-")
	' "$work_dir/build-spec-$init_system.json" >/dev/null ||
		fail "$init_system: oniguruma is missing from the resolved closure"
	jq -e '
		.packages[1].cpv | startswith("app-misc/jq-")
	' "$work_dir/build-spec-$init_system.json" >/dev/null ||
		fail "$init_system: jq is missing from the resolved closure"
done

jq '
	.target.init = "systemd"
	| .target.id = "volatoo/amd64/glibc/systemd/23.0/base-v1"
	| .target.profile_id = "volatoo/amd64/glibc/systemd/base-v1"
' "$work_dir/context-openrc.json" >"$work_dir/wrong-init.json"
if docker run --rm \
	--platform "$platform" \
	--volumes-from "$repo_container" \
	--mount "type=bind,src=$repo_root,dst=/work,readonly" \
	--mount "type=bind,src=$work_dir,dst=/result" \
	--entrypoint /usr/bin/python3 \
	"$openrc_stage3" \
	/work/update/volatoo-plan \
		--build-context /result/wrong-init.json \
		--output /result/bad-spec.json \
		--query-output /result/bad-query.json \
		app-misc/jq >"$work_dir/wrong-init.log" 2>&1
then
	fail "planner accepted a systemd context in an OpenRC root"
fi
grep -Fq "init system does not match build context" \
	"$work_dir/wrong-init.log" ||
	fail "planner did not report the init mismatch"

jq '
	.sources[0].revision = ("f" * 40)
' "$work_dir/context-openrc.json" >"$work_dir/wrong-revision.json"
if docker run --rm \
	--platform "$platform" \
	--volumes-from "$repo_container" \
	--mount "type=bind,src=$repo_root,dst=/work,readonly" \
	--mount "type=bind,src=$work_dir,dst=/result" \
	--entrypoint /usr/bin/python3 \
	"$openrc_stage3" \
	/work/update/volatoo-plan \
		--build-context /result/wrong-revision.json \
		--output /result/bad-revision-spec.json \
		--query-output /result/bad-revision-query.json \
		app-misc/jq >"$work_dir/wrong-revision.log" 2>&1
then
	fail "planner accepted a repository revision mismatch"
fi
grep -Fq "repository gentoo revision does not match build context" \
	"$work_dir/wrong-revision.log" ||
	fail "planner did not report the repository revision mismatch"

echo "volatoo planner Docker tests passed"
