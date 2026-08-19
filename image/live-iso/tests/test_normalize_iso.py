#!/usr/bin/env python3

import subprocess
import sys
import tempfile
from pathlib import Path


GENERATED_NAME = b"2026-08-15-12-34-56-00.uuid"
NORMALIZED_NAME = b"2000-01-01-00-00-00-00.uuid"
NORMALIZED_SERIAL = bytes.fromhex("00012000")


def joliet(value: bytes) -> bytes:
    return b"".join(b"\x00" + bytes((byte,)) for byte in value)


def fixture(*, uuid_references: int = 4, fat_images: int = 1) -> bytes:
    data = bytearray()
    for _ in range(uuid_references):
        data.extend(GENERATED_NAME + b"\x00")
    for _ in range(2):
        data.extend(joliet(GENERATED_NAME) + b"\x00\x00")
    for serial in range(fat_images):
        boot_sector = bytearray(512)
        boot_sector[3:11] = b"MTOO4049"
        boot_sector[39:43] = (serial + 1).to_bytes(4, "little")
        boot_sector[54:62] = b"FAT12   "
        data.extend(boot_sector)
    return bytes(data)


def run(normalizer: str, path: Path, *, success: bool) -> subprocess.CompletedProcess:
    result = subprocess.run(
        [normalizer, str(path)],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if (result.returncode == 0) != success:
        raise AssertionError(
            f"normalizer returned {result.returncode}; stderr={result.stderr!r}"
        )
    return result


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_normalize_iso.py NORMALIZER")
    normalizer = sys.argv[1]

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        image = root / "image.iso"
        image.write_bytes(fixture())
        run(normalizer, image, success=True)
        normalized = image.read_bytes()
        assert normalized.count(NORMALIZED_NAME) == 4
        assert normalized.count(joliet(NORMALIZED_NAME)) == 2
        fat_offset = normalized.index(b"MTOO4049") - 3
        assert normalized[fat_offset + 39 : fat_offset + 43] == NORMALIZED_SERIAL

        # Normalization is safe to repeat and must preserve exact bytes.
        run(normalizer, image, success=True)
        assert image.read_bytes() == normalized

        missing_reference = root / "missing-reference.iso"
        missing_reference.write_bytes(fixture(uuid_references=3))
        result = run(normalizer, missing_reference, success=False)
        assert "expected four generated GRUB ISO UUID references" in result.stderr

        duplicate_fat = root / "duplicate-fat.iso"
        duplicate_fat.write_bytes(fixture(fat_images=2))
        result = run(normalizer, duplicate_fat, success=False)
        assert "expected one GRUB FAT12 boot image" in result.stderr

    print("live ISO normalization tests passed")


if __name__ == "__main__":
    main()
