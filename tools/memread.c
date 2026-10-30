// memread <pid> <hexaddr> <len>: print len bytes of another process's memory as hex (read-only; session 10, inspecting the
// running test copy while it hangs and Lua is not running).
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: memread <pid> <hexaddr> <len>\n"); return 2; }
    DWORD pid = (DWORD)strtoul(argv[1], NULL, 10);
    unsigned long long addr = strtoull(argv[2], NULL, 16);
    size_t len = (size_t)strtoul(argv[3], NULL, 0);
    if (len > 4096) len = 4096;
    HANDLE p = OpenProcess(PROCESS_VM_READ, FALSE, pid);
    if (!p) { fprintf(stderr, "OpenProcess failed %lu\n", GetLastError()); return 3; }
    unsigned char buf[4096]; SIZE_T got = 0;
    if (!ReadProcessMemory(p, (LPCVOID)addr, buf, len, &got)) { fprintf(stderr, "read failed %lu\n", GetLastError()); return 4; }
    for (SIZE_T i = 0; i < got; i += 16) {
        printf("%llX:", addr + i);
        for (SIZE_T k = i; k < i + 16 && k < got; k++) printf(" %02X", buf[k]);
        printf("\n");
    }
    CloseHandle(p);
    return 0;
}
