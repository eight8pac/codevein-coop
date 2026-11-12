"""Find instructions that write a dword/byte at [reg+disp32] for given displacements (read-only). Prints VA and bytes.
Patterns: OR/AND dword [reg+d32], imm8 (83 /1, 83 /4), MOV byte [reg+d32], imm8 (C6 /0), MOV byte [reg+d32], r8 (88 /r), MOV [reg+d32], r32 (89 /r).
Usage: python -I scanoff.py <exe> <disp hex> [<disp hex> ...]"""
import sys, struct
exe = sys.argv[1]
disps = [int(x, 16) for x in sys.argv[2:]]
data = open(exe, 'rb').read()
e = struct.unpack_from('<I', data, 0x3C)[0]
nsec = struct.unpack_from('<H', data, e + 6)[0]
opt = struct.unpack_from('<H', data, e + 20)[0]
base = struct.unpack_from('<Q', data, e + 48)[0]
o = e + 24 + opt
secs = []
for i in range(nsec):
    name = data[o:o + 8].rstrip(b'\0').decode('latin1')
    vsz, va, rsz, raw = struct.unpack_from('<IIII', data, o + 8)
    ch = struct.unpack_from('<I', data, o + 36)[0]
    secs.append((name, va, vsz, raw, rsz, ch))
    o += 40
for d in disps:
    db = struct.pack('<I', d)
    print('== displacement 0x%X' % d)
    for name, va, vsz, raw, rsz, ch in secs:
        if not (ch & 0x20000000): continue          # executable sections only
        blob = data[raw:raw + rsz]
        pos = 0
        while True:
            pos = blob.find(db, pos)
            if pos < 0: break
            hits = []
            # opcode + modrm directly before the disp32 (no SIB): modrm mod=10, rm != 4
            if pos >= 2:
                op, modrm = blob[pos - 2], blob[pos - 1]
                mod, reg, rm = modrm >> 6, (modrm >> 3) & 7, modrm & 7
                if mod == 2 and rm != 4:
                    if op == 0x83 and reg in (1, 4): hits.append(('OR' if reg == 1 else 'AND') + ' dword imm8=0x%02X' % blob[pos + 4])
                    elif op == 0xC6 and reg == 0: hits.append('MOV byte imm8=0x%02X' % blob[pos + 4])
                    elif op == 0x88: hits.append('MOV byte r8')
                    elif op == 0x89: hits.append('MOV dword r32')
                    elif op == 0x80 and reg in (1, 4): hits.append(('OR' if reg == 1 else 'AND') + ' byte imm8=0x%02X' % blob[pos + 4])
            for h in hits:
                v = base + va + pos - 2
                ctx = blob[max(0, pos - 6):pos + 8].hex(' ')
                print('  0x%X %s %s  [%s]' % (v, name, h, ctx))
            pos += 1
