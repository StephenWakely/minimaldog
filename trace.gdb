set environment DD_DOGSTATSD_URL udp://127.0.0.1:8125
printf "entry=%p\n", (void*)entry
break *0x401030 if ((char*)$rax)[0]=='D' && ((char*)$rax)[1]=='D'
run
printf "AT-LOOP rdx=%p rax=%p\n", (void*)$rdx, (void*)$rax
x/4bx (void*)$rdx
x/10bx 0x40101d
x/16bx (void*)$rdx
