#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/fetch-gentoo-inputs.sh [--metadata-only] OUTPUT_DIR

Resolve the latest official Gentoo amd64 OpenRC stage3 and Catalyst SquashFS
snapshot, verify their signed metadata, and download the inputs.

The script prints key=value records suitable for GitHub Actions outputs.
--metadata-only verifies and resolves the signed metadata without downloading
the two large payloads.
EOF
}

metadata_only=no
if (( $# > 0 )) && [[ $1 == --metadata-only ]]; then
	metadata_only=yes
	shift
fi
if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
	usage
	exit 0
fi
if (( $# != 1 )); then
	usage >&2
	exit 2
fi

output_dir=$1
for command_name in awk curl gpgv sort tail; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "error: required command is not installed: $command_name" >&2
		exit 1
	fi
done

mkdir -p "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd)
marker=$output_dir/.volatoo-gentoo-inputs
if [[ ! -e $marker ]] &&
	find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
	echo "error: refusing to reuse an unmarked non-empty directory: $output_dir" >&2
	exit 1
fi
: >"$marker"

distfiles_base=https://distfiles.gentoo.org
stage3_base=$distfiles_base/releases/amd64/autobuilds
snapshot_base=$distfiles_base/snapshots/squashfs
keyring_url=https://qa-reports.gentoo.org/output/service-keys.gpg
stage3_signer=534E4209AB49EEE1C19D96162C44695DB9F6043D
snapshot_signer=E1D6ABB63BFCFB4BA02FDF1CEC590EEAC9189250

download() {
	url=$1
	destination=$2

	echo "downloading $url" >&2
	curl \
		--fail \
		--location \
		--proto '=https' \
		--retry 5 \
		--retry-all-errors \
		--show-error \
		--silent \
		--tlsv1.2 \
		--output "$destination" \
		"$url"
}

verify_signed_file() {
	signed_file=$1
	expected_signer=$2

	status=$(
		gpgv \
			--keyring "$keyring_path" \
			--status-fd 1 \
			"$signed_file" 2>/dev/null
	) || {
		echo "error: invalid OpenPGP signature: $signed_file" >&2
		exit 1
	}
	actual_signer=$(
		printf '%s\n' "$status" |
			awk '$1 == "[GNUPG:]" && $2 == "VALIDSIG" { print $3 }'
	)
	if [[ $actual_signer != "$expected_signer" ]]; then
		echo "error: unexpected signer for $signed_file: ${actual_signer:-none}" >&2
		exit 1
	fi
}

sha512_file() {
	path=$1

	if command -v sha512sum >/dev/null 2>&1; then
		sha512sum "$path" | awk '{ print $1 }'
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 512 "$path" | awk '{ print $1 }'
	else
		echo "error: sha512sum or shasum is required" >&2
		exit 1
	fi
}

keyring_path=$output_dir/gentoo-service-keys.gpg
stage3_latest_path=$output_dir/latest-stage3-amd64-openrc.txt
snapshot_digests_path=$output_dir/snapshot-sha512sums.txt

download "$keyring_url" "$keyring_path"
download "$stage3_base/latest-stage3-amd64-openrc.txt" "$stage3_latest_path"
verify_signed_file "$stage3_latest_path" "$stage3_signer"

stage3_entries=$(
	awk '
		$1 ~ /^[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z\/stage3-amd64-openrc-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z\.tar\.xz$/ {
			print $1
		}
	' "$stage3_latest_path"
)
if [[ -z $stage3_entries || $stage3_entries == *$'\n'* ]]; then
	echo "error: signed stage3 metadata did not contain exactly one input" >&2
	exit 1
fi
stage3_relative=$stage3_entries
stage3_name=${stage3_relative##*/}
stage3_url=$stage3_base/$stage3_relative
stage3_digest_url=$stage3_url.DIGESTS
stage3_digest_path=$output_dir/$stage3_name.DIGESTS

download "$stage3_digest_url" "$stage3_digest_path"
verify_signed_file "$stage3_digest_path" "$stage3_signer"
stage3_sha512=$(
	awk -v name="$stage3_name" '
		$0 == "# SHA512 HASH" {
			in_sha512 = 1
			next
		}
		/^#/ {
			in_sha512 = 0
		}
		in_sha512 && $2 == name && length($1) == 128 &&
			$1 !~ /[^0-9a-f]/ {
			print $1
			exit
		}
	' "$stage3_digest_path"
)
if [[ ! $stage3_sha512 =~ ^[0-9a-f]{128}$ ]]; then
	echo "error: signed stage3 metadata has no valid SHA-512" >&2
	exit 1
fi

download "$snapshot_base/sha512sum.txt" "$snapshot_digests_path"
verify_signed_file "$snapshot_digests_path" "$snapshot_signer"
snapshot_record=$(
	awk '
		length($1) == 128 && $1 !~ /[^0-9a-f]/ &&
		$2 ~ /^gentoo-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.xz\.sqfs$/ {
			print $2, $1
		}
	' "$snapshot_digests_path" |
		LC_ALL=C sort |
		tail -1
)
read -r snapshot_name snapshot_sha512 <<<"$snapshot_record"
if [[ ! ${snapshot_name:-} =~ ^gentoo-([0-9]{8})\.xz\.sqfs$ ]]; then
	echo "error: signed snapshot metadata has no valid latest snapshot" >&2
	exit 1
fi
snapshot_id=${BASH_REMATCH[1]}
if [[ ! ${snapshot_sha512:-} =~ ^[0-9a-f]{128}$ ]]; then
	echo "error: signed snapshot metadata has no valid SHA-512" >&2
	exit 1
fi
snapshot_url=$snapshot_base/$snapshot_name

stage3_path=$output_dir/$stage3_name
snapshot_path=$output_dir/$snapshot_name
if [[ $metadata_only == no ]]; then
	download "$stage3_url" "$stage3_path"
	actual_stage3_sha512=$(sha512_file "$stage3_path")
	if [[ $actual_stage3_sha512 != "$stage3_sha512" ]]; then
		echo "error: stage3 SHA-512 mismatch" >&2
		exit 1
	fi

	download "$snapshot_url" "$snapshot_path"
	actual_snapshot_sha512=$(sha512_file "$snapshot_path")
	if [[ $actual_snapshot_sha512 != "$snapshot_sha512" ]]; then
		echo "error: snapshot SHA-512 mismatch" >&2
		exit 1
	fi
fi

printf '%s\n' \
	"stage3_name=$stage3_name" \
	"stage3_url=$stage3_url" \
	"stage3_sha512=$stage3_sha512" \
	"stage3_path=$stage3_path" \
	"snapshot_id=$snapshot_id" \
	"snapshot_name=$snapshot_name" \
	"snapshot_url=$snapshot_url" \
	"snapshot_sha512=$snapshot_sha512" \
	"snapshot_path=$snapshot_path"
echo "verified Gentoo stage3 and snapshot metadata" >&2
