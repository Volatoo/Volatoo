#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage:
  scripts/build-catalyst-squashfs.sh [OPTIONS] OUTPUT
  scripts/build-catalyst-squashfs.sh --validate-only

Build an amd64 Volatoo minimal SquashFS with Catalyst in Docker.

Required build options:
  --stage3 PATH       Official Gentoo amd64 stage3 archive matching --init-system
  --snapshot PATH     Matching Gentoo Catalyst repository snapshot (.sqfs)
  --snapshot-id ID    Snapshot treeish used in gentoo-ID.sqfs
  --trust-key PATH    Install a trusted signify public key; repeat for rotation

Other options:
  --init-system NAME  Select openrc or systemd (default: openrc)
  --version STAMP     Image version stamp (default: current UTC date)
  --work-volume NAME  Docker volume for Catalyst work/cache
                      (defaults: volatoo-catalyst-work for OpenRC,
                      volatoo-catalyst-work-systemd for systemd)
  --validate-only     Build the builder and validate the rendered spec only
  -h, --help          Show this help

Environment:
  VOLATOO_CATALYST_IMAGE    Builder image tag
  VOLATOO_GENTOO_IMAGE     Builder base stage3 OCI image
  VOLATOO_PORTAGE_IMAGE    Builder Portage OCI image
  VOLATOO_CATALYST_VERSION Catalyst package version
  VOLATOO_CATALYST_VOLUME  Default Catalyst work volume
  VOLATOO_BUILD_JOBS       Catalyst emerge jobs (default: host CPU count)
EOF
}

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
stage3_path=
snapshot_path=
snapshot_id=
declare -a trust_keys=()
trust_key_count=0
init_system=openrc
version_stamp=$(date -u +%Y%m%d)
work_volume=
output_path=
validate_only=no

while (( $# > 0 )); do
	case $1 in
		--stage3)
			(( $# >= 2 )) || { echo "error: --stage3 requires a path" >&2; exit 2; }
			stage3_path=$2
			shift 2
			;;
		--snapshot)
			(( $# >= 2 )) || { echo "error: --snapshot requires a path" >&2; exit 2; }
			snapshot_path=$2
			shift 2
			;;
		--snapshot-id)
			(( $# >= 2 )) || { echo "error: --snapshot-id requires a value" >&2; exit 2; }
			snapshot_id=$2
			shift 2
			;;
		--trust-key)
			(( $# >= 2 )) || { echo "error: --trust-key requires a path" >&2; exit 2; }
			trust_keys+=("$2")
			trust_key_count=$((trust_key_count + 1))
			shift 2
			;;
		--init-system)
			(( $# >= 2 )) || { echo "error: --init-system requires a value" >&2; exit 2; }
			init_system=$2
			shift 2
			;;
		--version)
			(( $# >= 2 )) || { echo "error: --version requires a value" >&2; exit 2; }
			version_stamp=$2
			shift 2
			;;
		--work-volume)
			(( $# >= 2 )) || { echo "error: --work-volume requires a name" >&2; exit 2; }
			work_volume=$2
			shift 2
			;;
		--validate-only)
			validate_only=yes
			shift
			;;
		-h|--help)
			usage
			exit
			;;
		-*)
			echo "error: unknown option: $1" >&2
			usage >&2
			exit 2
			;;
		*)
			if [[ -n $output_path ]]; then
				echo "error: only one output path may be specified" >&2
				exit 2
			fi
			output_path=$1
			shift
			;;
	esac
done

if [[ $init_system != openrc && $init_system != systemd ]]; then
	echo "error: --init-system must be openrc or systemd" >&2
	exit 2
fi
if [[ -z $work_volume ]]; then
	if [[ -n ${VOLATOO_CATALYST_VOLUME:-} ]]; then
		work_volume=$VOLATOO_CATALYST_VOLUME
	elif [[ $init_system == openrc ]]; then
		# Preserve the existing OpenRC cache volume.
		work_volume=volatoo-catalyst-work
	else
		work_volume=volatoo-catalyst-work-systemd
	fi
fi

if ! [[ $version_stamp =~ ^[A-Za-z0-9._+-]+$ ]]; then
	echo "error: version stamp contains unsupported characters" >&2
	exit 1
fi
if [[ -n $snapshot_id ]] && ! [[ $snapshot_id =~ ^[A-Za-z0-9._+-]+$ ]]; then
	echo "error: snapshot ID contains unsupported characters" >&2
	exit 1
fi
if ! [[ $work_volume =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
	echo "error: Docker work volume contains unsupported characters" >&2
	exit 1
fi
if (( trust_key_count > 0 )); then
	for trust_key in "${trust_keys[@]}"; do
		[[ -f $trust_key && ! -L $trust_key ]] || {
			echo "error: trusted key is missing or unsafe: $trust_key" >&2
			exit 1
		}
	done
fi

if [[ $validate_only = no ]]; then
	[[ -n $stage3_path ]] || { echo "error: --stage3 is required" >&2; exit 2; }
	[[ -n $snapshot_path ]] || { echo "error: --snapshot is required" >&2; exit 2; }
	[[ -n $snapshot_id ]] || { echo "error: --snapshot-id is required" >&2; exit 2; }
	[[ -n $output_path ]] || output_path=$repo_root/out/volatoo-minimal-${init_system}-${version_stamp}.squashfs
	[[ -f $stage3_path ]] || { echo "error: stage3 not found: $stage3_path" >&2; exit 1; }
	[[ -f $snapshot_path ]] || { echo "error: snapshot not found: $snapshot_path" >&2; exit 1; }
else
	snapshot_id=${snapshot_id:-validate}
fi

if ! command -v docker >/dev/null 2>&1; then
	echo "error: docker is not installed" >&2
	exit 1
fi
if ! docker info >/dev/null 2>&1; then
	echo "error: the Docker daemon is not available" >&2
	exit 1
fi

if command -v getconf >/dev/null 2>&1; then
	default_jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
else
	default_jobs=1
fi
build_jobs=${VOLATOO_BUILD_JOBS:-$default_jobs}
if ! [[ $build_jobs =~ ^[1-9][0-9]*$ ]]; then
	echo "error: VOLATOO_BUILD_JOBS must be a positive integer" >&2
	exit 1
fi

builder_image=${VOLATOO_CATALYST_IMAGE:-volatoo-catalyst:4.1.1-r1}
gentoo_image=${VOLATOO_GENTOO_IMAGE:-gentoo/stage3@sha256:b5317fd2127e15ace5ff7a2c8aab1ed37a22736a8218546f3b00b4d94b78e500}
portage_image=${VOLATOO_PORTAGE_IMAGE:-gentoo/portage@sha256:6c49dbf51f9e52e3edeb43ca83e79025394b0a9b4c6cab1ed2b2f629e05c78e8}
catalyst_version=${VOLATOO_CATALYST_VERSION:-4.1.1-r1}

runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-catalyst-config.XXXXXX")
cleanup() {
	rm -rf -- "$runtime_dir"
}
trap cleanup EXIT

mkdir -p "$runtime_dir/overlay/usr/sbin" \
	"$runtime_dir/overlay/usr/bin" \
	"$runtime_dir/overlay/usr/libexec" \
	"$runtime_dir/overlay/usr/libexec/volatoo-update" \
	"$runtime_dir/overlay/etc/volatoo"
cp -R "$repo_root/image/catalyst/overlay/." "$runtime_dir/overlay/"
cp "$repo_root/persist/volatoo-persist" \
	"$runtime_dir/overlay/usr/sbin/volatoo-persist"
cp "$repo_root/persist/volatoo-identity" \
	"$runtime_dir/overlay/usr/sbin/volatoo-identity"
cp "$repo_root/persist/volatoo-persist-early" \
	"$runtime_dir/overlay/usr/libexec/volatoo-persist-early"
cp "$repo_root/update/volatoo-update-view" \
	"$runtime_dir/overlay/usr/libexec/volatoo-update-view"
update_tools=(
	volatoo-acquire
	volatoo-activate
	volatoo-engine
	volatoo-generation
	volatoo-layer
	volatoo-manifest
	volatoo-plan
)
for update_tool in "${update_tools[@]}"; do
	cp "$repo_root/update/$update_tool" \
		"$runtime_dir/overlay/usr/libexec/volatoo-update/$update_tool"
	chmod 0755 \
		"$runtime_dir/overlay/usr/libexec/volatoo-update/$update_tool"
	ln -s "../libexec/volatoo-update/$update_tool" \
		"$runtime_dir/overlay/usr/bin/$update_tool"
done
ln -s ../libexec/volatoo-update-view \
	"$runtime_dir/overlay/usr/bin/volatoo-update-view"
if (( trust_key_count > 0 )); then
	mkdir -p "$runtime_dir/overlay/etc/volatoo/trusted.d"
	for trust_key in "${trust_keys[@]}"; do
		if command -v sha256sum >/dev/null 2>&1; then
			key_checksum=$(sha256sum "$trust_key")
		else
			key_checksum=$(shasum -a 256 "$trust_key")
		fi
		key_digest=${key_checksum%% *}
		key_destination=$runtime_dir/overlay/etc/volatoo/trusted.d/$key_digest.pub
		if [[ -e $key_destination ]]; then
			cmp -s "$trust_key" "$key_destination" || {
				echo "error: trusted key digest collision: $trust_key" >&2
				exit 1
			}
		else
			install -m 0644 "$trust_key" "$key_destination"
		fi
	done
fi
chmod 0755 \
	"$runtime_dir/overlay/usr/sbin/volatoo-persist" \
	"$runtime_dir/overlay/usr/sbin/volatoo-identity" \
	"$runtime_dir/overlay/usr/libexec/volatoo-persist-early" \
	"$runtime_dir/overlay/usr/libexec/volatoo-update-view"
printf '%s\n' "$init_system" \
	>"$runtime_dir/overlay/etc/volatoo/init-system"
if [[ $init_system == openrc ]]; then
	mkdir -p "$runtime_dir/overlay/etc/init.d"
	cp "$repo_root/persist/volatoo-persist.initd" \
		"$runtime_dir/overlay/etc/init.d/volatoo-persist"
	chmod 0755 "$runtime_dir/overlay/etc/init.d/volatoo-persist"
else
	mkdir -p "$runtime_dir/overlay/usr/lib/systemd/system"
	cp "$repo_root/persist/volatoo-persist.service" \
		"$runtime_dir/overlay/usr/lib/systemd/system/volatoo-persist.service"
	chmod 0644 \
		"$runtime_dir/overlay/usr/lib/systemd/system/volatoo-persist.service"
fi
cp "$repo_root/image/catalyst/finalize.sh" "$runtime_dir/finalize.sh"
chmod 0755 "$runtime_dir/finalize.sh"

source_name=stage3-amd64-${init_system}-validate.tar.xz
if [[ $validate_only = no ]]; then
	source_name=$(basename -- "$stage3_path")
	if ! [[ $source_name =~ ^stage3-amd64-${init_system}-[0-9]{8}T[0-9]{6}Z\.tar\.xz$ ]]; then
		echo "error: stage3 filename does not match $init_system target: $source_name" >&2
		exit 1
	fi
fi

if [[ $init_system == openrc ]]; then
	profile=default/linux/amd64/23.0
	rel_type=volatoo
	init_settings="stage4/rcadd: dhcpcd|default sshd|default sysklogd|default volatoo-persist|default"
else
	profile=default/linux/amd64/23.0/systemd
	rel_type=volatoo-systemd
	init_settings=
fi

rendered_packages=$runtime_dir/packages
for package_file in \
	"$repo_root/image/catalyst/package-sets/minimal" \
	"$repo_root/image/catalyst/package-sets/minimal-${init_system}"; do
	while IFS= read -r package || [[ -n $package ]]; do
		package=${package%%#*}
		package=${package#"${package%%[![:space:]]*}"}
		package=${package%"${package##*[![:space:]]}"}
		[[ -n $package ]] || continue
		if [[ $package == *[[:space:]]* ]] \
			|| ! [[ $package =~ ^[A-Za-z0-9+_.@/-]+$ ]]; then
			echo "error: invalid package atom in $package_file: $package" >&2
			exit 1
		fi
		printf '%s\n' "$package" >> "$rendered_packages"
	done < "$package_file"
done
[[ -s $rendered_packages ]] || { echo "error: minimal package set is empty" >&2; exit 1; }

awk \
	-v version="$version_stamp" \
	-v snapshot="$snapshot_id" \
	-v source="$source_name" \
	-v profile="$profile" \
	-v rel_type="$rel_type" \
	-v init_settings="$init_settings" \
	-v packages="$rendered_packages" '
		$0 == "@PACKAGES@" {
			while ((getline package < packages) > 0)
				print "  " package
			close(packages)
			next
		}
		$0 == "@INIT_SETTINGS@" {
			if (init_settings != "")
				print init_settings
			next
		}
		{
			gsub(/@VERSION@/, version)
			gsub(/@SNAPSHOT@/, snapshot)
			gsub(/@SOURCE@/, source)
			gsub(/@PROFILE@/, profile)
			gsub(/@REL_TYPE@/, rel_type)
			print
		}
	' "$repo_root/image/catalyst/specs/minimal.spec.in" \
	> "$runtime_dir/volatoo.spec"

cat > "$runtime_dir/catalyst.conf" <<EOF
digests = ["sha256"]
jobs = ${build_jobs}
options = ["autoresume", "bindist", "pkgcache"]
storedir = "/work/catalyst"
target_distdir = "/work/catalyst/cache/distfiles"
target_logdir = "/work/catalyst/logs"
target_pkgdir = "/work/catalyst/cache/binpkgs"
EOF

docker build \
	--platform linux/amd64 \
	--progress plain \
	--build-arg "CATALYST_VERSION=$catalyst_version" \
	--build-arg "GENTOO_IMAGE=$gentoo_image" \
	--build-arg "PORTAGE_IMAGE=$portage_image" \
	--tag "$builder_image" \
	--file "$repo_root/image/catalyst/Dockerfile" \
	"$repo_root"

if [[ $validate_only = yes ]]; then
	docker run --rm \
		--platform linux/amd64 \
		--env VOLATOO_VALIDATE_ONLY=yes \
		--env "VOLATOO_INIT_SYSTEM=$init_system" \
		--volume "$runtime_dir:/config:ro" \
		"$builder_image"
	exit
fi

stage3_path=$(cd -- "$(dirname -- "$stage3_path")" && pwd)/$(basename -- "$stage3_path")
snapshot_path=$(cd -- "$(dirname -- "$snapshot_path")" && pwd)/$(basename -- "$snapshot_path")

docker volume create "$work_volume" >/dev/null

docker run --rm \
	--privileged \
	--platform linux/amd64 \
	--env "VOLATOO_INIT_SYSTEM=$init_system" \
	--env "VOLATOO_REL_TYPE=$rel_type" \
	--env "VOLATOO_SOURCE_NAME=$source_name" \
	--env "VOLATOO_SNAPSHOT_ID=$snapshot_id" \
	--volume "$runtime_dir:/config:ro" \
	--volume "$work_volume:/work" \
	--volume "$stage3_path:/inputs/stage3:ro" \
	--volume "$snapshot_path:/inputs/snapshot:ro" \
	"$builder_image"

mkdir -p "$(dirname -- "$output_path")"
output_path=$(cd -- "$(dirname -- "$output_path")" && pwd)/$(basename -- "$output_path")
temporary_output=$output_path.tmp.$$
artifact=/work/catalyst/builds/${rel_type}/stage4-amd64-${version_stamp}.squashfs
docker run --rm \
	--platform linux/amd64 \
	--user "$(id -u):$(id -g)" \
	--entrypoint cp \
	--volume "$work_volume:/work:ro" \
	--volume "$(dirname -- "$output_path"):/export" \
	"$builder_image" \
	"$artifact" "/export/$(basename -- "$temporary_output")"
[[ -f $temporary_output ]] \
	|| { echo "error: Catalyst did not create $artifact" >&2; exit 1; }
mv -f "$temporary_output" "$output_path"

if command -v sha256sum >/dev/null 2>&1; then
	checksum_output=$(sha256sum "$output_path")
else
	checksum_output=$(shasum -a 256 "$output_path")
fi
checksum=${checksum_output%% *}
printf '%s  %s\n' "$checksum" "$(basename -- "$output_path")" \
	> "$output_path.sha256"

echo "built $output_path"
echo "wrote $output_path.sha256"
