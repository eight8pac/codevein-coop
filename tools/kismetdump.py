"""Read-only Kismet (Blueprint bytecode) decompiler for cooked UE 4.18 packages: prints every function of an asset as pseudo-code,
with the ubergraph split at its event entry points. On disk an object/property pointer is a 4-byte package index (8 bytes in
memory), an FName 8 bytes; in-memory offsets (used by the event entry points and latent resumes) are tracked for the labels.
Library use: dump(ua_bytes, uexp_bytes) -> (text, calls) where calls = [(function, callee, [arg strings])].
CLI: python -I kismetdump.py <tools dir> <paks dir> <AssetName or path part> [more ...]  (prints to stdout)"""
import sys, os, struct

def fstr(b, o):
    n, = struct.unpack_from('<i', b, o); o += 4
    if n == 0: return '', o
    if n < 0: return b[o:o - n * 2].decode('utf-16-le', 'replace').rstrip('\0'), o - n * 2
    return b[o:o + n].decode('latin-1').rstrip('\0'), o + n

class Pkg:
    def __init__(self, ua, ue):
        o = 20
        nc, = struct.unpack_from('<i', ua, o); o += 4 + nc * 20
        self.total, = struct.unpack_from('<i', ua, o); o += 4
        _, o = fstr(ua, o); o += 4
        name_count, name_off, _a, _b, exp_count, exp_off, imp_count, imp_off = struct.unpack_from('<8i', ua, o)
        q = name_off; self.names = []
        for _ in range(name_count):
            s, q = fstr(ua, q); q += 4; self.names.append(s)
        self.imports = []
        for i in range(imp_count):
            _cp, _, cn, _, outer, on, _ = struct.unpack_from('<iiiiiii', ua, imp_off + i * 28)
            self.imports.append((self.names[cn], self.names[on], outer))
        self.exports = []
        for k in range(exp_count):
            b = exp_off + k * 104
            ci, si, ti, oi, nn, nnum = struct.unpack_from('<iiiiii', ua, b)
            size, off = struct.unpack_from('<qq', ua, b + 28)
            self.exports.append({'cls': ci, 'outer': oi, 'name': self.names[nn] + ('_%d' % (nnum - 1) if nnum else ''), 'size': size, 'off': off - self.total})
        self.ue = ue
    def ref(self, i):
        if i < 0 and -i - 1 < len(self.imports): return self.imports[-i - 1][1]
        if i > 0 and i - 1 < len(self.exports): return self.exports[i - 1]['name']
        return 'null' if i == 0 else '?%d' % i
    def refcls(self, i):
        if i < 0 and -i - 1 < len(self.imports):
            o = self.imports[-i - 1][2]
            return self.ref(o)
        if i > 0 and i - 1 < len(self.exports): return self.ref(self.exports[i - 1]['outer'])
        return ''
    def cls(self, e): return self.ref(e['cls'])
    def name(self, b, o):
        i, n = struct.unpack_from('<ii', b, o)
        s = self.names[i] if 0 <= i < len(self.names) else '?name%d' % i
        return s + ('_%d' % (n - 1) if n else '')

class Dec:
    def __init__(self, pkg, b, start, end):
        self.p, self.b, self.o, self.start, self.end, self.ptrs = pkg, b, start, start, end, 0
        self.calls = []
    def mem(self): return self.o - self.start + 4 * self.ptrs
    def u8(self): v = self.b[self.o]; self.o += 1; return v
    def u16(self): v, = struct.unpack_from('<H', self.b, self.o); self.o += 2; return v
    def i32(self): v, = struct.unpack_from('<i', self.b, self.o); self.o += 4; return v
    def u32(self): v, = struct.unpack_from('<I', self.b, self.o); self.o += 4; return v
    def f32(self): v, = struct.unpack_from('<f', self.b, self.o); self.o += 4; return v
    def ptr(self): self.ptrs += 1; return self.i32()
    def nm(self): s = self.p.name(self.b, self.o); self.o += 8; self.ptrs += 1; return s   # FScriptName: 12 bytes in memory
    def cstr(self):
        e = self.b.index(b'\0', self.o); s = self.b[self.o:e].decode('latin-1'); self.o = e + 1; return s
    def wstr(self):
        e = self.o
        while self.b[e:e + 2] != b'\0\0': e += 2
        s = self.b[self.o:e].decode('utf-16-le', 'replace'); self.o = e + 2; return s
    def params(self):
        a = []
        while True:
            if self.b[self.o] == 0x16: self.o += 1; return a
            a.append(self.expr())
    def until(self, tok):
        a = []
        while True:
            if self.b[self.o] == tok: self.o += 1; return a
            a.append(self.expr())
    def call(self, callee, args, kind):
        self.calls.append((callee, args))
        return '%s(%s)' % (callee, ', '.join(args))
    def expr(self):
        t = self.u8()
        if t in (0x00, 0x01, 0x02, 0x48): return self.p.ref(self.ptr())
        if t == 0x04: return 'return ' + self.expr()
        if t == 0x06: return 'goto %d' % self.u32()
        if t == 0x07: off = self.u32(); return 'if not (%s) goto %d' % (self.expr(), off)
        if t == 0x09: self.u16(); self.u8(); return 'assert(%s)' % self.expr()
        if t == 0x0B: return 'nothing'
        if t == 0x0F: self.ptr(); v = self.expr(); return '%s = %s' % (v, self.expr())
        if t in (0x14, 0x5F, 0x60, 0x43, 0x44): v = self.expr(); return '%s = %s' % (v, self.expr())
        if t in (0x12, 0x19, 0x1A):
            ob = self.expr(); self.u32(); self.ptr(); return '%s.%s' % (ob, self.expr())
        if t in (0x13, 0x2E, 0x52, 0x54, 0x55): c = self.p.ref(self.ptr()); return 'Cast<%s>(%s)' % (c, self.expr())
        if t in (0x15, 0x16, 0x30, 0x32, 0x3A, 0x3C, 0x3E, 0x40, 0x66): return '<end>'
        if t == 0x17: return 'self'
        if t == 0x18: self.u32(); return self.expr()
        if t in (0x1B, 0x45): n = self.nm(); return self.call(n, self.params(), 'v')
        if t in (0x1C, 0x46, 0x68, 0x63):
            f = self.ptr(); n = self.p.ref(f); c = self.p.refcls(f)
            return self.call((c + '.' if c and t != 0x46 else '') + n, self.params(), 'f')
        if t == 0x1D: return str(self.i32())
        if t == 0x1E: return '%g' % self.f32()
        if t == 0x1F: return '"%s"' % self.cstr()
        if t == 0x20: return self.p.ref(self.ptr())
        if t == 0x21: return "'%s'" % self.nm()
        if t in (0x22, 0x23): v = struct.unpack_from('<3f', self.b, self.o); self.o += 12; return '(%g,%g,%g)' % v
        if t == 0x24: return str(self.u8())
        if t == 0x25: return '0'
        if t == 0x26: return '1'
        if t == 0x27: return 'true'
        if t == 0x28: return 'false'
        if t == 0x29:
            k = self.u8()
            if k == 0: return 'text""'
            if k == 1: s = self.expr(); self.expr(); self.expr(); return 'text' + s
            if k in (2, 3): return 'text' + self.expr()
            if k == 4: self.ptr(); a = self.expr(); return 'strtable(%s,%s)' % (a, self.expr())
            return 'text?'
        if t in (0x2A, 0x2D): return 'None'
        if t == 0x2B: self.o += 40; return 'transform'
        if t == 0x2C: return str(self.u8())
        if t == 0x2F:
            s = self.p.ref(self.ptr()); self.i32(); return '%s{%s}' % (s, ', '.join(self.until(0x30)))
        if t == 0x31: arr = self.expr(); return '%s = [%s]' % (arr, ', '.join(self.until(0x32)))
        if t == 0x34: return 'u"%s"' % self.wstr()
        if t in (0x35, 0x36): self.o += 8; return 'int64'
        if t == 0x38: self.u8(); return self.expr()
        if t in (0x39, 0x3B): s = self.expr(); self.i32(); return '%s = {%s}' % (s, ', '.join(self.until(0x3A if t == 0x39 else 0x3C)))
        if t == 0x3D: self.ptr(); self.i32(); return '{%s}' % ', '.join(self.until(0x3E))
        if t == 0x3F: self.ptr(); self.ptr(); self.i32(); return '{%s}' % ', '.join(self.until(0x40))
        if t == 0x42: pr = self.p.ref(self.ptr()); return '%s.%s' % (self.expr(), pr)
        if t == 0x4A: return 'op4A'
        if t == 0x4B: return 'delegate ' + self.nm()
        if t == 0x4C: return 'push_flow %d' % self.u32()
        if t == 0x4D: return 'pop_flow'
        if t == 0x4E: return 'goto computed ' + self.expr()
        if t == 0x4F: return 'pop_flow_if_not(%s)' % self.expr()
        if t in (0x50, 0x5A, 0x5E): return 'trace'
        if t == 0x51: return self.expr()
        if t == 0x53: return '<end of script>'
        if t == 0x5B: return 'skipoffset %d' % self.u32()
        if t in (0x5C, 0x62): d = self.expr(); return '%s += %s' % (d, self.expr())
        if t == 0x5D: return 'clear ' + self.expr()
        if t == 0x61: n = self.nm(); d = self.expr(); return 'bind %s(%s, %s)' % (n, d, self.expr())
        if t == 0x64: pr = self.p.ref(self.ptr()); return '%s = %s' % (pr, self.expr())
        if t == 0x65: self.ptr(); self.i32(); return '[%s]' % ', '.join(self.until(0x66))
        if t == 0x67: return 'soft(%s)' % self.expr()
        if t == 0x69:
            n = self.u16(); self.u32(); ix = self.expr(); cs = []
            for _ in range(n):
                v = self.expr(); self.u32(); cs.append('%s: %s' % (v, self.expr()))
            return 'switch(%s){%s; default: %s}' % (ix, '; '.join(cs), self.expr())
        if t == 0x6A:
            k = self.u8()
            if k == 4: self.nm()
            return 'instr'
        if t == 0x6B: a = self.expr(); return '%s[%s]' % (a, self.expr())
        raise ValueError('unknown token 0x%02X at %d' % (t, self.o - 1))

def skip_props(pkg, b, o):
    while True:
        n = pkg.name(b, o); o += 8
        if n == 'None': return o
        ty = pkg.name(b, o); o += 8
        size, _ = struct.unpack_from('<ii', b, o); o += 8
        if ty == 'StructProperty': o += 8 + 16
        elif ty == 'BoolProperty': o += 1
        elif ty in ('ByteProperty', 'EnumProperty', 'ArrayProperty', 'SetProperty'): o += 8
        elif ty == 'MapProperty': o += 16
        g = b[o]; o += 1
        if g: o += 16
        o += size

def dump(ua, ue):
    p = Pkg(ua, ue)
    funcs = [e for e in p.exports if p.cls(e) == 'Function']
    out, allcalls, entries, bodies = [], [], {}, {}
    for e in funcs:
        try:
            o = skip_props(p, ue, e['off'])
            # Next, SuperStruct, then (this build) the children as an array: count + package indices
            o += 8
            nch, = struct.unpack_from('<i', ue, o); o += 4 + 4 * nch
            _mem, disk = struct.unpack_from('<ii', ue, o); o += 8
            if disk <= 0 or o + disk > e['off'] + e['size'] or ue[o + disk - 1] != 0x53: raise ValueError('bad script size %d' % disk)
            d = Dec(p, ue, o, o + disk); lines = []
            while d.o < d.end:
                m = d.mem(); s = d.expr(); lines.append((m, s))
                if s == '<end of script>': break
            bodies[e['name']] = (lines, d.calls)
        except Exception as ex:
            bodies[e['name']] = ([(0, 'DECODE ERROR: %s' % ex)], [])
    ug = [n for n in bodies if n.startswith('ExecuteUbergraph_')]
    for n, (lines, calls) in bodies.items():
        if n in ug: continue
        for _m, s in lines:
            for u in ug:
                if s.startswith(u + '(') :
                    try: entries.setdefault(u, {})[int(s[len(u) + 1:].split(')')[0])] = n
                    except ValueError: pass
    for n, (lines, calls) in bodies.items():
        if n not in ug and any(s.startswith(tuple(u + '(' for u in ug)) for _m, s in lines) and len(lines) <= 3: continue
        out.append('== function %s' % n)
        ent = entries.get(n, {})
        for m, s in lines:
            if m in ent: out.append('  -- event %s (entry %d)' % (ent[m], m))
            if s in ('<end of script>', 'nothing', 'trace', 'instr'): continue
            out.append('  %5d  %s' % (m, s))
        allcalls += [(n, c, a) for c, a in calls]
    return '\n'.join(out), allcalls

def find_assets(paks, wanted):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import pakv4
    order = sorted([f for f in os.listdir(paks) if f.endswith('.pak')],
                   key=lambda f: (f.replace('_0_P', '').replace('_0_p', ''), '_0_p' in f.lower()))
    src = {}
    for f in order:
        pk = pakv4.Pak(os.path.join(paks, f))
        for n in pk.entries:
            for w in wanted:
                base = n.rsplit('/', 1)[-1]
                if (base == w + '.uasset' or base == w + '.umap' or (('/' in w) and w in n and n.endswith(('.uasset', '.umap')))):
                    src[n] = pk
                if base == w + '.uexp' or (('/' in w) and w in n and n.endswith('.uexp')):
                    src[n] = pk
    res = []
    for n, pk in src.items():
        if n.endswith(('.uasset', '.umap')):
            x = n.rsplit('.', 1)[0] + '.uexp'
            if x in src: res.append((n, pk.read(n), src[x].read(x)))
    return res

if __name__ == '__main__':
    sys.path.insert(0, sys.argv[1])
    for n, ua, ue in find_assets(sys.argv[2], sys.argv[3:]):
        print('#### ' + n.split('Content/', 1)[-1])
        print(dump(ua, ue)[0])
