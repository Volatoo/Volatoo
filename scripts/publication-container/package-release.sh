#!/usr/bin/env bash

set -euo pipefail

host_uid=${HOST_UID:?missing HOST_UID}
host_gid=${HOST_GID:?missing HOST_GID}
openrc_name=${OPENRC_NAME:?missing OPENRC_NAME}
systemd_name=${SYSTEMD_NAME:?missing SYSTEMD_NAME}
[[ $openrc_name =~ ^[A-Za-z0-9._-]+\.img$ && \
	$systemd_name =~ ^[A-Za-z0-9._-]+\.img$ ]] || {
	echo "error: unsafe release disk name" >&2
	exit 1
}

for input in \
	/input/openrc.img \
	/input/openrc.img.manifest \
	/input/systemd.img \
	/input/systemd.img.manifest \
	/input/INSTALL.md \
	/input/install-volatoo.sh
do
	[[ -f $input && ! -L $input ]] || {
		echo "error: release packaging input is missing or unsafe: $input" >&2
		exit 1
	}
done
[[ -d /output && ! -L /output ]] || {
	echo "error: release output directory is missing or unsafe" >&2
	exit 1
}
if find /output -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
	echo "error: release output directory must be empty" >&2
	exit 1
fi

manifest_value()
{
	local manifest=$1
	local key=$2
	awk -F= -v key="$key" '
		$1 == key { count++; value=substr($0, length(key) + 2) }
		END { if (count != 1) exit 1; print value }
	' "$manifest"
}

validate_manifest()
{
	local image=$1
	local manifest=$2
	local init_system=$3
	local disk_name=$4
	local digest_name digest_value secure_boot secure_boot_cert uki
	[[ $(manifest_value "$manifest" schema) == org.volatoo.release-media/v2 && \
		$(manifest_value "$manifest" channel) == v0.1-dev && \
		$(manifest_value "$manifest" init_system) == "$init_system" && \
		$(manifest_value "$manifest" disk_file) == "$disk_name" ]] || {
		echo "error: $init_system release manifest identity is invalid" >&2
		exit 1
	}
	[[ $(manifest_value "$manifest" disk_size) == "$(stat -c %s "$image")" && \
		$(manifest_value "$manifest" disk_sha256) == \
		"$(sha256sum "$image" | awk '{print $1}')" ]] || {
		echo "error: $init_system release disk differs from its manifest" >&2
		exit 1
	}
	for digest_name in kernel_sha256 initramfs_sha256 rootfs_sha256 state_sha256; do
		digest_value=$(manifest_value "$manifest" "$digest_name")
		[[ $digest_value =~ ^[0-9a-f]{64}$ ]] || {
			echo "error: invalid $digest_name in $init_system manifest" >&2
			exit 1
		}
	done
	secure_boot=$(manifest_value "$manifest" secure_boot)
	secure_boot_cert=$(manifest_value "$manifest" secure_boot_cert_sha256)
	uki=$(manifest_value "$manifest" uki_sha256)
	if [[ $secure_boot == yes ]]; then
		[[ $secure_boot_cert =~ ^[0-9a-f]{64}$ && $uki =~ ^[0-9a-f]{64}$ ]] || {
			echo "error: invalid Secure Boot provenance in $init_system manifest" >&2
			exit 1
		}
	elif [[ $secure_boot == no ]]; then
		[[ $secure_boot_cert == none && $uki == none ]] || {
			echo "error: unsigned $init_system manifest claims Secure Boot inputs" >&2
			exit 1
		}
	else
		echo "error: invalid secure_boot in $init_system manifest" >&2
		exit 1
	fi
}

package_disk()
{
	local image=$1
	local manifest=$2
	local init_system=$3
	local disk_name=$4
	local archive=/output/$disk_name.zst
	local actual expected
	validate_manifest "$image" "$manifest" "$init_system" "$disk_name"
	install -m 0644 "$manifest" "/output/$disk_name.manifest"
	zstd -19 -T0 --no-progress "$image" -o "$archive"
	zstd -t --no-progress "$archive"
	actual=$(zstd -dc --no-progress "$archive" | sha256sum | awk '{print $1}')
	expected=$(manifest_value "$manifest" disk_sha256)
	[[ $actual == "$expected" ]] || {
		echo "error: compressed $init_system disk does not round-trip" >&2
		exit 1
	}
}

install -m 0644 /input/INSTALL.md /output/INSTALL.md
install -m 0755 /input/install-volatoo.sh /output/install-volatoo.sh
package_disk \
	/input/openrc.img /input/openrc.img.manifest openrc "$openrc_name"
package_disk \
	/input/systemd.img /input/systemd.img.manifest systemd "$systemd_name"

(
	cd /output
	sha256sum \
		INSTALL.md \
		install-volatoo.sh \
		"$openrc_name.manifest" \
		"$openrc_name.zst" \
		"$systemd_name.manifest" \
		"$systemd_name.zst" \
		>SHA256SUMS
	sha256sum -c SHA256SUMS
)
chown -R "$host_uid:$host_gid" /output
echo "packaged release assets in /output"
