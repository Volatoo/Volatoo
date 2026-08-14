#!/usr/bin/env python3

"""Build internally consistent generation fixtures for update tests."""

from __future__ import annotations

import argparse
import hashlib
import runpy
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
UPDATE_DIR = SCRIPT_DIR.parent
EXAMPLES_DIR = UPDATE_DIR / "examples"
CONTRACTS = runpy.run_path(str(UPDATE_DIR / "volatoo-manifest"))


def read_manifest(
    path: Path,
    schema: str | tuple[str, ...],
) -> dict[str, Any]:
    value = CONTRACTS["read_manifest"](str(path))
    actual = CONTRACTS["validate_manifest"](value)
    expected = (schema,) if isinstance(schema, str) else schema
    if actual not in expected:
        raise RuntimeError(
            f"{path}: expected one of {', '.join(expected)}, got {actual}"
        )
    return value


def write_manifest(path: Path, value: dict[str, Any]) -> str:
    CONTRACTS["validate_manifest"](value)
    canonical = CONTRACTS["canonical_bytes"](value)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(canonical)
    return CONTRACTS["manifest_digest"](value)


def file_digest(path: Path) -> tuple[str, int]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
            size += len(block)
    return f"sha256:{digest.hexdigest()}", size


def make_context_fixture(arguments: argparse.Namespace) -> None:
    output = arguments.output_dir
    context = read_manifest(
        arguments.build_context,
        "org.volatoo.build-context/v1",
    )
    base_digest, base_size = file_digest(arguments.base)
    context["base"]["rootfs_digest"] = base_digest
    context_digest = write_manifest(output / "build-context.json", context)

    spec = read_manifest(
        EXAMPLES_DIR / "build-spec-v1.json",
        "org.volatoo.build-spec/v1",
    )
    spec["target_id"] = context["target"]["id"]
    spec["build_context_digest"] = context_digest
    spec["resolver"]["version"] = context["toolchain"]["portage_version"]
    spec_digest = write_manifest(output / "build-spec.json", spec)

    catalog = read_manifest(
        EXAMPLES_DIR / "package-source-catalog-v1.json",
        "org.volatoo.package-source-catalog/v1",
    )
    catalog["target_id"] = context["target"]["id"]
    for source in catalog["sources"]:
        if source["kind"] == "local":
            source["location"] = (
                "/var/lib/volatoo/local-binpkgs/"
                f"{context['target']['id']}"
            )
    catalog_digest = write_manifest(output / "source-catalog.json", catalog)

    acquisition = read_manifest(
        EXAMPLES_DIR / "package-acquisition-v1.json",
        "org.volatoo.package-acquisition/v1",
    )
    acquisition["target_id"] = context["target"]["id"]
    acquisition["build_context_digest"] = context_digest
    acquisition["build_spec_digest"] = spec_digest
    acquisition["source_catalog_digest"] = catalog_digest
    for package in acquisition["packages"]:
        package["package_digest"] = CONTRACTS["package_build_digest"](
            spec,
            spec["packages"][package["sequence"]],
        )
    write_manifest(output / "acquisition.json", acquisition)

    generation = {
        "schema": "org.volatoo.generation/v1",
        "target_id": context["target"]["id"],
        "build_context_digest": context_digest,
        "base": {
            "rootfs_digest": base_digest,
            "rootfs_size": base_size,
            "format": "squashfs",
        },
        "layers": [],
    }
    CONTRACTS["verify_generation_context"](generation, context)
    CONTRACTS["verify_build_spec_context"](spec, context)
    CONTRACTS["verify_acquisition_closure"](
        acquisition,
        spec,
        context,
        catalog,
    )
    write_manifest(output / "base-generation.json", generation)


def make_layer_fixture(arguments: argparse.Namespace) -> None:
    output = arguments.output_dir
    context = read_manifest(
        arguments.build_context,
        "org.volatoo.build-context/v1",
    )
    spec = read_manifest(
        arguments.build_spec,
        "org.volatoo.build-spec/v1",
    )
    acquisition = read_manifest(
        arguments.acquisition,
        "org.volatoo.package-acquisition/v1",
    )
    parent = read_manifest(
        arguments.parent,
        (
            "org.volatoo.generation/v1",
            "org.volatoo.generation/v2",
        ),
    )
    changed = read_manifest(
        arguments.changed_paths,
        "org.volatoo.layer-paths/v1",
    )
    tombstones = read_manifest(
        arguments.tombstones,
        "org.volatoo.tombstones/v1",
    )
    layer_digest, layer_size = file_digest(arguments.layer)

    transaction = read_manifest(
        EXAMPLES_DIR / "layer-transaction-v1.json",
        "org.volatoo.layer-transaction/v1",
    )
    transaction["target_id"] = context["target"]["id"]
    transaction["build_context_digest"] = CONTRACTS["manifest_digest"](
        context
    )
    transaction["build_spec_digest"] = CONTRACTS["manifest_digest"](spec)
    transaction["acquisition_digest"] = CONTRACTS["manifest_digest"](
        acquisition
    )
    transaction["parent_generation_digest"] = CONTRACTS["manifest_digest"](
        parent
    )
    transaction["portage"]["version"] = context["toolchain"][
        "portage_version"
    ]
    transaction["packages"] = [
        {
            "sequence": package["sequence"],
            "cpv": package["cpv"],
            "package_digest": package["package_digest"],
            "artifact_digest": package["artifact_digest"],
            "build_id": package["build_id"],
        }
        for package in acquisition["packages"]
    ]
    transaction["filesystem"].update(
        {
            "changed_paths_digest": CONTRACTS["manifest_digest"](changed),
            "changed_paths_count": len(changed["paths"]),
            "tombstones_digest": CONTRACTS["manifest_digest"](tombstones),
            "tombstones_count": len(tombstones["paths"]),
            "rootfs_digest": layer_digest,
            "rootfs_size": layer_size,
        }
    )
    transaction["world_digest"] = (
        arguments.result_world_digest or context["world_digest"]
    )
    transaction_digest = write_manifest(
        output / "transaction.json",
        transaction,
    )

    layer_record = {
        "rootfs_digest": layer_digest,
        "rootfs_size": layer_size,
        "format": "squashfs",
        "tombstones_digest": CONTRACTS["manifest_digest"](
            tombstones
        ),
        "transaction_digest": transaction_digest,
    }
    portage_state = None
    if arguments.generation_version == 1:
        if parent["schema"] != "org.volatoo.generation/v1":
            raise RuntimeError("generation v1 cannot extend generation v2")
        generation = {
            **parent,
            "layers": [*parent["layers"], layer_record],
        }
    else:
        portage_state = CONTRACTS["portage_state_from_context"](
            context,
            transaction["world_digest"],
        )
        portage_state_digest = write_manifest(
            output / "portage-state.json",
            portage_state,
        )
        generation = {
            "schema": "org.volatoo.generation/v2",
            "target_id": parent["target_id"],
            "build_context_digest": CONTRACTS["manifest_digest"](context),
            "portage_state_digest": portage_state_digest,
            "parent_generation_digest": CONTRACTS["manifest_digest"](parent),
            "base": parent["base"],
            "layers": [*parent["layers"], layer_record],
        }
    CONTRACTS["verify_build_spec_context"](spec, context)
    CONTRACTS["verify_layer_transaction_closure"](
        transaction,
        generation,
        parent,
        context,
        spec,
        acquisition,
        changed,
        tombstones,
        portage_state,
    )
    write_manifest(output / "generation.json", generation)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    context = subparsers.add_parser("context")
    context.add_argument("--build-context", type=Path, required=True)
    context.add_argument("--base", type=Path, required=True)
    context.add_argument("--output-dir", type=Path, required=True)
    context.set_defaults(handler=make_context_fixture)

    layer = subparsers.add_parser("layer")
    layer.add_argument("--build-context", type=Path, required=True)
    layer.add_argument("--build-spec", type=Path, required=True)
    layer.add_argument("--acquisition", type=Path, required=True)
    layer.add_argument("--parent", type=Path, required=True)
    layer.add_argument("--changed-paths", type=Path, required=True)
    layer.add_argument("--tombstones", type=Path, required=True)
    layer.add_argument("--layer", type=Path, required=True)
    layer.add_argument("--output-dir", type=Path, required=True)
    layer.add_argument(
        "--generation-version",
        type=int,
        choices=(1, 2),
        default=1,
    )
    layer.add_argument(
        "--result-world-digest",
        help="override the resulting Portage world digest",
    )
    layer.set_defaults(handler=make_layer_fixture)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    arguments.handler(arguments)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
