"""Find 64-bit writes to a RIP-relative global: mov [rip+d], r64 (48/4C 89 modrm), mov [rip+d], imm32 (48 C7 05 d imm32),
or [rip+d], -1 (48 83 0D d FF), and mov r64, [rip+d] reads (48/4C 8B) for context. Read-only.
Usage: python -I findwrites64.py <exe> <target hex>   (session 10: who sets/clears the frame lock 0x14413C410)"""
import sys, struct
exe, target = sys.argv[1], int(sys.argv[2], 16)
data = open(exe, 'rb').read()
e = struct.unpack_from('<I', data, 0x3C)[0]; nsec = struct.unpack_from('<H', data, e + 6)[0]; opt = struct.unpack_from('<H', data, e + 20)[0]
base = struct.unpack_from('<Q', data, e + 48)[0]; o = e + 24 + opt
pats = [(b'\x48\x89', 'mov [g], r64', 0), (b'\x4c\x89', 'mov [g], r64', 0), (b'\x48\xc7', 'mov [g], imm32', 4),
        (b'\x48\x83', 'op [g], imm8', 1), (b'\x48\x8b', 'read r64, [g]', 0), (b'\x4c\x8b', 'read r64, [g]', 0),
        (b'\x48\x39', 'cmp [g], r64', 0), (b'\x48\x3b', 'cmp r64, [g]', 0), (b'\x48\xff', 'inc/dec [g]', 0)]
for i in range(nsec):
    name = data[o:o + 8].rstrip(b'\0').decode(errors='replace')
    vs, va, rs, ra = struct.unpack_from('<IIII', data, o + 8); o += 40
    if not name.startswith(('.code', '.text', '.xtls')): continue
    sec = data[ra:ra + rs]
    for pat, what, imm in pats:
        p = sec.find(pat)
        while p != -1 and p + 7 + imm <= len(sec):
            modrm = sec[p + 2]
            if (modrm & 0xC7) == 0x05:
                d = struct.unpack_from('<i', sec, p + 3)[0]
                end = base + va + p + 7 + imm
                if end + d == target:
                    extra = ''
                    if pat == b'\x48\x83': extra = ' /%d imm %d' % ((modrm >> 3) & 7, struct.unpack_from('<b', sec, p + 7)[0])
                    if pat == b'\x48\xc7': extra = ' imm %d' % struct.unpack_from('<i', sec, p + 7)[0]
                    print('0x%X %s%s' % (base + va + p, what, extra))
            p = sec.find(pat, p + 1)
