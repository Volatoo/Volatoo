#!/usr/bin/env bash

set -euo pipefail

usage()
{
	cat <<'EOF'
Usage: scripts/tests/test-release-disk-reproducible-docker.sh \
  --init-system openrc|systemd \
  --kernel PATH --initramfs PATH --rootfs PATH --state PATH \
  [--secure-boot-key KEY.pem --secure-boot-cert CERT.pem] \
  [--evidence PATH]

Build the v0.1-dev release disk twice from the same pinned inputs in the
OrbStack Docker context and assert that both images are byte-identical. The
disk image and its SHA-256 are the reproducibility claim; the sidecar
manifests are allowed to differ only in the output filename they record.
When --evidence is given, the two digests and the build commands are written
there for audit.
EOF
}

init_system=
kernel=
initramfs=
rootfs=
state=
secure_boot_key=
secure_boot_cert=
evidence=
while (( $# > 0 )); do
	case $1 in
		--init-system|--kernel|--initramfs|--rootfs|--state|--secure-boot-key|--secure-boot-cert|--evidence)
			(( $# >= 2 )) || { echo "error: $1 requires a value" >&2; exit 2; }
			case $1 in
				--init-system) init_system=$2 ;;
				--kernel) kernel=$2 ;;
				--initramfs) initramfs=$2 ;;
				--rootfs) rootfs=$2 ;;
				--state) state=$2 ;;
				--secure-boot-key) secure_boot_key=$2 ;;
				--secure-boot-cert) secure_boot_cert=$2 ;;
				--evidence) evidence=$2 ;;
			esac
			shift 2
			;;
		-h|--help) usage; exit 0 ;;
		-*) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
		*) echo "error: unexpected positional argument: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: --init-system must be openrc or systemd" >&2
	exit 2
}
[[ -n $kernel && -n $initramfs && -n $rootfs && -n $state ]] || {
	echo "error: --kernel, --initramfs, --rootfs and --state are required" >&2
	exit 2
}
[[ -z $secure_boot_key && -z $secure_boot_cert ]] || {
	[[ -n $secure_boot_key && -n $secure_boot_cert ]] || {
		echo "error: --secure-boot-key and --secure-boot-cert are required together" >&2
		exit 2
	}
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
builder=$repo_root/scripts/build-release-disk-docker.sh
[[ -x $builder ]] || {
	echo "error: release builder is missing: $builder" >&2
	exit 1
}

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-reproducible.XXXXXX")
cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

build_args=(--init-system "$init_system" --kernel "$kernel" --initramfs "$initramfs" --rootfs "$rootfs" --state "$state")
if [[ -n $secure_boot_key ]]; then
	build_args+=(--secure-boot-key "$secure_boot_key" --secure-boot-cert "$secure_boot_cert")
fi

echo "building first image"
"$builder" "${build_args[@]}" "$work_dir/first.img"
echo "building second image"
"$builder" "${build_args[@]}" "$work_dir/second.img"

checksum_file()
{
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

first_sha256=$(checksum_file "$work_dir/first.img")
second_sha256=$(checksum_file "$work_dir/second.img")

echo "first image  SHA-256: $first_sha256"
echo "second image SHA-256: $second_sha256"

if [[ $first_sha256 != "$second_sha256" ]]; then
	echo "error: release disk is not bit-reproducible" >&2
	cmp -l "$work_dir/first.img" "$work_dir/second.img" 2>/dev/null | head -20 >&2 || true
	exit 1
fi

echo "release disk is bit-reproducible: two builds produced identical images"

if [[ -n $evidence ]]; then
	{
		echo "schema=org.volatoo.reproducibility/v1"
		echo "init_system=$init_system"
		echo "disk_sha256=$first_sha256"
		echo "kernel=$kernel"
		echo "initramfs=$initramfs"
		echo "rootfs=$rootfs"
		echo "state=$state"
		if [[ -n $secure_boot_key ]]; then
			echo "secure_boot=yes"
		else
			echo "secure_boot=no"
		fi
		echo "build_command=$builder ${build_args[*]} OUTPUT"
	} >"$evidence"
	echo "evidence written: $evidence"
fi
