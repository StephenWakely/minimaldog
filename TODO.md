# TODO

This list assumes URL parsing is already working and focuses on the next phase:
create the socket connection, keep it alive, and emit one DogStatsD metric once
per minute. Each item is intentionally small and has explicit success criteria.

## 1. Lock Down Runtime Behavior

### 1.1 Define the steady-state control flow

Status: decided — see the "Runtime control flow" comment above `_start` in
`dogstatsd.asm` (also summarized in README.md). Configuration errors exit(1)
immediately; transient transport failures (socket/connect/send) log, sleep,
and retry forever.

- Decide the exact `_start` flow after `parse_url` succeeds:
  `create_socket` -> `connect_socket` when needed -> `send_loop`.
- Decide whether the process should exit immediately on startup failures or keep
  retrying forever after logging.
- Write the flow as comments near `_start` before changing code.

Success criteria:
- The runtime path from parse success to first metric send is written down in
  code comments or notes.
- There is one unambiguous answer for startup failures and one for runtime
  failures.

### 1.2 Define the metric payload format

Status: decided — fixed counter `minimaldog.heartbeat:1|c` (24 bytes), no
tags; documented in README and the `_start` comment.

- Pick a concrete metric name to send until configurability exists.
- Pick a metric type, likely a counter or gauge, and the exact wire format.
- Decide whether to include tags in the first implementation.
- Document the literal payload string that should be emitted every minute.

Success criteria:
- The project has a single documented metric payload example such as
  `minimaldog.heartbeat:1|c`.
- The assembly implementation can build that payload without guessing.

### 1.3 Decide retry policy

Status: decided — socket/connect/send failures log, sleep for the retry
interval (= metric interval, default 60s), and retry forever; documented in
README and the `_start` comment.

- Decide what happens if socket creation fails.
- Decide what happens if `connect` fails for stream transports.
- Decide what happens if `send` fails after the program has been running.
- Decide the retry interval and whether it is the same as the metric interval.

Success criteria:
- There is a written retry policy for startup failures and runtime failures.
- The retry policy is simple enough to express in a small state machine.

## 2. Extend Parsed State For Connection Setup

Status: done — runtime state lives in named BSS (`socket_fd`,
`sockaddr_buf`, `socklen`, `interval_secs`, `envp_start`, ...); the envp
scan is factored into `find_env`.

### 2.1 Add storage for socket and transport state
- Add BSS or data slots for:
  socket fd, reconnect-needed flag, metric buffer, metric length, and any
  sockaddr buffer needed for `connect`.
- Reserve enough space for both `sockaddr_un` and IP socket structures if both
  are supported in the same binary.

Success criteria:
- All runtime state needed after parsing exists in named storage.
- No stage needs to recompute values by reparsing the original URL.

### 2.2 Preserve parsed UDP host and port in canonical form

Status: done — the host stays textual until connect time; `parsed_ipv6`
(bracketed-host flag) and `parsed_port_bin` (network byte order, filled at
parse time) are the precomputed handoff to address construction.

- Confirm `parsed_host` and `parsed_port` are the only source of truth for UDP.
- Decide whether the host remains textual until connect time or should be
  converted and cached earlier.
- If needed, add fields for binary port and binary address family.

Success criteria:
- The code has a clear handoff from string parse results to binary socket
  address construction.
- No later step depends on output-format buffers by accident.

### 2.3 Preserve parsed Unix path in canonical form

Status: done — `parsed_path` is the single input to sockaddr_un
construction; length is validated against SUN_PATH_MAX (108) when the
address buffer is built.

- Confirm `parsed_path` is the only source of truth for Unix transports.
- Record whether the path should be copied directly into `sockaddr_un` or first
  validated for maximum length.

Success criteria:
- Unix address construction has a single input buffer and a defined max length.

## 3. Implement Address Construction

### 3.1 Add constants and layouts for socket addresses
- Define constants for `sockaddr_in`, `sockaddr_in6`, and `sockaddr_un`
  structure sizes and relevant fields.
- Add constants for `htons`-style byte ordering logic where needed.

Success criteria:
- The code has symbolic constants for every sockaddr field offset it writes.
- No magic numbers remain in address-building code.

### 3.2 Build Unix socket addresses
- Write a helper that fills a `sockaddr_un` buffer from `parsed_path`.
- Reject paths that do not fit into the structure.
- Return a clear error code if the path is too long.

Success criteria:
- Given a valid `unix://` or `unixstream://` URL, the code produces a complete
  `sockaddr_un` buffer and a correct structure length.
- Oversized paths fail with a deterministic logged error.

### 3.3 Build IPv4 UDP socket addresses
- Decide whether hostname support is limited to numeric IPv4 first or whether
  DNS resolution will be added now.
- If numeric-only first, implement dotted-quad parsing in assembly.
- Convert the parsed port into network byte order.

Success criteria:
- `udp://127.0.0.1:8125` produces a valid `sockaddr_in`.
- Invalid numeric IPv4 addresses fail before any send attempt.

### 3.4 Build IPv6 UDP socket addresses
- Decide whether bracketed IPv6 support should remain first-class at connect
  time or be deferred.
- If supported now, implement binary IPv6 parsing or clearly document that
  numeric IPv6 is not yet connectable.

Success criteria:
- There is an explicit implementation decision for IPv6: either working
  connection support with tests, or a deliberate deferred item with a logged
  startup error.

### 3.5 Decide on DNS hostname resolution
- Linux syscalls alone do not provide simple hostname lookup without libc.
- Decide whether to:
  1. Support numeric IP literals only for the first milestone.
  2. Parse `/etc/hosts` only.
  3. Add a custom DNS client over UDP.
- Document the first milestone clearly in README or comments.

Success criteria:
- Hostname behavior is intentionally designed, not accidental.
- The user-visible behavior for `udp://localhost:8125` is documented.

## 4. Implement Socket Lifecycle

### 4.1 Split socket creation from address parsing
- Refactor `create_socket` so it only opens the fd and returns it.
- Add a separate helper that builds the destination address and length.

Success criteria:
- Socket creation and address construction are separate units with separate
  failure paths.
- Each helper has a single responsibility.

### 4.2 Implement `connect_socket`
- Add a helper that calls `connect` for Unix datagram, Unix stream, and UDP.
- For connected UDP sockets, call `connect` once so later sends can use `write`
  or `send`.
- Store the connected fd for reuse in the send loop.

Success criteria:
- The code can create and connect a socket exactly once after startup.
- Failures from `connect` are logged and return control to the retry policy.

### 4.3 Decide whether to reconnect on every failure
- For stream sockets, any send failure may require closing and reconnecting.
- For datagram sockets, decide whether send failure should also trigger
  close-and-reconnect.
- Add a small state flag if the socket can become unusable after startup.

Success criteria:
- The runtime has explicit rules for when an fd is reused and when it is
  discarded.

### 4.4 Implement `close_socket`
- Add a helper for `close(fd)` and clear the stored fd afterward.
- Make it safe to call when no socket is open.

Success criteria:
- Every path that abandons a socket goes through one helper.
- The stored fd cannot be reused after close by mistake.

## 5. Implement Metric Emission

### 5.1 Add the metric payload buffer
- Store the metric payload in `.data` if it is fixed.
- If some fields are dynamic, add a helper to assemble the payload into a
  mutable buffer.

Success criteria:
- The send path has a buffer pointer and exact byte length before syscall time.

### 5.2 Choose the send syscall strategy
- Decide between `write`, `sendto`, or `send`.
- Prefer the smallest implementation that works with connected sockets across
  the supported transports.
- Record the syscall numbers and argument registers needed.

Success criteria:
- There is one send helper with a defined syscall ABI.
- The helper works for every supported transport class.

### 5.3 Implement `send_metric_once`
- Send the exact metric payload over the already connected fd.
- Return success or a small error code.
- Do not mix logging with the send helper itself unless needed for simplicity.

Success criteria:
- A successful call emits exactly one DogStatsD datagram or stream write.
- Failed syscalls return control to the caller without corrupting state.

### 5.4 Handle partial writes for stream sockets
- For `SOCK_STREAM`, loop until the whole payload is written or an error occurs.
- For datagram sockets, treat short writes as failure because the message must
  remain atomic.

Success criteria:
- Stream sends either write the full metric or surface an error.
- Datagram sends never silently emit truncated payloads.

## 6. Implement Time-Based Scheduling

### 6.1 Choose the sleep mechanism
- Decide whether to use `nanosleep` or `clock_nanosleep`.
- Prefer a monotonic-clock-based approach if drift matters.

Success criteria:
- The project has one chosen sleep syscall with documented rationale.

### 6.2 Add a reusable 60-second sleep helper
- Add a helper that sleeps for one minute.
- Handle `EINTR` by resuming the remaining duration or restarting the full
  minute, depending on the chosen policy.

Success criteria:
- One helper can pause the process for approximately 60 seconds repeatedly.
- Interruption behavior is defined and implemented.

### 6.3 Decide first-send timing
- Decide whether the first metric is sent immediately at startup or only after
  the first 60-second delay.
- Document that behavior and test it.

Success criteria:
- Startup behavior is explicit and stable.
- Tests can assert the time ordering of connect, first send, and later sends.

### 6.4 Build the main send loop
- Implement:
  ensure connected -> send metric -> sleep 60s -> repeat.
- On failure:
  log -> close if needed -> wait per retry policy -> retry.

Success criteria:
- The binary can run indefinitely without exiting on ordinary connection
  failures.
- The loop behavior matches the documented retry and timing policy.

## 7. Implement Error Logging To Stdout

### 7.1 Standardize runtime log messages
- Define message prefixes for startup, connect, send, and retry errors.
- Include enough context to distinguish parse failures from runtime failures.

Success criteria:
- Every runtime failure path has a human-readable stdout message.
- Messages are stable enough for tests to match key substrings.

### 7.2 Add errno-aware logging if useful
- Decide whether to print raw negative syscall returns or only coarse messages.
- If printing codes, add a tiny integer-to-string helper.

Success criteria:
- Logged output is useful for diagnosing failures without a debugger.
- The implementation cost stays proportionate to the project’s minimal scope.

### 7.3 Keep stdout logging safe inside loops
- Ensure repeated failures do not corrupt output formatting.
- Make sure each log entry ends with a newline.

Success criteria:
- Repeated runtime errors produce readable line-oriented output.

## 8. Add Verification Coverage

### 8.1 Extend parser tests only where behavior changed
- Keep existing URL parser tests passing.
- Update any expectations if transport support is intentionally narrowed for the
  first connection milestone.

Success criteria:
- Current parser coverage still passes after the runtime changes.

### 8.2 Add connection-setup tests
- Add tests for successful Unix socket connection setup.
- Add tests for UDP numeric IP address connection setup.
- Add tests for unsupported hostname or IPv6 behavior if those are deferred.

Success criteria:
- Each supported transport has at least one passing connection-level test.
- Each deliberately unsupported input has a deterministic failure test.

### 8.3 Add periodic-send integration tests
- Use a local UDP listener or Unix socket listener in Python to capture one or
  more emitted metrics.
- Verify payload correctness and that repeated sends occur roughly once per
  minute.
- For practicality, add a test-only shorter interval if needed.

Success criteria:
- An automated test can observe a metric emitted from the assembly binary.
- The received payload exactly matches the documented metric string.

### 8.4 Add reconnection and error-path tests
- Test startup socket failure logging.
- Test send failure after initial success and confirm retry behavior.
- Test stream partial-write handling if stream transport remains supported.

Success criteria:
- At least one automated test covers each major runtime error path.
- Error logs are asserted, not just manually inspected.

### 8.5 Add a test mode for faster feedback
- Introduce an environment variable or build-time constant for the send interval
  so tests can run with a short period like 1 second.
- Keep production default at 60 seconds.

Success criteria:
- Integration tests finish quickly without changing production behavior.
- The production binary still defaults to one send per minute.

## 9. Update Project Documentation

### 9.1 Document supported connection strings
- State which transports are fully supported for actual connections, not just
  for parsing.
- Call out any first-milestone limitations around DNS or IPv6.

Success criteria:
- A reader can tell which URLs merely parse and which actually connect.

### 9.2 Document runtime behavior
- Explain startup, retry, reconnect, and logging behavior.
- Document whether the first metric is immediate or delayed.

Success criteria:
- Runtime behavior is understandable without reading the assembly.

### 9.3 Document testing workflow
- Add commands for rebuilding and running parser/integration tests.
- If tests need elevated permissions because of sandboxed sockets, note that.

Success criteria:
- Another contributor can run the expected verification steps from the docs.

## 10. Final Readiness Checks

### 10.1 Run the parser suite after runtime refactors
- Rebuild the binary.
- Run the existing parser tests.

Success criteria:
- Parser regressions are caught before runtime testing begins.

### 10.2 Run end-to-end transport checks
- Verify at least one Unix socket path and one UDP path end to end.
- Capture the actual metric bytes received by the test listener.

Success criteria:
- Supported transports work in a live send scenario.

### 10.3 Review failure behavior under repetition
- Force repeated connect failures.
- Force repeated send failures.
- Confirm the process keeps logging and retrying instead of spinning or dying
  unexpectedly.

Success criteria:
- Failure loops are bounded by sleep and remain observable on stdout.

### 10.4 Decide what is explicitly out of scope for v1
- If DNS, full IPv6 connect support, or rich metric configurability are not in
  the first milestone, write that down.

Success criteria:
- The implementation target is crisp enough to finish without scope drift.
