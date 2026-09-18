#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-init-parity.XXXXXX")
fake_bin=$work_dir/bin
rendered=$work_dir/rendered
mkdir -p "$fake_bin" "$rendered"

cleanup()
{
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash

set -euo pipefail

case ${1:-} in
	context)
		[[ ${2:-} == show ]]
		echo orbstack
		exit 0
		;;
	info | build)
		exit 0
		;;
	run)
		shift
		init_system=
		config_dir=
		while (( $# > 0 )); do
			case $1 in
				--env)
					case $2 in
						VOLATOO_INIT_SYSTEM=*)
							init_system=${2#VOLATOO_INIT_SYSTEM=}
							;;
					esac
					shift 2
					;;
				--volume)
					case $2 in
						*:/config:ro)
							config_dir=${2%:/config:ro}
							;;
					esac
					shift 2
					;;
				*)
					shift
					;;
			esac
		done

		[[ -n $init_system && -n $config_dir ]]
		mkdir -p "$PARITY_RENDER_OUTPUT/$init_system"
		cp -R "$config_dir/." "$PARITY_RENDER_OUTPUT/$init_system/"
		exit 0
		;;
esac

exit 1
FAKE_DOCKER
chmod 0755 "$fake_bin/docker"

render()
{
	local init_system=$1
	PATH="$fake_bin:$PATH" \
	PARITY_RENDER_OUTPUT="$rendered" \
		"$repo_root/scripts/build-catalyst-squashfs.sh" \
		--init-system "$init_system" \
		--validate-only
}

render openrc
render systemd

openrc=$rendered/openrc
systemd=$rendered/systemd
[[ -d $openrc/overlay && -d $systemd/overlay ]] ||
	fail "the rendered overlays are missing"

# The shared persistence tools are init-agnostic and must be byte-identical.
for tool in \
	usr/sbin/volatoo-persist \
	usr/sbin/volatoo-identity \
	usr/libexec/volatoo-persist-early \
	usr/libexec/volatoo-update-view \
	usr/libexec/volatoo-firstboot-access; do
	cmp -s "$openrc/overlay/$tool" "$systemd/overlay/$tool" ||
		fail "shared tool differs between targets: $tool"
done
for tool in \
	volatoo-acquire \
	volatoo-activate \
	volatoo-engine \
	volatoo-generation \
	volatoo-layer \
	volatoo-manifest \
	volatoo-plan; do
	cmp -s \
		"$openrc/overlay/usr/libexec/volatoo-update/$tool" \
		"$systemd/overlay/usr/libexec/volatoo-update/$tool" ||
		fail "shared update tool differs between targets: $tool"
done

# Each target installs exactly one shutdown sync unit, and never the other's.
[[ -x $openrc/overlay/etc/init.d/volatoo-persist ]] ||
	fail "OpenRC target is missing /etc/init.d/volatoo-persist"
[[ ! -e $openrc/overlay/usr/lib/systemd/system/volatoo-persist.service ]] ||
	fail "OpenRC target must not install the systemd unit"
[[ -f $systemd/overlay/usr/lib/systemd/system/volatoo-persist.service ]] ||
	fail "systemd target is missing volatoo-persist.service"
[[ ! -e $systemd/overlay/etc/init.d/volatoo-persist ]] ||
	fail "systemd target must not install the OpenRC init script"

# The two units must invoke the same sync command.
grep -Fq '/usr/sbin/volatoo-persist sync' \
	"$openrc/overlay/etc/init.d/volatoo-persist" ||
	fail "OpenRC service does not run volatoo-persist sync"
grep -Fq 'ExecStop=/usr/sbin/volatoo-persist sync' \
	"$systemd/overlay/usr/lib/systemd/system/volatoo-persist.service" ||
	fail "systemd unit does not run volatoo-persist sync"

# The two units must guard on the same two conditions.
grep -Fq '/.volatoo/state/volatoo/layout-version' \
	"$openrc/overlay/etc/init.d/volatoo-persist" ||
	fail "OpenRC service is missing the state layout guard"
grep -Fq '/.volatoo/image-id' \
	"$openrc/overlay/etc/init.d/volatoo-persist" ||
	fail "OpenRC service is missing the image-id guard"
grep -Fq 'ConditionPathExists=/.volatoo/state/volatoo/layout-version' \
	"$systemd/overlay/usr/lib/systemd/system/volatoo-persist.service" ||
	fail "systemd unit is missing the state layout guard"
grep -Fq 'ConditionPathExists=/.volatoo/image-id' \
	"$systemd/overlay/usr/lib/systemd/system/volatoo-persist.service" ||
	fail "systemd unit is missing the image-id guard"

# The systemd unit must be ordered to stop before the filesystems unmount.
grep -Fq 'Before=umount.target' \
	"$systemd/overlay/usr/lib/systemd/system/volatoo-persist.service" ||
	fail "systemd unit is not ordered before umount.target"

# Each target must enable its unit: rcadd for OpenRC, wanted-by for systemd.
grep -Fq 'volatoo-persist|default' "$openrc/volatoo.spec" ||
	fail "OpenRC spec does not enable volatoo-persist in the default runlevel"
grep -Fq 'volatoo-persist' "$systemd/finalize.sh" ||
	fail "systemd finalize does not enable volatoo-persist"

# The init-system marker must match the target.
[[ $(cat "$openrc/overlay/etc/volatoo/init-system") == openrc ]] ||
	fail "OpenRC init-system marker is wrong"
[[ $(cat "$systemd/overlay/etc/volatoo/init-system") == systemd ]] ||
	fail "systemd init-system marker is wrong"

echo "OpenRC/systemd persistence and shutdown parity tests passed"
