"""Find RIP-relative instructions (LEA / MOV / CMP ... [rip+disp32]) whose target lies in [lo, hi]: who uses a string or a global.
Read-only. Covers REX.W/REX.R LEA (48/4C 8D), plain and REX MOV loads/stores (8B/89/C7, 48/4C 8B/89), with ModRM mod=00 rm=101.
Usage: python -I findlea.py <exe> <lo hex> <hi hex>"""
import struct, sys, mmap, re
path, lo, hi = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
f = open(path, 'rb'); m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
pe = struct.unpack_from('<I', m, 0x3C)[0]; nsec = struct.unpack_from('<H', m, pe + 6)[0]; optsz = struct.unpack_from('<H', m, pe + 20)[0]
base = struct.unpack_from('<Q', m, pe + 24 + 24)[0]
# REX prefix (optional) + opcode + ModRM with mod 00, rm 101 (rip-relative)
pat = re.compile(rb'[\x48\x4C]?[\x8D\x8B\x89\x3B\x39]([\x05\x0D\x15\x1D\x25\x2D\x35\x3D])', re.S)
hits = 0
for i in range(nsec):
    nm, vsz, va, rsz, rp = struct.unpack_from('<8sIIII', m, pe + 24 + optsz + i * 40)
    ch = struct.unpack_from('<I', m, pe + 24 + optsz + i * 40 + 36)[0]
    if not ch & 0x20000000: continue
    sec = m[rp:rp + rsz]; sva = base + va
    for mt in pat.finditer(sec):
        o = mt.end()                 # disp32 starts after the ModRM byte
        if o + 4 > len(sec): break
        tgt = sva + o + 4 + struct.unpack_from('<i', sec, o)[0]
        if lo <= tgt <= hi:
            hits += 1
            print('0x%X: %s -> 0x%X  (%s)' % (sva + mt.start(), sec[mt.start():o + 4].hex(' '), tgt, nm.rstrip(b'\0').decode()))
print('# %d hit(s)' % hits)
