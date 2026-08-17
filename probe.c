/* Verification probe: mirror the asm's envp computation and dump what it sees. */
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    char **envp = argv + argc + 1; /* same as lea rsi,[rsp+8+argc*8+8] */
    printf("argc=%d argv=%p envp=%p\n", argc, (void *)argv, (void *)envp);
    int n = 0, found = 0;
    for (char **e = envp; *e; e++, n++) {
        if (strncmp(*e, "DD_DOGSTATSD_URL", 14) == 0)
            printf("  match at %d: %s\n", n, *e);
        if (strncmp(*e, "DD_DOGSTATSD", 12) == 0)
            found = 1;
    }
    printf("total=%d matched_prefix=%d\n", n, found);
    return 0;
}
