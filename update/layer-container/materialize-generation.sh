#!/bin/sh

set -eu

test "$#" -eq 4 || test "$#" -eq 5 || test "$#" -eq 6

state=$1
generation=$2
expected_plan_digest=$3
root=$4
expected_target=${5:-}
retained_cache=${6:-}
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
test ! -e "$root"
test ! -L "$root"
cache=${root}.volatoo-materialize
cleanup_cache=yes
if [ -n "$retained_cache" ]; then
	case $retained_cache in
		/*) ;;
		*) echo "error: retained object cache must be absolute" >&2; exit 1 ;;
	esac
	test "$retained_cache" != "$root"
	case $retained_cache/ in
		"$root"/*)
			echo "error: retained object cache must be outside the materialized root" >&2
			exit 1
			;;
	esac
	cache=$retained_cache
	cleanup_cache=no
fi
test ! -e "$cache"
test ! -L "$cache"
mkdir "$cache"
cleanup()
{
	if [ "$cleanup_cache" = yes ]; then
		rm -rf -- "${cache:?}"
	fi
}
trap cleanup 0

verify_object()
{
	digest=$1
	case $digest in
		sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
		*) echo "error: invalid object digest" >&2; exit 1 ;;
	esac
	test "${#digest}" -eq 71
	case ${digest#sha256:} in
		*[!0-9a-f]*) echo "error: invalid object digest" >&2; exit 1 ;;
	esac
	object=$system/objects/sha256/${digest#sha256:}
	test -f "$object"
	snapshot=$cache/${digest#sha256:}
	if [ ! -f "$snapshot" ]; then
		cp -- "$object" "$snapshot"
	fi
	actual=$(sha256sum "$snapshot")
	actual=sha256:${actual%% *}
	if [ "$actual" != "$digest" ]; then
		echo "error: object digest mismatch: $digest" >&2
		exit 1
	fi
	printf '%s\n' "$snapshot"
}

manifest=$system/manifests/$hex.json
test -f "$manifest"
manifest_snapshot=$cache/manifest.json
cp -- "$manifest" "$manifest_snapshot"
manifest_actual=$(sha256sum "$manifest_snapshot")
manifest_actual=sha256:${manifest_actual%% *}
test "$manifest_actual" = "$generation"

plan_pointer=$system/plans/$hex
test -f "$plan_pointer"
plan_digest=$(cat "$plan_pointer")
case $plan_digest in
	sha256:[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
	*) echo "error: invalid boot plan digest" >&2; exit 1 ;;
esac
test "${#plan_digest}" -eq 71
case ${plan_digest#sha256:} in
	*[!0-9a-f]*) echo "error: invalid boot plan digest" >&2; exit 1 ;;
esac
if [ "$plan_digest" != "$expected_plan_digest" ]; then
	echo "error: boot plan pointer changed after validation" >&2
	exit 1
fi
plan=$(verify_object "$plan_digest")

line_number=0
generation_seen=no
target_seen=no
context_seen=no
base_seen=no
layer_digest=
layer_size=
layer_open=no
ended=no
while IFS= read -r line; do
	line_number=$((line_number + 1))
	if [ "$ended" = yes ]; then
		echo "error: data follows boot plan end" >&2
		exit 1
	fi
	case $line_number:$line in
		1:VOLATOO_GENERATION_V1) continue ;;
	esac
	case $line in
		"generation $generation")
			test "$generation_seen" = no
			test "$target_seen" = no
			test "$context_seen" = no
			test "$base_seen" = no
			generation_seen=yes
			;;
		target\ *)
			test "$generation_seen" = yes
			test "$target_seen" = no
			test "$context_seen" = no
			test "$base_seen" = no
			# The verified boot-plan format uses fixed tokens.
			# shellcheck disable=SC2086
			set -- $line
			test "$#" -eq 2
			if [ -n "$expected_target" ] && [ "$2" != "$expected_target" ]; then
				echo "error: boot plan target changed after validation" >&2
				exit 1
			fi
			target_seen=yes
			;;
		context\ *)
			test "$generation_seen" = yes
			test "$target_seen" = yes
			test "$context_seen" = no
			test "$base_seen" = no
			# The verified boot-plan format uses fixed tokens.
			# shellcheck disable=SC2086
			set -- $line
			test "$#" -eq 2
			verify_object "$2" >/dev/null
			context_seen=yes
			;;
		base\ *)
			test "$generation_seen" = yes
			test "$target_seen" = yes
			test "$context_seen" = yes
			test "$base_seen" = no
			test "$layer_open" = no
			# The verified boot-plan format uses fixed tokens.
			# shellcheck disable=SC2086
			set -- $line
			test "$#" -eq 3
			base=$(verify_object "$2")
			test "$(stat -c %s "$base")" -eq "$3"
			unsquashfs -no-progress -d "$root" "$base" >/dev/null
			base_seen=yes
			;;
		layer\ *)
			test "$base_seen" = yes
			test "$layer_open" = no
			# The verified boot-plan format uses fixed tokens.
			# shellcheck disable=SC2086
			set -- $line
			test "$#" -eq 5
			layer_digest=$2
			layer_size=$3
			verify_object "$4" >/dev/null
			verify_object "$5" >/dev/null
			layer_open=yes
			;;
		remove\ *)
			test "$layer_open" = yes
			path=${line#remove }
			case $path in
				/*) ;;
				*) echo "error: non-absolute tombstone" >&2; exit 1 ;;
			esac
			test "$path" != /
			case "$path" in
				*//* | */../* | */.. | */./* | */.)
					echo "error: unsafe tombstone" >&2
					exit 1
					;;
			esac
			rm -rf -- "${root:?}/${path#/}"
			;;
		endlayer)
			test "$layer_open" = yes
			layer=$(verify_object "$layer_digest")
			test "$(stat -c %s "$layer")" -eq "$layer_size"
			unsquashfs \
				-no-progress \
				-f \
				-d "$root" \
				"$layer" >/dev/null
			layer_open=no
			layer_digest=
			layer_size=
			;;
		end)
			test "$generation_seen" = yes
			test "$target_seen" = yes
			test "$context_seen" = yes
			test "$base_seen" = yes
			test "$layer_open" = no
			ended=yes
			;;
		*)
			echo "error: malformed boot plan line $line_number" >&2
			exit 1
			;;
	esac
done <"$plan"

test "$ended" = yes
test "$generation_seen" = yes
test "$target_seen" = yes
test "$context_seen" = yes
test -d "$root"
