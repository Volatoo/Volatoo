#!/usr/bin/env bash

set -euo pipefail

if (( $# != 3 )); then
	echo "Usage: test-live-iso.sh ISO INIT_SYSTEM FIRMWARE" >&2
	exit 2
fi
iso=$1
init_system=$2
firmware=$3
timeout_seconds=${VOLATOO_LIVE_QEMU_TIMEOUT:-240}
[[ -f $iso && ! -L $iso ]] || { echo "error: live ISO is missing or unsafe" >&2; exit 1; }
[[ $init_system == openrc || $init_system == systemd ]] || { echo "error: invalid init system" >&2; exit 2; }
[[ $firmware == bios || $firmware == uefi ]] || { echo "error: invalid firmware" >&2; exit 2; }
[[ $timeout_seconds =~ ^[1-9][0-9]*$ ]] || { echo "error: invalid QEMU timeout" >&2; exit 2; }

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
	-m 4096 -smp 2 -nographic -no-reboot \
	"${firmware_args[@]}" \
	-drive "file=$iso,format=raw,media=cdrom,readonly=on" \
	-boot d \
	-net none \
	>"$log" 2>&1 &
qemu_pid=$!

deadline=$((SECONDS + timeout_seconds))
while (( SECONDS < deadline )); do
	if grep -Eq '(^|[^[:alpha:]])login: ' "$log"; then break; fi
	if ! kill -0 "$qemu_pid" 2>/dev/null; then
		echo "error: $firmware live ISO exited before the login prompt" >&2
		tail -160 "$log" >&2
		exit 1
	fi
	sleep 0.5
done
if ! grep -Eq '(^|[^[:alpha:]])login: ' "$log"; then
	echo "error: $firmware live ISO did not reach a login prompt" >&2
	tail -160 "$log" >&2
	exit 1
fi
required_patterns=(
	'\[volatoo\] image device resolved: LABEL=VOLATOO_LIVE'
	'\[volatoo\] state partition not found; continuing without persistence'
	'\[volatoo\] SHA-256 verified in [0-9]+s'
	'\[volatoo\] immutable store overlay root ready'
)
case $init_system in
	openrc) required_patterns+=('OpenRC .* is starting up') ;;
	systemd) required_patterns+=('systemd\[[[:space:]]*1\]') ;;
esac
for pattern in "${required_patterns[@]}"; do
	if ! grep -Eq "$pattern" "$log"; then
		echo "error: $firmware live ISO log is missing: $pattern" >&2
		tail -160 "$log" >&2
		exit 1
	fi
done
echo "Volatoo $init_system live ISO passed $firmware boot"
