#!/usr/bin/env python3
"""
Table-driven tests for the DogStatsD URL parser (assembly implementation).
Tests the executable by running it with various DD_DOGSTATSD_URL values.
"""

import subprocess
import os
import sys
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

# Valid test cases
VALID_CASES = [
    TestCase(
        name="udp_localhost_8125",
        url="udp://localhost:8125",
        expect_success=True,
        expect_transport="UDP",
        expect_host="localhost",
        expect_port="8125",
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
        url="unix:///var/run/datadog/dsd.socket",
        expect_success=True,
        expect_transport="UDS_DATAGRAM",
        expect_path="/var/run/datadog/dsd.socket",
    ),
    TestCase(
        name="unix_stream_socket",
        url="unixstream:///var/run/datadog/dsd-stream.socket",
        expect_success=True,
        expect_transport="UDS_STREAM",
        expect_path="/var/run/datadog/dsd-stream.socket",
    ),
    TestCase(
        name="unix_path_with_percent_encoding",
        url="unix:///var/run/my%20socket.sock",
        expect_success=True,
        expect_transport="UDS_DATAGRAM",
        expect_path="/var/run/my socket.sock",
    ),
    TestCase(
        name="unix_path_encoded_slash",
        url="unix:///tmp/test%2Fpath.sock",
        expect_success=True,
        expect_transport="UDS_DATAGRAM",
        expect_path="/tmp/test/path.sock",
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
        parts = output[3:].split(":")
        if len(parts) >= 1:
            result["transport"] = parts[0]
        if len(parts) >= 3 and result["transport"] == "UDP":
            result["host"] = parts[1]
            result["port"] = parts[2] if len(parts) > 2 else None
        elif len(parts) >= 2 and result["transport"] in ("UDS_DATAGRAM", "UDS_STREAM"):
            result["path"] = parts[1]
    elif output.startswith("ERROR:"):
        result["error"] = output[6:]
    
    return result


def run_test(tc: TestCase) -> bool:
    """Run a single test case and return True if it passes."""
    env = os.environ.copy()
    
    # Remove the env var if testing unset case
    if tc.url is None:
        env.pop("DD_DOGSTATSD_URL", None)
    else:
        env["DD_DOGSTATSD_URL"] = tc.url
    
    try:
        result = subprocess.run(
            [EXECUTABLE],
            env=env,
            capture_output=True,
            text=True,
            timeout=5,
        )
        output = result.stdout + result.stderr
    except subprocess.TimeoutExpired:
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
    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed out of {len(all_cases)} tests")
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
