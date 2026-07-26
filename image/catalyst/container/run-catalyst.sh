#!/bin/sh

set -eu

spec=/config/volatoo.spec
config=/config/catalyst.conf

if [ "${VOLATOO_VALIDATE_ONLY:-no}" = yes ]; then
	python - "${spec}" <<'PY'
import os
import sys

from catalyst.config import SpecParser
from DeComp.definitions import COMPRESS_DEFINITIONS, DECOMPRESS_DEFINITIONS

values = SpecParser(sys.argv[1]).get_values()
required = {
    "compression_mode",
    "profile",
    "rel_type",
    "snapshot_treeish",
    "source_subpath",
    "stage4/fsscript",
    "stage4/packages",
    "stage4/root_overlay",
    "subarch",
    "target",
    "version_stamp",
}
missing = sorted(required - values.keys())
if missing:
    raise SystemExit("missing spec keys: " + ", ".join(missing))
if values["target"] != "stage4":
    raise SystemExit("the Volatoo image target must be stage4")
if values["compression_mode"] != "squashfs_zstd":
    raise SystemExit("the Volatoo image must use squashfs_zstd")
if not values["stage4/packages"]:
    raise SystemExit("the package set is empty")
if any("@" in str(value) for value in values.values()):
    raise SystemExit("the rendered spec still contains a placeholder")

init_system = os.environ.get("VOLATOO_INIT_SYSTEM")
expected_profiles = {
    "openrc": "default/linux/amd64/23.0",
    "systemd": "default/linux/amd64/23.0/systemd",
}
expected_rel_types = {
    "openrc": "volatoo",
    "systemd": "volatoo-systemd",
}
if init_system not in expected_profiles:
    raise SystemExit("VOLATOO_INIT_SYSTEM must be openrc or systemd")
if values["profile"] != expected_profiles[init_system]:
    raise SystemExit(
        f"{init_system} target uses unexpected profile: {values['profile']}"
    )
if values["rel_type"] != expected_rel_types[init_system]:
    raise SystemExit(
        f"{init_system} target uses unexpected rel_type: {values['rel_type']}"
    )
expected_source_prefix = expected_rel_types[init_system] + "/"
if not values["source_subpath"].startswith(expected_source_prefix):
    raise SystemExit(
        f"{init_system} source_subpath is outside its target namespace"
    )
if init_system == "openrc" and "stage4/rcadd" not in values:
    raise SystemExit("the OpenRC target must configure stage4/rcadd")
if init_system == "systemd" and "stage4/rcadd" in values:
    raise SystemExit("the systemd target must not configure stage4/rcadd")

unknown_decompressors = sorted(
    set(values["decompressor_search_order"]) - DECOMPRESS_DEFINITIONS.keys()
)
if unknown_decompressors:
    raise SystemExit(
        "unsupported decompressors: " + ", ".join(unknown_decompressors)
    )

arguments = COMPRESS_DEFINITIONS["squashfs_zstd"][2]
level_index = arguments.index("-Xcompression-level") + 1
if arguments[level_index] != "19":
    raise SystemExit("the builder is not configured for Zstd level 19")
if "-xattrs" not in arguments:
    raise SystemExit("the builder has incompatible SquashFS xattr options")

print("Catalyst spec is valid")
print("init system: " + init_system)
print("packages: " + " ".join(values["stage4/packages"]))
PY
	exit
fi

: "${VOLATOO_SOURCE_NAME:?VOLATOO_SOURCE_NAME is required}"
: "${VOLATOO_SNAPSHOT_ID:?VOLATOO_SNAPSHOT_ID is required}"
: "${VOLATOO_REL_TYPE:?VOLATOO_REL_TYPE is required}"

storedir=/work/catalyst
source_dir=${storedir}/builds/${VOLATOO_REL_TYPE}
snapshot_dir=${storedir}/snapshots

mkdir -p "${source_dir}" "${snapshot_dir}"
ln -sfn /inputs/stage3 "${source_dir}/${VOLATOO_SOURCE_NAME}"
ln -sfn /inputs/snapshot \
	"${snapshot_dir}/gentoo-${VOLATOO_SNAPSHOT_ID}.sqfs"

exec catalyst --nocolor -c "${config}" -f "${spec}"
