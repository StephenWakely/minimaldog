; Minimal DogStatsD Client - x86-64 Assembly
; Parses DD_DOGSTATSD_URL, connects the corresponding socket, and emits
; one DogStatsD metric.
; NASM syntax, Linux x86-64

section .data
    env_var_name: db "DD_DOGSTATSD_URL", 0
    env_interval_name: db "DD_DOGSTATSD_INTERVAL_SECS", 0   ; TODO 8.5
    ok_prefix: db "OK:", 0
    err_prefix: db "ERROR:", 0
    transport_udp: db "UDP", 0
    transport_uds_dg: db "UDS_DATAGRAM", 0
    transport_uds_str: db "UDS_STREAM", 0
    colon: db ":", 0
    newline: db 10, 0
    
    err_empty: db "DD_DOGSTATSD_URL is empty", 0
    err_not_found: db "DD_DOGSTATSD_URL not set", 0
    err_scheme: db "unknown scheme", 0
    err_userinfo: db "user info not allowed", 0
    err_query: db "query string not allowed", 0
    err_fragment: db "fragment not allowed", 0
    err_nul: db "NUL byte in URL", 0
    err_udp_nohost: db "UDP requires non-empty host", 0
    err_udp_noport: db "UDP requires port", 0
    err_udp_port: db "UDP port out of range", 0
    err_unix_no_path: db "Unix socket path required", 0
    err_unix_relative: db "Unix socket path must be absolute", 0
    err_malformed_pct: db "malformed percent escape", 0
    err_invalid_hex: db "invalid hex in percent escape", 0
    err_unix_query: db "query not allowed in unix URL", 0
    err_unix_fragment: db "fragment not allowed in unix URL", 0
    err_socket_create: db "socket creation failed", 0
    err_connect: db "connect failed", 0
    err_send: db "send failed", 0
    err_bad_host: db "unsupported host (numeric IPv4 required in v1)", 0
    err_bad_v6: db "malformed IPv6 address", 0
    err_path_too_long: db "unix path too long", 0
    err_interval: db "DD_DOGSTATSD_INTERVAL_SECS must be 1-3600", 0
    
; Metric payload (TODO 1.2/5.1): fixed counter, no tags. The send path uses
; metric_payload + metric_len directly; nothing is assembled at runtime.
    metric_payload: db "minimaldog.heartbeat:1|c"
    metric_len equ $ - metric_payload      ; 24 bytes

    scheme_udp: db "udp://", 0
    scheme_unix: db "unix://", 0
    scheme_unixstream: db "unixstream://", 0

; struct sigaction for ignoring SIGPIPE (TODO 6.4): sa_handler, sa_mask,
; sa_flags, sa_restorer — 28 bytes.
    sigpipe_ign: dd SIG_IGN
                 dq 0
                 dq 0
    
    AF_INET equ 2
    AF_INET6 equ 10
    AF_UNIX equ 1
    SOCK_STREAM equ 1        ; per <asm-generic/socket.h>
    SOCK_DGRAM equ 2
    IPPROTO_UDP equ 17

; --- sockaddr layout constants (TODO 3.1) -----------------------------------
; Every offset the address builders write is named here; no magic numbers in
; address-building code.
    SUN_PATH_MAX equ 108        ; max sun_path length including NUL
    SOCKADDR_UN_LEN equ 110     ; sizeof(struct sockaddr_un)
    SOCKADDR_IN_LEN equ 16      ; sizeof(struct sockaddr_in)
    SOCKADDR_IN6_LEN equ 28     ; sizeof(struct sockaddr_in6)
    SA_OFF_FAMILY equ 0         ; sa_family_t
    SUN_OFF_PATH equ 2          ; sun_path[]
    SIN_OFF_PORT equ 2          ; sin_port (network byte order)
    SIN_OFF_ADDR equ 4          ; sin_addr.s_addr (4 bytes)
    SIN6_OFF_PORT equ 2         ; sin6_port (network byte order)
    SIN6_FLOWINFO equ 4         ; sin6_flowinfo
    SIN6_OFF_ADDR equ 12        ; sin6_addr (16 bytes)

; Address construction failure codes (returned in rax by build_addr):
ADDR_ERR_HOST equ 1       ; build_ipv4_addr: hostname / non-numeric text
ADDR_ERR_V6 equ 2         ; build_ipv6_addr: malformed IPv6 text
ADDR_ERR_PATHLEN equ 3    ; build_unix_addr: path does not fit sun_path
    
    EINTR equ 4
    SIGPIPE equ 13
    SIG_IGN equ 1
    SYS_write equ 1
    SYS_exit equ 60
    SYS_rt_sigaction equ 13   ; x86-64 has no standalone signal() syscall
    SYS_getenv equ 318
    SYS_close equ 3
    SYS_socket equ 41
    SYS_connect equ 42
    SYS_nanosleep equ 35

section .bss
    url_buf: resb 1024
    host_buf: resb 256
    path_buf: resb 512
    port_buf: resb 16
    result_buf: resb 512
    parsed_transport: resb 1
    parsed_host: resb 256
    parsed_port: resb 16
    parsed_path: resb 512

; --- Runtime state for connection setup (TODO 2.1) -------------------------
; Everything needed after parsing lives in named storage here; no later step
; reparses the original URL.
    envp_start: resq 1        ; pointer to the envp array, saved at _start
    socket_fd: resd 4         ; open socket fd, 0 = no socket open
    sockaddr_buf: resb 110    ; holds either sockaddr_un (110) or
                              ; sockaddr_in / sockaddr_in6 (16 / 28)
    socklen: resw 2           ; length of the address in sockaddr_buf
    interval_secs: resd 4     ; metric and retry interval, default 60 (TODO 1.3)
    sleep_ts: resq 2          ; struct timespec {tv_sec, tv_nsec} for sleep_interval
    steady_state: resb 1      ; 1 once the first send has succeeded (TODO 6.4)
    parse_only: resb 1        ; DD_DOGSTATSD_PARSE_ONLY set -> print OK, exit 0
; --- Canonical parse results handed to address construction (TODO 2.2/2.3) --
; The host stays textual until connect time; the ipv6 flag and the binary
; port are the only precomputed pieces. parsed_path is the single source of
; truth for Unix transports and is length-checked against SUN_PATH_MAX when
; the sockaddr_un is built (TODO 2.3).
    parsed_ipv6: resb 1       ; 1 if the URL host was bracketed (IPv6 form)
    parsed_port_bin: resw 2   ; UDP port in network byte order

section .text
    global _start

; ---------------------------------------------------------------------------
; Runtime control flow (locked in by TODO item 1.1)
;
; Startup sequence (one-shot, at process start):
;   1. Walk envp on the stack for DD_DOGSTATSD_URL (no libc getenv).
;   2. Copy the value into url_buf and run parse_url.
;   3. On success: create_socket -> connect_socket -> send_loop.
;
; Steady state (after parse succeeds):
;   create_socket   socket() per parsed transport: AF_INET/SOCK_DGRAM for UDP,
;                   AF_UNIX/SOCK_DGRAM for unix, AF_UNIX/SOCK_STREAM for
;                   unixstream. The fd is cached in BSS.
;   connect_socket  connect() is called for all three transports: for UDP it
;                   pins the default destination and enables ICMP error
;                   feedback on later sends; for UDS_STREAM it establishes
;                   the connection; for UDS_DATAGRAM it pins the destination.
;   send_loop       sleep for the interval -> send metric payload -> repeat.
;                   The first send is immediate after connect (TODO 6.3);
;                   sleeping uses nanosleep, resuming the remaining time on
;                   EINTR (TODO 6.1/6.2).
;
; Metric payload (decided in TODO 1.2): the fixed counter
;   minimaldog.heartbeat:1|c
; is sent every interval. No tags in v1.
;
; Failure policy (decided in TODO 1.3):
;   Configuration errors (env var not set, empty value, URL parse/validation
;   failure, unsupported hostname, malformed numeric IP): log to stdout and
;   exit(1) immediately. The input is read once from envp and cannot change
;   while the process runs, so retrying is pointless.
;   Transient transport failures before the first send (socket() or connect()
;   fails): log to stdout, sleep for the retry interval, and retry forever.
;   The process never exits on these.
;   Runtime failures after the first successful send (send() fails, stream
;   peer goes away): log to stdout; for stream transports close the fd and
;   repeat create_socket -> connect_socket; for datagram transports keep the
;   socket; sleep for the retry interval; resume sending. The process never
;   exits on these either.
;   Retry interval = metric interval (one constant, default 60s).
;
; Socket lifecycle rules (decided in TODO 4.3):
;   [socket_fd] == 0 is the "no usable socket" state; there is no separate
;   flag. Before the first send, every create/connect failure goes through
;   the startup retry loop, which closes any live fd before reopening.
;   After a successful send: stream transports close and reconnect on any
;   send failure; datagram transports keep the socket and simply retry the
;   send (implemented in send_loop below).
;
; Net: in steady state the process never exits; the only exit at all is
; exit(1) on configuration errors.
; ---------------------------------------------------------------------------

_start:
    ; Ignore SIGPIPE (TODO 6.4): a stream peer going away must surface as
    ; -EPIPE from write(), not kill the process — the client has to run
    ; indefinitely through ordinary connection failures.
    mov eax, SYS_rt_sigaction
    mov edi, SIGPIPE
    lea rsi, [sigpipe_ign]
    xor edx, edx                ; oldact = NULL
    mov r10d, 8                 ; sigsetsize — 4th syscall arg is R10 on
                                ; x86-64 (the syscall insn clobbers RCX)
    syscall
    ; Stack at _start: [rsp]=argc, [rsp+8]=argv[0], ..., [rsp+8*(argc+1)]=NULL, then envp
    mov rcx, [rsp]        ; rcx = argc
    lea rsi, [rsp+8]      ; rsi = argv start
    lea rsi, [rsi+rcx*8+8] ; rsi = argv + argc + 1 (skip NULL terminator)
                            ; now rsi points to envp array
    mov [envp_start], rsi
    mov rdi, env_var_name
    call find_env
    test rax, rax
    jz start_not_found
    mov rsi, rax          ; rsi = value string after '='
    mov rdi, url_buf
    mov rcx, 1024
    call copy_string
    cmp byte [url_buf], 0
    jz start_empty_url
    mov rdi, url_buf
    call parse_url
    test rax, rax
    jnz start_parse_error
    ; TODO 1.3: one constant for the metric and the retry interval.
    mov dword [interval_secs], 60
    ; TODO 8.5: optional test hook — DD_DOGSTATSD_INTERVAL_SECS overrides the
    ; send/retry period so integration tests can run with a short interval;
    ; the production default above applies when the variable is unset.
    ; An invalid value is a configuration error (exit 1), like a bad URL.
    mov rdi, env_interval_name
    call find_env
    test rax, rax
    jz interval_ok
    mov rsi, rax
    call parse_interval
    test rax, rax
    jnz interval_ok
start_bad_interval:
    mov rdi, err_interval
    call output_error
    jmp start_exit_error
interval_ok:
startup_retry:               ; pre-first-send failures retry forever (TODO 4.2)
    call close_socket         ; discard a failed socket from a previous pass;
                              ; no-op on the first iteration ([socket_fd] == 0)
    call create_socket
    test rax, rax
    jz startup_sock_fail
    call build_addr
    test rax, rax
    jz startup_addr_ok
    ; Address construction failure is a configuration error: the input cannot
    ; change while the process runs, so log and exit(1) (TODO 1.3).
    cmp al, ADDR_ERR_HOST
    je startup_bad_host
    cmp al, ADDR_ERR_V6
    je startup_bad_v6
    call close_socket
    mov rdi, err_path_too_long
    call output_error
    jmp start_exit_error
startup_bad_host:
    call close_socket
    mov rdi, err_bad_host
    call output_error
    jmp start_exit_error
startup_bad_v6:
    call close_socket
    mov rdi, err_bad_v6
    call output_error
    jmp start_exit_error
startup_addr_ok:
    call connect_socket
    test rax, rax
    jz startup_conn_fail
    ; First send after (re)connect is immediate (TODO 6.3).
    call send_metric_once
    test rax, rax
    jz startup_send_fail
    cmp byte [steady_state], 1
    je send_loop               ; steady-state reconnect: resume silently
    call output_success        ; report exactly once, at startup
    mov byte [steady_state], 1
    jmp send_loop

send_loop:                     ; steady state (TODO 6.4): sleep -> send -> repeat
    call sleep_interval
    call send_metric_once
    test rax, rax
    jz send_fail
    jmp send_loop
send_fail:                     ; runtime failure after the first send (TODO 1.3)
    mov rdi, err_send
    call output_error
    cmp byte [parsed_transport], 3
    je sf_stream               ; stream: fd may be broken; rebuild from scratch
    call sleep_interval        ; datagram: keep the socket, wait, retry send
    jmp send_loop
sf_stream:
    call close_socket
    call sleep_interval        ; then recreate + reconnect via startup_retry
    jmp startup_retry

startup_sock_fail:
    mov rdi, err_socket_create
    call output_error
    jmp startup_sleep
startup_conn_fail:
    mov rdi, err_connect
    call output_error
startup_send_fail:
    mov rdi, err_send
    call output_error
startup_sleep:
    call sleep_interval
    jmp startup_retry

start_not_found:
    mov rdi, err_not_found
    call output_error
    jmp start_exit_error

start_empty_url:
    mov rdi, err_empty
    call output_error
    jmp start_exit_error

start_parse_error:
    dec rax
    mov rdi, [parse_error_msgs + rax*8]
    call output_error
    jmp start_exit_error

start_exit_success:
    mov rax, SYS_exit
    xor rdi, rdi
    syscall

start_exit_error:
    mov rax, SYS_exit
    mov rdi, 1
    syscall

; find_env(rdi = NUL-terminated name) -> rax = pointer to the value after
; '=', or 0 if the variable is not present. Exact match: the name must be
; followed by '='. Clobbers r8, r9, r10; saves rsi/rdx.
find_env:
    push rsi
    push rdx
    mov rsi, [envp_start]
find_env_scan:
    mov r10, [rsi]        ; current env string pointer
    test r10, r10
    jz find_env_not_found
    lea r9, [r10]         ; r9 walks the env string
    lea r8, [rdi]         ; r8 walks the name
find_env_match:
    movzx rax, byte [r8]
    test al, al           ; end of name?
    jz find_env_check_eq
    cmp al, [r9]
    jne find_env_next
    inc r8
    inc r9
    jmp find_env_match
find_env_check_eq:
    cmp byte [r9], '='
    jne find_env_next
    lea rax, [r9+1]       ; value starts after '='
    jmp find_env_done
find_env_next:
    add rsi, 8
    jmp find_env_scan
find_env_not_found:
    xor rax, rax
find_env_done:
    pop rdx
    pop rsi
    ret

copy_string:
    push rsi
    push rdi
    mov r8, rdi           ; Save destination pointer
copy_string_loop:
    lodsb
    test al, al
    jz copy_string_done
    cmp rcx, 0
    jz copy_string_done
    stosb
    dec rcx
    jmp copy_string_loop
copy_string_done:
    xor al, al
    stosb
    dec rdi                 ; Point to the null terminator we just stored
    mov rax, rdi            ; Return pointer to null terminator
    pop rdi
    pop rsi
    ret

parse_url:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, 0
    mov rsi, r12
    mov rdi, scheme_udp
    mov rcx, 6
    call strncmp
    test rax, rax
    jz parse_url_found_udp
    mov rsi, r12
    mov rdi, scheme_unix
    mov rcx, 7
    call strncmp
    test rax, rax
    jz parse_url_found_unix
    mov rsi, r12
    mov rdi, scheme_unixstream
    mov rcx, 11
    call strncmp
    test rax, rax
    jz parse_url_found_unixstream
    mov r13, 1
    jmp parse_url_done
parse_url_found_udp:
    mov byte [parsed_transport], 1
    add r12, 6
    call parse_udp
    mov r13, rax
    jmp parse_url_done
parse_url_found_unix:
    mov byte [parsed_transport], 2
    add r12, 7
    call parse_unix
    mov r13, rax
    jmp parse_url_done
parse_url_found_unixstream:
    mov byte [parsed_transport], 3
    add r12, 13
    call parse_unix
    mov r13, rax
    jmp parse_url_done
parse_url_done:
    mov rax, r13
    pop r14
    pop r13
    pop r12
    ret
parse_udp:
    push r12
    push r14
    mov r14, r12
    mov rsi, r12
parse_udp_check_special:
    mov al, [rsi]
    cmp al, 0
    je parse_udp_check_host
    cmp al, '@'
    je parse_udp_err_userinfo
    cmp al, '?'
    je parse_udp_err_query
    cmp al, '#'
    je parse_udp_err_fragment
    inc rsi
    jmp parse_udp_check_special
parse_udp_check_host:
    xor byte [parsed_ipv6], 0   ; TODO 2.2: bracketed host => IPv6 form
    cmp byte [r12], '['
    jne parse_udp_ipv4_host
    mov byte [parsed_ipv6], 1
    mov rsi, r12
parse_udp_inc_search:
    mov al, [rsi]
    cmp al, ']'
    je parse_udp_found_bracket
    cmp al, 0
    je parse_udp_err_nohost
    inc rsi
    jmp parse_udp_inc_search
parse_udp_found_bracket:
    mov rsi, r14
    inc rsi
    mov rdi, parsed_host
    mov rcx, 255
parse_udp_copy_ipv6:
    mov al, [rsi]
    cmp al, ']'
    je parse_udp_ipv6_copied
    cmp rcx, 0
    jz parse_udp_ipv6_copied
    stosb
    inc rsi
    dec rcx
    jmp parse_udp_copy_ipv6
parse_udp_ipv6_copied:
    xor al, al
    stosb
    cmp byte [parsed_host], 0
    je parse_udp_err_nohost
    mov r12, rsi
    inc r12
    jmp parse_udp_check_colon
parse_udp_err_nohost:
    mov rax, 2
    jmp parse_udp_done
parse_udp_ipv4_host:
    mov rsi, r12
    mov rdi, parsed_host
    mov rcx, 255
parse_udp_copy_host:
    mov al, [rsi]
    cmp al, ':'
    je parse_udp_host_copied
    cmp al, 0
    je parse_udp_noport
    cmp rcx, 0
    jz parse_udp_host_copied
    stosb
    inc rsi
    dec rcx
    jmp parse_udp_copy_host
parse_udp_host_copied:
    xor al, al
    stosb
    cmp byte [parsed_host], 0
    jz parse_udp_err_nohost
    mov r12, rsi
    jmp parse_udp_check_colon
parse_udp_noport:
    mov rax, 3
    jmp parse_udp_done
parse_udp_check_colon:
    cmp byte [r12], ':'
    jne parse_udp_noport
    inc r12
    mov rsi, r12
    mov rdi, parsed_port
    mov rcx, 15
parse_udp_copy_port:
    mov al, [rsi]
    cmp al, 0
    je parse_udp_port_copied
    cmp rcx, 0
    jz parse_udp_port_copied
    stosb
    inc rsi
    dec rcx
    jmp parse_udp_copy_port
parse_udp_port_copied:
    xor al, al
    stosb
    mov rsi, parsed_port
    call parse_port
    test rax, rax
    jz parse_udp_err_port
    xor rax, rax
    jmp parse_udp_done
parse_udp_err_port:
    mov rax, 4
    jmp parse_udp_done
parse_udp_err_userinfo:
    mov rax, 11
    jmp parse_udp_done
parse_udp_err_query:
    mov rax, 12
    jmp parse_udp_done
parse_udp_err_fragment:
    mov rax, 13
parse_udp_done:
    pop r14
    pop r12
    ret
parse_unix:
    push r12
    cmp byte [r12], 0
    je parse_unix_err_nopath
    cmp byte [r12], '/'
    jne parse_unix_err_relative
    mov rsi, r12
parse_unix_check_special:
    mov al, [rsi]
    cmp al, 0
    je parse_unix_no_special
    cmp al, '?'
    je parse_unix_err_q
    cmp al, '#'
    je parse_unix_err_f
    inc rsi
    jmp parse_unix_check_special
parse_unix_no_special:
    mov rsi, r12
    mov rdi, parsed_path
    mov rcx, 511
parse_unix_url_decode_loop:
    mov al, [rsi]
    cmp al, 0
    je parse_unix_decode_done
    cmp al, '%'
    je parse_unix_handle_pct
    stosb
    inc rsi
    dec rcx
    jmp parse_unix_url_decode_loop
parse_unix_handle_pct:
    cmp rcx, 2
    jl parse_unix_err_malformed
    inc rsi
    mov al, [rsi]
    call hex_to_val
    cmp rax, 0xffff
    je parse_unix_err_badhex
    mov bl, al
    inc rsi
    mov al, [rsi]
    call hex_to_val
    cmp rax, 0xffff
    je parse_unix_err_badhex
    mov bh, al
    mov al, bl
    shl al, 4
    or al, bh
    stosb
    dec rcx
    inc rsi
    jmp parse_unix_url_decode_loop
parse_unix_err_badhex:
    mov rax, 10
    jmp parse_unix_done_e
parse_unix_err_malformed:
    mov rax, 9
    jmp parse_unix_done_e
parse_unix_decode_done:
    xor al, al
    stosb
    xor rax, rax
    jmp parse_unix_done
parse_unix_err_nopath:
    mov rax, 5
    jmp parse_unix_done_e
parse_unix_err_relative:
    mov rax, 6
    jmp parse_unix_done_e
parse_unix_err_q:
    mov rax, 7
    jmp parse_unix_done_e
parse_unix_err_f:
    mov rax, 8
parse_unix_done_e:
parse_unix_done:
    pop r12
    ret

hex_to_val:
    cmp al, '0'
    jb hex_to_val_inv
    cmp al, '9'
    jbe hex_to_val_digit
    cmp al, 'A'
    jb hex_to_val_lower
    cmp al, 'F'
    ja hex_to_val_lower
    sub al, 'A'
    add al, 10
    ret
hex_to_val_lower:
    cmp al, 'a'
    jb hex_to_val_inv
    cmp al, 'f'
    ja hex_to_val_inv
    sub al, 'a'
    add al, 10
    ret
hex_to_val_digit:
    sub al, '0'
    ret
hex_to_val_inv:
    mov rax, 0xffff
    ret
parse_port:
    push rsi
    push rdx
    xor rax, rax
    xor rdx, rdx
parse_port_loop:
    mov bl, [rsi]
    cmp bl, 0
    je parse_port_chk
    cmp bl, '0'
    jb parse_port_inv
    cmp bl, '9'
    ja parse_port_inv
    sub bl, '0'
    movzx rcx, bl
    imul rax, rax, 10
    add rax, rcx
    inc rdx
    inc rsi
    jmp parse_port_loop
parse_port_inv:
    xor rax, rax
    jmp parse_port_done
parse_port_chk:
    test rdx, rdx
    jz parse_port_inv
    cmp rax, 65535
    ja parse_port_inv
    cmp rax, 0
    jz parse_port_inv
    ; TODO 2.2: cache the port in network byte order so address construction
    ; does not reparse the textual port.
    movzx eax, ax
    xchg al, ah
    mov [parsed_port_bin], ax
    mov rax, 1
parse_port_done:
    pop rdx
    pop rsi
    ret

; parse_interval(rsi = NUL-terminated decimal) -> rax = 1 and [interval_secs]
; set when the value is an integer in 1..3600, else rax = 0 (TODO 8.5).
; Clobbers bl/rcx; saves rsi.
parse_interval:
    push rsi
    xor rax, rax          ; accumulator
    xor rdx, rdx          ; digit count
parse_interval_loop:
    mov bl, [rsi]
    cmp bl, 0
    je parse_interval_chk
    cmp bl, '0'
    jb parse_interval_inv
    cmp bl, '9'
    ja parse_interval_inv
    sub bl, '0'
    movzx rcx, bl
    imul rax, rax, 10
    add rax, rcx
    cmp rax, 3600         ; a decimal value only grows: reject early so the
    ja parse_interval_inv ; accumulator can never overflow (<= 36009 here)
    inc rdx
    inc rsi
    jmp parse_interval_loop
parse_interval_inv:
    xor rax, rax
    jmp parse_interval_done
parse_interval_chk:
    test rdx, rdx
    jz parse_interval_inv
    test rax, rax
    jz parse_interval_inv ; 0 would busy-loop the send loop
    mov [interval_secs], eax
    mov rax, 1
parse_interval_done:
    pop rsi
    ret

strncmp:
    push rcx
    push rsi
    push rdi
strncmp_loop:
    test rcx, rcx
    jz strncmp_equal
    mov al, [rsi]
    mov bl, [rdi]
    cmp al, bl
    jne strncmp_not_eq
    inc rsi
    inc rdi
    dec rcx
    jmp strncmp_loop
strncmp_equal:
    xor rax, rax
    jmp strncmp_done
strncmp_not_eq:
    mov rax, 1
strncmp_done:
    pop rdi
    pop rsi
    pop rcx
    ret
; --- Address construction (TODO 3.2-3.5) ------------------------------------
; All builders write into sockaddr_buf and set [socklen]. They return 0 on
; success and a nonzero error code on failure:
;   build_unix_addr: ADDR_ERR_PATHLEN (3) = path too long for sun_path
;   build_ipv4_addr: ADDR_ERR_HOST (1) = not a valid dotted-quad numeric
;                    address (this is how unsupported hostnames are detected,
;                    TODO 3.5)
;   build_ipv6_addr: ADDR_ERR_V6 (2) = malformed IPv6 text
;
; v1 scope (TODO 3.5): no DNS resolution. Only numeric IP literals connect;
; udp://localhost:8125 is a deterministic startup error.

; build_unix_addr: sockaddr_un from parsed_path (single source of truth).
build_unix_addr:
    mov rsi, parsed_path
    xor ecx, ecx              ; path length
bua_len:
    mov al, [rsi+rcx]
    test al, al
    jz bua_done
    inc rcx
    jmp bua_len
bua_done:
    cmp rcx, SUN_PATH_MAX - 1 ; leave room for the NUL inside sun_path
    ja bua_toolong
    mov word [sockaddr_buf + SA_OFF_FAMILY], AF_UNIX
    lea rdi, [sockaddr_buf + SUN_OFF_PATH]
    movzx rax, ecx            ; save len: rep movsb zeroes rcx
    rep movsb                 ; copy the path
    mov byte [rdi], 0         ; NUL terminator
    add eax, 3                ; 2 (family) + len + 1 (NUL)
    mov [socklen], ax
    xor rax, rax
    ret
bua_toolong:
    mov rax, ADDR_ERR_PATHLEN
    ret

; build_ipv4_addr: sockaddr_in from parsed_host (dotted quad) and the cached
; binary port. Rejects anything that is not exactly four octets of 0-255.
build_ipv4_addr:
    mov rsi, parsed_host
    xor rbx, rbx              ; octet index 0..3
biva_octet:
    xor r12d, r12d            ; octet value
    xor r13b, r13b            ; digit seen
biva_digits:
    movzx rax, byte [rsi]
    cmp al, '0'
    jb biva_end_octet         ; '.' or NUL ends the octet
    cmp al, '9'
    ja biva_invalid           ; any other char (hostnames) is rejected
    sub al, '0'
    movzx rax, al
    imul r12d, r12d, 10
    add r12d, eax
    mov r13b, 1
    inc rsi
    jmp biva_digits
biva_end_octet:
    test r13b, r13b
    jz biva_invalid           ; empty octet: leading '.', '..', or trailing '.'
    cmp r12d, 255
    ja biva_invalid
    mov al, r12b
    lea r12, [sockaddr_buf + SIN_OFF_ADDR]
    mov [r12+rbx], al
    cmp byte [rsi], '.'
    jne biva_after_octet
    inc rsi                   ; skip the dot
    inc rbx
    cmp rbx, 4
    jae biva_invalid          ; a fifth octet
    jmp biva_octet
biva_after_octet:
    cmp rbx, 3                ; exactly four octets consumed...
    jne biva_invalid
    cmp byte [rsi], 0         ; ...and the string is over (al holds the
                              ; last octet here, not the terminator)
    jnz biva_invalid
    mov word [sockaddr_buf + SA_OFF_FAMILY], AF_INET
    movzx rax, word [parsed_port_bin]
    mov [sockaddr_buf + SIN_OFF_PORT], ax
    mov word [socklen], SOCKADDR_IN_LEN
    xor rax, rax
    ret
biva_invalid:
    mov rax, ADDR_ERR_HOST
    ret

; build_ipv6_addr: sockaddr_in6 from bracketed IPv6 text in parsed_host.
; Supports full 8-group addresses and single "::" compression. Rejects
; everything else (including IPv4-mapped tails) as malformed in v1.
build_ipv6_addr:
    lea rsi, [parsed_host]
    xor r15b, r15b            ; "::" seen
    xor r11d, r11d            ; n_right (tokens after "::")
    lea r8, [rsi]
b6_scan:
    movzx rax, byte [r8]
    test al, al
    jz b6_scan_done
    cmp al, ':'
    jne b6_scan_next
    cmp byte [r8+1], ':'
    jne b6_scan_next
    mov r15b, 1
    sub r8, rsi               ; r8 = offset of "::"
    jmp b6_count_right
b6_scan_next:
    inc r8
    jmp b6_scan
b6_scan_done:
    sub r8, rsi               ; r8 = total length; no compression
    mov r14d, r8d
    lea r8, [rsi + r8]        ; right region start == NUL position
    mov rdi, r8               ; save (empty right region)
    jmp b6_fill_left
b6_count_right:
    mov r14d, r8d             ; left region length
    lea r8, [rsi + r8 + 2]    ; right region start
    mov rdi, r8               ; save; the colon count below walks r8
    xor r11d, r11d
    movzx rax, byte [r8]
    test al, al
    jz b6_fill_left           ; empty right region: 0 tokens
    mov r11d, 1
b6_cr_colons:
    movzx rax, byte [r8]
    test al, al
    jz b6_fill_left
    cmp al, ':'
    je b6_cr_inc
    inc r8
    jmp b6_cr_colons
b6_cr_inc:
    inc r11d
    inc r8
    jmp b6_cr_colons
b6_fill_left:
    lea r9, [rsi]             ; walk the left region
    lea r10, [rsi + r14]      ; its end ("::" start or NUL)
    lea r12, [sockaddr_buf + SIN6_OFF_ADDR]
    xor eax, eax
    mov [r12], rax            ; zero the 16-byte address up front
    mov [r12+8], rax
    xor rbx, rbx              ; n_left
    test r14d, r14d
    jz b6_store_left          ; empty left region (string starts with "::")
    inc rbx                   ; first token
b6_count_colon:
    cmp r9, r10
    jae b6_trail_check
    movzx eax, byte [r9]
    cmp al, ':'
    je b6_count_inc
    inc r9
    jmp b6_count_colon
b6_count_inc:
    inc rbx
    inc r9
    jmp b6_count_colon
b6_trail_check:
    cmp byte [r10 - 1], ':'   ; trailing ':' => empty final group
    je b6_invalid
b6_store_left:
    lea r12, [sockaddr_buf + SIN6_OFF_ADDR]  ; left groups start at the head;
    lea r9, [rsi]                            ; "::" fills the gap to the right
b6_left_tok:
    cmp r9, r10
    jae b6_left_done
    xor r13d, r13d            ; group value
    xor r14b, r14b            ; digit count
b6_left_digit:
    movzx rax, byte [r9]
    test al, al               ; NUL terminates the final group
    jz b6_left_tok_end
    cmp al, ':'
    je b6_left_tok_end
    call hex_to_val
    cmp rax, 0xffff
    je b6_invalid
    shl r13d, 4
    add r13d, eax
    inc r14b
    cmp r14b, 4
    ja b6_invalid             ; more than 4 hex digits
    inc r9
    jmp b6_left_digit
b6_left_tok_end:
    test r14b, r14b
    jz b6_invalid             ; empty group inside the left region
    movzx eax, r13w           ; store the group big-endian
    shr eax, 8
    mov [r12], al
    movzx eax, r13w
    mov [r12+1], al
    add r12, 2
    inc r9                    ; skip the ':' separator
    jmp b6_left_tok
b6_left_done:
    mov r9, rdi               ; right region start (== NUL if no compression)
    xor r10b, r10b            ; "expecting digit" flag (r10 is free now)
    lea r12, [sockaddr_buf + SIN6_OFF_ADDR + 16]
    mov r14d, r11d            ; right block: last 2*n_right bytes
    shl r14d, 1
    sub r12, r14
    jmp b6_right_tok
b6_right_tok:
    movzx rax, byte [r9]
    test al, al
    jz b6_right_nul
    xor r13d, r13d
    xor r14b, r14b
b6_right_digit:
    movzx rax, byte [r9]
    test al, al               ; NUL terminates the final group
    jz b6_right_tok_end
    cmp al, ':'
    je b6_right_tok_end
    call hex_to_val
    cmp rax, 0xffff
    je b6_invalid
    shl r13d, 4
    add r13d, eax
    inc r14b
    cmp r14b, 4
    ja b6_invalid
    inc r9
    jmp b6_right_digit
b6_right_tok_end:
    test r14b, r14b
    jz b6_invalid             ; empty group inside the right region
    movzx eax, r13w           ; store the group big-endian
    shr eax, 8
    mov [r12], al
    movzx eax, r13w
    mov [r12+1], al
    add r12, 2
    movzx rax, byte [r9]
    test al, al
    jz b6_check               ; clean end, no trailing ':'
    inc r9                    ; skip ':'
    mov r10b, 1               ; a digit must follow
    jmp b6_right_tok
b6_right_nul:
    test r10b, r10b
    jnz b6_invalid            ; trailing ':' means an empty final group
    jmp b6_check
b6_check:
    mov eax, ebx              ; n_left + n_right
    add eax, r11d
    test r15b, r15b
    jz b6_check_exact
    cmp eax, 7
    ja b6_invalid             ; compression: "::" covers >= 1 zero group,
                              ; so at most 7 explicit groups
    jmp b6_ok
b6_check_exact:
    cmp eax, 8                ; no compression: exactly 8 groups
    jne b6_invalid
b6_ok:
    mov word [sockaddr_buf + SA_OFF_FAMILY], AF_INET6
    movzx rax, word [parsed_port_bin]
    mov [sockaddr_buf + SIN6_OFF_PORT], ax
    mov dword [sockaddr_buf + SIN6_FLOWINFO], 0
    mov word [socklen], SOCKADDR_IN6_LEN
    xor rax, rax
    ret
b6_invalid:
    mov rax, ADDR_ERR_V6
    ret

; build_addr: dispatch on transport/ipv6 flag. Returns the builder's code.
build_addr:
    cmp byte [parsed_transport], 1
    jne ba_unix
    test byte [parsed_ipv6], 1
    jz ba_ipv4
    call build_ipv6_addr
    ret
ba_ipv4:
    call build_ipv4_addr
    ret
ba_unix:
    call build_unix_addr
    ret

; create_socket (TODO 4.1): open a socket per the parsed transport and store
; the fd in [socket_fd]. Returns 1 on success, 0 on failure ([socket_fd]
; left 0). Address construction is a separate unit: build_addr.
create_socket:
    mov al, [parsed_transport]
    cmp al, 1
    je cs_udp
    cmp al, 2
    je cs_uds_dg
    cmp al, 3
    je cs_uds_str
    xor rax, rax
    ret
cs_udp:
    mov esi, SOCK_DGRAM
    test byte [parsed_ipv6], 1
    jz cs_udp4                ; bracketed host -> AF_INET6 socket
    mov edi, AF_INET6
    jmp cs_syscall
cs_udp4:
    mov edi, AF_INET
    jmp cs_syscall
cs_uds_dg:
    mov edi, AF_UNIX
    mov esi, SOCK_DGRAM
    jmp cs_syscall
cs_uds_str:
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM
cs_syscall:
    xor edx, edx
    mov rax, SYS_socket
    syscall
    test rax, rax
    js cs_fail
    mov [socket_fd], eax
    mov rax, 1
    ret
cs_fail:
    xor rax, rax
    ret

; connect_socket (TODO 4.2): connect([socket_fd]) to the address built by
; build_addr. For UDP this pins the default destination so later sends can
; use write/send and receive ICMP errors; for UDS_STREAM it establishes the
; connection; for UDS_DATAGRAM it pins the peer. Returns 1 on success,
; 0 on failure.
connect_socket:
    mov eax, [socket_fd]
    test eax, eax
    jz conn_fail
    mov edi, eax
    lea rsi, [sockaddr_buf]
    movzx edx, word [socklen]
    mov rax, SYS_connect
    syscall
    test rax, rax
    js conn_fail
    xor rax, rax
    inc rax
    ret
conn_fail:
    xor rax, rax
    ret

; close_socket (TODO 4.4): close([socket_fd]) and clear it. Safe to call
; when no socket is open ([socket_fd] == 0).
close_socket:
    mov eax, [socket_fd]
    test eax, eax
    jz close_done
    mov edi, eax
    mov rax, SYS_close
    syscall
close_done:
    mov dword [socket_fd], 0
    ret

; send_metric_once (TODO 5.2-5.4): write metric_payload over [socket_fd].
; Syscall strategy (TODO 5.2): write(2) — SYS_write = 1, rdi=fd, rsi=buf,
; rdx=len -> rax = bytes written or -errno. Every supported transport is
; connected before sending, so write() reaches the pinned destination on all
; of them; sendto/send would add arguments for no benefit.
; Partial writes (TODO 5.4): stream transports loop until the whole payload
; is out; datagram transports treat any short write as failure — a truncated
; datagram is already on the wire and must not be retried.
; Returns 1 on success, 0 on failure. No logging here (TODO 5.3); the caller
; owns error reporting. [socket_fd] is left untouched on failure.
send_metric_once:
    mov eax, [socket_fd]
    test eax, eax
    jz smo_fail
    lea rsi, [metric_payload]
    mov edx, metric_len
smo_write:
    mov edi, [socket_fd]      ; reload the fd each pass: eax is clobbered by
                              ; the syscall (return value), so it cannot hold
                              ; the fd across iterations
    mov rax, SYS_write
    syscall
    cmp rax, 0
    jle smo_fail              ; signed <= 0: -errno or an anomalous 0-byte
                              ; write. (jbe would be wrong: -errno is a huge
                              ; unsigned value and would fall through here.)
    add rsi, rax              ; advance past the bytes that went out
    sub edx, eax
    jz smo_ok                 ; whole payload sent
    cmp byte [parsed_transport], 3
    jne smo_fail              ; datagram (udp/unix dgram): short write = fail
    jmp smo_write             ; stream: keep writing the remainder
smo_ok:
    mov rax, 1
    ret
smo_fail:
    xor rax, rax
    ret

; sleep_interval (TODO 6.1/6.2): nanosleep for [interval_secs] seconds.
; Chosen over clock_nanosleep (TODO 6.1): we need a relative interval, not an
; absolute monotonic deadline, and nanosleep already hands back the remaining
; time on EINTR, which is all the drift protection this design needs.
; EINTR policy (TODO 6.2): resume the remaining duration (the kernel writes
; it back into sleep_ts) instead of restarting the full interval, so repeated
; interruptions do not accumulate drift.
sleep_interval:
    mov rax, [interval_secs]
    mov [sleep_ts], rax
    xor qword [sleep_ts+8], 0
    lea rdi, [sleep_ts]
sleep_loop:
    mov eax, SYS_nanosleep
    syscall
    cmp rax, -EINTR
    je sleep_loop
    ret
output_success:
    mov rsi, ok_prefix
    call write_str
    mov al, [parsed_transport]
    cmp al, 1
    je output_success_out_udp
    cmp al, 2
    je output_success_out_uds_dg
    cmp al, 3
    je output_success_out_uds_str
output_success_out_udp:
    mov rsi, transport_udp
    call write_str
    cmp byte [parsed_host], 0
    je output_success_udp_no_host
    mov rsi, colon
    call write_str
    mov rsi, parsed_host
    call write_str
    cmp byte [parsed_port], 0
    je output_success_udp_done
    mov rsi, colon
    call write_str
    mov rsi, parsed_port
    call write_str
    jmp output_success_udp_done
output_success_udp_no_host:
    jmp output_success_udp_done
output_success_udp_done:
    mov rsi, newline
    call write_str
    ret
output_success_out_uds_dg:
    mov rsi, transport_uds_dg
    call write_str
    jmp output_success_uds_common
output_success_out_uds_str:
    mov rsi, transport_uds_str
    call write_str
    jmp output_success_uds_common
output_success_uds_common:
    cmp byte [parsed_path], 0
    je output_success_uds_done
    mov rsi, colon
    call write_str
    mov rsi, parsed_path
    call write_str
output_success_uds_done:
    mov rsi, newline
    call write_str
    ret

output_error:
    mov rsi, err_prefix
    call write_str
    mov rsi, rdi
    call write_str
    mov rsi, newline
    call write_str
    ret

write_str:
    push rax
    push rdi
    push rdx
    push r8              ; Save r8
    mov r8, rsi          ; Save original rsi in r8
    mov rdx, 0
write_str_find_len:
    mov al, [rsi]
    test al, al
    jz write_str_found
    inc rdx
    inc rsi
    jmp write_str_find_len
write_str_found:
    mov rsi, r8          ; Restore original rsi
    mov rdi, 1
    mov rax, SYS_write
    syscall
    pop r8
    pop rdx
    pop rdi
    pop rax
    ret

parse_error_msgs:
    dq err_scheme
    dq err_udp_nohost
    dq err_udp_noport
    dq err_udp_port
    dq err_unix_no_path
    dq err_unix_relative
    dq err_unix_query
    dq err_unix_fragment
    dq err_malformed_pct
    dq err_invalid_hex
    dq err_userinfo
    dq err_query
    dq err_fragment
