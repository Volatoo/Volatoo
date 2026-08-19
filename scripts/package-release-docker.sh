#!/usr/bin/env bash

set -euo pipefail

if (( $# != 3 )); then
	cat >&2 <<'EOF'
Usage: scripts/package-release-docker.sh \
  OPENRC.img SYSTEMD.img OUTPUT_DIRECTORY

Reproduce the legacy developer-preview bundle from two release-media v2 disks.
Formal releases use Volatoo/releng and must not include install-volatoo.sh.
OUTPUT_DIRECTORY must not exist.
EOF
	exit 2
fi

openrc=$1
systemd=$2
output=$3
for variable in openrc systemd; do
	image=${!variable}
	manifest=$image.manifest
	[[ -f $image && ! -L $image && -f $manifest && ! -L $manifest ]] || {
		echo "error: $variable image and manifest must be regular non-symlink files" >&2
		exit 1
	}
	printf -v "$variable" '%s/%s' \
		"$(cd -- "$(dirname -- "$image")" && pwd)" "$(basename -- "$image")"
done
[[ ! -e $output && ! -L $output ]] || {
	echo "error: release output already exists or is a symlink: $output" >&2
	exit 1
}
output_parent=$(cd -- "$(dirname -- "$output")" && pwd)
output_name=$(basename -- "$output")
[[ $output_name =~ ^[A-Za-z0-9._-]+$ ]] || {
	echo "error: unsafe release output directory name: $output_name" >&2
	exit 1
}
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
handbook=$repo_root/docs/handbook.md
installer=$repo_root/scripts/install-volatoo.sh
[[ -f $handbook && ! -L $handbook && -f $installer && ! -L $installer ]] || {
	echo "error: release handbook or installer is missing or unsafe" >&2
	exit 1
}

staging=$(mktemp -d "$output_parent/.${output_name}.staging.XXXXXX")
output=$(cd -- "$staging" && pwd)
cleanup()
{
	if [[ -n ${staging:-} && -d $staging ]]; then
		echo "error: incomplete release staging retained for inspection: $staging" >&2
	fi
}
trap cleanup EXIT
image=volatoo-release-packager:0.1-dev
docker build \
	--platform linux/amd64 \
	--tag "$image" \
	--file "$repo_root/scripts/publication-container/Dockerfile" \
	"$repo_root"
docker run --rm --network none \
	--platform linux/amd64 \
	--env "HOST_UID=$(id -u)" \
	--env "HOST_GID=$(id -g)" \
	--env "OPENRC_NAME=$(basename -- "$openrc")" \
	--env "SYSTEMD_NAME=$(basename -- "$systemd")" \
	--mount "type=bind,src=$openrc,dst=/input/openrc.img,readonly" \
	--mount "type=bind,src=$openrc.manifest,dst=/input/openrc.img.manifest,readonly" \
	--mount "type=bind,src=$systemd,dst=/input/systemd.img,readonly" \
	--mount "type=bind,src=$systemd.manifest,dst=/input/systemd.img.manifest,readonly" \
	--mount "type=bind,src=$handbook,dst=/input/INSTALL.md,readonly" \
	--mount "type=bind,src=$installer,dst=/input/install-volatoo.sh,readonly" \
	--mount "type=bind,src=$output,dst=/output" \
	"$image"

[[ -f $output/SHA256SUMS && ! -L $output/SHA256SUMS ]] || {
	echo "error: release packager did not publish SHA256SUMS" >&2
	exit 1
}
final=$output_parent/$output_name
mv "$output" "$final"
staging=
trap - EXIT
output=$final
echo "packaged release assets: $output"
