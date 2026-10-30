"""Read a Windows minidump (read-only): exception code/address, the module it lies in, and the crashing thread's stack values that
point into loaded modules (innermost first). Usage: python -I minidump.py <file.dmp>  (session 10: guest join crash)"""
import sys, struct

d = open(sys.argv[1], 'rb').read()
assert d[:4] == b'MDMP', 'not a minidump'
nstreams, dir_rva = struct.unpack_from('<II', d, 8)
streams = {}
for i in range(nstreams):
    t, size, rva = struct.unpack_from('<III', d, dir_rva + i * 12)
    streams.setdefault(t, []).append((size, rva))

def utf16(rva):
    n = struct.unpack_from('<I', d, rva)[0]
    return d[rva + 4: rva + 4 + n].decode('utf-16-le', errors='replace')

modules = []
for size, rva in streams.get(4, []):            # ModuleListStream
    n = struct.unpack_from('<I', d, rva)[0]
    for k in range(n):
        m = rva + 4 + k * 108
        base, msize = struct.unpack_from('<QI', d, m)
        name_rva = struct.unpack_from('<I', d, m + 20)[0]
        modules.append((base, msize, utf16(name_rva).split('\\')[-1]))

def where(a):
    for base, size, name in modules:
        if base <= a < base + size: return '%s+0x%X' % (name, a - base)
    return None

mem = []
for size, rva in streams.get(5, []):            # MemoryListStream
    n = struct.unpack_from('<I', d, rva)[0]
    for k in range(n):
        start, dsize, drva = struct.unpack_from('<QII', d, rva + 4 + k * 16)
        mem.append((start, dsize, drva))
def read(a, n):
    for start, size, rva in mem:
        if start <= a and a + n <= start + size: return d[rva + a - start: rva + a - start + n]
    return None

for size, rva in streams.get(6, []):            # ExceptionStream
    tid = struct.unpack_from('<I', d, rva)[0]
    code, flags, rec, addr = struct.unpack_from('<IIQQ', d, rva + 8)
    nparams = struct.unpack_from('<I', d, rva + 8 + 24)[0]
    params = struct.unpack_from('<15Q', d, rva + 8 + 32)[:nparams]
    ctx_size, ctx_rva = struct.unpack_from('<II', d, rva + 8 + 152)
    print('thread %d exception 0x%08X at 0x%X (%s) params %s' % (tid, code, addr, where(addr), [hex(p) for p in params]))
    rip, = struct.unpack_from('<Q', d, ctx_rva + 0xF8)
    rsp, = struct.unpack_from('<Q', d, ctx_rva + 0x98)
    print('context RIP 0x%X (%s) RSP 0x%X' % (rip, where(rip), rsp))
    stack = read(rsp, 0x2000) or b''
    out = []
    for i in range(0, len(stack) - 7, 8):
        v = struct.unpack_from('<Q', stack, i)[0]
        w = where(v)
        if w and not w.startswith('ntdll') : out.append(w)
        if len(out) >= 40: break
    print('stack (%d bytes read):' % len(stack))
    for w in out: print('  ' + w)
