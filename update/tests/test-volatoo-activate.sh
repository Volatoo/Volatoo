#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
activation_tool=$repo_root/update/volatoo-activate
manifest=$repo_root/update/volatoo-manifest
fixture_tool=$repo_root/update/tests/make-generation-fixture.py
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-activate-test.XXXXXX")

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

state=$work_dir/state
system=$state/volatoo/system
root=$work_dir/root
mkdir -p \
	"$state/volatoo/config" \
	"$state/volatoo/data/bind" \
	"$state/volatoo/data/identity" \
	"$state/volatoo/data/overlay" \
	"$state/volatoo/data/sync" \
	"$state/volatoo/snapshots" \
	"$root/.volatoo" \
	"$root/etc" \
	"$root/usr/bin" \
	"$root/var/db/pkg/app-misc/jq-1.8.1"
printf '1\n' >"$state/volatoo/layout-version"
"$generation_tool" migrate-state --state "$state" >/dev/null

printf 'hsqsactivation-base\n' >"$work_dir/base.squashfs"
python3 "$fixture_tool" context \
	--build-context "$repo_root/update/examples/build-context-v1.json" \
	--base "$work_dir/base.squashfs" \
	--output-dir "$work_dir/provenance"
context=$work_dir/provenance/build-context.json
build_spec=$work_dir/provenance/build-spec.json
source_catalog=$work_dir/provenance/source-catalog.json
acquisition=$work_dir/provenance/acquisition.json
base_generation=$work_dir/provenance/base-generation.json
target_id=$(jq -r '.target.id' "$context")
"$generation_tool" publish \
	--state "$state" \
	--generation "$base_generation" \
	--object "$context" \
	--object "$work_dir/base.squashfs" \
	--activate \
	--expected-current none >/dev/null
generation_zero=$(canonical_digest "$base_generation")
printf '%s\n' "$generation_zero" >"$root/.volatoo/generation-id"
printf 'old-binary\n' >"$root/usr/bin/web"
printf 'old-config\n' >"$root/etc/web.conf"
printf 'obsolete\n' >"$root/etc/obsolete"
printf 'old-vdb\n' >"$root/var/db/pkg/app-misc/jq-1.8.1/CONTENTS"

make_candidate()
{
	local number=$1
	local parent=$2
	local parent_manifest=$3
	local layer=$work_dir/layer-$number.squashfs
	local changed=$work_dir/changed-$number.json
	local tombstones=$work_dir/tombstones-$number.json
	local output=$work_dir/candidate-$number

	printf 'hsqsactivation-layer-%s\n' "$number" >"$layer"
	jq -n \
		--arg target "$target_id" \
		'{
		  schema: "org.volatoo.layer-paths/v1",
		  target_id: $target,
		  paths: [
		    "/etc",
		    "/etc/web.conf",
		    "/usr",
		    "/usr/bin",
		    "/usr/bin/web",
		    "/var",
		    "/var/db",
		    "/var/db/pkg",
		    "/var/db/pkg/app-misc",
		    "/var/db/pkg/app-misc/jq-1.8.1",
		    "/var/db/pkg/app-misc/jq-1.8.1/CONTENTS"
		  ]
		}' |
		"$manifest" canonicalize - >"$changed"
	jq -n \
		--arg target "$target_id" \
		'{
		  schema: "org.volatoo.tombstones/v1",
		  target_id: $target,
		  paths: ["/etc/obsolete"]
		}' |
		"$manifest" canonicalize - >"$tombstones"
	python3 "$fixture_tool" layer \
		--generation-version 2 \
		--build-context "$context" \
		--build-spec "$build_spec" \
		--acquisition "$acquisition" \
		--parent "$parent_manifest" \
		--changed-paths "$changed" \
		--tombstones "$tombstones" \
		--layer "$layer" \
		--output-dir "$output"
	"$generation_tool" publish \
		--state "$state" \
		--generation "$output/generation.json" \
		--object "$context" \
		--object "$build_spec" \
		--object "$source_catalog" \
		--object "$acquisition" \
		--object "$layer" \
		--object "$changed" \
		--object "$tombstones" \
		--object "$output/transaction.json" \
		--object "$output/portage-state.json" \
		--activate \
		--expected-current "$parent" >/dev/null
}

make_candidate 1 "$generation_zero" "$base_generation"
generation_one=$(canonical_digest "$work_dir/candidate-1/generation.json")

mkdir -p \
	"$work_dir/prepared-1/etc" \
	"$work_dir/prepared-1/usr/bin" \
	"$work_dir/prepared-1/var/db/pkg/app-misc/jq-1.8.1"
printf 'new-binary\n' >"$work_dir/prepared-1/usr/bin/web"
printf 'good\n' >"$work_dir/prepared-1/etc/web.conf"
printf 'new-vdb\n' \
	>"$work_dir/prepared-1/var/db/pkg/app-misc/jq-1.8.1/CONTENTS"

check_script=$work_dir/check
health_script=$work_dir/health
action_script=$work_dir/action
rollback_script=$work_dir/rollback
# The generated helper scripts expand these variables when they run.
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/bin/sh' \
	'set -eu' \
	'test -s "$VOLATOO_ACTIVATION_ROOT/etc/web.conf"' \
	>"$check_script"
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/bin/sh' \
	'set -eu' \
	'test "$(cat "$VOLATOO_ACTIVATION_ROOT/etc/web.conf")" = good' \
	>"$health_script"
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/bin/sh' \
	'set -eu' \
	'printf "activate\n" >>"$VOLATOO_ACTIVATION_ROOT/action.log"' \
	>"$action_script"
# shellcheck disable=SC2016
printf '%s\n' \
	'#!/bin/sh' \
	'set -eu' \
	'printf "rollback\n" >>"$VOLATOO_ACTIVATION_ROOT/action.log"' \
	>"$rollback_script"
chmod +x "$check_script" "$health_script" "$action_script" "$rollback_script"

jq -cS -n \
	--arg target "$target_id" \
	--arg check "$check_script" \
	--arg health "$health_script" \
	--arg action "$action_script" \
	--arg rollback "$rollback_script" \
	'{
	  schema: "org.volatoo.activation-policy/v1",
	  target_id: $target,
	  service: "web",
	  init_system: "openrc",
	  packages: ["app-misc/jq"],
	  allowed_paths: [
	    "/etc/obsolete",
	    "/etc/web.conf",
	    "/usr/bin/web",
	    "/var/db/pkg/app-misc/jq-1.8.1"
	  ],
	  activation: {
	    type: "external",
	    unit: "",
	    argv: [$action],
	    rollback_argv: [$rollback]
	  },
	  config_checks: [{
	    argv: [$check],
	    timeout_seconds: 5
	  }],
	  health_checks: [{
	    argv: [$health],
	    timeout_seconds: 5,
	    attempts: 1,
	    interval_seconds: 0
	  }]
	}' >"$work_dir/policy.json"

jq -e \
	--arg candidate "$generation_one" \
	--arg running "$generation_zero" \
	'.eligible == true
	 and .candidate_generation == $candidate
	 and .running_generation == $running' \
	< <(
		"$activation_tool" check \
			--state "$state" \
			--root "$root" \
			--policy "$work_dir/policy.json"
	) >/dev/null ||
	fail "eligible activation was rejected"
"$activation_tool" activate \
	--state "$state" \
	--root "$root" \
	--policy "$work_dir/policy.json" \
	--prepared-layer "$work_dir/prepared-1" \
	--allow-unprivileged >/dev/null
[[ $(<"$root/.volatoo/generation-id") == "$generation_one" ]] ||
	fail "live generation marker was not advanced"
[[ $(<"$root/etc/web.conf") == good ]] ||
	fail "new configuration was not activated"
[[ $(<"$root/usr/bin/web") == new-binary ]] ||
	fail "new service binary was not activated"
[[ ! -e $root/etc/obsolete ]] ||
	fail "live activation did not apply tombstones"
[[ -f $system/activations/${generation_one#sha256:}.json ]] ||
	fail "successful activation receipt is missing"

make_candidate 2 "$generation_one" "$work_dir/candidate-1/generation.json"
generation_two=$(canonical_digest "$work_dir/candidate-2/generation.json")
mkdir -p \
	"$work_dir/prepared-2/etc" \
	"$work_dir/prepared-2/usr/bin" \
	"$work_dir/prepared-2/var/db/pkg/app-misc/jq-1.8.1"
printf 'broken-binary\n' >"$work_dir/prepared-2/usr/bin/web"
printf 'bad\n' >"$work_dir/prepared-2/etc/web.conf"
printf 'broken-vdb\n' \
	>"$work_dir/prepared-2/var/db/pkg/app-misc/jq-1.8.1/CONTENTS"
printf 'obsolete-again\n' >"$root/etc/obsolete"

if "$activation_tool" activate \
	--state "$state" \
	--root "$root" \
	--policy "$work_dir/policy.json" \
	--prepared-layer "$work_dir/prepared-2" \
	--allow-unprivileged \
	>"$work_dir/failure.stdout" 2>"$work_dir/failure.stderr"; then
	fail "unhealthy activation succeeded"
fi
grep -q 'live activation rolled back' "$work_dir/failure.stderr" ||
	fail "failed activation did not report rollback"
[[ $(<"$system/current") == "$generation_one" ]] ||
	fail "failed activation did not restore generation selection"
[[ $(<"$root/.volatoo/generation-id") == "$generation_one" ]] ||
	fail "failed activation advanced the running generation marker"
[[ $(<"$root/etc/web.conf") == good ]] ||
	fail "failed activation did not restore configuration"
[[ $(<"$root/usr/bin/web") == new-binary ]] ||
	fail "failed activation did not restore the service binary"
[[ $(<"$root/etc/obsolete") == obsolete-again ]] ||
	fail "failed activation did not restore a tombstoned file"
[[ $(tail -n 1 "$root/action.log") == rollback ]] ||
	fail "failed activation did not run the rollback action"
[[ ! -e $system/activations/${generation_two#sha256:}.json ]] ||
	fail "failed activation wrote a success receipt"

python3 - "$activation_tool" <<'PY'
import runpy
import sys

module = runpy.run_path(sys.argv[1])
openrc = {
    "init_system": "openrc",
    "activation": {
        "type": "reload",
        "unit": "nginx",
        "argv": [],
        "rollback_argv": [],
    },
}
systemd = {
    "init_system": "systemd",
    "activation": {
        "type": "restart",
        "unit": "nginx.service",
        "argv": [],
        "rollback_argv": [],
    },
}
assert module["action_argv"](openrc) == [
    "/sbin/rc-service",
    "nginx",
    "reload",
]
assert module["action_argv"](systemd) == [
    "/bin/systemctl",
    "restart",
    "nginx.service",
]
PY

echo "volatoo service activation tests passed"
