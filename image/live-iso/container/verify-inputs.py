#!/usr/bin/env python3

import hashlib
import json
from pathlib import Path
import re


DIGEST = re.compile(r"^[0-9a-f]{64}$")
TOP_FIELDS = {"schema", "architecture", "channel", "build_id", "release_index", "installer", "keyring"}
INDEX_FIELDS = {"file", "size", "sha256", "format"}
INSTALLER_FIELDS = {"version", "url", "size", "sha256", "format"}
KEY_FIELDS = {"url", "size", "sha256", "format"}


def fail(message: str) -> None:
    raise SystemExit(f"error: {message}")


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON member {key!r}")
        result[key] = value
    return result


def exact(value: object, fields: set[str], description: str) -> dict:
    if not isinstance(value, dict) or set(value) != fields:
        fail(f"{description} fields are invalid")
    return value


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def safe_file(path: Path, description: str, maximum: int) -> None:
    if path.is_symlink() or not path.is_file():
        fail(f"{description} is not a regular non-symlink file")
    if path.stat().st_size <= 0 or path.stat().st_size > maximum:
        fail(f"{description} size is outside the accepted range")


def artifact(value: object, fields: set[str], expected_format: str, description: str) -> tuple[dict, Path]:
    record = exact(value, fields, description)
    digest = record.get("sha256")
    size = record.get("size")
    url = record.get("url")
    if (
        not isinstance(digest, str)
        or not DIGEST.fullmatch(digest)
        or not isinstance(size, int)
        or isinstance(size, bool)
        or size <= 0
        or not isinstance(url, str)
        or url != f"../../../../objects/sha256/{digest[:2]}/{digest}"
        or record.get("format") != expected_format
    ):
        fail(f"{description} metadata is invalid")
    path = Path("/input/publication/objects/sha256") / digest[:2] / digest
    safe_file(path, f"{description} object", 4 * 1024 * 1024 * 1024)
    if path.stat().st_size != size or digest_file(path) != digest:
        fail(f"{description} object differs from signed metadata")
    return record, path


def main() -> None:
    document_path = Path("/input/publication/releases/amd64/channels/v0.1-dev/live-media-inputs.json")
    index_path = document_path.with_name("index.json")
    safe_file(document_path, "live-media input document", 1024 * 1024)
    safe_file(index_path, "release index", 16 * 1024 * 1024)
    raw = document_path.read_bytes()
    try:
        document = json.loads(raw.decode(), object_pairs_hook=unique_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"live-media input document is invalid JSON: {error}")
    top = exact(document, TOP_FIELDS, "live-media input document")
    if (
        top["schema"] != "org.volatoo.live-media-inputs/v1"
        or top["architecture"] != "amd64"
        or top["channel"] != "v0.1-dev"
        or not isinstance(top["build_id"], str)
        or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", top["build_id"])
        or raw != (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode()
    ):
        fail("live-media input identity or encoding is invalid")

    binding = exact(top["release_index"], INDEX_FIELDS, "release index binding")
    if (
        binding.get("file") != "index.json"
        or binding.get("format") != "release-index-v1"
        or not isinstance(binding.get("size"), int)
        or isinstance(binding.get("size"), bool)
        or binding["size"] <= 0
        or not isinstance(binding.get("sha256"), str)
        or not DIGEST.fullmatch(binding["sha256"])
        or index_path.stat().st_size != binding["size"]
        or digest_file(index_path) != binding["sha256"]
    ):
        fail("release index differs from the signed live-media binding")

    installer, _ = artifact(top["installer"], INSTALLER_FIELDS, "elf64-static", "installer")
    keyring = top["keyring"]
    if not isinstance(keyring, list) or len(keyring) != 1:
        fail("live-media keyring must contain exactly one key")
    key, _ = artifact(keyring[0], KEY_FIELDS, "signify-public-key", "release key")
    version = installer.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,63}", version):
        fail("installer version is invalid")
    Path("/run/live-inputs.env").write_text(
        f"INSTALLER_DIGEST={installer['sha256']}\n"
        f"INSTALLER_VERSION={version}\n"
        f"KEY_DIGEST={key['sha256']}\n"
        f"INDEX_DIGEST={binding['sha256']}\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
