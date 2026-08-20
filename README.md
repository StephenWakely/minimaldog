# minimaldog

A minimal DogStatsD client in bare x86-64 assembly. No libc, no runtime, no
linker scripts — a single NASM source file (`dogstatsd.asm`, ~650 lines) that
talks to Linux directly through `write`, `exit`, and `socket` syscalls.

At startup the program walks the stack itself to locate `envp`, searches it
for `DD_DOGSTATSD_URL`, parses and validates the URL, creates the
corresponding socket, and reports the result on stdout.

## Behavior

Reads the target from the `DD_DOGSTATSD_URL` environment variable (walked
manually from the `_start` stack layout — there is no `getenv`).

### Supported URL forms

| URL | Result |
| --- | --- |
| `udp://ip:port` | `OK:UDP:ip:port` — `AF_INET` / `SOCK_DGRAM` socket (v1: numeric IPv4 only, no DNS) |
| `udp://[ipv6]:port` | `OK:UDP:ipv6:port` — bracketed IPv6 hosts, `AF_INET6` socket |
| `unix:///abs/path` | `OK:UDS_DATAGRAM:/abs/path` — `AF_UNIX` / `SOCK_DGRAM` |
| `unixstream:///abs/path` | `OK:UDS_STREAM:/abs/path` — `AF_UNIX` / `SOCK_STREAM` |

Validation rules:

- UDP: host required, port required and numeric in range 1–65535
- Unix: path required and must be absolute; `%XX` percent-escapes are
  decoded (invalid escapes and short sequences are rejected)
- All schemes: userinfo (`@`), query (`?`), and fragment (`#`) components
  are rejected

### Output and exit codes

```console
$ DD_DOGSTATSD_URL=udp://127.0.0.1:8125 ./dogstatsd
OK:UDP:127.0.0.1:8125            # exit 0

$ DD_DOGSTATSD_URL=udp://localhost:8125 ./dogstatsd
ERROR:unsupported host (numeric IPv4 required in v1)   # exit 1

$ DD_DOGSTATSD_URL=gopher://x:1 ./dogstatsd
ERROR:unknown scheme             # exit 1
```

Error messages include `DD_DOGSTATSD_URL not set`, `DD_DOGSTATSD_URL is
empty`, `unknown scheme`, `UDP requires port`, `UDP port out of range`,
`Unix socket path must be absolute`, `malformed percent escape`,
`socket creation failed`, and friends (see the `err_*` strings in
`dogstatsd.asm`).

### Locked-in runtime flow and failure policy (TODO 1.1)

The steady-state control flow is decided and written as a comment above
`_start` in `dogstatsd.asm`; TODO items 2–8 will implement it:

- After a successful parse: `create_socket` → `connect_socket` →
  `send_loop` (send metric → sleep for the interval → repeat).
- `connect()` is used for all three transports: it pins the destination for
  datagram sockets and establishes stream connections.
- **Configuration errors** (env var missing/empty, URL parse failure,
  unsupported hostname, malformed numeric IP) log to stdout and exit with
  code 1; they are never retried because the input cannot change at runtime.
- **Transient transport failures** (socket/connect before the first send,
or a failed send after steady state is reached) log to stdout, sleep for
  the retry interval, and retry forever — the process does not exit on
  them.

The current binary still stops after printing `OK:`; the loop above is the
design target.

### Metric payload (TODO 1.2)

Until metric configurability exists, every interval the client sends this
exact 24-byte counter payload:

```
minimaldog.heartbeat:1|c
```

No tags in v1; the name/type are fixed.

### Retry policy (TODO 1.3)

- `socket()` fails → log, sleep for the retry interval, retry forever.
- `connect()` fails → log, sleep for the retry interval, retry forever
  (stream and datagram alike).
- `send()` fails after running → log; stream transports close the fd and
  repeat create + connect, datagram transports keep the socket; sleep for
  the retry interval, resume sending.
- The retry interval **is** the metric interval: one constant, default
  60 seconds.

## Build

The toolchain comes from the Nix flake (`nasm` + binutils `ld`); neither is
expected to be on the system `PATH`:

```sh
nix develop . --command sh -c 'nasm -f elf64 -o dogstatsd dogstatsd.asm && ld -o dogstatsd dogstatsd.o'
```

Or via the flake package:

```sh
nix build .
./result/bin/dogstatsd
```

`nix develop .` gives a shell with `nasm`, `ld`, `python3`, `pytest`, and
`gdb`.

## Run

```sh
DD_DOGSTATSD_URL=udp://127.0.0.1:8125 nix run .
```

## Tests

`test_dogstatsd.py` is a table-driven pytest suite that executes the
compiled binary with a matrix of valid and invalid `DD_DOGSTATSD_URL` values
and checks the stdout/exit-code contract. Build first, then:

```sh
nix develop . --command pytest test_dogstatsd.py
```

## Project layout

| File | Purpose |
| --- | --- |
| `dogstatsd.asm` | The entire client: envp scan, URL parser, socket creation, output |
| `flake.nix` | Build package, dev shell (nasm, binutils, python3, pytest, gdb) |
| `test_dogstatsd.py` | Table-driven black-box tests of the binary |
| `probe.c` | Small C probe that mirrors the asm's envp/stack logic for debugging |
| `trace.gdb` | GDB convenience script for stepping through `_start` |
| `TODO.md` | Backlog for the next phase (metric send loop) |

## Design notes

- **Stack at `_start`**: `[rsp]` is `argc`, followed by `argv`, a `NULL`,
  then `envp`. The program computes the envp pointer arithmetically
  (`rsp + 8 + argc*8 + 8`) and scans it for a `DD_DOGSTATSD_URL=` prefix.
- **Syscalls**: `write` (1), `exit` (60), `socket` (41), `connect` (42) —
  issued via raw `syscall` instructions; string writes are length-scanned
  by hand in `write_str`.
- **Verification rule**: the deliverable must stay pure assembly. When asm
  behaves unexpectedly, write a small C probe (see `probe.c`) that mirrors
  the asm's logic to isolate whether the bug is in the asm or in an
  assumption about the environment.

## Status

URL parsing, validation, and socket creation are implemented and tested.
Sending actual DogStatsD metrics (steady-state send loop) is the next phase
— see `TODO.md`.
