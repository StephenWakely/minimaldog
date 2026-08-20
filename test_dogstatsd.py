#!/usr/bin/env python3
"""
Table-driven tests for the DogStatsD URL parser (assembly implementation).
Tests the executable by running it with various DD_DOGSTATSD_URL values.
"""

import socket
import subprocess
import os
import sys
from contextlib import contextmanager, nullcontext
from dataclasses import dataclass
from typing import Optional

# Path to the compiled executable
EXECUTABLE = os.path.join(os.path.dirname(__file__), "dogstatsd")

@dataclass
class TestCase:
    name: str
    url: Optional[str]
    expect_success: bool
    expect_transport: Optional[str] = None
    expect_host: Optional[str] = None
    expect_port: Optional[str] = None
    expect_path: Optional[str] = None
    expect_error_contains: Optional[str] = None
    # When set ("dgram" or "stream"), a live Unix socket peer is bound at
    # expect_path for the duration of the case (connection-setup tests).
    peer_kind: Optional[str] = None
    skip_reason: Optional[str] = None

# Valid test cases
VALID_CASES = [
    # v1 scope (TODO 3.5): no DNS resolution. Hostnames parse fine but are a
    # deterministic startup error at address construction.
    TestCase(
        name="udp_localhost_8125",
        url="udp://localhost:8125",
        expect_success=False,
        expect_error_contains="host",
    ),
    TestCase(
        name="udp_127_0_0_1_8125",
        url="udp://127.0.0.1:8125",
        expect_success=True,
        expect_transport="UDP",
        expect_host="127.0.0.1",
        expect_port="8125",
    ),
    TestCase(
        name="udp_ipv6_loopback",
        url="udp://[::1]:8125",
        expect_success=True,
        expect_transport="UDP",
        expect_host="::1",
        expect_port="8125",
    ),
    TestCase(
        name="unix_datagram_socket",
        url="unix:///tmp/minimaldog-test/dsd.socket",
        expect_success=True,
        expect_transport="UDS_DATAGRAM",
        expect_path="/tmp/minimaldog-test/dsd.socket",
        peer_kind="dgram",
    ),
    TestCase(
        name="unix_stream_socket",
        url="unixstream:///tmp/minimaldog-test/dsd-stream.socket",
        expect_success=True,
        expect_transport="UDS_STREAM",
        expect_path="/tmp/minimaldog-test/dsd-stream.socket",
        peer_kind="stream",
    ),
    TestCase(
        name="unix_path_with_percent_encoding",
        url="unix:///tmp/minimaldog-test/my%20socket.sock",
        expect_success=True,
        expect_transport="UDS_DATAGRAM",
        expect_path="/tmp/minimaldog-test/my socket.sock",
        peer_kind="dgram",
    ),
    TestCase(
        name="unix_path_encoded_slash",
        url="unix:///tmp/minimaldog-test/test%2Fpath.sock",
        expect_success=True,
        expect_transport="UDS_DATAGRAM",
        expect_path="/tmp/minimaldog-test/test/path.sock",
        peer_kind="dgram",
    ),
]

# Invalid test cases
INVALID_CASES = [
    TestCase(
        name="udp_missing_port",
        url="udp://localhost",
        expect_success=False,
        expect_error_contains="port",
    ),
    TestCase(
        name="udp_empty_host",
        url="udp://:8125",
        expect_success=False,
        expect_error_contains="host",
    ),
    TestCase(
        name="udp_port_zero",
        url="udp://localhost:0",
        expect_success=False,
        expect_error_contains="port",
    ),
    TestCase(
        name="udp_port_too_large",
        url="udp://localhost:65536",
        expect_success=False,
        expect_error_contains="port",
    ),
    TestCase(
        name="unix_relative_path",
        url="unix://relative/path.sock",
        expect_success=False,
        expect_error_contains="absolute",
    ),
    TestCase(
        name="unixstream_empty",
        url="unixstream://",
        expect_success=False,
        expect_error_contains="path",
    ),
    # No peer socket exists at this path: connect fails, the binary logs and
    # retries forever (retry loop), so the case times out after logging.
    TestCase(
        name="unix_datagram_no_peer",
        url="unix:///tmp/minimaldog-test/nopeer.sock",
        expect_success=False,
        expect_error_contains="connect",
    ),
    TestCase(
        name="unknown_scheme_tcp",
        url="tcp://localhost:8125",
        expect_success=False,
        expect_error_contains="scheme",
    ),
    TestCase(
        name="url_with_credentials",
        url="udp://user:pass@localhost:8125",
        expect_success=False,
        expect_error_contains="user",
    ),
    TestCase(
        name="url_with_query",
        url="udp://localhost:8125?foo=bar",
        expect_success=False,
        expect_error_contains="query",
    ),
    TestCase(
        name="url_with_fragment",
        url="udp://localhost:8125#section",
        expect_success=False,
        expect_error_contains="fragment",
    ),
    TestCase(
        name="unix_with_query",
        url="unix:///path.sock?foo=bar",
        expect_success=False,
        expect_error_contains="query",
    ),
    TestCase(
        name="unix_with_fragment",
        url="unix:///path.sock#section",
        expect_success=False,
        expect_error_contains="fragment",
    ),
    TestCase(
        name="malformed_percent_escape",
        url="unix:///path%GG.sock",
        expect_success=False,
        expect_error_contains="percent",
    ),
    TestCase(
        name="incomplete_percent_escape",
        url="unix:///path%2.sock",
        expect_success=False,
        expect_error_contains="percent",
    ),
    TestCase(
        name="nul_byte_in_url",
        url="udp://localhost\x00:8125",
        expect_success=False,
        expect_error_contains="NUL",
        skip_reason="Environment variables cannot contain embedded NUL bytes",
    ),
]

# Environment variable not set
EMPTY_CASES = [
    TestCase(
        name="env_var_not_set",
        url=None,
        expect_success=False,
        expect_error_contains="not set",
    ),
    TestCase(
        name="env_var_empty",
        url="",
        expect_success=False,
        expect_error_contains="empty",
    ),
]


def parse_output(output: str) -> dict:
    """Parse the executable output into a structured dict."""
    result = {
        "success": False,
        "transport": None,
        "host": None,
        "port": None,
        "path": None,
        "error": None,
    }
    
    output = output.strip()
    if output.startswith("OK:"):
        result["success"] = True
        payload = output[3:]
        if payload.startswith("UDP:"):
            result["transport"] = "UDP"
            host_and_port = payload[4:]
            if host_and_port.startswith("["):
                close = host_and_port.find("]")
                if close != -1:
                    result["host"] = host_and_port[1:close]
                    if close + 1 < len(host_and_port) and host_and_port[close + 1] == ":":
                        result["port"] = host_and_port[close + 2 :]
            else:
                host, sep, port = host_and_port.rpartition(":")
                if sep:
                    result["host"] = host
                    result["port"] = port
        elif payload.startswith("UDS_DATAGRAM:"):
            result["transport"] = "UDS_DATAGRAM"
            result["path"] = payload[len("UDS_DATAGRAM:") :]
        elif payload.startswith("UDS_STREAM:"):
            result["transport"] = "UDS_STREAM"
            result["path"] = payload[len("UDS_STREAM:") :]
    elif output.startswith("ERROR:"):
        result["error"] = output[6:]
    
    return result


@contextmanager
def unix_peer(path: str, kind: str):
    """Bind a live Unix socket peer at path for the duration of the block."""
    sock_type = socket.SOCK_STREAM if kind == "stream" else socket.SOCK_DGRAM
    fd = socket.socket(socket.AF_UNIX, sock_type)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        fd.bind(path)
        if kind == "stream":
            fd.listen(4)
        yield
    finally:
        fd.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


# Expected wire payload (TODO 1.2): the fixed counter, no tags.
EXPECTED_METRIC = b"minimaldog.heartbeat:1|c"


@contextmanager
def udp_listener():
    """Bind a UDP socket on 127.0.0.1:0; yield (socket, url)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.settimeout(4)
    try:
        yield s, f"udp://127.0.0.1:{port}"
    finally:
        s.close()


@contextmanager
def uds_listener(path: str, kind: str):
    """Bind a Unix socket peer at path; yield (socket, url)."""
    sock_type = socket.SOCK_STREAM if kind == "stream" else socket.SOCK_DGRAM
    s = socket.socket(socket.AF_UNIX, sock_type)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        s.bind(path)
        if kind == "stream":
            s.listen(4)
        s.settimeout(4)
        yield s, f"unix{'stream' if kind == 'stream' else ''}://{path}"
    finally:
        s.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def run_send_case(name: str, listener, stream: bool) -> bool:
    """Run the binary against a live listener and verify one metric arrives."""
    env = os.environ.copy()
    try:
        with listener as (lsn, url):
            env["DD_DOGSTATSD_URL"] = url
            result = subprocess.run(
                [EXECUTABLE],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            out = result.stdout + result.stderr
            if not out.startswith("OK:"):
                print(f"  FAIL: {name} - expected OK output, got: {out.strip()!r}")
                return False
            if stream:
                conn, _ = lsn.accept()
                data = conn.recv(len(EXPECTED_METRIC))
                conn.close()
            else:
                data, _ = lsn.recvfrom(65536)
            if data != EXPECTED_METRIC:
                print(f"  FAIL: {name} - expected {EXPECTED_METRIC!r}, got {data!r}")
                return False
    except (subprocess.TimeoutExpired, socket.timeout, OSError) as exc:
        print(f"  FAIL: {name} - {type(exc).__name__}: {exc}")
        return False
    return True


def run_test(tc: TestCase) -> bool:
    """Run a single test case and return True if it passes."""
    if tc.skip_reason:
        print(f"  SKIP: {tc.name} - {tc.skip_reason}")
        return True

    env = os.environ.copy()
    
    # Remove the env var if testing unset case
    if tc.url is None:
        env.pop("DD_DOGSTATSD_URL", None)
    else:
        env["DD_DOGSTATSD_URL"] = tc.url
    
    peer = unix_peer(tc.expect_path, tc.peer_kind) if tc.peer_kind else nullcontext()
    with peer:
        try:
            result = subprocess.run(
                [EXECUTABLE],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )
            output = result.stdout + result.stderr
        except subprocess.TimeoutExpired as exc:
            # The retry loop keeps the process alive after logging a connect
            # failure; if an error substring was expected, check what it wrote.
            raw = exc.output or b""
            text_out = raw.decode(errors="replace") if isinstance(raw, bytes) else raw
            if tc.expect_error_contains and tc.expect_error_contains.lower() in text_out.lower():
                return True
            print(f"  FAIL: {tc.name} - timeout")
            return False
        except FileNotFoundError:
            print(f"  FAIL: {tc.name} - executable not found at {EXECUTABLE}")
            return False
    
    parsed = parse_output(output)
    
    # Check success/failure
    if parsed["success"] != tc.expect_success:
        print(f"  FAIL: {tc.name}")
        print(f"    Expected success={tc.expect_success}, got success={parsed['success']}")
        print(f"    Output: {output.strip()}")
        return False
    
    if not tc.expect_success:
        # Check error message contains expected text
        if tc.expect_error_contains:
            if tc.expect_error_contains.lower() not in (parsed["error"] or "").lower():
                print(f"  FAIL: {tc.name}")
                print(f"    Expected error to contain '{tc.expect_error_contains}'")
                print(f"    Got error: {parsed['error']}")
                return False
        return True
    
    # For success cases, check parsed values
    if tc.expect_transport and parsed["transport"] != tc.expect_transport:
        print(f"  FAIL: {tc.name}")
        print(f"    Expected transport={tc.expect_transport}, got {parsed['transport']}")
        return False
    
    if tc.expect_host and parsed["host"] != tc.expect_host:
        print(f"  FAIL: {tc.name}")
        print(f"    Expected host={tc.expect_host}, got {parsed['host']}")
        return False
    
    if tc.expect_port and parsed["port"] != tc.expect_port:
        print(f"  FAIL: {tc.name}")
        print(f"    Expected port={tc.expect_port}, got {parsed['port']}")
        return False
    
    if tc.expect_path and parsed["path"] != tc.expect_path:
        print(f"  FAIL: {tc.name}")
        print(f"    Expected path={tc.expect_path}, got {parsed['path']}")
        return False
    
    return True


def main():
    """Run all tests and report results."""
    all_cases = VALID_CASES + INVALID_CASES + EMPTY_CASES
    
    passed = 0
    failed = 0
    
    print("=" * 60)
    print("DogStatsD URL Parser Tests")
    print("=" * 60)
    print()
    
    for tc in all_cases:
        if run_test(tc):
            print(f"  PASS: {tc.name}")
            passed += 1
        else:
            failed += 1
    
    print()
    print("Send tests (one metric per case, captured by a local listener):")
    send_cases = [
        ("send_udp", udp_listener(), False),
        ("send_unix_datagram",
         uds_listener("/tmp/minimaldog-test/send-dg.sock", "dgram"), False),
        ("send_unix_stream",
         uds_listener("/tmp/minimaldog-test/send-str.sock", "stream"), True),
    ]
    for name, listener, stream in send_cases:
        if run_send_case(name, listener, stream):
            print(f"  PASS: {name}")
            passed += 1
        else:
            failed += 1
    
    print()
    print("=" * 60)
    total = len(all_cases) + len(send_cases)
    print(f"Results: {passed} passed, {failed} failed out of {total} tests")
    print("=" * 60)
    
    # Show transport mapping summary
    print()
    print("Transport Mapping Summary:")
    print("  udp://host:port        -> UDP datagram socket (AF_INET/AF_INET6)")
    print("  unix://path            -> Unix datagram socket (AF_UNIX, SOCK_DGRAM)")
    print("  unixstream://path      -> Unix stream socket (AF_UNIX, SOCK_STREAM)")
    print()
    
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
