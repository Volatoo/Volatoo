#!/usr/bin/env bash

set -euo pipefail

usage() {
	cat <<'EOF'
Usage: scripts/validate-kernel-config.sh CONFIG [FRAGMENT]

Verify that a generated Linux kernel CONFIG contains every setting from the
Volatoo amd64 baseline at the requested built-in value. FRAGMENT defaults to
kernel/config/amd64.fragment.
EOF
}

if (( $# == 1 )) && [[ $1 == -h || $1 == --help ]]; then
	usage
	exit 0
fi

if (( $# < 1 || $# > 2 )); then
	usage >&2
	exit 2
fi

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
config_path=$1
fragment_path=${2:-"$repo_root/kernel/config/amd64.fragment"}

if [[ ! -f $config_path ]]; then
	echo "error: kernel config does not exist: $config_path" >&2
	exit 1
fi
if [[ ! -f $fragment_path ]]; then
	echo "error: kernel fragment does not exist: $fragment_path" >&2
	exit 1
fi

checked=0
failed=0
while IFS= read -r requirement || [[ -n $requirement ]]; do
	case $requirement in
		CONFIG_*=y | CONFIG_*=m)
			symbol=${requirement%%=*}
			;;
		'# CONFIG_'*' is not set')
			symbol=${requirement#\# }
			symbol=${symbol% is not set}
			;;
		'' | '#'*)
			continue
			;;
		*)
			echo "error: unsupported fragment line: $requirement" >&2
			exit 1
			;;
	esac

	checked=$((checked + 1))
	actual=$(grep -E -m 1 \
		"^${symbol}=(y|m)$|^# ${symbol} is not set$" \
		"$config_path" || true)
	if [[ $actual != "$requirement" ]]; then
		[[ -n $actual ]] || actual="$symbol is absent"
		printf 'error: required %-35s found %s\n' \
			"$requirement" "$actual" >&2
		failed=$((failed + 1))
	fi
done <"$fragment_path"

if (( checked == 0 )); then
	echo "error: kernel fragment contains no requirements" >&2
	exit 1
fi
if (( failed > 0 )); then
	echo "kernel config validation failed: $failed of $checked requirements unmet" >&2
	exit 1
fi

echo "kernel config validation passed: $checked requirements satisfied"
