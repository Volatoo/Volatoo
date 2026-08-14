#!/usr/bin/env bash

set -euo pipefail

if (( $# != 3 )); then
	echo "Usage: test-release-disk.sh DISK INIT_SYSTEM FIRMWARE" >&2
	exit 2
fi

disk=$1
init_system=$2
firmware=$3
timeout_seconds=${VOLATOO_RELEASE_QEMU_TIMEOUT:-240}
ssh_key=${VOLATOO_RELEASE_SSH_KEY:-}
[[ -f $disk && ! -L $disk ]] || {
	echo "error: release disk is missing or unsafe: $disk" >&2
	exit 1
}
[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: init system must be openrc or systemd" >&2
	exit 2
}
[[ $firmware == bios || $firmware == uefi ]] || {
	echo "error: firmware must be bios or uefi" >&2
	exit 2
}
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
	echo "error: VOLATOO_RELEASE_QEMU_TIMEOUT must be a positive integer" >&2
	exit 2
}
if [[ -n $ssh_key && (! -f $ssh_key || -L $ssh_key) ]]; then
	echo "error: VOLATOO_RELEASE_SSH_KEY is missing or unsafe" >&2
	exit 1
fi

log=$(mktemp)
vars=
qemu_pid=
cleanup()
{
	if [[ -n $qemu_pid ]]; then
		kill "$qemu_pid" 2>/dev/null || true
		wait "$qemu_pid" 2>/dev/null || true
	fi
	rm -f -- "$log" "$vars"
}
trap cleanup EXIT

firmware_args=()
if [[ $firmware == uefi ]]; then
	vars=$(mktemp)
	cp /usr/share/OVMF/OVMF_VARS.fd "$vars"
	firmware_args=(
		-drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd"
		-drive "if=pflash,format=raw,file=$vars"
	)
fi

qemu-system-x86_64 \
	-machine accel=tcg \
	-m 4096 \
	-smp 2 \
	-nographic \
	-no-reboot \
	"${firmware_args[@]}" \
	-drive "file=$disk,format=raw,if=virtio,snapshot=on" \
	-netdev user,id=net0,hostfwd=tcp:127.0.0.1:2222-:22 \
	-device virtio-net-pci,netdev=net0 \
	>"$log" 2>&1 &
qemu_pid=$!

deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
	if grep -Eq '(^|[^[:alpha:]])login: ' "$log"; then
		break
	fi
	if ! kill -0 "$qemu_pid" 2>/dev/null; then
		echo "error: $firmware QEMU exited before the login prompt" >&2
		tail -160 "$log" >&2
		exit 1
	fi
	sleep 0.5
done
if ! grep -Eq '(^|[^[:alpha:]])login: ' "$log"; then
	echo "error: $firmware did not reach a login prompt in ${timeout_seconds}s" >&2
	tail -160 "$log" >&2
	exit 1
fi

required_patterns=(
	'\[volatoo\] image device resolved: LABEL=VOLATOO-SYSTEM'
	'\[volatoo\] state device resolved: LABEL=VOLATOO-STATE'
	'\[volatoo\] SHA-256 verified in [0-9]+s'
	'\[volatoo\] immutable store overlay root ready'
	'\[volatoo\] persistent machine identity ready'
)
case $init_system in
	openrc) required_patterns+=('OpenRC .* is starting up') ;;
	systemd) required_patterns+=('systemd\[[[:space:]]*1\]') ;;
esac
for pattern in "${required_patterns[@]}"; do
	if ! grep -Eq "$pattern" "$log"; then
		echo "error: $firmware boot log is missing: $pattern" >&2
		tail -160 "$log" >&2
		exit 1
	fi
done

if [[ -n $ssh_key ]]; then
	ssh_output=
	while (( SECONDS < deadline )); do
		if ssh_output=$(ssh \
			-o BatchMode=yes \
			-o ConnectTimeout=3 \
			-o LogLevel=ERROR \
			-o StrictHostKeyChecking=no \
			-o UserKnownHostsFile=/dev/null \
			-i "$ssh_key" \
			-p 2222 \
			volatoo@127.0.0.1 \
			'id -u; sudo -n true; for tool in signify volatoo-acquire volatoo-activate volatoo-engine volatoo-generation volatoo-layer volatoo-manifest volatoo-plan volatoo-update-view; do command -v "$tool" >/dev/null || exit 1; done; signify -h >/dev/null 2>&1; test $? -eq 1; find /etc/volatoo/trusted.d -type f -name "*.pub" -print -quit | grep -q .; volatoo-manifest --help >/dev/null; printf "volatoo-ssh-ready\\n"' 2>/dev/null)
		then
			break
		fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then break; fi
		sleep 1
	done
	if ! grep -Fxq volatoo-ssh-ready <<<"$ssh_output" ||
		! grep -Fxq 1000 <<<"$ssh_output"; then
		echo "error: $firmware key-only administrator SSH check failed" >&2
		tail -160 "$log" >&2
		exit 1
	fi
fi

echo "Volatoo $init_system release disk passed $firmware boot"
