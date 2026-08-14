#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
openrc_stage3=gentoo/stage3@sha256:ffc1ede408d1f7f0194c13259679630533913a9473e7adcef367375932c7e8cb
systemd_stage3=gentoo/stage3@sha256:0107bcedb0f12f4e905aa9dd4c7e00054b3339fe8cb7080b06e160e5a166c22d
portage_image=gentoo/portage@sha256:6c49dbf51f9e52e3edeb43ca83e79025394b0a9b4c6cab1ed2b2f629e05c78e8
platform=linux/amd64
repo_container=volatoo-acquire-portage-$$
binhost_container=volatoo-acquire-binhost-$$
binhost_network=volatoo-acquire-net-$$
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/volatoo-acquire-test.XXXXXX")
chmod 755 "$work_dir"

cleanup()
{
	docker rm -f -- "$binhost_container" >/dev/null 2>&1 || true
	docker rm -f -- "$repo_container" >/dev/null 2>&1 || true
	docker network rm -- "$binhost_network" >/dev/null 2>&1 || true
	docker run --rm \
		--platform "$platform" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--entrypoint /bin/chmod \
		"$openrc_stage3" \
		-R a+rwX /result >/dev/null 2>&1 || true
	rm -rf -- "$work_dir"
}
trap cleanup EXIT

fail()
{
	echo "error: $*" >&2
	exit 1
}

run_acquire()
{
	local stage3_image=$1
	local context=$2
	local spec=$3
	local catalog=$4
	local store=$5
	local receipt=$6
	shift 6
	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--mount "type=bind,src=$repo_root,dst=/work,readonly" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--entrypoint /usr/bin/python3 \
		"$stage3_image" \
		/work/update/volatoo-acquire \
			--build-context "$context" \
			--build-spec "$spec" \
			--source-catalog "$catalog" \
			--store "$store" \
			--receipt "$receipt" \
			"$@"
}

expect_acquire_failure()
{
	local expected=$1
	local label=$2
	shift 2
	if run_acquire "$@" >"$work_dir/$label.log" 2>&1; then
		fail "$label: acquisition unexpectedly succeeded"
	fi
	grep -Fq -- "$expected" "$work_dir/$label.log" ||
		fail "$label: expected '$expected'"
}

docker pull --platform "$platform" "$openrc_stage3" >/dev/null
docker pull --platform "$platform" "$systemd_stage3" >/dev/null
docker pull --platform "$platform" "$portage_image" >/dev/null
docker create \
	--platform "$platform" \
	--name "$repo_container" \
	"$portage_image" >/dev/null

revision=$(
	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--entrypoint /bin/sh \
		"$openrc_stage3" \
		-c 'sed -n "s/ .*//p" /var/db/repos/gentoo/metadata/timestamp.commit'
)

for init_system in openrc systemd; do
	if [[ $init_system == openrc ]]; then
		stage3_image=$openrc_stage3
		context_example=$repo_root/update/examples/build-context-v1.json
	else
		stage3_image=$systemd_stage3
		context_example=$repo_root/update/examples/build-context-systemd-v1.json
	fi
	portage_version=$(
		docker run --rm \
			--platform "$platform" \
			--entrypoint /usr/bin/python3 \
			"$stage3_image" \
			-c 'import portage; print(portage.VERSION)'
	)
	jq \
		--arg revision "$revision" \
		--arg portage_version "$portage_version" \
		'
		.target.profile_revision = $revision
		| .sources = [{
		    "name": "gentoo",
		    "revision": $revision,
		    "tree_digest": ("sha256:" + ("2" * 64))
		  }]
		| .toolchain.portage_version = $portage_version
		' \
		"$context_example" \
		>"$work_dir/context-$init_system.json"
	target_id=$(
		jq -r '.target.id' "$work_dir/context-$init_system.json"
	)
	mkdir -p "$work_dir/pkgdir/$target_id"

	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--mount "type=bind,src=$repo_root,dst=/work,readonly" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--entrypoint /usr/bin/python3 \
		"$stage3_image" \
		/work/update/volatoo-plan \
			--build-context "/result/context-$init_system.json" \
			--output "/result/build-spec-$init_system.json" \
			--query-output "/result/query-$init_system.json" \
			app-arch/zstd

	docker run --rm \
		--platform "$platform" \
		--volumes-from "$repo_container" \
		--mount "type=bind,src=$work_dir,dst=/result" \
		--entrypoint /bin/sh \
		"$stage3_image" \
		-c 'PKGDIR=$1 quickpkg app-arch/zstd' \
		sh "/result/pkgdir/$target_id"

	jq -n \
		--arg target "$target_id" \
		--arg location "/result/pkgdir/$target_id" \
		'{
		  schema: "org.volatoo.package-source-catalog/v1",
		  target_id: $target,
		  sources: [{
		    id: "local",
		    kind: "local",
		    priority: 100,
		    location: $location,
		    signature_policy: "machine-local",
		    compatibility: "portage-resolved",
		    gpg_home: "",
		    trusted_fingerprints: []
		  }]
		}' >"$work_dir/catalog-$init_system.json"

	run_acquire \
		"$stage3_image" \
		"/result/context-$init_system.json" \
		"/result/build-spec-$init_system.json" \
		"/result/catalog-$init_system.json" \
		"/result/store-$init_system" \
		"/result/receipt-$init_system.json"
	"$repo_root/update/volatoo-manifest" verify-acquisition \
		"$work_dir/receipt-$init_system.json" \
		"$work_dir/build-spec-$init_system.json" \
		"$work_dir/context-$init_system.json" \
		"$work_dir/catalog-$init_system.json"
	jq -e '
		.complete
		and (.packages | length == 1)
		and (.packages[0].signature == "machine-local")
		and (.packages[0].source_kind == "local")
	' "$work_dir/receipt-$init_system.json" >/dev/null ||
		fail "$init_system: local acquisition receipt is invalid"
done

jq '
	del(.packages[0].use.enabled[] | select(. == "zlib"))
' "$work_dir/build-spec-openrc.json" >"$work_dir/wrong-use-spec.json"
expect_acquire_failure \
	"binary package closure is incomplete" \
	"wrong-use" \
	"$openrc_stage3" \
	/result/context-openrc.json \
	/result/wrong-use-spec.json \
	/result/catalog-openrc.json \
	/result/wrong-use-store \
	/result/wrong-use-receipt.json

openrc_target=$(
	jq -r '.target.id' "$work_dir/context-openrc.json"
)
mkdir -p "$work_dir/bad-pkgdir/$openrc_target"
cp -R \
	"$work_dir/pkgdir/$openrc_target/." \
	"$work_dir/bad-pkgdir/$openrc_target/"
sed 's/^SHA1: .*/SHA1: ffffffffffffffffffffffffffffffffffffffff/' \
	"$work_dir/pkgdir/$openrc_target/Packages" \
	>"$work_dir/bad-pkgdir/$openrc_target/Packages"
jq \
	--arg location "/result/bad-pkgdir/$openrc_target" \
	'.sources[0].location = $location' \
	"$work_dir/catalog-openrc.json" \
	>"$work_dir/bad-hash-catalog.json"
expect_acquire_failure \
	"SHA1 mismatch" \
	"wrong-hash" \
	"$openrc_stage3" \
	/result/context-openrc.json \
	/result/build-spec-openrc.json \
	/result/bad-hash-catalog.json \
	/result/wrong-hash-store \
	/result/wrong-hash-receipt.json

jq '
	.sources[0].compatibility = "volatoo-attested"
' "$work_dir/catalog-openrc.json" >"$work_dir/attested-catalog.json"
expect_acquire_failure \
	"provenance VOLATOO_TARGET_ID mismatch" \
	"missing-attestation" \
	"$openrc_stage3" \
	/result/context-openrc.json \
	/result/build-spec-openrc.json \
	/result/attested-catalog.json \
	/result/missing-attestation-store \
	/result/missing-attestation-receipt.json

mkdir -p "$work_dir/empty-pkgdir/$openrc_target"
printf 'PACKAGES: 0\nTIMESTAMP: 1\nVERSION: 0\n' \
	>"$work_dir/empty-pkgdir/$openrc_target/Packages"
jq \
	--arg location "/result/empty-pkgdir/$openrc_target" \
	'.sources[0].location = $location' \
	"$work_dir/catalog-openrc.json" \
	>"$work_dir/empty-catalog.json"
for missing_action in local-build remote-build; do
	set +e
	run_acquire \
		"$openrc_stage3" \
		/result/context-openrc.json \
		/result/build-spec-openrc.json \
		/result/empty-catalog.json \
		"/result/$missing_action-store" \
		"/result/$missing_action-receipt.json" \
		--missing-action "$missing_action"
	status=$?
	set -e
	[[ $status -eq 2 ]] ||
		fail "$missing_action: expected incomplete status 2, got $status"
	"$repo_root/update/volatoo-manifest" verify-acquisition \
		"$work_dir/$missing_action-receipt.json" \
		"$work_dir/build-spec-openrc.json" \
		"$work_dir/context-openrc.json" \
		"$work_dir/empty-catalog.json"
	jq -e \
		--arg action "$missing_action" \
		'
		(.complete | not)
		and (.packages | length == 0)
		and (.missing | length == 1)
		and (.missing[0].action == $action)
		' "$work_dir/$missing_action-receipt.json" >/dev/null ||
		fail "$missing_action: incomplete receipt is invalid"
done

signed_root=$work_dir/signed/$openrc_target
mkdir -p "$signed_root" "$work_dir/gnupg" "$work_dir/verify-gnupg"
chmod 700 "$work_dir/gnupg" "$work_dir/verify-gnupg"
cp -R "$work_dir/pkgdir/$openrc_target/." "$signed_root/"
docker run --rm \
	--platform "$platform" \
	--mount "type=bind,src=$work_dir,dst=/result" \
	--entrypoint /bin/sh \
	"$openrc_stage3" \
	-c '
	set -eu
	gpg --homedir /result/gnupg \
		--batch --pinentry-mode loopback --passphrase "" \
		--quick-gen-key \
		"Volatoo acquisition test <acquisition@volatoo.invalid>" \
		ed25519 sign 1d
	fingerprint=$(
		gpg --homedir /result/gnupg --batch --with-colons \
			--fingerprint --list-keys |
			awk -F: '"'"'$1 == "fpr" { print $10; exit }'"'"'
	)
	printf "%s:6:\n" "$fingerprint" |
		gpg --homedir /result/gnupg --import-ownertrust
	gpg --homedir /result/gnupg --batch \
		--export "$fingerprint" >/result/test-signing-public.gpg
	gpg --homedir /result/verify-gnupg --batch \
		--import /result/test-signing-public.gpg
	printf "%s:6:\n" "$fingerprint" |
		gpg --homedir /result/verify-gnupg --import-ownertrust
	find /result/verify-gnupg -type d -exec chmod 755 {} +
	find /result/verify-gnupg -type f -exec chmod 644 {} +
	printf "%s\n" "$fingerprint" >/result/fingerprint
	' >/dev/null
fingerprint=$(cat "$work_dir/fingerprint")
signed_cpv=$(jq -r '.packages[0].cpv' "$work_dir/build-spec-openrc.json")
signed_path=$(sed -n 's/^PATH: //p' "$signed_root/Packages")
docker run --rm --interactive \
	--platform "$platform" \
	--mount "type=bind,src=$work_dir,dst=/result" \
	--entrypoint /usr/bin/python3 \
	"$openrc_stage3" \
	- "$fingerprint" "$signed_cpv" \
	"/result/signed/$openrc_target/$signed_path" <<'PY'
import sys

import portage
from portage.gpkg import gpkg

fingerprint, cpv, artifact = sys.argv[1:]
settings = portage.config(clone=portage.settings)
settings.unlock()
settings["BINPKG_GPG_SIGNING_BASE_COMMAND"] = (
    "/usr/bin/gpg --sign --armor --yes --pinentry-mode loopback "
    "--passphrase-file /dev/null [PORTAGE_CONFIG]"
)
settings["BINPKG_GPG_SIGNING_DIGEST"] = "SHA512"
settings["BINPKG_GPG_SIGNING_GPG_HOME"] = "/result/gnupg"
settings["BINPKG_GPG_SIGNING_KEY"] = fingerprint
settings.lock()
gpkg(
    settings,
    basename=cpv,
    gpkg_file=artifact,
    verify_signature=False,
).update_signature()
PY

signed_artifact=$signed_root/$signed_path
signed_size=$(wc -c <"$signed_artifact" | tr -d ' ')
signed_sha1=$(openssl dgst -sha1 "$signed_artifact" | awk '{print $NF}')
signed_md5=$(openssl dgst -md5 "$signed_artifact" | awk '{print $NF}')
awk \
	-v size="$signed_size" \
	-v sha1="$signed_sha1" \
	-v md5="$signed_md5" '
	/^SIZE: / {$0 = "SIZE: " size}
	/^SHA1: / {$0 = "SHA1: " sha1}
	/^MD5: / {$0 = "MD5: " md5}
	{print}
	' "$work_dir/pkgdir/$openrc_target/Packages" \
	>"$signed_root/Packages"

docker run --rm \
	--platform "$platform" \
	--mount "type=bind,src=$work_dir,dst=/result" \
	--entrypoint /usr/bin/openssl \
	"$openrc_stage3" \
	req -x509 -newkey rsa:2048 -nodes -days 1 \
		-subj /CN=binhost \
		-addext subjectAltName=DNS:binhost \
		-addext basicConstraints=critical,CA:TRUE \
		-keyout /result/binhost-key.pem \
		-out /result/binhost-cert.pem >/dev/null 2>&1
docker network create "$binhost_network" >/dev/null
docker run -d --rm \
	--platform "$platform" \
	--name "$binhost_container" \
	--network "$binhost_network" \
	--network-alias binhost \
	--mount "type=bind,src=$work_dir/signed,dst=/srv,readonly" \
	--mount "type=bind,src=$work_dir/binhost-cert.pem,dst=/cert.pem,readonly" \
	--mount "type=bind,src=$work_dir/binhost-key.pem,dst=/key.pem,readonly" \
	--entrypoint /usr/bin/python3 \
	"$openrc_stage3" \
	-c '
import http.server
import ssl

server = http.server.ThreadingHTTPServer(
    ("0.0.0.0", 8443),
    lambda *args, **kwargs: http.server.SimpleHTTPRequestHandler(
        *args, directory="/srv", **kwargs
    ),
)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/cert.pem", "/key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
' >/dev/null
for _attempt in 1 2 3 4 5; do
	if docker exec "$binhost_container" \
		python3 -c \
		'import socket; socket.create_connection(("127.0.0.1", 8443), 1)' \
		>/dev/null 2>&1
	then
		break
	fi
	sleep 1
done

jq -n \
	--arg target "$openrc_target" \
	--arg location "https://binhost:8443/$openrc_target" \
	--arg fingerprint "$fingerprint" \
	'{
	  schema: "org.volatoo.package-source-catalog/v1",
	  target_id: $target,
	  sources: [{
	    id: "remote",
	    kind: "remote",
	    priority: 100,
	    location: $location,
	    signature_policy: "required",
	    compatibility: "portage-resolved",
	    gpg_home: "/result/verify-gnupg",
	    trusted_fingerprints: [$fingerprint]
	  }]
	}' >"$work_dir/remote-catalog.json"
docker run --rm \
	--platform "$platform" \
	--network "$binhost_network" \
	--volumes-from "$repo_container" \
	--env SSL_CERT_FILE=/result/binhost-cert.pem \
	--mount "type=bind,src=$repo_root,dst=/work,readonly" \
	--mount "type=bind,src=$work_dir,dst=/result" \
	--entrypoint /usr/bin/python3 \
	"$openrc_stage3" \
	/work/update/volatoo-acquire \
		--build-context /result/context-openrc.json \
		--build-spec /result/build-spec-openrc.json \
		--source-catalog /result/remote-catalog.json \
		--store /result/remote-store \
		--receipt /result/remote-receipt.json
"$repo_root/update/volatoo-manifest" verify-acquisition \
	"$work_dir/remote-receipt.json" \
	"$work_dir/build-spec-openrc.json" \
	"$work_dir/context-openrc.json" \
	"$work_dir/remote-catalog.json"
jq -e '
	.complete
	and (.packages | length == 1)
	and (.packages[0].signature == "verified")
	and (.packages[0].source_kind == "remote")
' "$work_dir/remote-receipt.json" >/dev/null ||
	fail "remote signed acquisition receipt is invalid"

echo "volatoo acquisition Docker tests passed"
