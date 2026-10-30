// memwrite <pid> <hexaddr> <hexbytes>: write bytes into another process (session 10: live test of the appear-lock fix on the
// running test copy). Only for the test copy.
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: memwrite <pid> <hexaddr> <hexbytes>\n"); return 2; }
    DWORD pid = (DWORD)strtoul(argv[1], NULL, 10);
    unsigned long long addr = strtoull(argv[2], NULL, 16);
    size_t n = strlen(argv[3]) / 2;
    if (n == 0 || n > 64) return 3;
    unsigned char buf[64];
    for (size_t i = 0; i < n; i++) { char h[3] = {argv[3][2 * i], argv[3][2 * i + 1], 0}; buf[i] = (unsigned char)strtoul(h, NULL, 16); }
    HANDLE p = OpenProcess(PROCESS_VM_WRITE | PROCESS_VM_OPERATION, FALSE, pid);
    if (!p) { fprintf(stderr, "OpenProcess failed %lu\n", GetLastError()); return 4; }
    SIZE_T done = 0;
    BOOL ok = WriteProcessMemory(p, (LPVOID)addr, buf, n, &done);
    printf("write %s (%zu bytes)\n", ok ? "ok" : "FAILED", (size_t)done);
    CloseHandle(p);
    return ok ? 0 : 5;
}
