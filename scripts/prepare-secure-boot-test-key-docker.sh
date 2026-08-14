#!/usr/bin/env bash

set -euo pipefail

if (( $# != 1 )); then
	echo "Usage: scripts/prepare-secure-boot-test-key-docker.sh OUTPUT_DIRECTORY" >&2
	exit 2
fi

output=$1
[[ ! -e $output ]] || {
	echo "error: output already exists: $output" >&2
	exit 1
}
[[ $(docker context show) == orbstack ]] || {
	echo "error: Docker context must be orbstack" >&2
	exit 1
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_name=$(basename -- "$output")
[[ $output_name =~ ^[A-Za-z0-9._-]+$ ]] || {
	echo "error: unsafe output directory name: $output_name" >&2
	exit 1
}

runner_image=volatoo-qemu-runner:1
docker build --tag "$runner_image" "$repo_root/scripts/qemu-container"
mkdir "$output"
output=$(cd -- "$output" && pwd)
docker run --rm --network none \
	--env "HOST_UID=$(id -u)" \
	--env "HOST_GID=$(id -g)" \
	--mount "type=bind,src=$output,dst=/output" \
	--entrypoint /bin/bash \
	"$runner_image" \
	-c '
		set -euo pipefail
		destination=/output
		openssl pkey \
			-in /usr/share/ovmf/PkKek-1-snakeoil.key \
			-passin pass:snakeoil \
			-out "$destination/db.key" >/dev/null
		chmod 0600 "$destination/db.key"
		install -m 0644 /usr/share/ovmf/PkKek-1-snakeoil.pem "$destination/db.crt"
		sha256sum "$destination/db.key" "$destination/db.crt" >"$destination/SHA256SUMS"
		chown -R "$HOST_UID:$HOST_GID" "$destination"
	'

echo "prepared OVMF snakeoil Secure Boot test key: $output"
