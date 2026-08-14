#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
tool=$repo_root/update/volatoo-manifest
layer_tool=$repo_root/update/volatoo-layer
context=$repo_root/update/examples/build-context-v1.json
generation=$repo_root/update/examples/generation-v1.json
generation_v2=$repo_root/update/examples/generation-v2.json
portage_state=$repo_root/update/examples/portage-state-v1.json
systemd_context=$repo_root/update/examples/build-context-systemd-v1.json
systemd_generation=$repo_root/update/examples/generation-systemd-v1.json
build_spec=$repo_root/update/examples/build-spec-v1.json
package_query=$repo_root/update/examples/package-source-query-v1.json
source_catalog=$repo_root/update/examples/package-source-catalog-v1.json
acquisition=$repo_root/update/examples/package-acquisition-v1.json
changed_paths=$repo_root/update/examples/layer-paths-v1.json
tombstones=$repo_root/update/examples/tombstones-v1.json
layer_transaction=$repo_root/update/examples/layer-transaction-v1.json
layer_generation=$repo_root/update/examples/generation-layer-candidate-v1.json

fail()
{
	echo "error: $*" >&2
	exit 1
}

expect_failure()
{
	expected=$1
	shift
	set +e
	output=$("$@" 2>&1)
	status=$?
	set -e
	[[ $status -eq 1 ]] || fail "expected status 1, got $status: $*"
	grep -Fq -- "$expected" <<<"$output" ||
		fail "expected '$expected' in: $output"
}

"$tool" validate "$context"
"$tool" validate "$generation"
"$tool" validate "$generation_v2"
"$tool" validate "$portage_state"
"$tool" validate "$systemd_context"
"$tool" validate "$systemd_generation"
"$tool" validate "$build_spec"
"$tool" validate "$package_query"
"$tool" validate "$source_catalog"
"$tool" validate "$acquisition"
"$tool" validate "$changed_paths"
"$tool" validate "$tombstones"
"$tool" validate "$layer_transaction"
"$tool" validate "$layer_generation"

context_digest=$("$tool" digest "$context")
expected_context_digest=sha256:fc45b271c47ab407c175451264f0847eb889d1720824edd9932d36ff6ac9bc25
[[ $context_digest == "$expected_context_digest" ]] ||
	fail "unexpected context digest: $context_digest"

"$tool" verify-generation "$generation" "$context"
"$tool" verify-generation "$generation_v2" "$context" "$portage_state"
"$tool" verify-generation "$systemd_generation" "$systemd_context"
"$tool" verify-build-spec "$build_spec" "$context"
"$tool" verify-package-source-query \
	"$package_query" "$build_spec" "$context"
"$tool" verify-acquisition \
	"$acquisition" "$build_spec" "$context" "$source_catalog"
"$tool" verify-layer-transaction \
	"$layer_transaction" \
	"$layer_generation" \
	"$generation" \
	"$context" \
	"$build_spec" \
	"$acquisition" \
	"$changed_paths" \
	"$tombstones"
"$tool" verify-layer-transaction \
	"$layer_transaction" \
	"$generation_v2" \
	"$generation" \
	"$context" \
	"$build_spec" \
	"$acquisition" \
	"$changed_paths" \
	"$tombstones" \
	--portage-state "$portage_state"

canonical=$("$tool" canonicalize "$context")
canonical_digest=$(printf '%s\n' "$canonical" | "$tool" digest -)
[[ $canonical_digest == "$expected_context_digest" ]] ||
	fail "canonical input changed the digest: $canonical_digest"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-manifest-test.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

python3 - "$context" "$work_dir/unknown.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["unexpected"] = True
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "unknown fields: unexpected" \
	"$tool" validate "$work_dir/unknown.json"

python3 - "$context" "$work_dir/unsorted.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["sources"].reverse()
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "sources must be sorted by name" \
	"$tool" validate "$work_dir/unsorted.json"

printf '%s\n' \
	'{"schema":"org.volatoo.generation/v1","schema":"duplicate"}' \
	>"$work_dir/duplicate.json"
expect_failure "duplicate JSON key: schema" \
	"$tool" validate "$work_dir/duplicate.json"

python3 - "$generation" "$work_dir/mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["build_context_digest"] = "sha256:" + ("f" * 64)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "build_context_digest does not match" \
	"$tool" verify-generation "$work_dir/mismatch.json" "$context"

python3 - "$generation" "$work_dir/bad-size.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["base"]["rootfs_size"] = True
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "rootfs_size must be a positive signed 64-bit integer" \
	"$tool" validate "$work_dir/bad-size.json"

python3 - "$generation" "$work_dir/bad-base.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["base"]["rootfs_digest"] = "sha256:" + ("e" * 64)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "base rootfs_digest does not match" \
	"$tool" verify-generation "$work_dir/bad-base.json" "$context"

python3 - "$systemd_context" "$work_dir/init-mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["target"]["id"] = "volatoo/amd64/glibc/openrc/23.0/base-v1"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "target.id must include its init value: systemd" \
	"$tool" validate "$work_dir/init-mismatch.json"

python3 - "$build_spec" "$work_dir/unsorted-use.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["packages"][0]["use"]["enabled"].reverse()
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "use.enabled must be sorted" \
	"$tool" validate "$work_dir/unsorted-use.json"

python3 - "$build_spec" "$work_dir/spec-target-mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["target_id"] = "volatoo/amd64/glibc/systemd/23.0/base-v1"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "BuildSpec target_id does not match" \
	"$tool" verify-build-spec "$work_dir/spec-target-mismatch.json" "$context"

python3 - "$package_query" "$work_dir/query-digest-mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["build_spec_digest"] = "sha256:" + ("f" * 64)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "build_spec_digest does not match" \
	"$tool" verify-package-source-query \
		"$work_dir/query-digest-mismatch.json" "$build_spec" "$context"

python3 - "$source_catalog" "$work_dir/catalog-target-mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["sources"][0]["location"] = (
    "/var/lib/volatoo/local-binpkgs/"
    "volatoo/amd64/glibc/systemd/23.0/base-v1"
)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "location must end with target_id" \
	"$tool" validate "$work_dir/catalog-target-mismatch.json"

python3 - "$acquisition" "$work_dir/acquisition-digest-mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["packages"][0]["package_digest"] = "sha256:" + ("f" * 64)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "digest does not match BuildSpec" \
	"$tool" verify-acquisition \
		"$work_dir/acquisition-digest-mismatch.json" \
		"$build_spec" "$context" "$source_catalog"

python3 - "$changed_paths" "$work_dir/unsorted-layer-paths.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["paths"].reverse()
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "paths must be sorted" \
	"$tool" validate "$work_dir/unsorted-layer-paths.json"

python3 - "$layer_transaction" "$work_dir/layer-digest-mismatch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    value = json.load(stream)
value["filesystem"]["changed_paths_digest"] = "sha256:" + ("f" * 64)
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream)
PY
expect_failure "changed paths digest mismatch" \
	"$tool" verify-layer-transaction \
		"$work_dir/layer-digest-mismatch.json" \
		"$layer_generation" \
		"$generation" \
		"$context" \
		"$build_spec" \
		"$acquisition" \
		"$changed_paths" \
		"$tombstones"

python3 - "$acquisition" "$work_dir/stage-report.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    acquisition = json.load(stream)
report = {
    "schema": "org.volatoo.layer-stage-report/v1",
    "target_id": "volatoo/amd64/glibc/openrc/23.0/base-v1",
    "build_context_digest": (
        "sha256:fc45b271c47ab407c175451264f0847e"
        "b889d1720824edd9932d36ff6ac9bc25"
    ),
    "build_spec_digest": (
        "sha256:f7c5327de13f08dcdda9918617d7c942"
        "ddb04d72a8cefa8db8ae9dc7c0f115e2"
    ),
    "acquisition_digest": (
        "sha256:ef431844d169fde38543fa95e62cd98a"
        "1885013b04f2dad6ade449b57c6e1501"
    ),
    "parent_generation_digest": (
        "sha256:23ba4c06024b23aa7bf48a9fef42cf5"
        "f6659aeb128e4c7182829507da01d4031"
    ),
    "portage_version": "3.0.77",
    "portage_options": [
        "--ask=n",
        "--autounmask=n",
        "--backtrack=30",
        "--binpkg-changed-deps=y",
        "--binpkg-respect-use=y",
        "--complete-graph=y",
        "--keep-going=n",
        "--newuse",
        "--oneshot",
        "--usepkgonly",
        "--with-bdeps=y",
    ],
    "world_digest": "sha256:" + ("c" * 64),
    "packages": [
        {
            "sequence": package["sequence"],
            "cpv": package["cpv"],
            "package_digest": package["package_digest"],
            "artifact_digest": package["artifact_digest"],
            "build_id": package["build_id"],
        }
        for package in acquisition["packages"]
    ],
}
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(report, stream)
PY
python3 - "$work_dir/layer.squashfs" <<'PY'
import sys

with open(sys.argv[1], "wb") as stream:
    stream.write(b"hsqs" + (b"\0" * 92))
PY
printf '%s\n' 4.7.5 >"$work_dir/compressor-version"
"$layer_tool" finalize \
	--build-context "$context" \
	--build-spec "$build_spec" \
	--acquisition "$acquisition" \
	--parent-generation "$generation" \
	--changed-paths "$changed_paths" \
	--tombstones "$tombstones" \
	--stage-report "$work_dir/stage-report.json" \
	--squashfs "$work_dir/layer.squashfs" \
	--compressor-version "$work_dir/compressor-version" \
	--transaction "$work_dir/finalized-transaction.json" \
	--portage-state "$work_dir/finalized-portage-state.json" \
	--generation "$work_dir/finalized-generation.json"
"$tool" verify-layer-transaction \
	"$work_dir/finalized-transaction.json" \
	"$work_dir/finalized-generation.json" \
	"$generation" \
	"$context" \
	"$build_spec" \
	"$acquisition" \
	"$changed_paths" \
	"$tombstones" \
	--portage-state "$work_dir/finalized-portage-state.json"

echo "volatoo manifest tests passed"
