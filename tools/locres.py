"""Dump a UE4 .locres (versions 0-2) from the paks (latest pak wins) as namespace<TAB>key<TAB>text lines. Read-only.
Usage: python -I locres.py <tools dir> <paks dir> <locres path suffix> <out.tsv>"""
import sys, os, struct
sys.path.insert(0, sys.argv[1]); import pakv4
paks, want, out = sys.argv[2], sys.argv[3], sys.argv[4]
order = sorted([f for f in os.listdir(paks) if f.endswith('.pak')], key=lambda f: (f.replace('_0_P', ''), '_0_P' in f))
data = None
for f in order:
    p = pakv4.Pak(os.path.join(paks, f))
    for n in p.entries:
        if n.endswith(want): data = p.read(n)
def fs(b, o):
    n, = struct.unpack_from('<i', b, o); o += 4
    if n == 0: return '', o
    if n < 0: return b[o:o - 2 * n].decode('utf-16-le', 'replace').rstrip('\0'), o - 2 * n
    return b[o:o + n].decode('latin-1').rstrip('\0'), o + n
o = 16; ver = data[o]; o += 1
soff, = struct.unpack_from('<q', data, o); o += 8
if ver >= 2: o += 4
q = soff; cnt, = struct.unpack_from('<i', data, q); q += 4; strs = []
for _ in range(cnt):
    s, q = fs(data, q)
    if ver >= 2: q += 4
    strs.append(s)
ns_n, = struct.unpack_from('<I', data, o); o += 4
rows = []
for _ in range(ns_n):
    if ver >= 2: o += 4
    ns, o = fs(data, o); kn, = struct.unpack_from('<I', data, o); o += 4
    for _ in range(kn):
        if ver >= 2: o += 4
        k, o = fs(data, o); o += 4; i, = struct.unpack_from('<i', data, o); o += 4
        rows.append((ns, k, strs[i] if 0 <= i < len(strs) else ''))
with open(out, 'w', encoding='utf-8') as w:
    for r in rows: w.write('\t'.join(x.replace('\t', ' ').replace('\r', ' ').replace('\n', ' / ') for x in r) + '\n')
print('version', ver, len(rows), 'entries')
