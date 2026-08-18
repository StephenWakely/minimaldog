; Minimal DogStatsD Client - x86-64 Assembly
; Parses DD_DOGSTATSD_URL and creates appropriate socket
; NASM syntax, Linux x86-64

section .data
    env_var_name: db "DD_DOGSTATSD_URL", 0
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
    
    scheme_udp: db "udp://", 0
    scheme_unix: db "unix://", 0
    scheme_unixstream: db "unixstream://", 0
    
    AF_INET equ 2
    AF_INET6 equ 10
    AF_UNIX equ 1
    SOCK_DGRAM equ 1
    SOCK_STREAM equ 2
    IPPROTO_UDP equ 17
    
    SYS_write equ 1
    SYS_exit equ 60
    SYS_getenv equ 318
    SYS_socket equ 41
    SYS_connect equ 42

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
;   send_loop       send metric payload -> sleep for the interval -> repeat.
;                   The first send is immediate after connect (TODO 6.3);
;                   sleeping uses nanosleep (TODO 6.1).
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
; Net: in steady state the only exit is exit(1) on configuration errors.
; (Until the send loop lands, a valid URL still prints OK and exits 0.)
; ---------------------------------------------------------------------------

_start:
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
    call create_socket
    test rax, rax
    jz start_socket_error
    call output_success
    jmp start_exit_success

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

start_socket_error:
    mov rdi, err_socket_create
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
    jb hex_to_val_inv
    cmp al, 'F'
    jbe hex_to_val_upper
    cmp al, 'a'
    jb hex_to_val_inv
    cmp al, 'f'
    ja hex_to_val_inv
hex_to_val_upper:
    sub al, 'A'
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
create_socket:
    mov al, [parsed_transport]
    cmp al, 1
    je create_socket_udp
    cmp al, 2
    je create_socket_uds_dg
    cmp al, 3
    je create_socket_uds_str
    xor rax, rax
    ret
create_socket_udp:
    mov rax, SYS_socket
    mov rdi, AF_INET
    mov rsi, SOCK_DGRAM
    xor rdx, rdx
    syscall
    test rax, rax
    jl create_socket_fail
    mov rax, 1
    ret
create_socket_uds_dg:
    mov rax, SYS_socket
    mov rdi, AF_UNIX
    mov rsi, SOCK_DGRAM
    xor rdx, rdx
    syscall
    test rax, rax
    jl create_socket_fail
    mov rax, 1
    ret
create_socket_uds_str:
    mov rax, SYS_socket
    mov rdi, AF_UNIX
    mov rsi, SOCK_STREAM
    xor rdx, rdx
    syscall
    test rax, rax
    jl create_socket_fail
    mov rax, 1
    ret
create_socket_fail:
    xor rax, rax
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
