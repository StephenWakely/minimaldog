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

section .text
    global _start

_start:
    ; Stack at _start: [rsp]=argc, [rsp+8]=argv[0], ..., [rsp+8*(argc+1)]=NULL, then envp
    mov rcx, [rsp]        ; rcx = argc
    lea rsi, [rsp+8]      ; rsi = argv start
    lea rsi, [rsi+rcx*8+8] ; rsi = argv + argc + 1 (skip NULL terminator)
                            ; now rsi points to envp array
find_env_var:
    mov rdi, [rsi]        ; rdi = current env string pointer
    test rdi, rdi
    jz start_not_found
    mov rax, rdi
    mov rdx, env_var_name
    xor rbx, rbx          ; rbx = offset in string
find_env_match:
    mov cl, [rax+rbx]
    mov dl, [rdx+rbx]
    test dl, dl           ; if target char is null terminator
    jz check_equals       ; potential match, check for '='
    cmp cl, dl
    jne next_env_var
    inc rbx
    jmp find_env_match
check_equals:
    mov dl, [rax+rbx]     ; get char after env_var_name
    cmp dl, '='
    jne next_env_var
    jmp found_env_var
next_env_var:
    add rsi, 8
    jmp find_env_var
found_env_var:
    ; rdi points to "VAR=value", find the '='
    mov rax, rdi
    mov rbx, 0
find_equals:
    mov cl, [rax+rbx]
    test cl, cl
    jz start_not_found    ; no '=' found, shouldn't happen
    cmp cl, '='
    je value_found
    inc rbx
    jmp find_equals
value_found:
    lea rdi, [rax+rbx+1]  ; rdi = pointer to value part
    mov rsi, rdi
    mov rdi, url_buf
    mov rcx, 1024
    call copy_string
    mov rdi, rax
    test byte [rdi], 0
    jz start_empty_url
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
    mov rax, 1
    jmp parse_url_done
parse_url_found_udp:
    mov byte [parsed_transport], 1
    add r12, 6
    call parse_udp
    jmp parse_url_done
parse_url_found_unix:
    mov byte [parsed_transport], 2
    add r12, 7
    call parse_unix
    jmp parse_url_done
parse_url_found_unixstream:
    mov byte [parsed_transport], 3
    add r12, 11
    call parse_unix
    jmp parse_url_done
parse_url_done:
    mov rax, r13
    pop r14
    pop r13
    pop r12
    ret
parse_udp:
    push r12
    push r13
    push r14
    mov r13, r12
    mov r14, r12
    cmp byte [r12], '['
    jne parse_udp_ipv4_host
parse_udp_inc_search:
    lodsb
    cmp al, ']'
    je parse_udp_found_bracket
    cmp al, 0
    je parse_udp_err_nohost
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
    mov r12, rsi
    inc r12
    jmp parse_udp_check_colon
parse_udp_err_nohost:
    mov r13, 2
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
    test rdi, rdi
    jz parse_udp_err_nohost
    mov r12, rsi
parse_udp_noport:
    mov r13, 3
    jmp parse_udp_done
parse_udp_check_colon:
    cmp byte [r12], ':'
    jne parse_udp_noport
    inc r12
    mov rsi, r12
    mov rdi, port_buf
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
    mov rsi, port_buf
    call parse_port
    test rax, rax
    jz parse_udp_err_port
    xor rax, rax
    jmp parse_udp_done
parse_udp_err_port:
    mov r13, 4
parse_udp_done:
    pop r14
    pop r13
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
    mov r13, rax
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
    dq 0
    dq err_udp_nohost
    dq err_udp_noport
    dq err_udp_port
    dq err_unix_no_path
    dq err_unix_relative
    dq err_unix_query
    dq err_unix_fragment
    dq err_malformed_pct
    dq err_invalid_hex
