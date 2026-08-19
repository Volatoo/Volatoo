#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat >&2 <<'EOF'
Usage: scripts/build-live-iso-docker.sh \
  --init-system openrc|systemd --kernel FILE --initramfs FILE --rootfs FILE \
  --publication DIRECTORY --trusted-key FILE OUTPUT.iso
EOF
}

init_system=
kernel=
initramfs=
rootfs=
publication=
trusted_key=
output=
while (( $# > 0 )); do
	case $1 in
		--init-system|--kernel|--initramfs|--rootfs|--publication|--trusted-key)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--init-system) init_system=$2 ;;
				--kernel) kernel=$2 ;;
				--initramfs) initramfs=$2 ;;
				--rootfs) rootfs=$2 ;;
				--publication) publication=$2 ;;
				--trusted-key) trusted_key=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage; exit 2 ;;
		*) [[ -z $output ]] || { echo "error: only one output is allowed" >&2; exit 2; }; output=$1; shift ;;
	esac
done
[[ $init_system == openrc || $init_system == systemd ]] || { usage; exit 2; }
[[ -d $publication && ! -L $publication && -n $output && $output == *.iso ]] || { usage; exit 2; }
for input in "$kernel" "$initramfs" "$rootfs" "$trusted_key"; do
	[[ -f $input && ! -L $input ]] || {
		echo "error: live ISO input is missing or unsafe: $input" >&2
		exit 1
	}
done
[[ ! -e $output && ! -L $output && ! -e $output.manifest ]] || {
	echo "error: output already exists or is unsafe: $output" >&2
	exit 1
}
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}

absolute_file()
{
	printf '%s/%s\n' "$(cd -- "$(dirname -- "$1")" && pwd)" "$(basename -- "$1")"
}
kernel=$(absolute_file "$kernel")
initramfs=$(absolute_file "$initramfs")
rootfs=$(absolute_file "$rootfs")
trusted_key=$(absolute_file "$trusted_key")
publication=$(cd -- "$publication" && pwd)
output_name=$(basename -- "$output")
output_parent=$(cd -- "$(dirname -- "$output")" && pwd)
[[ $output_name =~ ^[A-Za-z0-9._-]+\.iso$ ]] || {
	echo "error: unsafe live ISO output name" >&2
	exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=volatoo-live-iso-builder:0.1-dev
docker build --platform linux/amd64 --tag "$image" \
	--file "$repo_root/image/live-iso/Dockerfile" "$repo_root"
docker run --rm --network none --platform linux/amd64 \
	--env "INIT_SYSTEM=$init_system" \
	--env "OUTPUT_NAME=$output_name" \
	--env "HOST_UID=$(id -u)" --env "HOST_GID=$(id -g)" \
	--mount "type=bind,src=$kernel,dst=/input/kernel,readonly" \
	--mount "type=bind,src=$initramfs,dst=/input/initramfs,readonly" \
	--mount "type=bind,src=$rootfs,dst=/input/rootfs,readonly" \
	--mount "type=bind,src=$publication,dst=/input/publication,readonly" \
	--mount "type=bind,src=$trusted_key,dst=/input/release.pub,readonly" \
	--mount "type=bind,src=$output_parent,dst=/output" \
	"$image"

manifest=$output.manifest
[[ -f $output && ! -L $output && -f $manifest && ! -L $manifest ]] || {
	echo "error: live ISO builder did not publish safe outputs" >&2
	exit 1
}
expected_digest=$(awk -F= '$1 == "iso_sha256" {print $2}' "$manifest")
expected_size=$(awk -F= '$1 == "iso_size" {print $2}' "$manifest")
if command -v sha256sum >/dev/null 2>&1; then
	actual_digest=$(sha256sum "$output" | awk '{print $1}')
else
	actual_digest=$(shasum -a 256 "$output" | awk '{print $1}')
fi
actual_size=$(wc -c <"$output" | tr -d '[:space:]')
[[ $expected_digest == "$actual_digest" && $expected_size == "$actual_size" ]] || {
	echo "error: live ISO differs after publication" >&2
	exit 1
}
echo "verified authenticated live ISO: $output"
