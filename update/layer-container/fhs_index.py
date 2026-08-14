"""Shared parser for canonical Volatoo FHS/ELF validation indexes."""

from __future__ import annotations

from pathlib import Path


HEADER = b"VOLATOO_FHS_ELF_INDEX_V1"


class IndexError(RuntimeError):
    pass


def parse_runtime_path(value: bytes, description: str) -> bytes:
    if not value.startswith(b"/") or b"//" in value or b"\x00" in value:
        raise IndexError(f"{description} is invalid")
    components = value.split(b"/")[1:]
    if any(component in (b"", b".", b"..") for component in components):
        if value != b"/":
            raise IndexError(f"{description} is invalid")
    return value


def record_path(record: bytes) -> bytes:
    fields = record.split(b"|")
    expected_fields = {
        b"P": 4,
        b"L": 3,
        b"S": 3,
        b"E": 10,
        b"C": 3,
    }
    if not fields or expected_fields.get(fields[0]) != len(fields):
        raise IndexError(f"validation index record is malformed: {record[:200]!r}")
    return parse_runtime_path(fields[1], "validation index path")


def read_index(path: Path) -> tuple[bytes, list[bytes]]:
    content = path.read_bytes()
    if not content.endswith(b"\n"):
        raise IndexError(f"validation index has no final newline: {path}")
    lines = content.splitlines()
    if len(lines) < 3 or lines[0] != HEADER or lines[-1] != b"end":
        raise IndexError(f"validation index framing is invalid: {path}")
    target_fields = lines[1].split(b" ")
    if (
        len(target_fields) != 2
        or target_fields[0] != b"target"
        or not target_fields[1]
    ):
        raise IndexError(f"validation index target is invalid: {path}")
    records = lines[2:-1]
    if records != sorted(set(records)):
        raise IndexError(f"validation index records are not canonical: {path}")
    for record in records:
        record_path(record)
    return target_fields[1], records
