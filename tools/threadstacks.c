// threadstacks <pid> [out.txt]: for every thread of the process, suspend it for a moment, read RIP and the first 0x2000 bytes of
// its stack, resume it, then print the values that point into the game exe (0x140001000-0x152000000), innermost first. Read-only;
// used on the test copy when the game hangs without a crash (session 9). Nothing is formatted while a thread is suspended.
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdint.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: threadstacks <pid> [out.txt]\n"); return 2; }
    DWORD pid = (DWORD)strtoul(argv[1], NULL, 10);
    FILE *out = argc > 2 ? fopen(argv[2], "w") : stdout;
    if (!out) return 3;
    HANDLE proc = OpenProcess(PROCESS_VM_READ | PROCESS_QUERY_INFORMATION, FALSE, pid);
    if (!proc) { fprintf(stderr, "OpenProcess failed %lu\n", GetLastError()); return 4; }
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    THREADENTRY32 te; te.dwSize = sizeof te;
    static uint64_t buf[0x2000 / 8];
    int shown = 0;
    for (BOOL ok = Thread32First(snap, &te); ok; ok = Thread32Next(snap, &te)) {
        if (te.th32OwnerProcessID != pid) continue;
        HANDLE th = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT, FALSE, te.th32ThreadID);
        if (!th) continue;
        CONTEXT c; memset(&c, 0, sizeof c); c.ContextFlags = CONTEXT_CONTROL | CONTEXT_INTEGER;
        SIZE_T got = 0; BOOL ctx = FALSE;
        if (SuspendThread(th) != (DWORD)-1) {
            ctx = GetThreadContext(th, &c);
            if (ctx) ReadProcessMemory(proc, (LPCVOID)c.Rsp, buf, sizeof buf, &got);
            ResumeThread(th);
        }
        CloseHandle(th);
        if (!ctx) continue;
        int n = 0;
        char line[2048]; int len = snprintf(line, sizeof line, "tid %lu RIP %llX:", te.th32ThreadID, (unsigned long long)c.Rip);
        for (size_t i = 0; i < got / 8 && n < 40; i++) {
            uint64_t v = buf[i];
            if (v >= 0x140001000ULL && v < 0x152000000ULL) { len += snprintf(line + len, sizeof line - len, " %llX", (unsigned long long)v); n++; }
        }
        int rip_in_exe = c.Rip >= 0x140001000ULL && c.Rip < 0x152000000ULL;
        if (n >= 4 || rip_in_exe) { fprintf(out, "%s\n", line); shown++; }
    }
    CloseHandle(snap); CloseHandle(proc);
    fprintf(out, "%d threads with game-code frames\n", shown);
    if (out != stdout) fclose(out);
    return 0;
}
