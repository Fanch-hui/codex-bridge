#!/usr/bin/env python3
"""Verify dpkg replaces an idle running service and the installed app reconnects."""

import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys


def service_pid(payload):
    path = Path(os.environ["XDG_RUNTIME_DIR"]) / "CodexBridge/service.sock"
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        peer = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        process_id, user_id, _ = struct.unpack("3i", peer)
    image = os.readlink(f"/proc/{process_id}/exe")
    if user_id != os.getuid() or image != str(payload / "codex-bridge-service"):
        raise RuntimeError("The isolated control socket does not belong to the installed service.")
    return process_id


def verify_replacement(payload, package):
    original_pid = service_pid(payload)
    descriptor = os.pidfd_open(original_pid)
    try:
        poller = select.poll()
        poller.register(descriptor, select.POLLIN)
        if poller.poll(0):
            raise RuntimeError("The service exited before package replacement began.")
        subprocess.run(["dpkg", "--install", str(package)], check=True, timeout=90)
        if not poller.poll(0):
            raise RuntimeError("Package replacement completed before the original service exited.")
    finally:
        os.close(descriptor)

    if (payload / ".package-maintenance").exists():
        raise RuntimeError("Package configuration left service startup blocked.")
    subprocess.run([str(payload / "codex-bridge"), "--ensure-service"], check=True, timeout=30)
    service_pid(payload)
    print("Idle service exited before dpkg completed; the replaced app obtained real Unix IPC.")


if __name__ == "__main__":
    verify_replacement(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
