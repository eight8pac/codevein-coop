"""Find vtables containing a function pointer and name their class via MSVC RTTI (read-only).
Usage: python -I vtfind.py <exe> <func va hex> [...]"""
import sys, struct
exe = sys.argv[1]
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
    secs.append((name, va, vsz, raw, rsz, ch)); o += 40
def off2va(off):
    for n, va, vsz, raw, rsz, ch in secs:
        if raw <= off < raw + rsz: return base + va + (off - raw)
def va2off(v):
    r = v - base
    for n, va, vsz, raw, rsz, ch in secs:
        if va <= r < va + rsz: return raw + (r - va)
def is_code(v):
    r = v - base
    for n, va, vsz, raw, rsz, ch in secs:
        if va <= r < va + max(vsz, rsz): return bool(ch & 0x20000000)
    return False
def rtti_name(col_va):
    co = va2off(col_va)
    if co is None: return None
    sig, offs, cdoff, td_rva, chd_rva = struct.unpack_from('<IIIII', data, co)[:5]
    to = va2off(base + td_rva)
    if to is None: return None
    s = data[to + 16:to + 16 + 200].split(b'\0')[0]
    return s.decode('latin1', 'replace')
for a in sys.argv[2:]:
    fv = int(a, 16)
    pat = struct.pack('<Q', fv)
    q = 0
    while True:
        q = data.find(pat, q)
        if q < 0: break
        if q % 8 == 0:
            # walk back to the vtable start (previous qword is not a code pointer = the COL slot)
            s = q
            while True:
                pv = struct.unpack_from('<Q', data, s - 8)[0]
                if is_code(pv): s -= 8
                else: break
            col = struct.unpack_from('<Q', data, s - 8)[0]
            print('0x%X found at 0x%X: vtable 0x%X index %d, class %s' % (fv, off2va(q), off2va(s), (q - s) // 8, rtti_name(col)))
        q += 8
