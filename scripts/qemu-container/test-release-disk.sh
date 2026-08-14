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
rejection_timeout_seconds=${VOLATOO_RELEASE_REJECTION_TIMEOUT:-45}
expect_secure_rejection=${VOLATOO_RELEASE_EXPECT_SECURE_REJECTION:-no}
ssh_key=${VOLATOO_RELEASE_SSH_KEY:-}
[[ -f $disk && ! -L $disk ]] || {
	echo "error: release disk is missing or unsafe: $disk" >&2
	exit 1
}
[[ $init_system == openrc || $init_system == systemd ]] || {
	echo "error: init system must be openrc or systemd" >&2
	exit 2
}
[[ $firmware == bios || $firmware == uefi || $firmware == uefi-secure ]] || {
	echo "error: firmware must be bios, uefi, or uefi-secure" >&2
	exit 2
}
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
	echo "error: VOLATOO_RELEASE_QEMU_TIMEOUT must be a positive integer" >&2
	exit 2
}
[[ $rejection_timeout_seconds =~ ^[1-9][0-9]*$ ]] || {
	echo "error: VOLATOO_RELEASE_REJECTION_TIMEOUT must be a positive integer" >&2
	exit 2
}
[[ $expect_secure_rejection == yes || $expect_secure_rejection == no ]] || {
	echo "error: VOLATOO_RELEASE_EXPECT_SECURE_REJECTION must be yes or no" >&2
	exit 2
}
if [[ $expect_secure_rejection == yes && $firmware != uefi-secure ]]; then
	echo "error: secure rejection can only be expected with uefi-secure" >&2
	exit 2
fi
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
machine=accel=tcg
if [[ $firmware == uefi ]]; then
	vars=$(mktemp)
	cp /usr/share/OVMF/OVMF_VARS.fd "$vars"
	firmware_args=(
		-drive "if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd"
		-drive "if=pflash,format=raw,file=$vars"
	)
elif [[ $firmware == uefi-secure ]]; then
	vars=$(mktemp)
	cp /usr/share/OVMF/OVMF_VARS_4M.snakeoil.fd "$vars"
	machine=q35,smm=on,accel=tcg
	firmware_args=(
		-global "driver=cfi.pflash01,property=secure,value=on"
		-drive "if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"
		-drive "if=pflash,format=raw,unit=1,file=$vars"
	)
fi

qemu-system-x86_64 \
	-machine "$machine" \
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

if [[ $expect_secure_rejection == yes ]]; then
	rejection_deadline=$((SECONDS + rejection_timeout_seconds))
	while (( SECONDS < rejection_deadline )); do
		if grep -Fq '[volatoo] initramfs started' "$log" ||
			grep -Eq '(^|[^[:alpha:]])login: ' "$log"; then
			echo "error: tampered Secure Boot image reached Volatoo userspace" >&2
			tail -160 "$log" >&2
			exit 1
		fi
		if ! kill -0 "$qemu_pid" 2>/dev/null; then
			break
		fi
		sleep 0.5
	done
	if ! grep -Eiq 'security violation|access denied|image failed to verify' "$log"; then
		echo "error: Secure Boot firmware did not report signature rejection" >&2
		tail -160 "$log" >&2
		exit 1
	fi
	echo "Volatoo tampered release disk rejected by uefi-secure"
	exit 0
fi

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
