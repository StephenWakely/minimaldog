# minimaldog

A minimal DogStatsD client in bare x86-64 assembly (`minimaldog.asm`). No libc —
hand-rolled `write`/`exit` syscalls, manual stack-walking of `envp` at `_start`.

## Toolchain (via the nix flake)

The system PATH has **no** `nasm`/`gdb`. The flake's `devShell` provides `nasm`
(3.02) and `ld` (binutils). Run tools through the shell:

```sh
nix develop . --command <cmd> [args]
# e.g.
nix develop . --command nasm -v
```

Install additional debugging tools by adding them to `devShell.packages` in
`flake.nix` (e.g. `pkgs.gdb`, `pkgs.strace`).

## Build

```sh
nix develop . --command sh -c 'nasm -f elf64 -o minimaldog.o minimaldog.asm && ld -o minimaldog minimaldog.o'
```

## Verifying asm behavior

C programs are permitted as **verification tools** (the deliverable must stay
pure asm): when asm behaves unexpectedly, write a small C probe that mirrors
the asm's logic to isolate whether the bug is in the asm or in assumptions
about the environment (stack layout, envp, etc.).
