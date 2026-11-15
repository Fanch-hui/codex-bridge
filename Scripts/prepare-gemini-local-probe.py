#!/usr/bin/env python3
"""Prepare a loopback HTTP endpoint and marker for the local MCP probe."""

from __future__ import annotations

import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import shlex
import sys
from typing import Sequence


MARKER_BODY = b"codex-bridge-local-mcp-probe-v1\n"
PROBE_PATH = "/codex-bridge-local-mcp-probe"


class ProbeRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        if not self._has_exact_host():
            self._respond(400)
            return
        if self.path != PROBE_PATH:
            self._respond(404)
            return
        self._respond(
            200,
            body=MARKER_BODY,
            headers=(("Content-Type", "text/plain; charset=utf-8"),),
        )

    def _reject_method(self) -> None:
        if not self._has_exact_host():
            self._respond(400)
            return
        self._respond(405, headers=(("Allow", "GET"),))

    def _has_exact_host(self) -> bool:
        expected = f"127.0.0.1:{self.server.server_port}"
        return self.headers.get_all("Host", []) == [expected]

    def _respond(
        self,
        status: int,
        body: bytes = b"",
        headers: tuple[tuple[str, str], ...] = (),
    ) -> None:
        self.close_connection = True
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def __getattr__(self, name: str):
        if name.startswith("do_"):
            return self._reject_method
        raise AttributeError(name)

    def log_message(self, format: str, *args: object) -> None:
        return


class ProbeHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def server_bind(self) -> None:
        if self.server_address[0] != "127.0.0.1":
            raise ValueError("probe server must bind to 127.0.0.1")
        self.socket.bind(self.server_address)
        self.server_address = self.socket.getsockname()
        self.server_name = "127.0.0.1"
        self.server_port = self.server_address[1]


def create_marker_directory(directory: Path) -> Path:
    if os.name != "posix":
        raise OSError("private 0700/0600 permissions require a POSIX host")
    if not directory.is_absolute():
        raise ValueError("--directory must be an absolute path")

    directory.mkdir(mode=0o700)
    os.chmod(directory, 0o700)
    marker = directory / "marker.txt"
    descriptor = os.open(
        marker,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
    )
    with os.fdopen(descriptor, "wb") as output:
        os.fchmod(output.fileno(), 0o600)
        output.write(MARKER_BODY)
        output.flush()
    return marker


def render_command(executable: str, endpoint: str, marker: Path) -> str:
    return shlex.join(
        [
            executable,
            "--mcp-stdio-probe",
            "--endpoint",
            endpoint,
            "--marker-file",
            str(marker),
        ]
    )


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", required=True, metavar="ABSOLUTE_PATH")
    parser.add_argument("--directory", required=True, type=Path, metavar="NEW_DIRECTORY")
    arguments = parser.parse_args(argv)
    if not Path(arguments.executable).is_absolute():
        parser.error("--executable must be an absolute path")
    if not arguments.directory.is_absolute():
        parser.error("--directory must be an absolute path")
    return arguments


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_args(argv)
    try:
        marker = create_marker_directory(arguments.directory)
        with ProbeHTTPServer(("127.0.0.1", 0), ProbeRequestHandler) as server:
            endpoint = f"http://127.0.0.1:{server.server_port}{PROBE_PATH}"
            print(render_command(arguments.executable, endpoint, marker), flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                pass
        return 0
    except (OSError, ValueError) as error:
        print(f"{Path(sys.argv[0]).name}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
