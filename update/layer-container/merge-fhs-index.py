#!/usr/bin/env python3

"""Merge an authenticated parent FHS/ELF index with one layer delta."""

from __future__ import annotations

import argparse
from pathlib import Path

from fhs_index import HEADER, IndexError, parse_runtime_path, read_index, record_path


def read_paths(path: Path, description: str) -> list[bytes]:
    content = path.read_bytes()
    if content and not content.endswith(b"\n"):
        raise IndexError(f"{description} has no final newline")
    values = content.splitlines()
    if values != sorted(set(values)):
        raise IndexError(f"{description} is not canonical")
    return [parse_runtime_path(value, description) for value in values]


def at_or_below(path: bytes, root: bytes) -> bool:
    return path == root or path.startswith(root + b"/")


def merge_indexes(
    parent_records: list[bytes],
    child_records: list[bytes],
    affected_paths: list[bytes],
    tombstones: list[bytes],
) -> list[bytes]:
    child_types: dict[bytes, bytes] = {}
    for record in child_records:
        fields = record.split(b"|")
        if fields[0] == b"P":
            child_types[fields[1]] = fields[2]
    for path in affected_paths:
        if path not in child_types:
            raise IndexError(f"affected path is absent from child index: {path!r}")

    retained: set[bytes] = set()
    for record in parent_records:
        path = record_path(record)
        if any(at_or_below(path, tombstone) for tombstone in tombstones):
            continue
        replaced = False
        for affected in affected_paths:
            if path == affected:
                replaced = True
                break
            if child_types[affected] != b"d" and at_or_below(path, affected):
                replaced = True
                break
        if not replaced:
            retained.add(record)

    affected = set(affected_paths)
    for record in child_records:
        if record_path(record) in affected:
            retained.add(record)
    return sorted(retained)


def write_index(path: Path, target: bytes, records: list[bytes]) -> None:
    if path.exists() or path.is_symlink():
        raise IndexError(f"output already exists: {path}")
    content = b"\n".join(
        [HEADER, b"target " + target, *records, b"end", b""]
    )
    path.write_bytes(content)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("parent", type=Path)
    parser.add_argument("child", type=Path)
    parser.add_argument("affected_paths", type=Path)
    parser.add_argument("tombstones", type=Path)
    parser.add_argument("output", type=Path)
    arguments = parser.parse_args()

    parent_target, parent_records = read_index(arguments.parent)
    child_target, child_records = read_index(arguments.child)
    if parent_target != child_target:
        raise IndexError("parent and child validation-index targets differ")
    affected_paths = read_paths(arguments.affected_paths, "affected path list")
    tombstones = read_paths(arguments.tombstones, "tombstone list")
    merged = merge_indexes(
        parent_records,
        child_records,
        affected_paths,
        tombstones,
    )
    write_index(arguments.output, child_target, merged)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IndexError, OSError) as error:
        raise SystemExit(f"error: {error}") from error
