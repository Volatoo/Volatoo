#!/bin/sh

set -eu

spec=/config/volatoo.spec
config=/config/catalyst.conf

if [ "${VOLATOO_VALIDATE_ONLY:-no}" = yes ]; then
	python - "${spec}" <<'PY'
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
print("packages: " + " ".join(values["stage4/packages"]))
PY
	exit
fi

: "${VOLATOO_SOURCE_NAME:?VOLATOO_SOURCE_NAME is required}"
: "${VOLATOO_SNAPSHOT_ID:?VOLATOO_SNAPSHOT_ID is required}"

storedir=/work/catalyst
source_dir=${storedir}/builds/volatoo
snapshot_dir=${storedir}/snapshots

mkdir -p "${source_dir}" "${snapshot_dir}"
ln -sfn /inputs/stage3 "${source_dir}/${VOLATOO_SOURCE_NAME}"
ln -sfn /inputs/snapshot \
	"${snapshot_dir}/gentoo-${VOLATOO_SNAPSHOT_ID}.sqfs"

exec catalyst --nocolor -c "${config}" -f "${spec}"
