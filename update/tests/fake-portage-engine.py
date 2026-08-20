#!/usr/bin/env python3

"""Minimal Portage Engine control-plane double for contract tests."""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


def canonical_bytes(value: dict[str, Any]) -> bytes:
    return (
        json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n"
    ).encode("utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--port-file", type=Path, required=True)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--mismatch-image", action="store_true")
    arguments = parser.parse_args()
    target = json.loads(arguments.target.read_text(encoding="utf-8"))
    engine = target["engine"]
    expected_key = "volatoo-test-key"
    job_id = "job-volatoo-contract-1"

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"

        def send_json(self, status: int, value: dict[str, Any]) -> None:
            content = canonical_bytes(value)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)

        def do_POST(self) -> None:
            if self.path != "/api/v1/builds/submit":
                self.send_json(404, {"error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                request = json.loads(self.rfile.read(length).decode("utf-8"))
            except (ValueError, UnicodeError, json.JSONDecodeError):
                self.send_json(400, {"error": "invalid request"})
                return
            capture = {
                "api_key": self.headers.get("X-API-Key", ""),
                "idempotency_key": self.headers.get("Idempotency-Key", ""),
                "request": request,
            }
            arguments.capture.write_bytes(canonical_bytes(capture))
            if capture["api_key"] != expected_key:
                self.send_json(401, {"error": "invalid API key"})
                return
            self.send_json(202, {"job_id": job_id, "status": "queued"})

        def do_GET(self) -> None:
            parsed = urlsplit(self.path)
            query = parse_qs(parsed.query)
            if (
                parsed.path != "/api/v1/packages/status"
                or query.get("job_id") != [job_id]
            ):
                self.send_json(404, {"error": "not found"})
                return
            image_digest = engine["image_digest"]
            if arguments.mismatch_image:
                image_digest = "sha256:" + "f" * 64
            self.send_json(
                200,
                {
                    "artifacts": [
                        engine["binhost_path"]
                        + "/app-misc/jq/jq-1.8.1-1.gpkg.tar"
                    ],
                    "job_id": job_id,
                    "resolved_context": {
                        "arch": engine["arch"],
                        "image_digest": image_digest,
                        "mirror_bundle_digest": engine["mirror_bundle_digest"],
                        "profile_id": engine["profile_id"],
                        "required_features": engine["required_features"],
                        "repositories": [
                            {"name": name}
                            for name in engine["repository_names"]
                        ],
                        "resource_class": engine["resource_class"],
                    },
                    "status": "success",
                },
            )

        def log_message(self, format_string: str, *args: object) -> None:
            del format_string, args

    server = HTTPServer(("127.0.0.1", 0), Handler)
    arguments.port_file.write_text(
        f"{server.server_port}\n",
        encoding="ascii",
    )
    server.handle_request()
    server.handle_request()
    server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
