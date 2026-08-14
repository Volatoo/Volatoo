#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-init-selection.XXXXXX")
fake_bin=$work_dir/bin
mkdir -p "$fake_bin"

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

expect_failure()
{
	expected=$1
	shift
	set +e
	output=$("$@" 2>&1)
	status=$?
	set -e
	[[ $status -eq 2 || $status -eq 1 ]] ||
		fail "expected failure, got status $status: $*"
	grep -Fq -- "$expected" <<<"$output" ||
		fail "expected '$expected' in: $output"
}

cat >"$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash

set -euo pipefail

case ${1:-} in
	info | build)
		exit 0
		;;
	run)
		shift
		init_system=
		rel_type=
		config_dir=
		while (( $# > 0 )); do
			case $1 in
				--env)
					case $2 in
						VOLATOO_INIT_SYSTEM=*)
							init_system=${2#VOLATOO_INIT_SYSTEM=}
							;;
						VOLATOO_REL_TYPE=*)
							rel_type=${2#VOLATOO_REL_TYPE=}
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
		[[ $(cat "$config_dir/overlay/etc/volatoo/init-system") == "$init_system" ]]
		case $init_system in
			openrc)
				[[ -z $rel_type || $rel_type == volatoo ]]
				grep -Fxq 'profile: default/linux/amd64/23.0' \
					"$config_dir/volatoo.spec"
				grep -Fxq 'rel_type: volatoo' "$config_dir/volatoo.spec"
				grep -Fxq \
					'source_subpath: volatoo/stage3-amd64-openrc-validate.tar.xz' \
					"$config_dir/volatoo.spec"
				grep -Fq 'stage4/rcadd:' "$config_dir/volatoo.spec"
				grep -Fq 'dhcpcd|default' "$config_dir/volatoo.spec"
				grep -Fq 'sshd|default' "$config_dir/volatoo.spec"
				grep -Fq '  app-admin/sysklogd' "$config_dir/volatoo.spec"
				[[ -x $config_dir/overlay/etc/init.d/volatoo-persist ]]
				grep -Fq '/usr/bin/sshd}' "$config_dir/finalize.sh"
				grep -Fq 'OpenRC sshd still references /usr/sbin/sshd' "$config_dir/finalize.sh"
				[[ ! -e $config_dir/overlay/usr/lib/systemd/system/volatoo-persist.service ]]
				;;
			systemd)
				[[ -z $rel_type || $rel_type == volatoo-systemd ]]
				grep -Fxq 'profile: default/linux/amd64/23.0/systemd' \
					"$config_dir/volatoo.spec"
				grep -Fxq 'rel_type: volatoo-systemd' \
					"$config_dir/volatoo.spec"
				grep -Fxq \
					'source_subpath: volatoo-systemd/stage3-amd64-systemd-validate.tar.xz' \
					"$config_dir/volatoo.spec"
				! grep -Fq 'stage4/rcadd:' "$config_dir/volatoo.spec"
				! grep -Fq 'app-admin/sysklogd' "$config_dir/volatoo.spec"
				grep -Fq '/usr/bin/sshd' "$config_dir/finalize.sh"
				grep -Fq 'systemd sshd units still reference /usr/sbin/sshd' "$config_dir/finalize.sh"
				[[ -f $config_dir/overlay/usr/lib/systemd/system/volatoo-persist.service ]]
				[[ ! -e $config_dir/overlay/etc/init.d/volatoo-persist ]]
				;;
			*)
				exit 1
				;;
		esac
		exit 0
		;;
esac

exit 1
FAKE_DOCKER
chmod 0755 "$fake_bin/docker"

for init_system in openrc systemd; do
	PATH="$fake_bin:$PATH" \
		"$repo_root/scripts/build-catalyst-squashfs.sh" \
		--init-system "$init_system" \
		--validate-only
done

expect_failure "--init-system must be openrc or systemd" \
	"$repo_root/scripts/fetch-gentoo-inputs.sh" \
	--init-system invalid "$work_dir/invalid-fetch"

mkdir "$work_dir/openrc-inputs"
printf '%s\n' "init-system=openrc" \
	>"$work_dir/openrc-inputs/.volatoo-gentoo-inputs"
expect_failure "input directory belongs to a different init target" \
	"$repo_root/scripts/fetch-gentoo-inputs.sh" \
	--init-system systemd \
	--metadata-only \
	"$work_dir/openrc-inputs"

printf '%s\n' "init-system=systemd" >"$work_dir/marker-target"
mkdir "$work_dir/symlinked-marker-inputs"
ln -s "$work_dir/marker-target" \
	"$work_dir/symlinked-marker-inputs/.volatoo-gentoo-inputs"
expect_failure "input directory belongs to a different init target" \
	"$repo_root/scripts/fetch-gentoo-inputs.sh" \
	--init-system systemd \
	--metadata-only \
	"$work_dir/symlinked-marker-inputs"

expect_failure "--init-system must be openrc or systemd" \
	"$repo_root/scripts/build-catalyst-squashfs.sh" \
	--init-system invalid --validate-only

touch "$work_dir/stage3-amd64-openrc-20260719T170103Z.tar.xz"
touch "$work_dir/gentoo-20260719.xz.sqfs"
expect_failure "stage3 filename does not match systemd target" \
	env PATH="$fake_bin:$PATH" \
	"$repo_root/scripts/build-catalyst-squashfs.sh" \
	--init-system systemd \
	--stage3 "$work_dir/stage3-amd64-openrc-20260719T170103Z.tar.xz" \
	--snapshot "$work_dir/gentoo-20260719.xz.sqfs" \
	--snapshot-id 20260719 \
	"$work_dir/output.squashfs"

echo "image init-system selection tests passed"
