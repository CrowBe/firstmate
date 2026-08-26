#!/usr/bin/env python3
"""Attempt the minimum Marooned control-plane and egress escapes.

The fixture writes one JSON object to stdout and never treats path absence as
an error. A check passes only when every named socket is absent or unreachable,
and when every outbound connection attempt is denied.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import stat
import sys
from collections.abc import Callable
from typing import Any

SCHEMA = 1
FIXTURE_ID = "marooned-hostile-v1"
CONNECT_TIMEOUT_SECONDS = 1.0


class ProbeTimeout(Exception):
    """A bounded probe exceeded its deadline."""


def _alarm_handler(_signum: int, _frame: Any) -> None:
    raise ProbeTimeout("probe timed out")


def bounded(call: Callable[[], Any], seconds: int = 2) -> Any:
    if not hasattr(signal, "SIGALRM"):
        return call()
    previous = signal.signal(signal.SIGALRM, _alarm_handler)
    signal.alarm(seconds)
    try:
        return call()
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous)


def socket_observation(path: str) -> dict[str, Any]:
    observation: dict[str, Any] = {"path": path, "present": False, "reachable": False}
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        observation["outcome"] = "absent"
        return observation
    except OSError as exc:
        observation["outcome"] = "stat-denied"
        observation["error"] = f"{exc.__class__.__name__}: {exc}"
        return observation

    observation["present"] = True
    observation["socket"] = stat.S_ISSOCK(mode)
    if not stat.S_ISSOCK(mode):
        observation["outcome"] = "present-not-socket"
        return observation

    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(CONNECT_TIMEOUT_SECONDS)
    try:
        client.connect(path)
        observation["reachable"] = True
        observation["outcome"] = "connected"
    except OSError as exc:
        observation["outcome"] = "connect-denied"
        observation["error"] = f"{exc.__class__.__name__}: {exc}"
    finally:
        client.close()
    return observation


def socket_check(check_id: str, paths: list[str]) -> dict[str, Any]:
    unique_paths = list(dict.fromkeys(path for path in paths if path))
    observations = [socket_observation(path) for path in unique_paths]
    present = any(item["outcome"] != "absent" for item in observations)
    return {
        "id": check_id,
        "kind": "unix-socket",
        "verdict": "fail" if present else "pass",
        "observations": observations,
    }


def tcp_attempt(name: str, host: str, port: int, family: int) -> dict[str, Any]:
    observation: dict[str, Any] = {
        "name": name,
        "host": host,
        "port": port,
        "reachable": False,
    }
    try:
        client = socket.socket(family, socket.SOCK_STREAM)
    except OSError as exc:
        # A host without this address family (e.g. no IPv6) cannot reach this
        # target, which is the same "denied" outcome as a blocked connect.
        observation["outcome"] = "connect-denied"
        observation["error"] = f"{exc.__class__.__name__}: {exc}"
        return observation
    client.settimeout(CONNECT_TIMEOUT_SECONDS)
    try:
        bounded(lambda: client.connect((host, port)))
        observation["reachable"] = True
        observation["outcome"] = "connected"
    except (OSError, ProbeTimeout) as exc:
        observation["outcome"] = "connect-denied"
        observation["error"] = f"{exc.__class__.__name__}: {exc}"
    finally:
        client.close()
    return observation


def dns_tcp_attempt() -> dict[str, Any]:
    observation: dict[str, Any] = {
        "name": "dns-and-tcp",
        "host": "example.com",
        "port": 443,
        "reachable": False,
    }
    try:
        addresses = bounded(lambda: socket.getaddrinfo("example.com", 443, type=socket.SOCK_STREAM))
        observation["resolvedAddresses"] = sorted({entry[4][0] for entry in addresses})
    except (OSError, ProbeTimeout) as exc:
        observation["outcome"] = "resolution-denied"
        observation["error"] = f"{exc.__class__.__name__}: {exc}"
        return observation

    for family, socktype, protocol, _canonname, address in addresses:
        client = socket.socket(family, socktype, protocol)
        client.settimeout(CONNECT_TIMEOUT_SECONDS)
        try:
            bounded(lambda: client.connect(address))
            observation["reachable"] = True
            observation["outcome"] = "connected"
            observation["connectedAddress"] = address[0]
            break
        except (OSError, ProbeTimeout) as exc:
            observation["outcome"] = "connect-denied"
            observation["error"] = f"{exc.__class__.__name__}: {exc}"
        finally:
            client.close()
    return observation


def network_check() -> dict[str, Any]:
    observations = [
        tcp_attempt("literal-ipv4", "1.1.1.1", 443, socket.AF_INET),
        tcp_attempt("literal-ipv6", "2606:4700:4700::1111", 443, socket.AF_INET6),
        dns_tcp_attempt(),
    ]
    reachable = any(item["reachable"] for item in observations)
    return {
        "id": "outbound-network",
        "kind": "network-egress",
        "verdict": "fail" if reachable else "pass",
        "observations": observations,
    }


def main() -> int:
    uid = os.getuid()
    xdg_runtime = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{uid}")
    ssh_auth_sock = os.environ.get("SSH_AUTH_SOCK", "")
    checks = [
        socket_check("docker-socket", ["/var/run/docker.sock", "/run/docker.sock"]),
        socket_check(
            "podman-socket",
            ["/run/podman/podman.sock", f"{xdg_runtime}/podman/podman.sock", f"/run/user/{uid}/podman/podman.sock"],
        ),
        socket_check(
            "containerd-socket",
            ["/run/containerd/containerd.sock", "/var/run/containerd/containerd.sock", "/run/k3s/containerd/containerd.sock", "/run/k0s/containerd.sock"],
        ),
        socket_check("dbus-socket", ["/run/dbus/system_bus_socket", "/var/run/dbus/system_bus_socket"]),
        socket_check("ssh-agent-socket", [ssh_auth_sock, f"/run/user/{uid}/gcr/ssh"]),
        socket_check("systemd-socket", ["/run/systemd/private", "/run/systemd/notify"]),
        socket_check(
            "cloud-control-socket",
            [
                "/run/host-services/backend.sock",
                "/run/host-services/docker.proxy.sock",
                "/var/run/kubelet.sock",
                "/run/google_osconfig_agent.sock",
                "/var/run/google-cloud-ops-agent.sock",
                "/run/azure-vm-agent.sock",
            ],
        ),
        network_check(),
    ]
    failures = [check["id"] for check in checks if check["verdict"] != "pass"]
    result = {
        "schema": SCHEMA,
        "fixture": FIXTURE_ID,
        "checks": checks,
        "summary": {
            "pass": len(checks) - len(failures),
            "fail": len(failures),
            "failedChecks": failures,
        },
        "verdict": "pass" if not failures else "fail",
    }
    json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
