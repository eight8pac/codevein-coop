"""Find UE native registration entries {const char* name, exec thunk} for given function names in the exe. Read-only.
Usage: python -I natreg.py <exe> Name1 Name2 ..."""
import sys, struct
exe = sys.argv[1]
data = open(exe, 'rb').read()
e = struct.unpack_from('<I', data, 0x3C)[0]
nsec = struct.unpack_from('<H', data, e + 6)[0]
opt = struct.unpack_from('<H', data, e + 20)[0]
base = struct.unpack_from('<Q', data, e + 48)[0]
secs = []
o = e + 24 + opt
for i in range(nsec):
    name = data[o:o + 8].rstrip(b'\0').decode('latin1')
    vsz, va, rsz, raw = struct.unpack_from('<IIII', data, o + 8)
    secs.append((name, va, vsz, raw, rsz))
    o += 40
def off2va(off):
    for n, va, vsz, raw, rsz in secs:
        if raw <= off < raw + rsz: return base + va + (off - raw)
    return None
def va2off(v):
    r = v - base
    for n, va, vsz, raw, rsz in secs:
        if va <= r < va + max(vsz, rsz): return raw + (r - va)
    return None
for nm in sys.argv[2:]:
    key = nm.encode() + b'\0'
    pos = 0
    while True:
        pos = data.find(key, pos)
        if pos < 0: break
        if pos > 0 and data[pos - 1] != 0:   # must be a whole string
            pos += 1; continue
        sva = off2va(pos)
        print('%s: string at 0x%X' % (nm, sva))
        ptr = struct.pack('<Q', sva)
        q = 0
        while True:
            q = data.find(ptr, q)
            if q < 0: break
            nxt = struct.unpack_from('<Q', data, q + 8)[0]
            prv = struct.unpack_from('<Q', data, q - 8)[0]
            print('   referenced at 0x%X: next qword 0x%X, previous qword 0x%X' % (off2va(q), nxt, prv))
            q += 8
        pos += 1
