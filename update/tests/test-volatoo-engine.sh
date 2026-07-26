#!/usr/bin/env bash

set -euo pipefail

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH='' cd -- "$script_dir/../.." && pwd)
engine="$repo_root/update/volatoo-engine"
fake_engine="$script_dir/fake-portage-engine.py"
context_example="$repo_root/update/examples/build-context-v1.json"
spec_example="$repo_root/update/examples/build-spec-v1.json"
target="$repo_root/update/examples/portage-engine-target-openrc-v1.json"
systemd_context_example="$repo_root/update/examples/build-context-systemd-v1.json"
systemd_target="$repo_root/update/examples/portage-engine-target-systemd-v1.json"
work_dir=$(mktemp -d)
server_pid=
context="$work_dir/build-context.json"
spec="$work_dir/build-spec.json"
systemd_context="$work_dir/build-context-systemd.json"
systemd_spec="$work_dir/build-spec-systemd.json"

cleanup() {
    if [[ -n $server_pid ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

wait_for_port() {
    local port_file=$1
    local _
    for _ in {1..100}; do
        if [[ -s $port_file ]]; then
            return
        fi
        sleep 0.05
    done
    echo "fake Portage Engine did not start" >&2
    exit 1
}

"$repo_root/update/volatoo-manifest" canonicalize "$context_example" >"$context"
"$repo_root/update/volatoo-manifest" canonicalize "$spec_example" >"$spec"
"$repo_root/update/volatoo-manifest" \
    canonicalize "$systemd_context_example" >"$systemd_context"
python3 - "$spec" "$systemd_context" "$systemd_spec" <<'PY'
import hashlib
import json
import sys

spec = json.load(open(sys.argv[1], encoding="utf-8"))
context_raw = open(sys.argv[2], "rb").read()
context = json.loads(context_raw)
spec["target_id"] = context["target"]["id"]
spec["build_context_digest"] = (
    "sha256:" + hashlib.sha256(context_raw).hexdigest()
)
with open(sys.argv[3], "w", encoding="utf-8") as stream:
    json.dump(spec, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY

request="$work_dir/request.json"
"$engine" render \
    --build-context "$context" \
    --build-spec "$spec" \
    --engine-target "$target" \
    --output "$request"

systemd_request="$work_dir/request-systemd.json"
"$engine" render \
    --build-context "$systemd_context" \
    --build-spec "$systemd_spec" \
    --engine-target "$systemd_target" \
    --output "$systemd_request"

python3 - "$request" "$spec" <<'PY'
import hashlib
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
spec_raw = open(sys.argv[2], "rb").read()
spec_digest = "sha256:" + hashlib.sha256(spec_raw).hexdigest()
assert request["package_name"] == "app-misc/jq"
assert request["version"] == "1.8.1"
assert request["repository_ids"] == ["gentoo", "volatoo-overlay"]
package = request["config_bundle"]["packages"]["packages"][0]
assert package["atom"] == "app-misc/jq"
assert package["version"] == "1.8.1"
assert package["use_flags"] == [
    "-static-libs",
    "-test",
    "abi_x86_64",
    "oniguruma",
]
assert package["keywords"] == ["amd64"]
assert package["environment"]["CFLAGS"] == "-O2 -pipe"
description = request["config_bundle"]["metadata"]["description"]
assert description == "Volatoo BuildSpec " + spec_digest
PY

python3 - "$systemd_request" <<'PY'
import json
import sys

request = json.load(open(sys.argv[1], encoding="utf-8"))
assert request["profile_id"] == (
    "volatoo/amd64/glibc/systemd/23.0/base-v1"
)
assert request["arch"] == "amd64"
PY

bad_target="$work_dir/bad-target.json"
python3 - "$target" "$bad_target" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
value["engine"]["required_features"] = ["sandbox"]
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
if "$engine" render \
    --build-context "$context" \
    --build-spec "$spec" \
    --engine-target "$bad_target" \
    --output "$work_dir/should-not-exist.json" \
    >"$work_dir/bad-target.out" 2>"$work_dir/bad-target.err"; then
    echo "feature-policy mismatch was accepted" >&2
    exit 1
fi
grep -q "FEATURES differ" "$work_dir/bad-target.err"

tampered_request="$work_dir/tampered-request.json"
python3 - "$request" "$tampered_request" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
value["package_name"] = "sys-apps/coreutils"
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    json.dump(value, stream, sort_keys=True, separators=(",", ":"))
    stream.write("\n")
PY
if "$engine" submit \
    --request "$tampered_request" \
    --build-spec "$spec" \
    --engine-target "$target" \
    --server https://engine.invalid \
    --receipt "$work_dir/tampered-receipt.json" \
    >"$work_dir/tampered.out" 2>"$work_dir/tampered.err"; then
    echo "tampered Portage Engine request was accepted" >&2
    exit 1
fi
grep -q "request does not match" "$work_dir/tampered.err"

api_key="$work_dir/api-key"
umask 077
printf '%s\n' 'volatoo-test-key' >"$api_key"

port_file="$work_dir/port"
capture="$work_dir/capture.json"
python3 "$fake_engine" \
    --target "$target" \
    --port-file "$port_file" \
    --capture "$capture" &
server_pid=$!
wait_for_port "$port_file"
port=$(<"$port_file")
receipt="$work_dir/receipt.json"
"$engine" submit \
    --request "$request" \
    --build-spec "$spec" \
    --engine-target "$target" \
    --server "http://127.0.0.1:$port" \
    --api-key-file "$api_key" \
    --receipt "$receipt" \
    --timeout 5 \
    --poll-interval 0.01 \
    --allow-http
wait "$server_pid"
server_pid=

python3 - "$request" "$spec" "$target" "$capture" "$receipt" <<'PY'
import hashlib
import json
import sys

request_raw = open(sys.argv[1], "rb").read()
spec_raw = open(sys.argv[2], "rb").read()
target_raw = open(sys.argv[3], "rb").read()
capture = json.load(open(sys.argv[4], encoding="utf-8"))
receipt = json.load(open(sys.argv[5], encoding="utf-8"))
target = json.loads(target_raw)
assert capture["api_key"] == "volatoo-test-key"
assert capture["request"] == json.loads(request_raw)
spec_digest = "sha256:" + hashlib.sha256(spec_raw).hexdigest()
idempotency_digest = hashlib.sha256(
    spec_raw + target_raw + request_raw
).hexdigest()
assert capture["idempotency_key"] == "volatoo-" + idempotency_digest
assert receipt["schema"] == "org.volatoo.portage-engine-job/v1"
assert receipt["status"] == "succeeded"
assert receipt["build_spec_digest"] == spec_digest
assert receipt["request_digest"] == (
    "sha256:" + hashlib.sha256(request_raw).hexdigest()
)
assert receipt["engine_target_digest"] == (
    "sha256:" + hashlib.sha256(target_raw).hexdigest()
)
assert receipt["binhost_path"] == target["engine"]["binhost_path"]
assert receipt["required_features"] == (
    target["engine"]["required_features"]
)
assert receipt["artifacts"] == [
    target["engine"]["binhost_path"]
    + "/app-misc/jq/jq-1.8.1-1.gpkg.tar"
]
PY

mismatch_port_file="$work_dir/mismatch-port"
python3 "$fake_engine" \
    --target "$target" \
    --port-file "$mismatch_port_file" \
    --capture "$work_dir/mismatch-capture.json" \
    --mismatch-image &
server_pid=$!
wait_for_port "$mismatch_port_file"
mismatch_port=$(<"$mismatch_port_file")
if "$engine" submit \
    --request "$request" \
    --build-spec "$spec" \
    --engine-target "$target" \
    --server "http://127.0.0.1:$mismatch_port" \
    --api-key-file "$api_key" \
    --receipt "$work_dir/mismatch-receipt.json" \
    --timeout 5 \
    --poll-interval 0.01 \
    --allow-http \
    >"$work_dir/mismatch.out" 2>"$work_dir/mismatch.err"; then
    echo "mismatched resolved context was accepted" >&2
    exit 1
fi
wait "$server_pid"
server_pid=
grep -q "resolved_context.image_digest differs" "$work_dir/mismatch.err"
test ! -e "$work_dir/mismatch-receipt.json"

echo "Portage Engine adapter tests passed"
