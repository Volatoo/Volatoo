#!/usr/bin/env python3

import re
import sys
from pathlib import Path


UUID_NAME = re.compile(rb"20[0-9]{2}(?:-[0-9]{2}){6}\.uuid")
NORMALIZED_UUID_NAME = b"2000-01-01-00-00-00-00.uuid"
FAT_OEM_NAME = b"MTOO4049"
FAT_TYPE = b"FAT12   "
NORMALIZED_FAT_SERIAL = bytes.fromhex("00012000")


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: normalize-iso.py ISO")

    path = Path(sys.argv[1])
    data = bytearray(path.read_bytes())

    uuid_names = set(UUID_NAME.findall(data))
    if len(uuid_names) != 1:
        fail("expected exactly one generated GRUB ISO UUID name")
    uuid_name = uuid_names.pop()
    uuid_count = data.count(uuid_name)
    if uuid_count != 4:
        fail(f"expected four generated GRUB ISO UUID references, found {uuid_count}")
    data = bytearray(data.replace(uuid_name, NORMALIZED_UUID_NAME))
    joliet_uuid_name = b"".join(b"\x00" + bytes((value,)) for value in uuid_name)
    normalized_joliet_name = b"".join(
        b"\x00" + bytes((value,)) for value in NORMALIZED_UUID_NAME
    )
    joliet_count = data.count(joliet_uuid_name)
    if joliet_count != 2:
        fail(f"expected two Joliet GRUB ISO UUID references, found {joliet_count}")
    data = bytearray(data.replace(joliet_uuid_name, normalized_joliet_name))

    fat_boot_sectors = []
    offset = 0
    while True:
        offset = data.find(FAT_OEM_NAME, offset)
        if offset < 0:
            break
        boot_sector = offset - 3
        if boot_sector >= 0 and data[boot_sector + 54 : boot_sector + 62] == FAT_TYPE:
            fat_boot_sectors.append(boot_sector)
        offset += len(FAT_OEM_NAME)
    if len(fat_boot_sectors) != 1:
        fail(f"expected one GRUB FAT12 boot image, found {len(fat_boot_sectors)}")
    serial_offset = fat_boot_sectors[0] + 39
    data[serial_offset : serial_offset + 4] = NORMALIZED_FAT_SERIAL

    path.write_bytes(data)


if __name__ == "__main__":
    main()
