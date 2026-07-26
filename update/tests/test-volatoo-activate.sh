#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
generation_tool=$repo_root/update/volatoo-generation
activation_tool=$repo_root/update/volatoo-activate
manifest=$repo_root/update/volatoo-manifest
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

raw_digest()
{
	python3 - "$1" <<'PY'
import hashlib
import pathlib
import sys

print("sha256:" + hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
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

"$manifest" canonicalize \
	"$repo_root/update/examples/build-context-v1.json" \
	>"$work_dir/context.json"
target_id=$(jq -r '.target.id' "$work_dir/context.json")
context_digest=$(canonical_digest "$work_dir/context.json")
printf 'hsqsactivation-base\n' >"$work_dir/base.squashfs"
base_digest=$(raw_digest "$work_dir/base.squashfs")
base_size=$(wc -c <"$work_dir/base.squashfs" | tr -d ' ')
jq -n \
	--arg target "$target_id" \
	--arg context "$context_digest" \
	--arg base "$base_digest" \
	--argjson size "$base_size" \
	'{
	  schema: "org.volatoo.generation/v1",
	  target_id: $target,
	  build_context_digest: $context,
	  base: {
	    rootfs_digest: $base,
	    rootfs_size: $size,
	    format: "squashfs"
	  },
	  layers: []
	}' |
	"$manifest" canonicalize - >"$work_dir/generation-0.json"
"$generation_tool" publish \
	--state "$state" \
	--generation "$work_dir/generation-0.json" \
	--object "$work_dir/context.json" \
	--object "$work_dir/base.squashfs" \
	--activate >/dev/null
generation_zero=$(canonical_digest "$work_dir/generation-0.json")
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
	local transaction=$work_dir/transaction-$number.json
	local generation=$work_dir/generation-$number.json
	local layer_digest
	local layer_size
	local changed_digest
	local tombstones_digest
	local transaction_digest

	printf 'hsqsactivation-layer-%s\n' "$number" >"$layer"
	layer_digest=$(raw_digest "$layer")
	layer_size=$(wc -c <"$layer" | tr -d ' ')
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
	changed_digest=$(canonical_digest "$changed")
	jq -n \
		--arg target "$target_id" \
		'{
		  schema: "org.volatoo.tombstones/v1",
		  target_id: $target,
		  paths: ["/etc/obsolete"]
		}' |
		"$manifest" canonicalize - >"$tombstones"
	tombstones_digest=$(canonical_digest "$tombstones")
	jq \
		--arg target "$target_id" \
		--arg context "$context_digest" \
		--arg parent "$parent" \
		--arg layer "$layer_digest" \
		--argjson size "$layer_size" \
		--arg changed "$changed_digest" \
		--arg tombstones "$tombstones_digest" \
		'
		.target_id = $target
		| .build_context_digest = $context
		| .parent_generation_digest = $parent
		| .filesystem.rootfs_digest = $layer
		| .filesystem.rootfs_size = $size
		| .filesystem.changed_paths_digest = $changed
		| .filesystem.changed_paths_count = 11
		| .filesystem.tombstones_digest = $tombstones
		| .filesystem.tombstones_count = 1
		' \
		"$repo_root/update/examples/layer-transaction-v1.json" |
		"$manifest" canonicalize - >"$transaction"
	transaction_digest=$(canonical_digest "$transaction")
	jq \
		--arg layer "$layer_digest" \
		--argjson size "$layer_size" \
		--arg tombstones "$tombstones_digest" \
		--arg transaction "$transaction_digest" \
		'.layers += [{
		  rootfs_digest: $layer,
		  rootfs_size: $size,
		  format: "squashfs",
		  tombstones_digest: $tombstones,
		  transaction_digest: $transaction
		}]' \
		"$parent_manifest" |
		"$manifest" canonicalize - >"$generation"
	"$generation_tool" publish \
		--state "$state" \
		--generation "$generation" \
		--object "$layer" \
		--object "$changed" \
		--object "$tombstones" \
		--object "$transaction" \
		--activate >/dev/null
}

make_candidate 1 "$generation_zero" "$work_dir/generation-0.json"
generation_one=$(canonical_digest "$work_dir/generation-1.json")

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

make_candidate 2 "$generation_one" "$work_dir/generation-1.json"
generation_two=$(canonical_digest "$work_dir/generation-2.json")
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
