#!/usr/bin/env python3

"""Validate global FHS semantics represented by an authenticated index."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import posixpath
import re

from fhs_index import IndexError, read_index, record_path


CONTRACT = "org.volatoo.gentoo-fhs/v1"
DEFAULT_LIBRARY_DIRECTORIES = (
    b"/lib",
    b"/lib32",
    b"/lib64",
    b"/usr/lib",
    b"/usr/lib32",
    b"/usr/lib64",
    b"/usr/local/lib",
    b"/usr/local/lib32",
    b"/usr/local/lib64",
)
FORBIDDEN_REFERENCES = (
    b"nix/store",
    b"/.volatoo/state/volatoo/system/objects/sha256",
    b"/state/volatoo/system/objects/sha256",
    b"/volatoo/system/objects/sha256",
    b"/parent/root/",
    b"/workspace/",
    b"/inputs/",
    b"/output/",
    b"/store/",
    b"/work/update/",
)


def fail(message: str) -> None:
    raise IndexError(message)


def has_forbidden_reference(value: bytes) -> bool:
    return any(reference in value for reference in FORBIDDEN_REFERENCES)


def executable(mode: bytes) -> bool:
    return any(int(digit) & 1 for digit in mode[-3:])


def write_lines(path: Path, lines: set[bytes] | list[bytes]) -> None:
    values = sorted(set(lines))
    path.write_bytes(b"".join(value + b"\n" for value in values))


def validate(index: Path, expected_target: bytes, report_dir: Path) -> None:
    target, records = read_index(index)
    if target != expected_target:
        fail("validation index target does not match the realization target")

    paths: dict[bytes, tuple[bytes, bytes]] = {}
    links: dict[bytes, bytes] = {}
    shebangs: dict[bytes, bytes] = {}
    elves: dict[bytes, bytes] = {}
    configurations: list[tuple[bytes, bytes]] = []

    for record in records:
        fields = record.split(b"|")
        path = record_path(record)
        kind = fields[0]
        if kind == b"P":
            inode_type, mode = fields[2], fields[3]
            if inode_type not in {b"b", b"c", b"d", b"f", b"l", b"p", b"s"}:
                fail(f"validation index inode type is invalid: {path!r}")
            if re.fullmatch(rb"[0-7]{3,4}", mode) is None:
                fail(f"validation index mode is invalid: {path!r}")
            if path in paths:
                fail(f"validation index repeats path metadata: {path!r}")
            paths[path] = (inode_type, mode)
        elif kind == b"L":
            if path in links or b"\x00" in fields[2] or b"\n" in fields[2]:
                fail(f"validation index symlink is invalid: {path!r}")
            if has_forbidden_reference(fields[2]):
                fail(f"FHS closure symlink leaks a build/store path: {path!r}")
            links[path] = fields[2]
        elif kind == b"S":
            interpreter = fields[2]
            if path in shebangs or not interpreter.startswith(b"/"):
                fail(f"FHS closure shebang is invalid: {path!r}")
            if has_forbidden_reference(interpreter):
                fail(f"FHS closure shebang leaks a build/store path: {path!r}")
            shebangs[path] = interpreter
        elif kind == b"E":
            if path in elves:
                fail(f"validation index repeats ELF metadata: {path!r}")
            interpreter = fields[9].strip()
            rpath = fields[8].strip()
            if interpreter == b"-":
                interpreter = b""
            if rpath == b"-":
                rpath = b""
            if interpreter and not interpreter.startswith(b"/"):
                fail(f"ELF interpreter is not absolute: {path!r}")
            if has_forbidden_reference(interpreter):
                fail(f"ELF interpreter leaks a build/store path: {path!r}")
            if has_forbidden_reference(rpath):
                fail(f"ELF RPATH/RUNPATH leaks a build/store path: {path!r}")
            elves[path] = b"|".join(fields[1:])
        elif kind == b"C":
            directory = fields[2]
            if not directory.startswith(b"/") or b"\x00" in directory:
                fail(f"dynamic loader directory is invalid: {directory!r}")
            configurations.append((path, directory))

    if b"/" not in paths or paths[b"/"][0] != b"d":
        fail("FHS closure root directory is missing or unsafe")
    for path in links:
        if paths.get(path, (None,))[0] != b"l":
            fail(f"symlink metadata has no matching path: {path!r}")
    for path, (inode_type, _mode) in paths.items():
        if inode_type == b"l" and path not in links:
            fail(f"path has no symlink metadata: {path!r}")
    for path in shebangs:
        metadata = paths.get(path)
        if metadata is None or metadata[0] != b"f" or not executable(metadata[1]):
            fail(f"shebang metadata has no executable regular path: {path!r}")
    for path in elves:
        if paths.get(path, (None,))[0] != b"f":
            fail(f"ELF metadata has no regular path: {path!r}")
    for path, _directory in configurations:
        if paths.get(path, (None,))[0] != b"f":
            fail(f"loader metadata has no regular configuration path: {path!r}")

    def resolve_runtime_path(path: bytes) -> bytes | None:
        path = posixpath.normpath(path)
        for _iteration in range(40):
            components = path.split(b"/")[1:]
            prefix = b""
            for position, component in enumerate(components):
                prefix += b"/" + component
                target = links.get(prefix)
                if target is None:
                    continue
                remainder = b"/".join(components[position + 1 :])
                if target.startswith(b"/"):
                    path = target
                else:
                    path = posixpath.join(posixpath.dirname(prefix), target)
                if remainder:
                    path = posixpath.join(path, remainder)
                path = posixpath.normpath(path)
                break
            else:
                return path if path in paths else None
        return None

    def runtime_metadata(path: bytes) -> tuple[bytes, bytes] | None:
        if path in paths:
            return paths[path]
        resolved = resolve_runtime_path(path)
        return paths.get(resolved) if resolved is not None else None

    def require_directory(path: bytes) -> None:
        if paths.get(path, (None,))[0] != b"d":
            fail(f"FHS closure directory is missing or unsafe: {path.decode(errors='replace')}")

    def require_runtime_path(path: bytes) -> None:
        if runtime_metadata(path) is None:
            fail(f"FHS closure runtime path is missing: {path.decode(errors='replace')}")

    def require_executable(path: bytes) -> None:
        require_runtime_path(path)
        inode_type, mode = runtime_metadata(path) or (b"", b"000")
        if inode_type != b"l" and not executable(mode):
            fail(f"FHS closure runtime path is not executable: {path.decode(errors='replace')}")

    for path in (b"/etc", b"/etc/portage", b"/usr", b"/usr/bin", b"/var", b"/var/db", b"/var/db/pkg"):
        require_directory(path)
    for path in (b"/bin", b"/sbin", b"/lib", b"/bin/sh", b"/sbin/init"):
        require_runtime_path(path)
    require_executable(b"/bin/sh")
    require_executable(b"/sbin/init")

    if b"/openrc/" in target:
        require_directory(b"/etc/init.d")
        require_executable(b"/sbin/openrc")
    elif b"/systemd/" in target:
        require_directory(b"/etc/systemd")
        require_executable(b"/usr/lib/systemd/systemd")
    else:
        fail("FHS closure target has unsupported init semantics")

    for reserved in (b"/inputs", b"/output", b"/parent", b"/state", b"/store", b"/work", b"/workspace"):
        if reserved in paths and paths[reserved][0] != b"d":
            fail(f"FHS closure contains reserved build/store mountpoint: {reserved!r}")
        prefix = reserved + b"/"
        if any(path.startswith(prefix) and metadata[0] != b"d" for path, metadata in paths.items()):
            fail(f"FHS closure contains data below reserved mountpoint: {reserved!r}")

    for path, interpreter in shebangs.items():
        if runtime_metadata(interpreter) is not None:
            continue
        if b"/systemd/" in target and interpreter == b"/sbin/openrc-run" and (
            path.startswith(b"/etc/init.d/") or path.startswith(b"/etc/user/init.d/")
        ):
            continue
        fail(f"FHS closure shebang interpreter is missing: {path!r} -> {interpreter!r}")

    for path, report in elves.items():
        fields = report.split(b"|")
        interpreter = fields[8].strip()
        if interpreter == b"-":
            interpreter = b""
        if interpreter and runtime_metadata(interpreter) is None:
            fail(f"ELF interpreter is missing from FHS closure: {interpreter!r}")
        if b"/glibc/" in target and b"ld-musl" in interpreter:
            fail(f"glibc target contains a musl ELF interpreter: {path!r}")

    report_dir.mkdir(mode=0o700)
    write_lines(report_dir / "directories", list(DEFAULT_LIBRARY_DIRECTORIES) + [directory for _, directory in configurations])
    write_lines(report_dir / "links", [path + b"|" + target for path, target in links.items()])
    write_lines(report_dir / "elf", list(elves.values()))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("index", type=Path)
    parser.add_argument("target", type=os.fsencode)
    parser.add_argument("report_dir", type=Path)
    arguments = parser.parse_args()
    if arguments.report_dir.exists() or arguments.report_dir.is_symlink():
        fail("validation report directory already exists")
    validate(arguments.index, arguments.target, arguments.report_dir)
    print(CONTRACT)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (IndexError, OSError) as error:
        raise SystemExit(f"error: {error}") from error
