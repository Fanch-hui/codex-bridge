#!/usr/bin/python3
"""Stop idle instances of the installed package before dpkg replaces its files."""

import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys


INSTALL_ROOT = Path("/opt/codex-bridge")
SERVICE = INSTALL_ROOT / "codex-bridge-service"
MARKER = INSTALL_ROOT / ".package-maintenance"


def service_processes(proc_root=Path("/proc")):
    result = []
    for directory in proc_root.iterdir():
        if not directory.name.isdecimal():
            continue
        try:
            image = os.readlink(directory / "exe")
            if image == str(SERVICE) + " (deleted)":
                raise RuntimeError("An earlier Codex Bridge service is still running. Exit it first.")
            if image != str(SERVICE):
                continue
            metadata = directory.stat()
            result.append((int(directory.name), metadata.st_uid, metadata.st_gid))
        except (FileNotFoundError, ProcessLookupError):
            continue
    return result


def socket_paths(process_id, proc_root=Path("/proc")):
    paths = set()
    with (proc_root / str(process_id) / "net/unix").open() as source:
        for line in source:
            fields = line.split(maxsplit=7)
            if len(fields) != 8:
                continue
            path = fields[7].rstrip("\n")
            if path.startswith("/") and path.endswith("/CodexBridge/service.sock"):
                paths.add(path)
    return paths


def runtime_directory(process_id, user_id):
    for path in socket_paths(process_id):
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
                connection.settimeout(2)
                connection.connect(path)
                peer = connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
                peer_pid, peer_uid, _ = struct.unpack("3i", peer)
                if (peer_pid, peer_uid) == (process_id, user_id):
                    return str(Path(path).parent.parent)
        except (ConnectionRefusedError, FileNotFoundError, socket.timeout):
            continue
    raise RuntimeError("The installed service has no trusted control socket. Exit it and retry.")


def shutdown_command(user_id, group_id, runtime_root):
    return [
        "/usr/bin/setpriv", f"--reuid={user_id}", f"--regid={group_id}", "--clear-groups",
        "/usr/bin/env", "-i", "PATH=/usr/bin:/bin", f"XDG_RUNTIME_DIR={runtime_root}",
        str(SERVICE), "--shutdown-if-idle",
    ]


def stop_idle_instance(process_id, user_id, group_id):
    try:
        descriptor = os.pidfd_open(process_id)
    except ProcessLookupError:
        return
    try:
        root = runtime_directory(process_id, user_id)
        result = subprocess.run(shutdown_command(user_id, group_id, root), timeout=35, check=False)
        if result.returncode:
            raise RuntimeError(
                "Upgrade refused: the service is busy or does not support conditional shutdown. "
                "Wait for Agent tasks and commands to finish, exit the old service, then retry."
            )
        poller = select.poll()
        poller.register(descriptor, select.POLLIN)
        if not poller.poll(30_000):
            raise RuntimeError("The installed service has not exited. Package files were not replaced.")
    finally:
        os.close(descriptor)


def prepare_installation():
    INSTALL_ROOT.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(MARKER, os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o644)
    try:
        if os.fstat(descriptor).st_uid != 0:
            raise RuntimeError("The package maintenance marker must be owned by root.")
    finally:
        os.close(descriptor)
    try:
        for process in service_processes():
            stop_idle_instance(*process)
        if service_processes():
            raise RuntimeError("A service instance started during upgrade. Exit it and retry.")
    except BaseException:
        MARKER.unlink(missing_ok=True)
        raise


def main(arguments):
    if arguments and arguments[0] in ("install", "upgrade"):
        prepare_installation()


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"Codex Bridge: {error}", file=sys.stderr)
        sys.exit(1)
